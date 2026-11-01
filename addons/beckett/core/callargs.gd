extends RefCounted

## JSON -> Variant coercion for CALL arguments (v1.10.2) and property WRITES (coerce_write). Shared VERBATIM by the
## editor's call_method and set_property (tools/reflection_tools.gd, core/reflection.gd) and the game runtime's
## "call" and "set" commands (runtime/mcp_runtime.gd), so the two sides can never drift apart.
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
## own). A resolver that refuses some objects on purpose (Beckett's own) may also have
## _object_arg_refusal(String) -> String, which says why: the error then carries that sentence
## instead of "could not resolve". Methods without metadata (rare) fall back to raw passthrough.
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
				if resolver.has_method("_object_arg_refusal"):
					var why := str(resolver._object_arg_refusal(rv))
					if not why.is_empty():
						return {"ok": false, "error": "arg %d (%s): %s" % [i, aname, why]}
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
			if raw is String or raw is NodePath:
				return {"ok": true, "value": StringName(_literal_text(str(raw), "&", "StringName"))}
			return _err("expected StringName, got %s" % _show(raw))
		TYPE_NODE_PATH:
			if raw is String or raw is StringName:
				return {"ok": true, "value": NodePath(_literal_text(str(raw), "^", "NodePath"))}
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
		TYPE_RECT2, TYPE_RECT2I, TYPE_TRANSFORM2D, TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_AABB, TYPE_PLANE:
			return _matrix(raw, want)
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
			# Any other value type: accept a Godot literal.
			return _literal(raw, want, 'pass a Godot literal string like "%s(...)"' % type_string(want))
	return _err("expected %s, got %s" % [type_string(want), _show(raw)])


## The value a WRITE to a property stores, made from what JSON carries: {"ok": true, "value": v}, or {"ok": false,
## "error", "suggestion"} naming the type and how to spell one. The one rule for the editor's set_property
## (reflection.gd, value_for_property) and the running game's "set" (mcp_runtime.gd, _coerce_write), so a value takes
## the same spellings on both sides of the bridge, and the ones an argument takes in coerce above: "0 6 11", "0, 6, 11",
## "(0.0, 6.0, 11.0)" (how str() prints a vector), "Vector3(0, 6, 11)", and the arrays a runtime read returns (1.17:
## [0, 6, 11], and for a transform [[x axis], [y axis], [z axis], [origin]]), so a value read back can be written back.
##
## Object.set() refuses nothing. A property given a value of another type gets that type's DEFAULT, and nothing says
## so: "0 6 11" for a position stored Vector3.ZERO, "(5.0, 6.0, 11.0)" lost its first number, "Always" for process_mode
## stored 0 (Inherit) and "maybe" for a bool stored false, and both sides answered that the write had landed. Here a
## value either becomes the type or is refused.
##
## `info` is the property's get_property_list() entry, and the type it declares is the one held to: a property that was
## never written can read null (a shader uniform at its default does), so the value it holds is no guide. A struct
## member (position:y) has no entry ({}), and an untyped script variable declares nothing, so the value they hold
## (`current`) decides there; an untyped variable holding an int also takes a fraction, since it can hold either. A text
## property keeps "[Press Start]" as written, where any other type reads a JSON array or object sent as text.
static func coerce_write(value: Variant, info: Dictionary, current: Variant) -> Dictionary:
	var want := int(info.get("type", TYPE_NIL))
	var untyped := want == TYPE_NIL and not info.is_empty()
	if want == TYPE_NIL:
		want = typeof(current)
	elif want == TYPE_STRING and typeof(current) in [TYPE_STRING_NAME, TYPE_NODE_PATH]:
		# The engine lists some StringName properties as String (theme_type_variation on every Control,
		# NavigationMesh.geometry_source_group_name: 78 of them on 4.6.2), and what they hold is the real type, so
		# &"walkable" is the name walkable there, not those eleven characters.
		want = typeof(current)
	if value is String and not (want in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]):
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	if want == TYPE_NIL:
		return {"ok": true, "value": value}  # nothing declared and nothing held: no type to hold the value to
	if want == TYPE_NODE_PATH and typeof(value) == TYPE_NIL:
		return {"ok": true, "value": NodePath()}  # clearing a path is a real intent
	if want == TYPE_OBJECT:
		if typeof(value) == TYPE_NIL or value is Object:
			return {"ok": true, "value": value}  # null clears the reference, a real intent too
		var leaf := str(info.get("name", ""))
		return {"ok": false, "error": "expected an object - only null (to clear it) can be written to an object property",
			"suggestion": "write one of the object's own properties with a ':' path instead, e.g. %s:<property>" % (leaf if not leaf.is_empty() else "<property>")}
	var r := coerce(value, want)
	if not bool(r.get("ok", false)) and untyped and want == TYPE_INT:
		var as_float := coerce(value, TYPE_FLOAT)
		if bool(as_float.get("ok", false)):
			r = as_float
	if bool(r.get("ok", false)):
		return r
	var choices := enum_choices(info) if want == TYPE_INT else ""
	if not choices.is_empty():
		return {"ok": false, "error": str(r.get("error", "")), "suggestion": "%s is an enum: pass the number of one of %s" % [str(info.get("name", "")), choices]}
	return {"ok": false, "error": str(r.get("error", "")), "suggestion": _write_hint(want)}


