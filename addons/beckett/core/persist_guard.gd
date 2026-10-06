extends RefCounted

## "Will this scene edit still be there after a save?" The editor reports success the moment a
## node is added, moved, deleted or edited, but PackedScene.pack() only writes what it can
## REACH. It skips every node whose owner is not the edited scene unless that instance has
## editable children turned on, and it has no way to record a deletion or a reorder INSIDE an
## instanced scene (the instance rebuilds itself from its own file on load). The edit then lives
## in the open scene, the next save quietly drops it, and the agent never finds out.
##
## Measured, not assumed: _t_persist_guard in tests/unit_tests.gd packs real scenes on every
## supported engine for each edit kind (with and without editable children, nested instances,
## the instance opened the way the editor opens it and added the way instance_scene adds it),
## instantiates the packed copy and requires THIS file's verdict to equal what survived. Where the
## engine is stricter than the obvious rule, the engine wins:
##   - a property set on an instance ROOT, or a node added under one, IS saved (an override / a
##     child of the instance), editable children or not;
##   - deleting, moving out or reordering a node that belongs to an instanced scene is NEVER saved,
##     even with editable children on, because there is nothing in the file format to say "this
##     node of the instance is gone";
##   - a node added under an instance root loads after the instance's own children, so it cannot
##     be placed among them;
##   - in an INHERITED scene (its root is an instance of a base scene: New Inherited Scene), the
##     nodes the base provides are rebuilt from the base file on every load, so deleting one, moving
##     it to another parent, or putting it in a different place among the base's own nodes is never
##     saved, while a property change on one is. The scene's own nodes can be deleted, moved and
##     reordered freely, among the base's as well (each saves its index), which makes moving a base
##     node past only the scene's own nodes the one reorder of it that is kept. The editor owns
##     the base's nodes by the inherited root, exactly like the scene's own, so the owner chain
##     cannot tell them apart: _base_scene_of asks the scene FILE (the base's state lists its nodes).
##
## HARD CONSTRAINT on this file: Node API only, no editor classes and no state. The unit suite
## runs it in a plain engine, and the scene tools (core, shipped in Lite) call it.

## What the edit does to the node handed to verdict().
const SET := "set"          ## one of its properties changes
const ADD := "add_child"    ## a node is created / instanced / duplicated / moved UNDER it
const REMOVE := "remove"    ## it is deleted or moved out of its parent (ask BEFORE doing it)
const REORDER := "reorder"  ## it moves to another index in its parent (ask AFTER the move)


## {persisted, reason, hint} for an edit on `node`, relative to the edited scene `root`.
## reason / hint are "" when it persists.
static func verdict(root: Node, node: Node, edit: String) -> Dictionary:
	# The scene root is always saved, and a node that is not under the root is not ours to judge.
	if root == null or node == null or node == root or not root.is_ancestor_of(node):
		return _yes()
	match edit:
		REMOVE:
			return _removal(root, node, "a deletion or move")
		REORDER:
			return _reorder(root, node)
		_:
			return _reachable(root, node, "a property change on" if edit == SET else "a node added under")


## Fold a verdict into a handler reply. Untouched when the edit persists. Otherwise the reply
## keeps its own text, gains one NOT SAVED sentence (batch_execute summaries and the dock feed read
## the text, so the warning has to be there) and carries the verdict as json for parsers.
static func attach(result: Dictionary, v: Dictionary) -> Dictionary:
	if bool(v.get("persisted", true)):
		return result
	result["text"] = "%s. NOT SAVED: %s %s" % [str(result.get("text", "")), str(v["reason"]), str(v["hint"])]
	result["json"] = v
	return result


# ---------------------------------------------------------------- rules

## SET and ADD: the node has to be one the saved file can reach.
static func _reachable(root: Node, node: Node, what: String) -> Dictionary:
	var block := _blocker(root, node)
	if block.is_empty():
		return _yes()
	return _unreachable(root, node, block, what)


