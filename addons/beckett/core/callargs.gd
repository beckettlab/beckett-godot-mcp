extends RefCounted

## JSON -> Variant coercion for CALL arguments (v1.10.2). Shared VERBATIM by the
## editor's call_method (tools/reflection_tools.gd) and the game runtime's "call"
## command (runtime/mcp_runtime.gd), so the two sides can never drift apart.
##
## Why this exists: Object.callv() with a mis-typed argument does NOT execute the
## method - the engine prints an error to the local console and callv returns null,
## which the tool layer used to report as success. And JSON simply has no Vector /
## Color / StringName types, so without this layer a whole slice of the engine API
## (anything spatial) was impossible to call correctly at all.
##
## Contract: coerce()/prepare() either produce the value in the DECLARED param type
## or fail with a readable error. No best-effort defaults - a value that cannot be
## represented errors instead of collapsing to a zero vector.
##
## HARD CONSTRAINTS on this file:
##  * No editor classes (EditorInterface & co): it is preloaded by the runtime and
##    must parse inside a running game and in export-template builds.
##  * Parse-safe on Godot 4.2+: no 4.3+ constants (e.g. TYPE_PACKED_VECTOR4_ARRAY).


## Coerce every element of raw_args to the declared parameter types of obj.method.
## Returns {"ok": true, "args": Array} or {"ok": false, "error": String}.
## Object-typed params accept a String resolved through `resolver` (any object with
## a _resolve_object_arg(String) -> Object method; editor and runtime each pass their
## own). Methods without metadata (rare) fall back to raw passthrough.
static func prepare(obj: Object, method: String, raw_args: Array, resolver: Object = null) -> Dictionary:
	var meta := _method_meta(obj, method)
	if meta.is_empty():
		return {"ok": true, "args": raw_args}
	var decl: Array = meta.get("args", [])
	var defaults: Array = meta.get("default_args", [])
	var vararg := (int(meta.get("flags", 0)) & METHOD_FLAG_VARARG) != 0
	var required := decl.size() - defaults.size()
	if raw_args.size() < required:
		return {"ok": false, "error": "takes at least %d arg(s), got %d - signature: %s" % [required, raw_args.size(), signature(meta)]}
	if not vararg and raw_args.size() > decl.size():
		return {"ok": false, "error": "takes at most %d arg(s), got %d - signature: %s" % [decl.size(), raw_args.size(), signature(meta)]}
	var out: Array = []
	for i in range(raw_args.size()):
		if i >= decl.size():  # vararg tail: no declared type to coerce to
			out.append(raw_args[i])
			continue
		var a: Dictionary = decl[i]
		var want := int(a.get("type", TYPE_NIL))
		var aname := str(a.get("name", "arg%d" % i))
		if want == TYPE_OBJECT:
			var rv: Variant = raw_args[i]
			if rv == null or typeof(rv) == TYPE_OBJECT:
				out.append(rv)
				continue
			if rv is String and resolver != null and resolver.has_method("_resolve_object_arg"):
				var o: Variant = resolver._resolve_object_arg(rv)
				if o is Object:
					out.append(o)
					continue
				return {"ok": false, "error": "arg %d (%s): could not resolve '%s' to a live object" % [i, aname, str(rv)]}
			var cls := str(a.get("class_name", ""))
			if cls.is_empty():
				cls = "Object"
			return {"ok": false, "error": "arg %d (%s): expected %s - pass a node name/path or res:// path" % [i, aname, cls]}
		var r := coerce(raw_args[i], want)
		if not bool(r.get("ok", false)):
			return {"ok": false, "error": "arg %d (%s): %s" % [i, aname, str(r.get("error", "type mismatch"))]}
		out.append(r["value"])
	return {"ok": true, "args": out}


