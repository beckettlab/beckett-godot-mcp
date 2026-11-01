@tool
extends RefCounted
class_name BeckettSceneTools

## Scene/Node authoring on the currently-open scene. Every mutation goes through
## EditorUndoRedoManager, so it's atomic + undoable in the editor (D6). New nodes get
## their owner set to the scene root so they actually persist on save. An edit inside an
## instanced scene, or one that deletes or reorders a node an inherited scene gets from its base,
## can still be dropped by that save; PersistGuard says so in the reply.

const Reflect := preload("res://addons/beckett/core/reflection.gd")
const Internals := preload("res://addons/beckett/core/internals.gd")  # instance_scene never puts one of Beckett's own scenes in the player's
const PersistGuard := preload("res://addons/beckett/core/persist_guard.gd")
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the read rule for a scene opened by path, the write rule for one saved to a path
const _RENAME_SHOWN := 8  # rewritten node paths a rename_node reply spells out in its text; the json lists every one

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
		"description": "Rename a node in the open scene (undoable). Like the Scene dock, it also respells every relative NodePath in the scene that leads through the node (an exported NodePath, Array[NodePath] or Dictionary entries, RemoteTransform3D.remote_path, a %unique path) in the same undo step, and the reply lists them. It refuses a sibling's name, and a %unique name that another node already holds. Characters a node name cannot hold are replaced the way Godot replaces them, and the reply gives the name the node ended up with.",
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
		"description": "Instantiate a packed scene (res://*.tscn, or an imported model such as .glb) as a child in the open scene (undoable). It instances the scene the way the editor does, so the saved scene stores it as an instance of the file and later edits to the file show up in this scene.",
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "res:// path to a .tscn/.scn, or an imported model such as .glb"},
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
	# class_exists FIRST, and it has to stay first: a global script class (class_name) is not a
	# ClassDB class, and from Godot 4.8 (#123379) can_instantiate() on one returns false AND
	# prints an error, where 4.7 and older returned true. The short-circuit keeps both
	# can_instantiate and instantiate to native classes.
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return {"error": "Cannot instantiate class: %s" % type, "suggestion": "Use find_classes base=Node to find a node type."}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		return {"error": Reflect.miss(str(args.get("parent", "")), "parent")}

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
	return PersistGuard.attach({"text": "created %s '%s' under %s" % [type, node.name, parent.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}},
		PersistGuard.verdict(root, parent, PersistGuard.ADD))


func _delete_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
	var root := EditorInterface.get_edited_scene_root()
	if node == root:
		return {"error": "Refusing to delete the scene root."}
	var parent := node.get_parent()
	if parent == null:
		return {"error": "Node has no parent."}
	var verdict := PersistGuard.verdict(root, node, PersistGuard.REMOVE)  # before: it reads the owner
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP delete_node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_method(node, "set_owner", root)
	ur.add_undo_reference(node)
	ur.commit_action()
	return PersistGuard.attach({"text": "deleted node %s" % str(args.get("target", ""))}, verdict)


func _rename_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
	var asked := str(args.get("name", ""))
	if asked.is_empty():
		return {"error": "name is required"}
	var root := Reflect.scene_root()  # the edited scene's root (the unit suite stands one in)
	# The paths below are respelled for the name the node ends up with, so it has to be that name: set_name
	# replaces what a node name cannot hold, and quietly numbers a name a sibling already has.
	var new_name := asked.validate_node_name()
	var old_name := str(node.name)
	if new_name.is_empty():
		return {"error": "'%s' leaves nothing a node name can hold." % asked}
	if new_name == old_name:
		return {"text": "%s already has that name; nothing changed" % old_name,
			"focus": {"kind": "node", "target": str(root.get_path_to(node))}}
	var parent := node.get_parent()
	var sibling: Node = parent.get_node_or_null(NodePath(new_name)) if parent != null else null
	if sibling != null and sibling != node:
		return {"error": "%s already has a child named '%s'." % [parent.name, new_name],
			"suggestion": "Pick another name, or rename that node first."}
	if node.unique_name_in_owner:
		var scope: Node = node.owner if node.owner != null else node
		var taken := scope.get_node_or_null(NodePath("%" + new_name))
		if taken != null and taken != node:
			return {"error": "Another node of this scene already has the unique name %%%s." % new_name,
				"suggestion": "Pick another name, or rename that node first."}
	# What the Scene dock does on a rename (SceneTreeDock::perform_node_renames): a NodePath that named the node
	# would point at nothing after it, so it is respelled in the same undo step. Renaming Barbarian to Farmer
	# used to leave the camera's `follow = NodePath("../Barbarian")` behind (Pixvale, 2026-10-08).
	var rewrites := _path_renames(root, node, new_name)
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP rename_node")
	ur.add_do_property(node, "name", new_name)
	ur.add_undo_property(node, "name", node.name)
	# The paths go in after the name, and on undo they go back after it, so a setter that looks its node up at once
	# (RemoteTransform3D does) finds it under the name its path spells.
	for r in rewrites:
		ur.add_do_property(r["node"], r["property"], r["after"])
		ur.add_undo_property(r["node"], r["property"], r["before"])
	ur.commit_action()
	var text := "renamed %s to %s" % [old_name, new_name]
	if new_name != asked:
		text += " (Godot's spelling of '%s': a node name cannot hold . : @ / \" %%)" % asked
	var out := {"focus": {"kind": "node", "target": str(root.get_path_to(node))}}
	if not rewrites.is_empty():
		var rows: Array = []
		for r in rewrites:
			for p in r["paths"]:
				rows.append({"node": str(root.get_path_to(r["node"])), "property": r["property"], "from": p[0], "to": p[1]})
		var shown: Array = []
		for row in rows.slice(0, _RENAME_SHOWN):
			shown.append("%s:%s %s -> %s" % [row["node"], row["property"], row["from"], row["to"]])
		text += ". Rewrote %d node path%s that named it: %s%s" % [rows.size(), "" if rows.size() == 1 else "s", "; ".join(shown),
			"" if rows.size() <= _RENAME_SHOWN else "; and %d more (json lists them all)" % (rows.size() - _RENAME_SHOWN)]
		out["json"] = {"renamed": {"from": old_name, "to": new_name}, "rewritten": rows}
	out["text"] = text
	return out


