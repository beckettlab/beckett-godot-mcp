@tool
extends RefCounted
class_name BeckettReflectionTools

## Reflection-first tool set (D2): discovery (find_classes / describe_class / find_methods)
## + generic execution (describe_object / set_property / call_method) + scene tree.
## These few tools reach any Node / Resource / Object without per-domain wrappers.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server  # mcp_server node (for get_undo_redo); set by the caller


func _register(registry) -> void:
	registry.register({
		"name": "get_godot_version",
		"description": "Return the running Godot engine version info.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_get_godot_version"),
	})
	registry.register({
		"name": "find_classes",
		"description": "Search classes by name substring — engine classes AND your project's own types (GDScript class_name + C# [GlobalClass]). Optional 'base' restricts to subclasses (e.g. base=Node2D). The discovery entry point — pair with describe_class.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string", "description": "case-insensitive name substring"},
			"base": {"type": "string", "description": "only subclasses of this class"},
			"max": {"type": "integer", "description": "max results (default 50)"},
		}},
		"handler": Callable(self, "_find_classes"),
	})
	registry.register({
		"name": "describe_class",
		"description": "List a class's properties and methods (with signatures) so you know exactly what to set_property / call_method. The discovery key for full domain coverage.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"class": {"type": "string"},
			"inherited": {"type": "boolean", "description": "include inherited members (default false)"},
		}, "required": ["class"]},
		"handler": Callable(self, "_describe_class"),
	})
	registry.register({
		"name": "find_methods",
		"description": "Search methods by name substring, optionally restricted to a class (incl. inherited). Any result is invokable via call_method.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string"},
			"class": {"type": "string"},
			"max": {"type": "integer"},
		}, "required": ["query"]},
		"handler": Callable(self, "_find_methods"),
	})
	registry.register({
		"name": "describe_object",
		"description": "Dump a live object's properties as JSON. target = a res:// path, a node name/path in the open scene, or a class name (falls back to describe_class).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
		}, "required": ["target"]},
		"handler": Callable(self, "_describe_object"),
	})
	registry.register({
		"name": "set_property",
		"description": "Set a property on a resolved object (undoable). value is coerced to the property's type (vectors accept \"x y z\" or [x,y,z]).",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"property": {"type": "string"},
			"value": {"description": "any JSON value"},
		}, "required": ["target", "property", "value"]},
		"handler": Callable(self, "_set_property"),
	})
	registry.register({
		"name": "call_method",
		"description": "Invoke a method on a resolved object. args = a positional array. Returns the result as JSON.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"method": {"type": "string"},
			"args": {"type": "array"},
		}, "required": ["target", "method"]},
		"handler": Callable(self, "_call_method"),
	})
	registry.register({
		"name": "get_scene_tree",
		"description": "Return the node tree of the scene currently open in the editor (name/class/script, nested).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_get_scene_tree"),
	})


# ---------------------------------------------------------------- handlers

func _get_godot_version(_args: Dictionary) -> Dictionary:
	return {"json": Engine.get_version_info()}


