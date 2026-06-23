@tool
extends RefCounted
class_name BeckettResourceTools

## Resource creation + assignment (P0). Reflection's set_property can't load/assign a
## resource from a path or mint an inline sub-resource — these close that gap so the agent
## can wire a Texture2D onto a Sprite2D, a Shape2D onto a CollisionShape2D, etc.

const Reflect := preload("res://addons/beckett/core/reflection.gd")


var server


func _register(registry) -> void:
	registry.register({
		"name": "create_resource",
		"description": "Create a Resource of the given class and save it to a res:// path (.tres). Optional 'properties' dict sets initial values.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"class": {"type": "string"},
			"path": {"type": "string", "description": "res:// path ending in .tres/.res"},
			"properties": {"type": "object"},
		}, "required": ["class", "path"]},
		"handler": Callable(self, "_create_resource"),
	})
	registry.register({
		"name": "set_resource",
		"description": "Assign a resource to a node's property (undoable). Use 'resource' (res:// path to load) OR 'class' (mint a new inline sub-resource of that class). e.g. set Sprite2D.texture from a path, or a fresh RectangleShape2D on CollisionShape2D.shape.",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"property": {"type": "string"},
			"resource": {"type": "string", "description": "res:// path of an existing resource"},
			"class": {"type": "string", "description": "class to instantiate as a new inline sub-resource"},
		}, "required": ["target", "property"]},
		"handler": Callable(self, "_set_resource"),
	})


func _create_resource(args: Dictionary) -> Dictionary:
	var cls := str(args.get("class", ""))
	if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls):
		return {"error": "Cannot instantiate class: %s" % cls}
	var obj: Variant = ClassDB.instantiate(cls)
	if not (obj is Resource):
		return {"error": "%s is not a Resource" % cls}
	var res: Resource = obj
	var props: Variant = args.get("properties", {})
	if props is Dictionary:
		for k in props:
			res.set(k, Reflect.coerce_for_property(res, str(k), props[k]))
	var path := str(args.get("path", ""))
	if not path.begins_with("res://"):
		return {"error": "path must start with res://"}
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return {"error": "save failed: %s" % error_string(err)}
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().update_file(path)
	return {"text": "created %s -> %s" % [cls, path]}


func _set_resource(args: Dictionary) -> Dictionary:
	var obj := Reflect.resolve(str(args.get("target", "")))
	if obj == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var prop := str(args.get("property", ""))
	var value: Resource = null
	if args.has("resource"):
		var rp := str(args["resource"])
		if not ResourceLoader.exists(rp):
			return {"error": "No resource at: %s" % rp}
		value = ResourceLoader.load(rp)
	elif args.has("class"):
		var cls := str(args["class"])
		if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls):
			return {"error": "Cannot instantiate class: %s" % cls}
		var inst: Variant = ClassDB.instantiate(cls)
		if not (inst is Resource):
			return {"error": "%s is not a Resource" % cls}
		value = inst
	else:
		return {"error": "Provide 'resource' (path) or 'class' (inline)."}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	if ur != null:
		ur.create_action("MCP set_resource %s" % prop)
		ur.add_do_property(obj, prop, value)
		ur.add_undo_property(obj, prop, obj.get(prop))
		ur.commit_action()
	else:
		obj.set(prop, value)
	return {"text": "assigned %s to %s.%s" % [value.get_class(), str(args.get("target", "")), prop]}
