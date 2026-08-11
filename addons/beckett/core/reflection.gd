@tool
extends RefCounted
class_name BeckettReflect

## Reflection-first substrate (D2). ClassDB + Object introspection, a target
## resolver, and JSON<->Variant coercion (the "hard 20%": vectors, colors,
## resources, enums). This is what lets a handful of generic tools drive any class.


## Resolve a string target to a live Object.
##   "res://path.tscn"/"uid://..."   -> loaded Resource
##   "."/root name                    -> the edited scene root
##   node path or node name           -> a node in the edited scene
## Returns null if nothing matched (callers may then treat it as a class name).
static func resolve(target: String) -> Object:
	if target == null or target.is_empty():
		return null
	if target.begins_with("res://") or target.begins_with("uid://"):
		return ResourceLoader.load(target)
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		if target == "." or target == "/root" or target == root.name:
			return root
		var n := root.get_node_or_null(NodePath(target))
		if n != null:
			return n
		n = root.find_child(target, true, false)
		if n != null:
			return n
		# Walk a path that dips from a node into its resource sub-properties, e.g.
		# "Cube/mesh" or "WorldEnvironment/environment/sky": resolve the longest node
		# prefix, then follow the remaining segments as Object-typed properties. This is
		# what lets `set_property target=Cube/mesh property=size` and friends work — the
		# resolver reaches the embedded sub-resource, not just nodes.
		var walked := _resolve_property_walk(root, target)
		if walked != null:
			return walked
	return null


## Resolve "Node/prop/subprop..." by taking the longest leading node path, then following
## each remaining segment as an Object-valued property. Returns null if no node prefix
## matches or a segment is missing / not an Object (so callers still fail loudly).
static func _resolve_property_walk(root: Node, target: String) -> Object:
	var parts := target.split("/", false)
	if parts.size() < 2:
		return null
	var node: Node = null
	var consumed := 0
	for split_at in range(parts.size() - 1, 0, -1):
		var node_path := "/".join(parts.slice(0, split_at))
		var cand := root.get_node_or_null(NodePath(node_path))
		if cand != null:
			node = cand
			consumed = split_at
			break
	if node == null:
		return null
	var cur: Object = node
	for i in range(consumed, parts.size()):
		var v: Variant = cur.get(parts[i])
		if v is Object:
			cur = v
		else:
			return null
	return cur


## Longer than any real node, class or property name — bounds the DP row on a hostile query.
const NEAREST_MAX_QUERY := 64
## Ceiling on candidates compared. A big scene tree, or the whole ClassDB (968 classes on a
## headless 4.4.1, more in the editor) — both fit, so nothing useful is silently dropped.
const NEAREST_MAX_CANDIDATES := 4000


## Candidates within one typo per four query characters, closest first, at most `limit`.
## Empty when nothing is close: a confident wrong name costs the agent more than a miss.
## Matching is case-insensitive, so a pure case slip ("sprite2d" for "Sprite2D") scores 0
## and wins — that is the commonest miss, not an exotic one.
## The (query, candidates, limit) shape is deliberate: an engine-side fuzzy matcher can
## replace the body without touching a call site. Godot's FuzzySearch is not exposed to
## script on 4.4.1, 4.6.2 or 4.7 (measured), so there is nothing to gate on today.
static func nearest(query: String, candidates: Array, limit: int = 3) -> Array:
	var q := query.strip_edges().to_lower()
	if q.is_empty() or q.length() > NEAREST_MAX_QUERY or candidates.is_empty() or limit <= 0:
		return []
	var budget: int = maxi(1, q.length() / 4)
	# Bucket by distance instead of sorting: the budget is tiny, and this keeps the order
	# stable (closest first, input order within a distance) without a comparator.
	var buckets: Array = []
	for _i in range(budget + 1):
		buckets.append([])
	var seen: Dictionary = {}
	var n: int = mini(candidates.size(), NEAREST_MAX_CANDIDATES)
	for i in range(n):
		var c := str(candidates[i])
		if c.is_empty() or seen.has(c):
			continue
		seen[c] = true
		var lc := c.to_lower()
		# A length gap alone can blow the budget — skip the DP for those, which is most of
		# a real tree or class list.
		if absi(lc.length() - q.length()) > budget:
			continue
		var d := _lev(q, lc)
		if d <= budget:
			buckets[d].append(c)
	var out: Array = []
	for d in range(buckets.size()):
		for c in buckets[d]:
			out.append(c)
			if out.size() >= limit:
				return out
	return out


## Levenshtein distance, two rows instead of a full matrix. Pure GDScript on purpose:
## it behaves identically on every engine from 4.0 up, and it only runs on a miss path.
static func _lev(a: String, b: String) -> int:
	var la := a.length()
	var lb := b.length()
	if la == 0:
		return lb
	if lb == 0:
		return la
	var prev := PackedInt32Array()
	prev.resize(lb + 1)
	var cur := PackedInt32Array()
	cur.resize(lb + 1)
	for j in range(lb + 1):
		prev[j] = j
	for i in range(1, la + 1):
		cur[0] = i
		var ca := a.unicode_at(i - 1)
		for j in range(1, lb + 1):
			var cost := 0 if ca == b.unicode_at(j - 1) else 1
			cur[j] = mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
		var swap := prev
		prev = cur
		cur = swap
	return prev[lb]


## Human-readable signature for a class_get_method_list / get_method_list entry.
static func method_signature(m: Dictionary) -> String:
	var arg_strs: Array = []
	for a in m.get("args", []):
		arg_strs.append("%s %s" % [_type_name(a), str(a.get("name", "arg"))])
	var ret := "void"
	if m.has("return"):
		ret = _type_name(m["return"])
	return "%s %s(%s)" % [ret, str(m.get("name", "?")), ", ".join(arg_strs)]