## "0 Inherit, 1 Pausable, ..." for a property with an enum hint, "" for any other: an enum takes its number, and a
## refused name ("Always") is answered with the numbers to choose from. The hint lists the names in order, each with
## an optional ":value" (a GDScript enum writes "A:0,B:5"); a name without one counts on from the one before it.
static func enum_choices(info: Dictionary) -> String:
	if int(info.get("hint", PROPERTY_HINT_NONE)) != PROPERTY_HINT_ENUM:
		return ""
	var out: Array = []
	var next := 0
	for item in str(info.get("hint_string", "")).split(",", false):
		var label := item.strip_edges()
		var at := label.rfind(":")
		if at != -1 and label.substr(at + 1).is_valid_int():
			next = label.substr(at + 1).to_int()
			label = label.substr(0, at)
		out.append("%d %s" % [next, label])
		next += 1
	return ", ".join(out)


## The names a vector literal starts with, for literal().
const VECTOR_LITERALS := ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i"]


## The value of a Godot literal that is ONE constructor named in `names` holding nothing but numbers ("Vector3(0, 6,
## 11)", "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 7, 8, 9)": the flat form var_to_str writes for every value type),
## read with str_to_var; null for any other text. str_to_var reads far more than that, and acts on it: a
## Resource("C:/elsewhere/x.json") anywhere in the text LOADS that file from any folder, past the read rule every
## path a tool takes is held to (core/path_guard.gd), and Object(Resource, ...) builds an object. Measured on 4.6.2:
## ExtResource and SubResource load the same way, and so do a space, a line break or a ';' comment before the "(",
## and a Resource inside an array or a dictionary. So no other text reaches it. inf, inf_neg and nan are the words
## var_to_str writes for those floats.
static func literal(text: String, names: Array) -> Variant:
	var s := text.strip_edges()
	var open := s.find("(")
	if open < 1 or not s.ends_with(")") or not names.has(s.left(open).strip_edges()):
		return null
	for part in s.substr(open + 1, s.length() - open - 2).split(","):
		var p := part.strip_edges()
		if not (p.is_valid_float() or p in ["inf", "-inf", "inf_neg", "nan"]):
			return null
	return str_to_var(s)


## A JSON-decoded flag as a bool: the safe spelling of bool(args.get("x", false)).
##
## GDScript 4 has no bool(String). bool("true") is a runtime error ("Nonexistent 'bool'
## constructor", measured on 4.4.1 and 4.7; null, Array, Dictionary and Object fail the same
## way) that aborts the whole handler, and the call comes back as a null result. The argument
## validator lets "true", "false", "1", "0", "yes" and "no" through for a boolean parameter, so
## a lenient client that sends a flag as text used to land exactly there. Accepted: a bool; an
## int or float (nonzero is true, which is all bool(number) ever did); those six strings in any
## case with the space around them ignored. null, "", any other string and every other type give
## `default`: a flag is never an error here, because the validator has already refused a
## top-level value that cannot be a boolean and a nested one (a playtest step, an input event)
## has nobody left to refuse it.
static func to_bool(raw: Variant, default: bool = false) -> bool:
	match typeof(raw):
		TYPE_BOOL:
			return raw
		TYPE_INT, TYPE_FLOAT:
			return raw != 0
		TYPE_STRING, TYPE_STRING_NAME:
			match str(raw).strip_edges().to_lower():
				"true", "1", "yes":
					return true
				"false", "0", "no":
					return false
	return default


