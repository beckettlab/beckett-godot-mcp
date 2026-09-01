extends Node

## Beckett runtime autoload: the ONLY Beckett file that a shipped game ever sees.
##
## Enabling the plugin registers this as a project autoload, so it is baked into
## project.godot and rides along into every export. That makes it the one Beckett
## script whose parse cost is paid by the player, which drives two hard rules:
##
##   1. It must parse on ANY engine build. A custom engine compiled with a build
##      profile can have hundreds of classes stripped from ClassDB, and GDScript
##      resolves class identifiers at PARSE time: one `is MeshInstance3D` against
##      an engine without MeshInstance3D fails the whole script, and a failed
##      autoload script prints errors before the main scene even loads. So this
##      file names nothing but Node, OS and String. Everything with a real type
##      dependency (mcp_runtime.gd and friends: Camera3D, ShaderMaterial,
##      GraphEdit, StreamPeerTCP, ...) is reached through load(), which resolves
##      at RUNTIME and only on the branch that never runs in an export.
##
##   2. It must do nothing outside the editor. The runtime channel exists to serve
##      a game the editor itself launched (EditorInterface.play_main_scene), so
##      "am I running under an editor build" is the exact gate. In an export
##      template OS.has_feature("editor") is false and this node stays an empty,
##      silent Node: no socket, no retry timer, no commands served.
##
## Pair this with core/export_filter.gd, which strips every OTHER Beckett file out
## of the pack, so a shipped game carries this stub and nothing else.

## Resolved at runtime, never preloaded: a preload() is a parse-time dependency and
## would drag mcp_runtime.gd's whole type closure back into this file.
const IMPL_PATH := "res://addons/beckett/runtime/mcp_runtime.gd"
const IMPL_NAME := "BeckettRuntimeImpl"


func _ready() -> void:
	# Rule 2. First statement in the file for a reason: everything below this line
	# is editor-only, and an exported game must fall out here having done nothing.
	if not OS.has_feature("editor"):
		return

	# Duplicate-autoload guard, twin case: a project upgraded across the
	# godot_mcp -> beckett rename can carry TWO autoload entries pointing at this
	# same script. Both twins would spawn an implementation and both would dial the
	# bridge with the same session token, and the newer one displaces the older
	# MID-COMMAND (replay windows then report frames=0 from the wrong twin). Tie-break
	# on child INDEX, not _ready order: Godot adds all autoloads before readying any,
	# so the lowest-index twin is the deterministic winner whether _ready fires
	# incrementally or all at once. Gating on "a same-script sibling exists" instead
	# would make BOTH twins dormant.
	for sib in get_tree().root.get_children():
		if sib != self and sib.get_script() == get_script() and sib.get_index() < get_index():
			push_warning("[beckett] duplicate runtime autoload '%s' (twin of '%s'), staying dormant; remove the stale autoload entry from project.godot" % [name, sib.name])
			return

	# Ask before loading. A load() that misses raises a hard engine ERROR of its own, and
	# this path is reachable with the file genuinely absent: core/export_filter.gd strips it
	# from the pack, so anyone running that pack under an editor binary (godot --main-pack,
	# a pack smoke test) would otherwise get a red line for a situation that is working as
	# designed. Same probe the dock uses for the optional shimmer module.
	if not ResourceLoader.exists(IMPL_PATH):
		push_warning("[beckett] runtime implementation not present at %s, so the play/observe loop is off; this is expected in an exported pack and means a half-installed addon anywhere else" % IMPL_PATH)
		return
	var impl = load(IMPL_PATH)
	if impl == null:
		# Present but unloadable, i.e. mcp_runtime.gd failed to parse. The engine has already
		# said why on its own line; ours names the consequence.
		push_warning("[beckett] runtime implementation at %s failed to load, so the play/observe loop is off" % IMPL_PATH)
		return

	# Duplicate-autoload guard, legacy case: before this stub existed the autoload
	# pointed straight at mcp_runtime.gd, and an upgraded project can still carry a
	# second entry that does. That entry is already a live channel at the tree root,
	# so spawning ours too recreates the two-peers-one-token bug the twin guard above
	# exists to prevent. Yield to it and name the fix.
	for sib in get_tree().root.get_children():
		if sib != self and sib.get_script() == impl:
			push_warning("[beckett] a legacy autoload ('%s') still points straight at %s, staying dormant; re-point it at %s so it stops shipping into your exports" % [sib.name, IMPL_PATH, get_script().resource_path])
			return

	# PROCESS_MODE_ALWAYS on the implementation is what keeps the channel alive while
	# the game is paused (pause menus and game-over screens are exactly when the agent
	# needs to look and click). It sets its own mode in _ready; matching it here keeps
	# the parent from being the thing that decides, whatever the tree's pause state is.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var node = impl.new()
	node.name = IMPL_NAME
	add_child(node)