## Coerce ONE JSON-decoded value to the Variant type `want`.
## Returns {"ok": true, "value": Variant} or {"ok": false, "error": String}.
static func coerce(raw: Variant, want: int) -> Dictionary:
	if want == TYPE_NIL or typeof(raw) == want:  # untyped (Variant) param, or already right
		return {"ok": true, "value": raw}
	match want:
		TYPE_BOOL:
			if raw is int and (raw == 0 or raw == 1):
				return {"ok": true, "value": raw == 1}
			if raw is float and (raw == 0.0 or raw == 1.0):
				return {"ok": true, "value": raw == 1.0}
			if raw is String:
				var s := (raw as String).to_lower()
				if s in ["true", "1", "yes"]:
					return {"ok": true, "value": true}
				if s in ["false", "0", "no"]:
					return {"ok": true, "value": false}
			return _err("expected bool, got %s" % _show(raw))
		TYPE_INT:
			if raw is float:
				if raw == floor(raw):
					return {"ok": true, "value": int(raw)}
				return _err("expected int, got fractional %s" % str(raw))
			if raw is String and (raw as String).strip_edges().is_valid_int():
				return {"ok": true, "value": (raw as String).strip_edges().to_int()}
			return _err("expected int, got %s" % _show(raw))
		TYPE_FLOAT:
			if raw is int:
				return {"ok": true, "value": float(raw)}
			if raw is String and (raw as String).strip_edges().is_valid_float():
				return {"ok": true, "value": (raw as String).strip_edges().to_float()}
			return _err("expected float, got %s" % _show(raw))
		TYPE_STRING:
			if raw is int or raw is float or raw is bool or raw is StringName or raw is NodePath:
				return {"ok": true, "value": str(raw)}
			return _err("expected String, got %s" % _show(raw))
		TYPE_STRING_NAME:
			if raw is String:
				return {"ok": true, "value": StringName(raw)}
			return _err("expected StringName, got %s" % _show(raw))
		TYPE_NODE_PATH:
			if raw is String:
				return {"ok": true, "value": NodePath(raw)}
			return _err("expected NodePath, got %s" % _show(raw))
		TYPE_VECTOR2:
			return _vec(raw, 2, false)
		TYPE_VECTOR2I:
			return _vec(raw, 2, true)
		TYPE_VECTOR3:
			return _vec(raw, 3, false)
		TYPE_VECTOR3I:
			return _vec(raw, 3, true)
		TYPE_VECTOR4:
			return _vec(raw, 4, false)
		TYPE_VECTOR4I:
			return _vec(raw, 4, true)
		TYPE_COLOR:
			return _color(raw)
		TYPE_QUATERNION:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				return {"ok": true, "value": Quaternion(raw[0], raw[1], raw[2], raw[3])}
			return _literal(raw, want, 'pass [x,y,z,w] or "Quaternion(...)"')
		TYPE_RECT2:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				return {"ok": true, "value": Rect2(raw[0], raw[1], raw[2], raw[3])}
			return _literal(raw, want, 'pass [x,y,w,h] or "Rect2(...)"')
		TYPE_RECT2I:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				return {"ok": true, "value": Rect2i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))}
			return _literal(raw, want, 'pass [x,y,w,h] or "Rect2i(...)"')
		TYPE_DICTIONARY:
			return _err("expected Dictionary, got %s" % _show(raw))
		TYPE_ARRAY:
			return _err("expected Array, got %s" % _show(raw))
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return _packed_num(raw, want, true)
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return _packed_num(raw, want, false)
		TYPE_PACKED_STRING_ARRAY:
			if raw is Array:
				var psa := PackedStringArray()
				for e in raw:
					if e is String or e is int or e is float:
						psa.append(str(e))
					else:
						return _err("PackedStringArray element %s is not a string" % _show(e))
				return {"ok": true, "value": psa}
			return _err("expected PackedStringArray - pass a JSON array of strings")
		TYPE_PACKED_VECTOR2_ARRAY:
			return _packed_vec(raw, 2)
		TYPE_PACKED_VECTOR3_ARRAY:
			return _packed_vec(raw, 3)
		TYPE_PACKED_COLOR_ARRAY:
			if raw is Array:
				var pca := PackedColorArray()
				for e in raw:
					var c := _color(e)
					if not bool(c.get("ok", false)):
						return c
					pca.append(c["value"])
				return {"ok": true, "value": pca}
			return _err("expected PackedColorArray - pass a JSON array of colors")
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return _err("%s cannot be passed over JSON" % type_string(want))
		TYPE_OBJECT:
			return _err("object args are resolved by the caller")  # prepare() intercepts first
		_:
			# Transform2D/3D, Basis, Plane, AABB, Projection, ...: accept a Godot literal.
			return _literal(raw, want, 'pass a Godot literal string like "%s(...)"' % type_string(want))
	return _err("expected %s, got %s" % [type_string(want), _show(raw)])


## Human-readable "name(Type arg, ...)" for a get_method_list entry. (Kept local so
## this file stays dependency-free - reflection.gd is editor-only.)
static func signature(meta: Dictionary) -> String:
	var parts: Array = []
	for a in meta.get("args", []):
		var t := int((a as Dictionary).get("type", TYPE_NIL))
		var tn := "Variant"
		if t == TYPE_OBJECT:
			tn = str((a as Dictionary).get("class_name", ""))
			if tn.is_empty():
				tn = "Object"
		elif t != TYPE_NIL:
			tn = type_string(t)
		parts.append("%s %s" % [tn, str((a as Dictionary).get("name", "arg"))])
	return "%s(%s)" % [str(meta.get("name", "?")), ", ".join(parts)]


# ---------------------------------------------------------------- internals

static func _method_meta(obj: Object, method: String) -> Dictionary:
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			return m
	return {}