func _find_classes(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", "")).to_lower()
	var base := str(args.get("base", ""))
	var maxn := int(args.get("max", 50))
	var src: PackedStringArray
	if not base.is_empty() and ClassDB.class_exists(base):
		src = ClassDB.get_inheriters_from_class(base)
	else:
		src = ClassDB.get_class_list()
	var out: Array = []
	for c in src:
		if query.is_empty() or String(c).to_lower().contains(query):
			out.append({"name": String(c), "parent": String(ClassDB.get_parent_class(c))})
			if out.size() >= maxn:
				break
	# Also surface user-defined global classes (GDScript class_name + C# [GlobalClass]) —
	# ClassDB never lists these. Tagged with language + script path so the agent knows they
	# are project types (drive them the same way: create_node / set_property / call_method).
	if out.size() < maxn:
		for e in _global_classes():
			var nm := String(e.get("class", ""))
			if nm.is_empty():
				continue
			if not query.is_empty() and not nm.to_lower().contains(query):
				continue
			if not base.is_empty() and String(e.get("base", "")) != base:
				continue
			out.append({
				"name": nm,
				"parent": String(e.get("base", "")),
				"kind": "script",
				"language": String(e.get("language", "")),
				"script": String(e.get("path", "")),
			})
			if out.size() >= maxn:
				break
	return {"json": {"count": out.size(), "truncated": out.size() >= maxn, "classes": out}}


func _describe_class(args: Dictionary) -> Dictionary:
	var cls := str(args.get("class", ""))
	if not ClassDB.class_exists(cls):
		var gentry := _global_class_entry(cls)
		if not gentry.is_empty():
			return _describe_global_class(cls, gentry)
		return {"error": "No such class: %s" % cls, "suggestion": _did_you_mean(cls)}
	var no_inh := not bool(args.get("inherited", false))
	var props: Array = []
	for p in ClassDB.class_get_property_list(cls, no_inh):
		var usage := int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		props.append({"name": String(p.get("name", "")), "type": Reflect._type_name(p)})
	var methods: Array = []
	for m in ClassDB.class_get_method_list(cls, no_inh):
		methods.append({"name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
	return {"json": {
		"class": cls,
		"parent": String(ClassDB.get_parent_class(cls)),
		"properties": props,
		"methods": methods,
	}}


func _find_methods(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", "")).to_lower()
	var cls := str(args.get("class", ""))
	var maxn := int(args.get("max", 50))
	var out: Array = []
	if not cls.is_empty() and ClassDB.class_exists(cls):
		for m in ClassDB.class_get_method_list(cls, false):
			if query.is_empty() or String(m.get("name", "")).to_lower().contains(query):
				out.append({"class": cls, "name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
				if out.size() >= maxn:
					break
	else:
		for c in ClassDB.get_class_list():
			for m in ClassDB.class_get_method_list(c, true):
				if String(m.get("name", "")).to_lower().contains(query):
					out.append({"class": String(c), "name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
					if out.size() >= maxn:
						break
			if out.size() >= maxn:
				break
	return {"json": {"count": out.size(), "methods": out}}


func _describe_object(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var obj := Reflect.resolve(target)
	if obj == null:
		if ClassDB.class_exists(target) or not _global_class_entry(target).is_empty():
			return _describe_class({"class": target, "inherited": args.get("inherited", false)})
		return {
			"error": "Could not resolve target: %s" % target,
			"suggestion": "Use a res:// path, a node name/path in the open scene, or a class name.",
		}
	return {"json": {
		"target": target,
		"class": obj.get_class(),
		"properties": Reflect.properties_of(obj),
	}}


func _set_property(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var prop := str(args.get("property", ""))
	if not args.has("value"):
		return {"error": "value is required"}
	var obj := Reflect.resolve(target)
	if obj == null:
		return {"error": "Could not resolve target: %s" % target}
	if not _has_property(obj, prop):
		return {"error": "%s has no property '%s'" % [obj.get_class(), prop],
			"suggestion": "Call describe_object target=%s (or describe_class) to see valid properties." % target}
	var coerced: Variant = Reflect.coerce_for_property(obj, prop, args["value"])
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	if ur != null:
		ur.create_action("MCP set_property %s.%s" % [target, prop])
		ur.add_do_property(obj, prop, coerced)
		ur.add_undo_property(obj, prop, obj.get(prop))
		ur.commit_action()
	else:
		obj.set(prop, coerced)
	return {"text": "set %s.%s = %s" % [target, prop, str(coerced)]}


func _call_method(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var method := str(args.get("method", ""))
	var obj := Reflect.resolve(target)
	if obj == null:
		return {"error": "Could not resolve target: %s" % target}
	if not obj.has_method(method):
		return {"error": "%s has no method '%s'" % [obj.get_class(), method],
			"suggestion": "Call find_methods query=%s class=%s to discover callable methods." % [method, obj.get_class()]}
	var call_args: Array = []
	var incoming: Variant = args.get("args", [])
	if incoming is Array:
		call_args = incoming
	var ret: Variant = obj.callv(method, call_args)
	return {"json": {"result": Reflect.to_json_safe(ret)}}


func _get_scene_tree(_args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"text": "No scene is currently open in the editor."}
	return {"json": _node_tree(root)}


# ---------------------------------------------------------------- helpers

func _node_tree(n: Node) -> Dictionary:
	var d: Dictionary = {"name": String(n.name), "class": n.get_class()}
	var scr := n.get_script()
	if scr != null and scr is Script:
		d["script"] = (scr as Script).resource_path
	var kids: Array = []
	for c in n.get_children():
		kids.append(_node_tree(c))
	if not kids.is_empty():
		d["children"] = kids
	return d


func _has_property(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if String(p.get("name", "")) == prop:
			return true
	return false


func _did_you_mean(cls: String) -> String:
	var q := cls.to_lower()
	var hits: Array = []
	for c in ClassDB.get_class_list():
		if String(c).to_lower().contains(q):
			hits.append(String(c))
			if hits.size() >= 5:
				break
	for e in _global_classes():  # include the project's own types in suggestions
		if hits.size() >= 5:
			break
		var nm := String(e.get("class", ""))
		if not nm.is_empty() and nm.to_lower().contains(q) and not hits.has(nm):
			hits.append(nm)
	if hits.is_empty():
		return "Use find_classes to search for the right class name."
	return "Did you mean: %s" % ", ".join(hits)


## User-defined global classes (GDScript class_name + C# [GlobalClass]) — the surface
## ClassDB does not track. Fresh each call so it reflects scripts added mid-session.
func _global_classes() -> Array:
	if ProjectSettings.has_method("get_global_class_list"):
		return ProjectSettings.get_global_class_list()
	return []


func _global_class_entry(name: String) -> Dictionary:
	if name.is_empty():
		return {}
	for e in _global_classes():
		if String(e.get("class", "")) == name:
			return e
	return {}


## Describe a user global class from its Script resource. get_script_method_list /
## get_script_property_list work for BOTH GDScript and CSharpScript — but C# type info
## is only populated after a successful build, so an empty result folds in the base class.
func _describe_global_class(cls: String, entry: Dictionary) -> Dictionary:
	var base := String(entry.get("base", ""))
	var lang := String(entry.get("language", ""))
	var path := String(entry.get("path", ""))
	var scr: Variant = load(path) if not path.is_empty() else null
	var props: Array = []
	var methods: Array = []
	if scr != null and scr is Script:
		for p in (scr as Script).get_script_property_list():
			var usage := int(p.get("usage", 0))
			if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_CATEGORY) != 0:
				continue
			props.append({"name": String(p.get("name", "")), "type": Reflect._type_name(p)})
		for m in (scr as Script).get_script_method_list():
			methods.append({"name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
	var result := {
		"class": cls,
		"parent": base,
		"language": lang,
		"script": path,
		"properties": props,
		"methods": methods,
	}
	if props.is_empty() and methods.is_empty():
		var why := " — C# type info needs a successful build (run build_csharp)" if lang == "C#" else ""
		result["note"] = "No script members resolved%s. Showing the base class '%s' instead." % [why, base]
		if ClassDB.class_exists(base):
			var bd := _describe_class({"class": base})
			if bd.has("json"):
				result["base_class"] = bd["json"]
	return {"json": result}