## Dump an object's editor-facing properties as {name: value} (values JSON-safe).
static func properties_of(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	for p in obj.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		var name: String = p.get("name", "")
		if name.is_empty():
			continue
		out[name] = to_json_safe(obj.get(name))
	return out


## A property-list entry's type as a readable name (handles class hints).
static func _type_name(entry: Dictionary) -> String:
	var t: int = int(entry.get("type", TYPE_NIL))
	if t == TYPE_OBJECT:
		var cn := str(entry.get("class_name", ""))
		return cn if not cn.is_empty() else "Object"
	return type_string(t)


## Make a Variant safe to hand to JSON.stringify (which only knows the JSON types).
static func to_json_safe(v: Variant) -> Variant:
	var t := typeof(v)
	match t:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return v if t != TYPE_STRING_NAME else String(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return {"x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_COLOR:
			return {"r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Resource and not (v as Resource).resource_path.is_empty():
				return {"_object": (v as Resource).resource_path, "class": v.get_class()}
			if v is Node:
				return {"_node": str((v as Node).name), "class": v.get_class()}
			return {"_object": v.get_class()}
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var arr: Array = []
			for e in v:
				arr.append(to_json_safe(e))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in v:
				d[str(k)] = to_json_safe(v[k])
			return d
		_:
			# Vectors/Transforms/etc not special-cased above: stringify the literal.
			return var_to_str(v)


## Coerce an incoming JSON value to the Variant type the target property expects.
## Best-effort: leans on the property's current type, then on str_to_var for literals.
static func coerce_for_property(obj: Object, prop: String, value: Variant) -> Variant:
	var cur: Variant = obj.get(prop)
	var want := typeof(cur)
	# A null/unset property has no live type to mirror — read the declared type from
	# the property list instead, so an unset Vector2/Color export still coerces (e.g.
	# "100 50" -> Vector2). Without this, want stays TYPE_NIL and the value passes
	# through uncoerced.
	if want == TYPE_NIL:
		want = _declared_type(obj, prop)
	return coerce_to_type(value, want)


## The declared Variant type of a property from the object's property list
## (TYPE_NIL if not found). Used when the live value is null and can't be mirrored.
static func _declared_type(obj: Object, prop: String) -> int:
	for p in obj.get_property_list():
		if str(p.get("name", "")) == prop:
			return int(p.get("type", TYPE_NIL))
	return TYPE_NIL


static func coerce_to_type(value: Variant, want: int) -> Variant:
	# MCP clients sometimes JSON-stringify array/object values for an untyped param, so
	# [1, 0.91, 0.78] can arrive as the String "[1, 0.91, 0.78]". Recover the structure
	# before matching, else a Color/Vector falls to the string branch (e.g. Color() black).
	if value is String:
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	var have := typeof(value)
	if have == want:
		return value
	# JSON gives us strings/numbers/bools/arrays/dicts; bridge to Godot types.
	match want:
		TYPE_VECTOR2:
			return _to_vec(value, 2, false)
		TYPE_VECTOR2I:
			return _to_vec(value, 2, true)
		TYPE_VECTOR3:
			return _to_vec(value, 3, false)
		TYPE_VECTOR3I:
			return _to_vec(value, 3, true)
		TYPE_VECTOR4:
			return _to_vec(value, 4, false)
		TYPE_VECTOR4I:
			return _to_vec(value, 4, true)
		TYPE_COLOR:
			if value is String:
				return Color(value)
			if value is Array and value.size() >= 3:
				return Color(value[0], value[1], value[2], value[3] if value.size() > 3 else 1.0)
			if value is Dictionary:
				return Color(value.get("r", 0), value.get("g", 0), value.get("b", 0), value.get("a", 1.0))
			return Color()
		TYPE_INT:
			return int(value) if (value is float or value is String) else value
		TYPE_FLOAT:
			return float(value) if (value is int or value is String) else value
		TYPE_BOOL:
			if value is String:
				return value.to_lower() in ["1", "true", "yes"]
			return bool(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return str(value)
		_:
			# Try a Godot literal (e.g. "Vector3(1, 0, 0)", "&\"name\"", a NodePath).
			if value is String:
				var parsed: Variant = str_to_var(value)
				if parsed != null:
					return parsed
			return value


static func _to_vec(value: Variant, dim: int, as_int: bool) -> Variant:
	var comps: Array = []
	if value is String:
		# Accept a real Godot literal like "Vector2(1, 2)"; but str_to_var("100 50")
		# partial-parses to 100, so only trust it when it yields an actual vector —
		# otherwise fall through to whitespace-separated components.
		var parsed: Variant = str_to_var(value)
		match typeof(parsed):
			TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
				return parsed
		for part in value.split(" ", false):
			comps.append(float(part))
	elif value is Array:
		for e in value:
			comps.append(float(e))
	elif value is Dictionary:
		comps = [value.get("x", 0), value.get("y", 0), value.get("z", 0), value.get("w", 0)]
	while comps.size() < dim:
		comps.append(0.0)
	if dim == 2:
		return Vector2i(comps[0], comps[1]) if as_int else Vector2(comps[0], comps[1])
	if dim == 3:
		return Vector3i(comps[0], comps[1], comps[2]) if as_int else Vector3(comps[0], comps[1], comps[2])
	return Vector4i(comps[0], comps[1], comps[2], comps[3]) if as_int else Vector4(comps[0], comps[1], comps[2], comps[3])
