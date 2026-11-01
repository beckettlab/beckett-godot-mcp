@tool
extends RefCounted
class_name BeckettReflect

## Reflection-first substrate (D2). ClassDB + Object introspection, a target
## resolver, and what a JSON value becomes in a property (the "hard 20%": vectors,
## colors, resources, enums; the conversion itself is CallArgs'). This is what lets
## a handful of generic tools drive any class.


const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # a resource loaded by path is a read like any other
const Internals := preload("res://addons/beckett/core/internals.gd")  # what a tool may never name: Beckett's own objects, and the editor around the open scene
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # call_method's coercion: a property takes text the way an argument does

## The unit suite points this at a scene of its own: a plain engine run has no editor, so no edited scene.
## Nothing else sets it.
static var scene_root_override: Node = null


## The root of the scene open in the editor, or null when there is none (and, outside an editor, null).
static func scene_root() -> Node:
	if scene_root_override != null and is_instance_valid(scene_root_override):
		return scene_root_override
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()


## Resolve a string target to a live Object.
##   "res://path.tscn"/"uid://..."   -> loaded Resource
##   "."/root name                    -> the edited scene root
##   node path or node name           -> a node in the edited scene
##   "Node/prop/subprop"              -> the object a node's property holds, and so on down
##   "Node:prop:subprop"              -> the same, in Godot's own NodePath spelling (see _resolve_subpath)
## Returns null if nothing matched (callers may then treat it as a class name). A resource path the
## read rule refuses (outside the project, or through a link that leaves it) matches nothing, and a
## tool that wants to say why asks PathGuard.check_read for the same path.
##
## Never an object of Beckett's own, and never a node outside the open scene (the editor's panels, the
## plugin nodes, the tree root): those match nothing either, so a tool that forgets to ask why still
## fails closed, and refusal_for / miss say why (internals.gd has the reasons).
static func resolve(target: String) -> Object:
	var obj := _resolve_raw(target)
	if obj != null and not refusal_of(obj).is_empty():
		return null
	return obj


## The node a scene-editing tool means by `target`: "", "." and "/root" and the root's own name are the open
## scene's root; anything else is a path from the root (or an absolute /root/... path to a node of this scene),
## or the first node of that name below it. The same rule as resolve for a node, minus resources and
## sub-resources, and the same answer for what is off limits: null. A target with a ':' is a property path, never
## a node, so it is null too.
static func scene_node(target: String) -> Node:
	var n := _scene_node_raw(target)
	if n != null and not refusal_of(n).is_empty():
		return null
	return n


## Why a tool may not touch `obj`, or "" when it may: one of Beckett's own objects, or a node in the tree that
## is not part of the open scene.
static func refusal_of(obj: Object, what: String = "") -> String:
	return Internals.refusal(obj, scene_root(), what)


## Why `target` is refused, or "" when it is not (it may still match nothing). Resolves again without the
## refusal, which only a miss pays for: a resource path is never the editor's own, so it is not asked.
static func refusal_for(target: String) -> String:
	if target.is_empty() or target.begins_with("res://") or target.begins_with("uid://"):
		return ""
	var obj := _resolve_raw(target)
	if obj == null:
		return ""
	return refusal_of(obj, target)


## The error for a target that matched nothing: the off-limits sentence when it names something a tool may not
## touch, else "Could not resolve <noun>: <target>", plus what a ':' path ran into when it has one.
static func miss(target: String, noun: String = "target") -> String:
	var why := refusal_for(target)
	if not why.is_empty():
		return why
	return "Could not resolve %s: %s%s" % [noun, target, subpath_note(target)]