static func _vec(raw: Variant, dim: int, as_int: bool) -> Dictionary:
	var want_name := "Vector%d%s" % [dim, "i" if as_int else ""]
	var comps: Array = []
	match typeof(raw):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if dim == 2:
				comps = [float(raw.x), float(raw.y)]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			if dim == 3:
				comps = [float(raw.x), float(raw.y), float(raw.z)]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			if dim == 4:
				comps = [float(raw.x), float(raw.y), float(raw.z), float(raw.w)]
		TYPE_ARRAY:
			if (raw as Array).size() != dim:
				return _err("expected %s: the array needs exactly %d numbers, got %d" % [want_name, dim, (raw as Array).size()])
			for e in raw:
				if not (e is int or e is float):
					return _err("expected %s: array element %s is not a number" % [want_name, _show(e)])
				comps.append(float(e))
		TYPE_DICTIONARY:
			for k in (["x", "y", "z", "w"].slice(0, dim)):
				var v: Variant = (raw as Dictionary).get(k)
				if not (v is int or v is float):
					return _err('expected %s: the dict needs a numeric "%s"' % [want_name, k])
				comps.append(float(v))
		TYPE_STRING:
			# A Godot literal ("Vector3(1, 0, 0)") or whitespace/comma components ("1 0 0").
			var parsed: Variant = str_to_var(raw)
			match typeof(parsed):
				TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
					return _vec(parsed, dim, as_int)
			var parts: PackedStringArray = (raw as String).replace(",", " ").split(" ", false)
			if parts.size() == dim:
				for p in parts:
					if not p.is_valid_float():
						return _err("expected %s: '%s' is not a number" % [want_name, p])
					comps.append(p.to_float())
	if comps.size() != dim:
		return _err('expected %s - pass [x,y,..], {"x":..}, or "x y .."' % want_name)
	if dim == 2:
		return {"ok": true, "value": Vector2i(int(comps[0]), int(comps[1])) if as_int else Vector2(comps[0], comps[1])}
	if dim == 3:
		return {"ok": true, "value": Vector3i(int(comps[0]), int(comps[1]), int(comps[2])) if as_int else Vector3(comps[0], comps[1], comps[2])}
	return {"ok": true, "value": Vector4i(int(comps[0]), int(comps[1]), int(comps[2]), int(comps[3])) if as_int else Vector4(comps[0], comps[1], comps[2], comps[3])}


static func _color(raw: Variant) -> Dictionary:
	match typeof(raw):
		TYPE_COLOR:
			return {"ok": true, "value": raw}
		TYPE_STRING:
			var s := (raw as String).strip_edges()
			var sentinel := Color(-9999.0, -9999.0, -9999.0, -9999.0)
			var c := Color.from_string(s, sentinel)
			if c != sentinel:
				return {"ok": true, "value": c}
			var parsed: Variant = str_to_var(s)
			if parsed is Color:
				return {"ok": true, "value": parsed}
			return _err('expected Color: "%s" is not a hex value or color name' % s)
		TYPE_ARRAY:
			var arr := raw as Array
			if (arr.size() == 3 or arr.size() == 4) and _all_numbers(arr):
				return {"ok": true, "value": Color(arr[0], arr[1], arr[2], arr[3] if arr.size() > 3 else 1.0)}
		TYPE_DICTIONARY:
			var d := raw as Dictionary
			if (d.get("r") is int or d.get("r") is float) and (d.get("g") is int or d.get("g") is float) and (d.get("b") is int or d.get("b") is float):
				return {"ok": true, "value": Color(d.get("r"), d.get("g"), d.get("b"), d.get("a", 1.0))}
	return _err('expected Color - pass "#rrggbb", a color name, or [r,g,b,a]')


static func _packed_num(raw: Variant, want: int, as_int: bool) -> Dictionary:
	if not (raw is Array):
		return _err("expected %s - pass a JSON array of numbers" % type_string(want))
	var nums: Array = []
	for e in raw:
		if not (e is int or e is float):
			return _err("%s element %s is not a number" % [type_string(want), _show(e)])
		nums.append(int(e) if as_int else float(e))
	match want:
		TYPE_PACKED_BYTE_ARRAY:
			return {"ok": true, "value": PackedByteArray(nums)}
		TYPE_PACKED_INT32_ARRAY:
			return {"ok": true, "value": PackedInt32Array(nums)}
		TYPE_PACKED_INT64_ARRAY:
			return {"ok": true, "value": PackedInt64Array(nums)}
		TYPE_PACKED_FLOAT32_ARRAY:
			return {"ok": true, "value": PackedFloat32Array(nums)}
	return {"ok": true, "value": PackedFloat64Array(nums)}


static func _packed_vec(raw: Variant, dim: int) -> Dictionary:
	if not (raw is Array):
		return _err("expected a JSON array of [x,y%s] points" % (",z" if dim == 3 else ""))
	var out2 := PackedVector2Array()
	var out3 := PackedVector3Array()
	for e in raw:
		var v := _vec(e, dim, false)
		if not bool(v.get("ok", false)):
			return v
		if dim == 2:
			out2.append(v["value"])
		else:
			out3.append(v["value"])
	return {"ok": true, "value": out2 if dim == 2 else out3}


static func _literal(raw: Variant, want: int, hint: String) -> Dictionary:
	if raw is String:
		var parsed: Variant = str_to_var(raw)
		if typeof(parsed) == want:
			return {"ok": true, "value": parsed}
	return _err("expected %s, got %s - %s" % [type_string(want), _show(raw), hint])


static func _all_numbers(arr: Array) -> bool:
	for e in arr:
		if not (e is int or e is float):
			return false
	return true


static func _show(v: Variant) -> String:
	var s := str(v)
	if s.length() > 48:
		s = s.substr(0, 48) + "..."
	return "%s (%s)" % [s, type_string(typeof(v))]


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