## to_bool straight off a dictionary: CallArgs.flag(args, "loop"), CallArgs.flag(args, "validate", true).
## The default is stated once and covers both an absent key and an explicit null, which
## to_bool(args.get("x", true)) would get wrong (a null in a present key skips get()'s default and
## falls to to_bool's own false).
static func flag(d: Dictionary, key: String, default: bool = false) -> bool:
	return to_bool(d.get(key), default)


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
			# A Godot literal ("Vector3(1, 0, 0)") or the components as _components reads them ("1 0 0", "(1.0, 0.0, 0.0)").
			var parsed: Variant = literal(raw, VECTOR_LITERALS)
			match typeof(parsed):
				TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
					return _vec(parsed, dim, as_int)
			var parts := _components(raw)
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


## How many numbers each part of a matrix-family value holds, in the order a runtime read returns them (1.17,
## core/typed_json.gd): a Transform3D is its x, y and z axes and its origin, a Basis its three axes, a Transform2D its x
## and y axes and its origin, a Projection its four columns, a Rect2 or an AABB its position and size, a Plane its normal
## and d. The order of Godot's own constructors: Transform3D(x_axis, y_axis, z_axis, origin).
const MATRIX_PARTS := {
	TYPE_RECT2: [2, 2], TYPE_RECT2I: [2, 2], TYPE_TRANSFORM2D: [2, 2, 2], TYPE_BASIS: [3, 3, 3],
	TYPE_TRANSFORM3D: [3, 3, 3, 3], TYPE_PROJECTION: [4, 4, 4, 4], TYPE_AABB: [3, 3], TYPE_PLANE: [3, 1],
}


## A matrix-family value (MATRIX_PARTS) from what JSON carries: the nested array a runtime read returns ([[1, 0, 0],
## [0, 1, 0], [0, 0, 1], [7, 8, 9]] for a Transform3D, [[0, 1, 0], 2] for a Plane), the same numbers flat and in the same
## order, or a Godot literal ("Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 7, 8, 9)", which var_to_str writes basis row by
## row: the literal is read as the engine reads it, so either spelling lands the same value).
static func _matrix(raw: Variant, want: int) -> Dictionary:
	var f: Variant = null
	if raw is Array:
		f = _matrix_numbers(raw, MATRIX_PARTS[want])
	if f == null:
		return _literal(raw, want, _matrix_hint(want))
	var n: Array = f
	match want:
		TYPE_RECT2:
			return {"ok": true, "value": Rect2(n[0], n[1], n[2], n[3])}
		TYPE_RECT2I:
			return {"ok": true, "value": Rect2i(int(n[0]), int(n[1]), int(n[2]), int(n[3]))}
		TYPE_TRANSFORM2D:
			return {"ok": true, "value": Transform2D(Vector2(n[0], n[1]), Vector2(n[2], n[3]), Vector2(n[4], n[5]))}
		TYPE_BASIS:
			return {"ok": true, "value": Basis(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8]))}
		TYPE_TRANSFORM3D:
			return {"ok": true, "value": Transform3D(Basis(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8])), Vector3(n[9], n[10], n[11]))}
		TYPE_PROJECTION:
			return {"ok": true, "value": Projection(Vector4(n[0], n[1], n[2], n[3]), Vector4(n[4], n[5], n[6], n[7]), Vector4(n[8], n[9], n[10], n[11]), Vector4(n[12], n[13], n[14], n[15]))}
		TYPE_AABB:
			return {"ok": true, "value": AABB(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]))}
	return {"ok": true, "value": Plane(Vector3(n[0], n[1], n[2]), float(n[3]))}


## The numbers of a matrix-family value given as an array, nested or flat (see _matrix), or null when it is neither.
static func _matrix_numbers(raw: Array, parts: Array) -> Variant:
	if raw.size() == _matrix_count(parts) and _all_numbers(raw):
		return raw
	if raw.size() != parts.size():
		return null
	var out: Array = []
	for i in parts.size():
		var part: Variant = raw[i]
		if int(parts[i]) == 1 and (part is int or part is float):
			out.append(part)
		elif part is Array and (part as Array).size() == int(parts[i]) and _all_numbers(part):
			out.append_array(part)
		else:
			return null
	return out