## What a ':' target that missed ran into, as a clause to append to the miss. "" for a target without a ':', and for
## one whose node part is the miss, which the plain words already cover. Walks the path again: only a miss pays.
static func subpath_note(target: String) -> String:
	var colon := target.find(":")
	if colon <= 0 or target.begins_with("res://") or target.begins_with("uid://"):
		return ""
	var head := target.left(colon)
	var cur: Object = _resolve_raw(head)
	var at := head
	for seg in target.substr(colon + 1).split(":"):
		if cur == null or not refusal_of(cur).is_empty():
			return ""
		if seg.is_empty():
			return " (a ':' with no property name after it)"
		var v: Variant = cur.get(seg)
		if typeof(v) != TYPE_OBJECT or not is_instance_valid(v):
			if typeof(v) != TYPE_NIL and typeof(v) != TYPE_OBJECT:
				return " (%s:%s holds a %s, not an object: pass target=%s and property=%s)" % [at, seg, type_string(typeof(v)), at, seg]
			if has_property(cur, seg):
				return " (%s:%s is null: nothing is assigned there yet)" % [at, seg]
			return " (%s is a %s with no property '%s')" % [at, cur.get_class(), seg]
		cur = v
		at += ":" + seg
	if not refusal_of(cur).is_empty():
		return ""
	# The whole path resolved, so the caller wanted a node and was handed what a property holds.
	return " (a ':' reads a property of %s, and this takes a node path)" % head


