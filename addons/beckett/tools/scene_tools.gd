@tool
extends RefCounted
class_name BeckettSceneTools

## Scene/Node authoring on the currently-open scene. Every mutation goes through
## EditorUndoRedoManager, so it's atomic + undoable in the editor (D6). New nodes get
## their owner set to the scene root so they actually persist on save.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server  # mcp_server node


func _register(registry) -> void:
	registry.register({
		"name": "create_node",
		"description": "Create a node of the given class and add it to the open scene (undoable). parent = a node path/name (default: scene root).",
		"input_schema": {"type": "object", "properties": {
			"type": {"type": "string", "description": "node class, e.g. Sprite2D"},
			"name": {"type": "string"},
			"parent": {"type": "string", "description": "parent node path/name; default scene root"},
		}, "required": ["type"]},
		"handler": Callable(self, "_create_node"),
	})
	registry.register({
		"name": "delete_node",
		"description": "Remove a node from the open scene (undoable).",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
		}, "required": ["target"]},
		"handler": Callable(self, "_delete_node"),
	})
	registry.register({
		"name": "rename_node",
		"description": "Rename a node in the open scene (undoable).",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"name": {"type": "string"},
		}, "required": ["target", "name"]},
		"handler": Callable(self, "_rename_node"),
	})
	registry.register({
		"name": "reparent_node",
		"description": "Move a node under a new parent in the open scene (undoable).",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"new_parent": {"type": "string"},
		}, "required": ["target", "new_parent"]},
		"handler": Callable(self, "_reparent_node"),
	})
	registry.register({
		"name": "instance_scene",
		"description": "Instantiate a packed scene (res://*.tscn) as a child in the open scene (undoable).",
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "res:// path to a .tscn/.scn"},
			"parent": {"type": "string"},
			"name": {"type": "string"},
		}, "required": ["scene"]},
		"handler": Callable(self, "_instance_scene"),
	})
	registry.register({
		"name": "save_scene",
		"description": "Save the scene currently open in the editor. Pass 'path' (res://) to save-as.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"},
		}},
		"handler": Callable(self, "_save_scene"),
	})
	registry.register({
		"name": "open_scene",
		"description": "Open a scene by res:// path in the editor (makes it the edited scene).",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"},
		}, "required": ["path"]},
		"handler": Callable(self, "_open_scene"),
	})
	registry.register({
		"name": "duplicate_node",
		"description": "Duplicate a node (with its children) under the same parent (undoable). Optional 'name' for the copy.",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"}, "name": {"type": "string"},
		}, "required": ["target"]},
		"handler": Callable(self, "_duplicate_node"),
	})
	registry.register({
		"name": "move_node",
		"description": "Reorder a node within its parent to a new child index (undoable).",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"}, "to_index": {"type": "integer"},
		}, "required": ["target", "to_index"]},
		"handler": Callable(self, "_move_node"),
	})


# ---------------------------------------------------------------- handlers

func _create_node(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var type := str(args.get("type", ""))
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return {"error": "Cannot instantiate class: %s" % type, "suggestion": "Use find_classes base=Node to find a node type."}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		return {"error": "Could not resolve parent: %s" % str(args.get("parent", ""))}

	var node := ClassDB.instantiate(type) as Node
	if node == null:
		return {"error": "%s did not instantiate to a Node." % type}
	if args.has("name"):
		node.name = str(args["name"])

	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP create_node %s" % type)
	ur.add_do_method(parent, "add_child", node)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()
	# Focus the NEW node (not the parent) — get_path_to is valid now it's in the tree.
	return {"text": "created %s '%s' under %s" % [type, node.name, parent.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}}


func _delete_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var root := EditorInterface.get_edited_scene_root()
	if node == root:
		return {"error": "Refusing to delete the scene root."}
	var parent := node.get_parent()
	if parent == null:
		return {"error": "Node has no parent."}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP delete_node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_method(node, "set_owner", root)
	ur.add_undo_reference(node)
	ur.commit_action()
	return {"text": "deleted node %s" % str(args.get("target", ""))}


func _rename_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var new_name := str(args.get("name", ""))
	if new_name.is_empty():
		return {"error": "name is required"}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP rename_node")
	ur.add_do_property(node, "name", new_name)
	ur.add_undo_property(node, "name", node.name)
	ur.commit_action()
	var root := EditorInterface.get_edited_scene_root()
	return {"text": "renamed to %s" % new_name,
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}}


