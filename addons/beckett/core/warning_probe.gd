extends SceneTree

## Child half of validate_script's GDScript warning check (core/warning_check.gd is the
## editor half).
##
## GDScript works out warnings for every script it compiles, then hands them to nobody in the
## editor process: GDScript.reload() returns only an Error, and the analyzer's warnings go to
## the remote debugger, which only exists in a game the editor launched. So the editor
## launches one. This script runs as a short headless game of the same project, with
## --remote-debug pointed at a socket the editor holds for the length of one call; it compiles
## the source it was handed, and the warnings travel back as ordinary debugger messages.
##
## This runs INSIDE the child process, never in the editor. Hard rules:
##  * A SceneTree, not a bare MainLoop: only a SceneTree main loop registers the project's
##    autoload names as globals, and without them any script that reads GameState.x fails
##    to compile here while compiling fine in the editor.
##  * Autoloads are instantiated before _initialize (their _init has run) but the root has
##    not entered the tree yet, so they are detached and freed below. No autoload's
##    _enter_tree or _ready ever runs: a validation call cannot start a game's music, open
##    its sockets, or wake the Beckett runtime autoload.
##  * Parse-safe on Godot 4.2+: it runs inside whatever engine the editor is.

var _frames := 0


func _initialize() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	var gd := GDScript.new()
	gd.source_code = FileAccess.get_file_as_string(args[0])
	var target: String = args[1] if args.size() > 1 else ""
	if not target.is_empty():
		# Compile AS the file it is meant for: relative preloads resolve from its folder, a
		# class_name matches its own registration, and every warning names that path.
		gd.take_over_path(target)
	gd.reload()


## The debugger flushes its queue from the main loop, so give it a couple of frames before
## quitting, or the warnings never leave this process.
func _process(_delta: float) -> bool:
	_frames += 1
	return _frames > 2