## Whether `obj` lists a property of exactly this name. Object.set() on a name it does not list changes nothing
## and says nothing, so a tool that writes asks this first and refuses, instead of reporting a write that never
## landed.
static func has_property(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if str(p.get("name", "")) == prop:
			return true
	return false


## Whether a file keeps obj.prop: the property carries PROPERTY_USAGE_STORAGE. resource_path does not, and neither does a
## script's plain `var`, so no save keeps a write to one, and a NOTE that says "until saved" would be wrong there.
static func is_stored(obj: Object, prop: String) -> bool:
	return (int(_property_entry(obj, prop).get("usage", 0)) & PROPERTY_USAGE_STORAGE) != 0


## The open scene's file: "" when no scene is open, or the open one was never saved (save_scene then needs a path).
static func open_scene_file() -> String:
	var root := scene_root()
	return root.scene_file_path if root != null else ""


static func _scene_node_raw(target: String) -> Node:
	var root := scene_root()
	if root == null:
		return null
	if target.is_empty() or target == "." or target == "/root" or target == root.name:
		return root
	# get_node_or_null drops everything after a ':' and answers with the node before it, so delete_node
	# target=Fx:material deleted Fx. A property path is never a node.
	if target.contains(":"):
		return null
	var n := root.get_node_or_null(NodePath(target))
	if n == null:
		n = root.find_child(target, true, false)
	return n


static func _resolve_raw(target: String) -> Object:
	if target == null or target.is_empty():
		return null
	if target.begins_with("res://") or target.begins_with("uid://"):
		if PathGuard.check_read(target).has("error"):
			return null
		return ResourceLoader.load(target)
	var root := scene_root()
	if root != null:
		# Before any NodePath is made of it: get_node_or_null would drop everything after the ':'.
		var colon := target.find(":")
		if colon != -1:
			return _resolve_subpath(target.left(colon), target.substr(colon + 1))
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
##
## The walk stops at the first object a tool may not touch and returns THAT one, so the caller's refusal
## names it. Without that, a prefix that reaches one of Beckett's nodes and a property that holds its socket
## (".../BeckettRuntimeBridge/_peer") would hand back an object that carries no Beckett script of its own, and
## put_data on it would write straight into the game's channel past everything send_command checks.
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
	if not refusal_of(cur).is_empty():
		return cur
	for i in range(consumed, parts.size()):
		var v: Variant = cur.get(parts[i])
		if v is Object:
			cur = v
			if not refusal_of(cur).is_empty():
				return cur
		else:
			return null
	return cur


## Resolve "Fx:material" and "Fx:material:shader", Godot's own spelling for an object a node holds in a property
## (a NodePath's subnames, as Node.get_node_and_resource and an AnimationPlayer track read them). `head`, the part
## before the first ':', is anything this resolver takes on its own: a path, a name, a "/" walk. Each ':' segment
## after it is one property name, whole, so "Mesh:surface_material_override/0" reaches a slot the "/" walk splits
## in two. get_node_or_null drops the subnames and answers with the node, so a ':' target used to BE the node:
## describe_object target=Ground:material_override described the MeshInstance3D (seen live on 4.6.2), and
## set_resource target=Fx:material property=shader reported a Shader assigned to a Sprite2D, which has no shader.
##
## Every segment has to hold an object or nothing matches, never the object before it. The walk stops at the first
## object a tool may not touch and returns that one, as the "/" walk does, so the caller's refusal names it.
static func _resolve_subpath(head: String, tail: String) -> Object:
	if head.is_empty():
		return null
	var cur: Object = _resolve_raw(head)
	if cur == null or not refusal_of(cur).is_empty():
		return cur
	for seg in tail.split(":"):
		if seg.is_empty():
			return null
		var v: Variant = cur.get(seg)
		if typeof(v) != TYPE_OBJECT or not is_instance_valid(v):
			return null
		cur = v
		if not refusal_of(cur).is_empty():
			return cur
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


## What a tool that WRITES obj.prop stores for `value`, as JSON carried it: {"value": v}, plus "note" when v was read
## from a file outside the project (PathGuard.check_read's note, for PathGuard.noted), or {"error", "suggestion"} when
## nothing that fits can be made of it. Object.set() does not refuse a value of the wrong type: the setter gets the
## type's default instead. So "res://icon.svg" given as text emptied a Sprite2D's texture, "Color(1, 0.85, 0, 1)" was
## stored as black, "(5.0, 6.0, 11.0)" (how str() prints a vector) became (0, 6, 11), "1 2" for a Vector3 was padded
## to (1, 2, 0), "Always" for process_mode became 0, and set_property said each had been set (seen live on 4.6.2,
## 2026-10-08). Here a property that holds an object takes a res:// or uid:// path, loaded under the read rule as
## set_resource loads one (a node-typed one takes a node's path), or null; any other value goes through
## CallArgs.coerce_write, the rule the running game's runtime_set_property keeps too: converted to the type the property
## declares, or refused, naming that type and how to spell one (an enum's numbers, for an enum).
static func value_for_property(obj: Object, prop: String, value: Variant) -> Dictionary:
	var entry := _property_entry(obj, prop)
	var current: Variant = obj.get(prop)
	var declared := int(entry.get("type", TYPE_NIL))
	# An untyped variable holding an object is held to it as an object, the way coerce_write holds it.
	if declared == TYPE_OBJECT or (declared == TYPE_NIL and typeof(current) == TYPE_OBJECT):
		return _object_value(obj, prop, entry, value)
	var fit := CallArgs.coerce_write(value, entry, current)
	if not bool(fit.get("ok", false)):
		return {"error": "%s.%s: %s" % [obj.get_class(), prop, str(fit["error"])], "suggestion": str(fit["suggestion"])}
	return {"value": fit["value"]}


## value_for_property for a property PATH, as set_indexed and an animation track spell one: "material_override:albedo_color"
## ends on a property of the object a property holds, and is held to the type that property declares; "modulate:a" and
## "position:x" end on a member of the value a property holds, and are held to the type of what that member holds. {}
## when the path names no property, so the caller's write goes ahead as it would have (Object.set ignores a name it does
## not know, and a script's _set may take one it does not list).
static func value_for_path(obj: Object, path: String, value: Variant) -> Dictionary:
	var parts := path.split(":", false)
	var cur: Object = obj
	for i in parts.size():
		var seg := parts[i]
		if not has_property(cur, seg):
			return {}
		if i == parts.size() - 1:
			return value_for_property(cur, seg, value)
		var held: Variant = cur.get(seg)
		if typeof(held) == TYPE_NIL:
			return {}  # nothing there to index into
		if typeof(held) != TYPE_OBJECT:
			var fit := CallArgs.coerce_write(value, {}, obj.get_indexed(NodePath(path)))
			if not bool(fit.get("ok", false)):
				return {"error": "%s.%s: %s" % [obj.get_class(), path, str(fit["error"])], "suggestion": str(fit["suggestion"])}
			return {"value": fit["value"]}
		if not is_instance_valid(held):
			return {}
		cur = held
	return {}


## What `value` becomes in obj.prop, a property declared to hold an object (`entry` is its property-list entry). Only
## null or an object of a class it takes can go there: anything else reaches a native setter as null, which empties it.
static func _object_value(obj: Object, prop: String, entry: Dictionary, value: Variant) -> Dictionary:
	if typeof(value) == TYPE_NIL:
		return {"value": null}  # emptying it is a real intent
	var takes := _classes_taken(entry)
	var what := "%s.%s takes %s" % [obj.get_class(), prop, ("a " + " or ".join(takes)) if not takes.is_empty() else "an object"]
	if not (value is String and ((value as String).begins_with("res://") or (value as String).begins_with("uid://"))):
		if value is String and _takes_node(entry, takes):
			return _node_value(obj, what, takes, value)
		return {"error": "%s, and %s is not a res:// or uid:// path: nothing was written" % [what, JSON.stringify(value)],
			"suggestion": "Pass a res:// path to load a resource into it, or null to empty it (set_resource property=%s resource=res://... does the same, and class=<Class> makes a new inline one)." % prop}
	var path: String = value
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	# attach_script's rule: a file of Beckett's own does not go into the project's scenes and resources. A script of
	# Beckett's on a node is one more of its internals, and set_property save=true would write the reference to a file.
	if Internals.is_beckett_path(path):
		return {"error": Internals.file_text(path)}
	if not ResourceLoader.exists(path):
		return {"error": "No resource at: %s" % path}
	var res := ResourceLoader.load(path)
	if res == null:
		return {"error": "Could not load %s" % path}
	if Internals.is_beckett_path(res.resource_path):  # a uid:// or another spelling of one
		return {"error": Internals.file_text(path)}
	if not _is_one_of(res, takes):
		return {"error": "%s, and %s is a %s: nothing was written" % [what, path, res.get_class()]}
	var out := {"value": res}
	if guard.has("note"):
		out["note"] = guard["note"]
	return out


## Whether an object property holds a node (an `@export var follow: Node3D`) rather than a resource.
static func _takes_node(entry: Dictionary, takes: PackedStringArray) -> bool:
	if int(entry.get("hint", PROPERTY_HINT_NONE)) == PROPERTY_HINT_NODE_TYPE:
		return true
	for cls in takes:
		if ClassDB.class_exists(cls) and ClassDB.is_parent_class(cls, "Node"):
			return true
	return false


## The node a node-typed property is given by path: read from the node that holds the property first ("../Player", the
## way a NodePath export spells it), then the way a target is read (a path from the scene root, or a name). Only a node
## of the open scene, of a class the property takes. A path used to reach the setter as text, which empties the
## property, and the reply said it was set.
static func _node_value(obj: Object, what: String, takes: PackedStringArray, path: String) -> Dictionary:
	var how := "Pass the node's path from this node (\"../Player\"), from the scene root (\"Main/Player\") or its name, or null to empty it."
	if path.strip_edges().is_empty():
		return {"error": "%s, and \"\" names no node: nothing was written" % what, "suggestion": how}
	var found: Node = null
	if obj is Node and not path.contains(":"):
		found = (obj as Node).get_node_or_null(NodePath(path))
		if found != null and not refusal_of(found).is_empty():
			return {"error": refusal_of(found, path)}
	if found == null:
		found = scene_node(path)
	if found == null:
		var why := refusal_for(path)
		if not why.is_empty():
			return {"error": why}
		return {"error": "%s, and no node of the open scene is at %s: nothing was written" % [what, JSON.stringify(path)], "suggestion": how}
	if not _is_one_of(found, takes):
		return {"error": "%s, and %s is a %s: nothing was written" % [what, path, found.get_class()], "suggestion": how}
	return {"value": found}


## The classes an object property takes, as its property-list entry names them: ["Texture2D"], or ["BaseMaterial3D",
## "ShaderMaterial"] for a material slot. Empty when it names none, and then any object fits.
static func _classes_taken(entry: Dictionary) -> PackedStringArray:
	var names := str(entry.get("class_name", ""))
	# A script's _get_property_list may give the hint alone, and so does the editor's stand-in for a script that is not
	# @tool: its `@export var follow: Node3D` names Node3D in the hint only, and a Sprite2D got through (live, 4.6.2).
	if names.is_empty() and int(entry.get("hint", PROPERTY_HINT_NONE)) in [PROPERTY_HINT_RESOURCE_TYPE, PROPERTY_HINT_NODE_TYPE]:
		names = str(entry.get("hint_string", ""))
	var out := PackedStringArray()
	for n in names.split(","):
		if not n.strip_edges().is_empty():
			out.append(n.strip_edges())
	return out


## Whether `o` is one of `takes`: an engine class it is or inherits, or a project class_name its script is or extends
## (an `@export var item: ItemData` takes a Resource that runs ItemData, which is_class does not know about).
static func _is_one_of(o: Object, takes: PackedStringArray) -> bool:
	if takes.is_empty():
		return true
	var scripts: Array = []
	var s: Variant = o.get_script()
	while s is Script:
		scripts.append((s as Script).resource_path)
		s = (s as Script).get_base_script()
	for cls in takes:
		if o.is_class(cls):
			return true
		for e in ProjectSettings.get_global_class_list():
			if str(e.get("class", "")) == cls and scripts.has(str(e.get("path", ""))):
				return true
	return false


## Read obj.prop back after a write of `wanted` over `before`, as the runtime's "set" does. Object.set() says nothing
## when a value is refused (a typed script variable keeps what it had, a name the object does not know changes
## nothing) or changed on the way in (a setter that clamps), and the replies quoted the value sent, not the one stored.
## {"value": what it holds now} when the write landed, with "note" when that is not quite what was written;
## {"error", "suggestion"} when it still holds `before`.
static func readback(obj: Object, prop: String, before: Variant, wanted: Variant) -> Dictionary:
	var after: Variant = obj.get(prop)
	if same_value(after, wanted):
		return {"value": after}
	if not same_value(after, before):
		return {"value": after, "note": "it reads back as %s, not %s as written: the property changed it on the way in (a setter that clamps or rounds, or a conversion to its type)" % [shown(after), shown(wanted)]}
	if _property_entry(obj, prop).is_empty():
		return {"error": "%s has no property '%s'" % [obj.get_class(), prop],
			"suggestion": "describe_class class=%s lists its properties. One that only appears once another is set (a ShaderMaterial's shader_parameter/*, after its shader) has to be set after it." % obj.get_class()}
	return {"error": "write did not stick: %s.%s is still %s (wanted %s)" % [obj.get_class(), prop, shown(after), shown(wanted)],
		"suggestion": "The property kept its value: it may be read-only, or a setter in its script refuses or ignores this value."}


const _TEXT_TYPES := [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]


## Whether a value read back is the one written. Numbers, vectors, colors and transforms within float error (0.1 stored
## in 32 bits reads back as 0.100000001, and that write did land); text by its characters, whatever its type (a String
## written to a StringName property reads back as a StringName); arrays element by element (a JSON array written to a
## typed or packed one reads back converted); dictionaries key by key.
static func same_value(a: Variant, b: Variant) -> bool:
	if a == null and b == null:  # an emptied object property reads back as a null Object, not as the Nil written
		return true
	var ta := typeof(a)
	var tb := typeof(b)
	if ta == TYPE_INT and tb == TYPE_INT:
		return a == b
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return is_equal_approx(float(a), float(b))
	if ta in _TEXT_TYPES and tb in _TEXT_TYPES:
		return str(a) == str(b)
	if ta >= TYPE_ARRAY and tb >= TYPE_ARRAY:  # Array and then every packed array: the last entries of Variant.Type
		if a.size() != b.size():
			return false
		for i in a.size():
			if not same_value(a[i], b[i]):
				return false
		return true
	if ta != tb:
		return false
	match ta:
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_QUATERNION, TYPE_PLANE, TYPE_RECT2, TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D:
			return a.is_equal_approx(b)
		TYPE_DICTIONARY:
			if a.size() != b.size():
				return false
			for k in a:
				if not b.has(k) or not same_value(a[k], b[k]):
					return false
			return true
	return a == b


## Packed arrays longer than this compare natively (==): both sides come from the same file format, and same_value's
## element-by-element walk would cost a mesh's worth of GDScript calls.
const _STORED_NATIVE_FROM := 1024
## How many resources deep same_stored looks into two resources that have no file of their own, and how many such pairs
## one comparison looks at: past either it takes the rest as the same, so a change that deep is written without being
## named. Far past real files (a sky material is two parts down); the limits are there for a cycle and for the stack.
const _STORED_DEPTH := 16
const _STORED_PAIRS := 4096


## same_value for a value as a FILE stores it, so a copy loaded from the file compares equal to the editor's. A resource
## with a file of its own by its path (a load shares those). Two that have none, parts of a file ('file::id': a load
## makes new objects for them) or resources with no path (a getter that builds a new one on every read, such as an
## ImageTexture's image), by their class and what they store, so a change inside a part counts. Arrays and dictionaries
## element by element.
static func same_stored(a: Variant, b: Variant) -> bool:
	return _same_stored(a, b, 0, {})


## same_stored under one comparison's state, `ctx` (stored_differences sets it up): the pairs met so far, and the
## property it leaves out. A fresh dictionary per comparison, never a default argument an engine could fold read-only.
static func _same_stored(a: Variant, b: Variant, depth: int, ctx: Dictionary) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta == TYPE_OBJECT and tb == TYPE_OBJECT:
		if a == b:
			return true
		if not (is_instance_valid(a) and is_instance_valid(b) and a is Resource and b is Resource):
			return false
		if not (_inline(a) and _inline(b)):
			return (a as Resource).resource_path == (b as Resource).resource_path
		return _content_differences(a, b, depth, ctx, true).is_empty()
	if ta == TYPE_ARRAY and tb == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same_stored(a[i], b[i], depth, ctx):
				return false
		return true
	if ta == TYPE_DICTIONARY and tb == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _same_stored(a[k], b[k], depth, ctx):
				return false
		return true
	if ta == tb and ta > TYPE_ARRAY and a.size() > _STORED_NATIVE_FROM:
		return a == b
	return same_value(a, b)


## The stored properties of `a` whose value differs from the same property of `b` (a copy loaded from a's file): what
## saving `a` writes over the file. A difference inside a part of the file that a property holds is named by its path
## from `a` ("sky:radiance_size"); one inside an array or a dictionary, or a part replaced by a new one, by the property.
## `skip` is left out on `skip_in` (`a` when null), wherever that object is met: the property being written.
static func stored_differences(a: Object, b: Object, skip: String = "", skip_in: Object = null) -> Array:
	if a == null or b == null:
		return []
	var ctx := {"skip": skip, "skip_in": (a if skip_in == null else skip_in).get_instance_id()}
	return _differences(a, b, 0, ctx, false)


## stored_differences under one comparison's state; `first` stops at the first difference (same_stored needs no more).
## b's property list is read first because a ShaderMaterial answers a uniform only after it listed it.
static func _differences(a: Object, b: Object, depth: int, ctx: Dictionary, first: bool) -> Array:
	var out: Array = []
	var listed := {}
	for p in b.get_property_list():
		listed[str(p.get("name", ""))] = true
	var skip := str(ctx.get("skip", "")) if a.get_instance_id() == int(ctx.get("skip_in", 0)) else ""
	for p in a.get_property_list():
		var name := str(p.get("name", ""))
		if name.is_empty() or name == skip or (int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		if not listed.has(name):
			out.append(name)
		else:
			var va: Variant = a.get(name)
			var vb: Variant = b.get(name)
			if not first and _part_pair(va, vb):
				for inner in _content_differences(va, vb, depth, ctx, false):
					out.append(name if str(inner).is_empty() else "%s:%s" % [name, inner])
			elif not _same_stored(va, vb, depth, ctx):
				out.append(name)
		if first and not out.is_empty():
			break
	return out


## No file of its own: a part of one ('file::id'), or no path at all.
static func _inline(r: Resource) -> bool:
	return r.resource_path.is_empty() or r.resource_path.contains("::")


## Two copies of one part of a file, the pair stored_differences names a difference inside.
static func _part_pair(a: Variant, b: Variant) -> bool:
	if typeof(a) != TYPE_OBJECT or typeof(b) != TYPE_OBJECT or a == b or not (is_instance_valid(a) and is_instance_valid(b)):
		return false
	return a is Resource and b is Resource and (a as Resource).resource_path.contains("::") and (b as Resource).resource_path.contains("::")


## What differs between two resources compared by what they store, as _differences lists it: [""] when they differ as a
## whole (another class). A pair met before answers from then (one still being compared, a cycle, counts as the same),
## so a part held in two places is compared once; past the limits, the same.
static func _content_differences(a: Resource, b: Resource, depth: int, ctx: Dictionary, first: bool) -> Array:
	if a.get_class() != b.get_class():
		return [""]
	if not ctx.has("pairs"):
		ctx["pairs"] = {}
	var pairs: Dictionary = ctx["pairs"]  # "<id a>:<id b>" -> whether they differ
	var key := "%d:%d" % [a.get_instance_id(), b.get_instance_id()]
	if pairs.has(key):
		return [""] if bool(pairs[key]) else []
	if depth >= _STORED_DEPTH or pairs.size() >= _STORED_PAIRS:
		return []
	pairs[key] = false
	var found := _differences(a, b, depth + 1, ctx, first)
	pairs[key] = not found.is_empty()
	return found


## The resource stored inside root's own file whose resource_path is `path` ('file::id'), or null. Breadth first over
## stored properties only: one declared as a value or a packed array holds no resource (and reading it copies it), a
## resource with a file of its own is another file and is never entered, arrays and dictionaries (keys and values) are
## entered four levels deep, and a cycle or a huge file stops at `cap` resources.
static func embedded_by_path(root: Resource, path: String, cap: int = 4096) -> Resource:
	if root == null or path.is_empty():
		return null
	if root.resource_path == path:
		return root
	var queue: Array = [root]
	var seen := {root.get_instance_id(): true}
	var visited := 0
	while not queue.is_empty() and visited < cap:
		var cur: Object = queue.pop_front()
		visited += 1
		for p in cur.get_property_list():
			if (int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
				continue
			if not (int(p.get("type", TYPE_NIL)) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_NIL]):
				continue
			var found := _embedded_in(cur.get(str(p.get("name", ""))), path, queue, seen, 0)
			if found != null:
				return found
	return null


static func _embedded_in(v: Variant, path: String, queue: Array, seen: Dictionary, depth: int) -> Resource:
	match typeof(v):
		TYPE_OBJECT:
			if not is_instance_valid(v) or not (v is Resource):
				return null
			var r := v as Resource
			if r.resource_path == path:
				return r
			if seen.has(r.get_instance_id()):
				return null
			seen[r.get_instance_id()] = true
			if r.resource_path.is_empty() or r.resource_path.contains("::"):
				queue.append(r)
		TYPE_ARRAY:
			if depth < 4:
				for e in v:
					var f := _embedded_in(e, path, queue, seen, depth + 1)
					if f != null:
						return f
		TYPE_DICTIONARY:
			if depth < 4:
				for k in v:
					var fk := _embedded_in(k, path, queue, seen, depth + 1)
					if fk != null:
						return fk
					var fv := _embedded_in(v[k], path, queue, seen, depth + 1)
					if fv != null:
						return fv
	return null


## A value as a reply quotes it: a saved resource by its path, a node of the open scene by its path from the root and
## its class, any other object by its class, nothing as null (a null Object as well, which str() prints as
## <Object#null>), and empty text as its literal (NodePath(""), not a blank that read "is still  (wanted ../Player)").
static func shown(v: Variant) -> String:
	if v == null:
		return "null"
	if typeof(v) == TYPE_OBJECT and is_instance_valid(v):
		if v is Resource and not (v as Resource).resource_path.is_empty():
			return (v as Resource).resource_path
		var root := scene_root()
		if v is Node and root != null and (v == root or root.is_ancestor_of(v)):
			return "%s (%s)" % [str(root.get_path_to(v)), (v as Object).get_class()]
		return "<%s>" % (v as Object).get_class()
	if typeof(v) in _TEXT_TYPES and str(v).is_empty():
		return var_to_str(v)
	return str(v)


## obj's property-list entry for `prop`, or {} when the object does not list it.
static func _property_entry(obj: Object, prop: String) -> Dictionary:
	for p in obj.get_property_list():
		if str(p.get("name", "")) == prop:
			return p
	return {}