## DELETE / move out: only a node this scene owns can be taken out for good. One owned by an
## instanced scene comes back on the next load whatever the editable-children switch says, and so
## does one a base scene provides (see _base_scene_of).
static func _removal(root: Node, node: Node, what: String) -> Dictionary:
	var inst := _owning_instance(root, node)
	if inst != null:
		return _no("'%s' belongs to the instanced scene %s: the instance rebuilds its own nodes from that file whenever this scene loads, so %s here is not kept (Editable Children does not change that)." % [
				root.get_path_to(node), _name(root, inst), what],
			"Make the change in %s itself (open_scene it first)." % _scene_of(inst))
	var base := _base_scene_of(root, node)
	if not base.is_empty():
		return _no("'%s' comes from %s, the base scene this scene inherits from: the inherited nodes are rebuilt from that file whenever this scene loads, so %s here is not kept." % [
				root.get_path_to(node), base, what],
			"Make the change in %s itself (open_scene it first). A property change on the inherited node is kept." % base)
	return _yes()


static func _reorder(root: Node, node: Node) -> Dictionary:
	if _owning_instance(root, node) != null:
		return _removal(root, node, "a reorder")
	# A node of this scene is kept wherever it sits (the packer saves its index), also among the base's
	# nodes. A node the BASE provides cannot change place relative to its fellow base nodes: moving it
	# past only this scene's own nodes is the one reorder of it that is kept.
	if not _base_scene_of(root, node).is_empty() and not _base_order_kept(root, node.get_parent()):
		return _removal(root, node, "a reorder")
	var block := _blocker(root, node)
	if not block.is_empty():
		return _unreachable(root, node, block, "a new position for")
	# The packer stores a child's index only when its parent sits INSIDE an instance. Under the
	# scene root or a node of this scene, children load in saved order, and under an instance
	# root the instance's own children always come first: a node of this scene placed before one
	# of them is put back after it. That only bites when the parent is the instance root.
	var parent := node.get_parent()
	if parent == root or parent.owner == root:
		var mine_seen := false
		for c in parent.get_children():
			if c.owner == root:
				mine_seen = true
			elif mine_seen and c.owner != null:
				return _no("'%s' sits among the children of the instanced scene %s, which always load first, so its position there is not kept." % [
						root.get_path_to(node), _name(root, parent)],
					"Keep nodes of this scene after the instance's own children, or reorder inside %s." % _scene_of(parent))
	return _yes()


# ---------------------------------------------------------------- the owner chain

## The instance root whose scene file `node` belongs to, or null when this scene owns it (or it
## has no owner at all, which makes the question moot).
static func _owning_instance(root: Node, node: Node) -> Node:
	var o: Node = node.owner
	if o != null and o != root and root.is_ancestor_of(o):
		return o
	return null


## The scenes `root` inherits from, nearest first: [] for an ordinary scene. An inherited scene is one
## whose ROOT is an instance of another scene (New Inherited Scene). The editor owns the inherited
## nodes by the inherited root, exactly like the scene's own, so the owner chain cannot tell them
## apart, and Node has no GDScript binding for its inherited state. The scene FILE can: its SceneState
## lists the root as an instance of the base, and each base's own state lists the nodes it provides.
## A base that inherits from another base is followed up the chain. A scene that was never saved has
## no file and reads as an ordinary one.
static func _bases_of(root: Node) -> Array:
	var out: Array = []
	var path := root.scene_file_path
	if path.is_empty() or not ResourceLoader.exists(path):
		return out
	var scene := ResourceLoader.load(path) as PackedScene
	for _hop in 16:  # the cap only stops a cycle of scenes that inherit from each other
		if scene == null:
			break
		var state: SceneState = scene.get_state()
		var base: PackedScene = state.get_node_instance(0) if state.get_node_count() > 0 else null
		if base == null:
			break
		out.append(base)
		scene = base
	return out


## A SceneState node path relative to its scene's root, spelled like Node.get_path_to: "A/B", and "."
## for the root. SceneState writes them as "./A/B".
static func _rel(p: NodePath) -> String:
	var s := str(p)
	return s.trim_prefix("./") if s != "." else s