func _reparent_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var new_parent := _node(str(args.get("new_parent", "")))
	if new_parent == null:
		return {"error": "Could not resolve new_parent: %s" % str(args.get("new_parent", ""))}
	var old_parent := node.get_parent()
	if old_parent == null:
		return {"error": "Node has no current parent."}
	var root := EditorInterface.get_edited_scene_root()
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP reparent_node")
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_method(node, "set_owner", root)
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_method(node, "set_owner", root)
	ur.commit_action()
	return {"text": "reparented %s under %s" % [node.name, new_parent.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}}


func _instance_scene(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var scene_path := str(args.get("scene", ""))
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return {"error": "Could not load PackedScene: %s" % scene_path}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		return {"error": "Could not resolve parent."}
	var inst := packed.instantiate()
	if args.has("name"):
		inst.name = str(args["name"])
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP instance_scene")
	ur.add_do_method(parent, "add_child", inst)
	ur.add_do_method(inst, "set_owner", root)
	ur.add_do_reference(inst)
	ur.add_undo_method(parent, "remove_child", inst)
	ur.commit_action()
	return {"text": "instanced %s as '%s'" % [scene_path, inst.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(inst))}}


func _save_scene(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open to save."}
	var path := str(args.get("path", ""))
	if path.is_empty():
		var err := EditorInterface.save_scene()  # returns Error
		if err != OK:
			return {"error": "save failed: %s" % error_string(err)}
		return {"text": "saved scene"}
	EditorInterface.save_scene_as(path, true)  # returns void
	return {"text": "saved scene as %s" % path}


func _open_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if not ResourceLoader.exists(path):
		return {"error": "No scene at: %s" % path}
	EditorInterface.open_scene_from_path(path)
	return {"text": "opened %s" % path}


func _duplicate_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var root := EditorInterface.get_edited_scene_root()
	if node == root:
		return {"error": "Refusing to duplicate the scene root."}
	var parent := node.get_parent()
	if parent == null:
		return {"error": "Node has no parent."}
	var dup := node.duplicate()
	if args.has("name"):
		dup.name = str(args["name"])
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP duplicate_node")
	ur.add_do_method(parent, "add_child", dup)
	ur.add_do_method(self, "_own_recursive", dup, root)
	ur.add_do_reference(dup)
	ur.add_undo_method(parent, "remove_child", dup)
	ur.commit_action()
	return {"text": "duplicated %s as '%s'" % [node.name, dup.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(dup))}}


func _move_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", ""))}
	var parent := node.get_parent()
	if parent == null:
		return {"error": "Node has no parent."}
	var from_index := node.get_index()
	var to_index := int(args.get("to_index", from_index))
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP move_node")
	ur.add_do_method(parent, "move_child", node, to_index)
	ur.add_undo_method(parent, "move_child", node, from_index)
	ur.commit_action()
	var root := EditorInterface.get_edited_scene_root()
	return {"text": "moved %s to index %d" % [node.name, to_index],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}}


# ---------------------------------------------------------------- helpers

func _node(target: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if target.is_empty() or target == "." or target == "/root" or target == root.name:
		return root
	var n := root.get_node_or_null(NodePath(target))
	if n == null:
		n = root.find_child(target, true, false)
	return n


## Set owner on a node and all descendants so a duplicated subtree persists on save.
func _own_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for c in node.get_children():
		_own_recursive(c, owner)