static func _matrix_count(parts: Array) -> int:
	var total := 0
	for p in parts:
		total += int(p)
	return total


## How a matrix-family value is spelled, for a refusal: its nested shape, the flat count and its literal.
static func _matrix_hint(want: int) -> String:
	var shape := "[[normal x, y, z], d]"
	match want:
		TYPE_RECT2, TYPE_RECT2I:
			shape = "[[x, y], [w, h]]"
		TYPE_TRANSFORM2D:
			shape = "[[x axis], [y axis], [origin]], each [x, y]"
		TYPE_BASIS:
			shape = "[[x axis], [y axis], [z axis]], each [x, y, z]"
		TYPE_TRANSFORM3D:
			shape = "[[x axis], [y axis], [z axis], [origin]], each [x, y, z]"
		TYPE_PROJECTION:
			shape = "[[x], [y], [z], [w]], four columns of 4"
		TYPE_AABB:
			shape = "[[position], [size]], each [x, y, z]"
	return 'pass %s, the same %d numbers flat, or "%s(...)"' % [shape, _matrix_count(MATRIX_PARTS[want]), type_string(want)]


static func _color(raw: Variant) -> Dictionary:
	match typeof(raw):
		TYPE_COLOR:
			return {"ok": true, "value": raw}
		TYPE_STRING:
			var c: Variant = _color_text(raw as String)
			if c is Color:
				return {"ok": true, "value": c}
			return _err('expected Color: "%s" is not a hex value, a color name or 3-4 numbers' % (raw as String).strip_edges())
		TYPE_ARRAY:
			var arr := raw as Array
			if (arr.size() == 3 or arr.size() == 4) and _all_numbers(arr):
				return {"ok": true, "value": Color(arr[0], arr[1], arr[2], arr[3] if arr.size() > 3 else 1.0)}
		TYPE_DICTIONARY:
			var d := raw as Dictionary
			if (d.get("r") is int or d.get("r") is float) and (d.get("g") is int or d.get("g") is float) and (d.get("b") is int or d.get("b") is float):
				return {"ok": true, "value": Color(d.get("r"), d.get("g"), d.get("b"), d.get("a", 1.0))}
	return _err('expected Color - pass "#rrggbb", a color name, or [r,g,b,a]')


## A Color from text, or null when the text is none. A hex code or a name ("#ffd900", "gold", "Color.GOLD"), or three
## or four numbers: as GDScript writes them ("Color(1, 0.85, 0, 1)", "Color(1, 0.85, 0)", 'Color("#ffd900")'), as str()
## prints them ("(1, 0.85, 0, 1)", so a value read back can be written back) or bare ("0.14 0.16 0.23 1", the lighting2d
## skill's spelling). Read by hand, not with str_to_var: that reads only the four-number literal, and it loads whatever
## a Resource("...") in the text names, from any folder (measured on 4.6.2).
static func _color_text(text: String) -> Variant:
	var s := text.strip_edges()
	var none := Color(-9999.0, -9999.0, -9999.0, -9999.0)  # what no hex code or name reads as
	var c := Color.from_string(s.trim_prefix("Color."), none)
	if c != none:
		return c
	var inner := s.trim_prefix("Color").strip_edges()
	if inner.begins_with("(") and inner.ends_with(")"):
		inner = inner.substr(1, inner.length() - 2).strip_edges()
	if inner.length() >= 2 and inner.begins_with("\"") and inner.ends_with("\""):  # Color("#ffd900")
		c = Color.from_string(inner.substr(1, inner.length() - 2), none)
		if c == none:
			return null
		return c
	var parts := _components(inner)
	if parts.size() != 3 and parts.size() != 4:
		return null
	var ch: Array = []
	for p in parts:
		if not p.is_valid_float():
			return null
		ch.append(p.to_float())
	return Color(ch[0], ch[1], ch[2], ch[3] if ch.size() == 4 else 1.0)