## The base scene `node` comes from, as that scene's path; "" for a node the scene adds itself and for
## an ordinary scene.
static func _base_scene_of(root: Node, node: Node) -> String:
	var want := str(root.get_path_to(node))
	for base in _bases_of(root):
		var st: SceneState = (base as PackedScene).get_state()
		for i in range(1, st.get_node_count()):  # 0 is the base's own root
			if _rel(st.get_node_path(i)) == want:
				return (base as PackedScene).resource_path
	return ""


## Do the base's nodes under `parent` still stand in the order the base gives them? The base's order is
## rebuilt the way a load does it: the farthest base's children in file order, then each nearer base's
## own nodes inserted at the index it saved (an index past the end means "last"). The live children
## that are the base's must read in that order; this scene's own nodes may sit anywhere among them.
static func _base_order_kept(root: Node, parent: Node) -> bool:
	var want := str(root.get_path_to(parent))
	var bases := _bases_of(root)
	var order: Array = []
	for k in range(bases.size() - 1, -1, -1):
		var st: SceneState = (bases[k] as PackedScene).get_state()
		for i in range(1, st.get_node_count()):
			if _rel(st.get_node_path(i, true)) != want:
				continue
			var nm := str(st.get_node_name(i))
			if order.has(nm):
				continue  # a nearer base's override of a node a farther one provided
			var at := st.get_node_index(i)
			if at < 0 or at >= order.size():
				order.append(nm)
			else:
				order.insert(at, nm)
	var live: Array = []
	for c in parent.get_children():
		if order.has(str(c.name)):
			live.append(str(c.name))
	return live == order.filter(func(nm): return live.has(nm))


## The OUTERMOST thing between `node` and the scene root that keeps it out of the saved file, as
## {kind:"instance", node:<instance root>} or {kind:"unowned", node:<the node>}; {} when the file
## reaches it. Outermost because that is the one to fix first: Editable Children on an inner
## instance does nothing while the outer one is still closed.
##
## Walking the parents as well as the node is deliberate. A node this scene owns, added under a
## node that belongs to a closed instance, is lost with it: the packer never descends into the
## instance's children, so it never meets the new node.
static func _blocker(root: Node, node: Node) -> Dictionary:
	var found := {}
	var cur: Node = node
	while cur != null and cur != root:
		var o: Node = cur.owner
		if o == null:
			found = {"kind": "unowned", "node": cur}
		elif o != root and root.is_ancestor_of(o) and not root.is_editable_instance(o):
			found = {"kind": "instance", "node": o}
		cur = cur.get_parent()
	return found


static func _unreachable(root: Node, node: Node, block: Dictionary, what: String) -> Dictionary:
	var at: Node = block["node"]
	if str(block["kind"]) == "unowned":
		return _no("%s '%s' is not kept: '%s' has no owner, so the saved scene leaves it out." % [what, root.get_path_to(node), root.get_path_to(at)],
			"Set its owner to the scene root (call_method set_owner), or create it with create_node.")
	return _no("%s '%s' is not kept: it sits inside the instanced scene %s, whose children are not editable in this scene, so a save drops it." % [what, root.get_path_to(node), _name(root, at)],
		"Turn on Editable Children for '%s' (call_method target=. method=set_editable_instance args=[\"%s\", true], or right-click it in the Scene dock), or make the change in %s." % [
			root.get_path_to(at), root.get_path_to(at), _scene_of(at)])


## "'Inst' (res://enemy.tscn)": the instance by its path in this scene, plus the file behind it.
static func _name(root: Node, inst: Node) -> String:
	var where := "'%s'" % root.get_path_to(inst)
	return "%s (%s)" % [where, inst.scene_file_path] if not inst.scene_file_path.is_empty() else where


static func _scene_of(inst: Node) -> String:
	return inst.scene_file_path if not inst.scene_file_path.is_empty() else "its source scene"


static func _yes() -> Dictionary:
	return {"persisted": true, "reason": "", "hint": ""}


static func _no(reason: String, hint: String) -> Dictionary:
	return {"persisted": false, "reason": reason, "hint": hint}