func _reparent_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
	var new_parent := _node(str(args.get("new_parent", "")))
	if new_parent == null:
		return {"error": Reflect.miss(str(args.get("new_parent", "")), "new_parent")}
	var old_parent := node.get_parent()
	if old_parent == null:
		return {"error": "Node has no current parent."}
	var root := EditorInterface.get_edited_scene_root()
	# Two questions, both asked before the move (it re-owns the node): can the node leave where it
	# is, and will the place it lands be saved.
	var verdict := PersistGuard.verdict(root, node, PersistGuard.REMOVE)
	if bool(verdict["persisted"]):
		verdict = PersistGuard.verdict(root, new_parent, PersistGuard.ADD)
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP reparent_node")
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_method(node, "set_owner", root)
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_method(node, "set_owner", root)
	ur.commit_action()
	return PersistGuard.attach({"text": "reparented %s under %s" % [node.name, new_parent.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}}, verdict)


func _instance_scene(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var scene_path := str(args.get("scene", ""))
	var guard := PathGuard.check_read(scene_path)
	if guard.has("error"):
		return guard
	if Internals.is_beckett_path(scene_path):
		return {"error": Internals.file_text(scene_path)}
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return {"error": "Could not load PackedScene: %s" % scene_path}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		var off := Reflect.refusal_for(str(args.get("parent", "")))
		return {"error": off if not off.is_empty() else "Could not resolve parent."}
	# GEN_EDIT_STATE_INSTANCE is what the editor's own instancing passes, and what makes the node an instance of
	# the file rather than a copy of its root. A plain instantiate() gives it the scene_file_path and none of the
	# scene's state, so the packer has nothing to compare it with: a save wrote `type="Node3D" ... instance=` and
	# every property the file's root sets as an override of the class defaults, so a later change to the file never
	# reached this instance (Pixvale, 2026-10-08).
	var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if inst == null:
		return {"error": "Could not instantiate %s." % scene_path}
	if args.has("name"):
		inst.name = str(args["name"])
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP instance_scene")
	ur.add_do_method(parent, "add_child", inst)
	ur.add_do_method(inst, "set_owner", root)
	ur.add_do_reference(inst)
	ur.add_undo_method(parent, "remove_child", inst)
	ur.commit_action()
	return PathGuard.noted(PersistGuard.attach({"text": "instanced %s as '%s'" % [scene_path, inst.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(inst))}},
		PersistGuard.verdict(root, parent, PersistGuard.ADD)), guard)


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
	# A save-as is a write to a path the caller names: the same rule as write_file (res:// or user://,
	# no "..", no link that leaves the project), checked before the editor is asked to write anything.
	var perr: String = PathGuard.write_path_error(path)
	if not perr.is_empty():
		return {"error": "%s: %s" % [path, perr]}
	EditorInterface.save_scene_as(path, true)  # returns void
	return {"text": "saved scene as %s" % path}


func _open_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	if not ResourceLoader.exists(path):
		return {"error": "No scene at: %s" % path}
	EditorInterface.open_scene_from_path(path)
	return PathGuard.noted({"text": "opened %s" % path}, guard)


func _duplicate_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
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
	return PersistGuard.attach({"text": "duplicated %s as '%s'" % [node.name, dup.name],
		"focus": {"kind": "node", "target": str(root.get_path_to(dup))}},
		PersistGuard.verdict(root, parent, PersistGuard.ADD))


func _move_node(args: Dictionary) -> Dictionary:
	var node := _node(str(args.get("target", "")))
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
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
	return PersistGuard.attach({"text": "moved %s to index %d" % [node.name, to_index],
		"focus": {"kind": "node", "target": str(root.get_path_to(node))}},
		PersistGuard.verdict(root, node, PersistGuard.REORDER))  # after: it reads the new order