## What a refused write suggests: the spellings a value of type `want` takes in JSON.
static func _write_hint(want: int) -> String:
	var t := type_string(want)
	match want:
		TYPE_BOOL:
			return 'pass true or false ("true", "false", "yes", "no", 1 and 0 read too)'
		TYPE_INT:
			return 'pass a whole number, such as 3 or "3"'
		TYPE_FLOAT:
			return 'pass a number, such as 0.5 or "0.5"'
		TYPE_STRING:
			return "pass text (a number or a bool is written as its text)"
		TYPE_STRING_NAME:
			return 'pass text, such as "run"'
		TYPE_NODE_PATH:
			return 'pass a node path as text, such as "../Player", or null to clear it'
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 'pass [x, y], "x y", "(x, y)", "%s(x, y)" or {"x": .., "y": ..}' % t
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return 'pass [x, y, z], "x y z", "(x, y, z)", "%s(x, y, z)" or {"x": .., "y": .., "z": ..}' % t
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return 'pass [x, y, z, w], "x y z w", "(x, y, z, w)", "%s(x, y, z, w)" or {"x": .., "y": .., "z": .., "w": ..}' % t
		TYPE_COLOR:
			return 'pass "#rrggbb", a color name such as "gold", [r, g, b] or [r, g, b, a] with channels from 0 to 1, "Color(r, g, b, a)" or {"r": .., "g": .., "b": ..}'
		TYPE_QUATERNION:
			return 'pass 4 numbers as [a, b, c, d], or "%s(...)"' % t
		TYPE_RECT2, TYPE_RECT2I, TYPE_TRANSFORM2D, TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_AABB, TYPE_PLANE:
			return _matrix_hint(want)
		TYPE_ARRAY:
			return "pass a JSON array"
		TYPE_DICTIONARY:
			return "pass a JSON object"
		TYPE_PACKED_VECTOR2_ARRAY:
			return "pass an array of points, each one as a Vector2 takes it: [[x, y], ...]"
		TYPE_PACKED_VECTOR3_ARRAY:
			return "pass an array of points, each one as a Vector3 takes it: [[x, y, z], ...]"
		TYPE_PACKED_COLOR_ARRAY:
			return "pass an array of colors, each one as a Color takes it"
		TYPE_PACKED_STRING_ARRAY:
			return "pass an array of strings"
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return "pass an array of numbers"
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return "a %s cannot be written from JSON: set it from a script" % t
	return 'pass a Godot literal such as "%s(...)", the form var_to_str writes' % t


## The components of a vector or a color written as text, still as text: "1 0 0", "1, 0, 0", or either inside one
## pair of brackets. "(1.0, 0.0, 0.0)" is how str() prints a vector or a Color, and how a runtime read and a runtime
## write's before/after reported one before 1.17 (they return [1, 0, 0] now): text copied from either still writes back.
## "[1, 0, 0]" is a JSON array that arrived as a string.
static func _components(raw: String) -> PackedStringArray:
	var s := raw.strip_edges()
	if s.length() >= 2 and ((s.begins_with("(") and s.ends_with(")")) or (s.begins_with("[") and s.ends_with("]"))):
		s = s.substr(1, s.length() - 2)
	return s.replace(",", " ").split(" ", false)


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
		var parsed: Variant = literal(raw as String, [type_string(want)])
		if typeof(parsed) == want:
			return {"ok": true, "value": parsed}
	return _err("expected %s, got %s - %s" % [type_string(want), _show(raw), hint])


## The path or name a NodePath or StringName literal spells, else `s` as it came. var_to_str and describe_object write
## them as NodePath("../Player") or ^"../Player", and &"run" or StringName("run"), and agents copy them back; a bare
## quoted "../Player" counts too. Wrapped whole, they made a path that resolves nothing. Only text in quotes is read
## this way (or an empty NodePath()), and no node name can hold a quote, so a real path is never taken for a
## literal. Read by hand, not with str_to_var, which loads whatever a Resource("...") in the text names.
static func _literal_text(s: String, sigil: String, ctor: String) -> String:
	var t := s.strip_edges()
	if t.begins_with(sigil + "\""):
		t = t.substr(sigil.length())
	elif t.begins_with(ctor + "(") and t.ends_with(")"):
		t = t.substr(ctor.length() + 1, t.length() - ctor.length() - 2).strip_edges()
		if t.is_empty():
			return ""
	if t.length() >= 2 and t.begins_with("\"") and t.ends_with("\""):
		return t.substr(1, t.length() - 2).c_unescape()
	return s


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
