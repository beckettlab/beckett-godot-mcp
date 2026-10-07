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
## Arguments, after the "--": a token, the file holding the source, and the path to compile it
## as (possibly empty, so it comes last).
##
## How the editor knows it has everything: right after reload() this script raises one more
## message whose text is the token. Messages queue in the debugger in the order they were
## raised and leave in that order, so when the editor reads the token it has already read every
## warning of the source. The editor then ends this process. It used to be this process that
## decided, by quitting a few frames after reload(), and that was a race: the debugger hands its
## queue to a thread that writes it out every few milliseconds, a process that quits first takes
## the queue with it, and on a slow macOS runner the warnings of the first check were lost while
## the check still said "ok". The limit below only stops a child whose editor went away.
##
## The token is an error, not a warning: the debugger drops warnings past a per-second limit
## (400 by default) and a source with more warnings than that would lose the token with them,
## while errors count on their own meter. Measured on 4.4.1, 4.6.2 and 4.7: 700 warnings arrive
## as 400, and the token behind them still arrives.
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

## Longest this process waits for its editor to end it. The editor's own limit is shorter.
const HOLD_MS := 12000

var _t0 := 0
var _frames := 0
var _told := false


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	if not EngineDebugger.is_active():
		# The connection to the editor failed (or was never asked for): nobody can hear a warning, and waiting for
		# the editor to end this process would be waiting for nothing. Checked on 4.4.1, 4.6.2 and 4.7: true when
		# connected, false when the editor's socket refuses or there is no --remote-debug.
		quit()
		return
	for c in root.get_children():
		root.remove_child(c)
		c.free()
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		return
	var gd := GDScript.new()
	gd.source_code = FileAccess.get_file_as_string(args[1])
	var target: String = args[2] if args.size() > 2 else ""
	if not target.is_empty():
		# Compile AS the file it is meant for: relative preloads resolve from its folder, a
		# class_name matches its own registration, and every warning names that path.
		gd.take_over_path(target)
	gd.reload()
	if not args[0].is_empty():
		push_error(args[0])
		_told = true


## Hold still until the editor has read the token and ended this process. A probe run by hand has
## no token to raise, so it ends after a couple of frames.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 1:
		OS.delay_msec(5)
	if not _told:
		return _frames > 2
	return Time.get_ticks_msec() - _t0 > HOLD_MS