# ---------------------------------------------------------------- helpers

## The node a target names in the open scene. The shared resolver (reflection.gd) answers, so this tool and every
## other one agree on what a target is, and on what no target may be: a node outside the open scene, or one of
## Beckett's own. This used to be a private copy of the lookup, one that also took any absolute path in the editor.
func _node(target: String) -> Node:
	return Reflect.scene_node(target)


## The NodePaths that renaming `node` to `new_name` would break, respelled: every property of a node of the scene
## under `root` (script exports and metadata included) that holds a path walking into `node` BY NAME, as a plain
## name or as its unique name (%Name), also inside an Array or a Dictionary. One entry per property:
## {node, property, before, after, paths: [[old, new], ...]}, where `after` is the value to set and `paths` the
## spellings that changed in it. The scene stays as it is; rename_node puts these in its undo step.
##
## A path that reaches the node without naming it (".." from a child, %Child to a unique node below it) keeps
## working after the rename and is left alone, and so is one that does not resolve now (it is broken already, or
## it is absolute and only resolves in a running game). The Scene dock also respells animation tracks and paths
## inside resources; this does not.
static func _path_renames(root: Node, node: Node, new_name: String) -> Array:
	var out: Array = []
	var holders: Array = [root]
	var i := 0
	while i < holders.size():
		var h: Node = holders[i]
		i += 1
		holders.append_array(h.get_children())
		for p in h.get_property_list():
			if int(p["usage"]) & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR) == 0:
				continue
			# NIL is a Variant-typed property, such as an untyped @export_storage var: only its value can tell.
			if int(p["type"]) not in [TYPE_NODE_PATH, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_NIL]:
				continue
			var before: Variant = h.get(p["name"])
			var paths: Array = []
			var after: Variant = _renamed_value(h, before, node, new_name, paths, 0)
			if not paths.is_empty():
				out.append({"node": h, "property": str(p["name"]), "before": before, "after": after, "paths": paths})
	return out


## `v` with every NodePath in it that names `node` respelled for `new_name`, each change appended to `paths` as
## [old, new]. A path resolves from `h`, the node that holds it. An Array or a Dictionary that changes comes back as
## a copy (a typed one stays typed), so `v` itself is still the value to undo to.
static func _renamed_value(h: Node, v: Variant, node: Node, new_name: String, paths: Array, depth: int) -> Variant:
	if depth > 16:  # a container that holds itself
		return v
	match typeof(v):
		TYPE_NODE_PATH:
			var np: NodePath = v
			var respelled: Variant = _renamed_path(h, np, node, new_name)
			if respelled == null:
				return v
			paths.append([str(np), str(respelled)])
			return respelled
		TYPE_ARRAY:
			var arr: Array = v
			var copy: Array = []
			var changed := false
			for k in arr.size():
				var seen := paths.size()
				var e: Variant = _renamed_value(h, arr[k], node, new_name, paths, depth + 1)
				if paths.size() > seen:
					if not changed:
						copy = arr.duplicate()
						changed = true
					copy[k] = e
			return copy if changed else v
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var copy: Dictionary = {}
			var changed := false
			for key in d:
				var seen := paths.size()
				var e: Variant = _renamed_value(h, d[key], node, new_name, paths, depth + 1)
				if paths.size() > seen:
					if not changed:
						copy = d.duplicate()
						changed = true
					copy[key] = e
			return copy if changed else v
	return v


## `np` (a path held by `h`) spelled for the rename, or null when it does not name `node` on its way, does not
## resolve, or is absolute. Walked one name at a time, the way get_node walks it, so a segment that names `node`
## is told apart from an equal name elsewhere and from a ".." that only passes through it. Subnames (":position")
## are kept.
static func _renamed_path(h: Node, np: NodePath, node: Node, new_name: String) -> Variant:
	if np.is_empty() or np.is_absolute():
		return null
	var old_name := str(node.name)
	var cur: Node = h
	var names := PackedStringArray()
	var changed := false
	for k in np.get_name_count():
		var seg := str(np.get_name(k))
		cur = cur.get_node_or_null(NodePath(seg))
		if cur == null:
			return null
		if cur == node and (seg == old_name or seg == "%" + old_name):
			seg = seg.left(seg.length() - old_name.length()) + new_name  # keeps the % of a unique name
			changed = true
		names.append(seg)
	if not changed:
		return null
	var spelled := "/".join(names)
	if np.get_subname_count() > 0:
		spelled += ":" + str(np.get_concatenated_subnames())
	return NodePath(spelled)


## Set owner on a duplicated subtree so it persists on save. Only on nodes that have none yet:
## a duplicated instance arrives with its sub-scene's nodes already owned by that instance, and
## owning them to the scene as well makes the saved file list them a second time next to the
## ones the instance rebuilds (found by persist_guard's pack-and-compare proof; 4.5+ doubled them).
func _own_recursive(node: Node, owner: Node) -> void:
	if node.owner == null:
		node.owner = owner
	for c in node.get_children():
		_own_recursive(c, owner)
