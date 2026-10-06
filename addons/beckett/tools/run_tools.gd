@tool
extends RefCounted
class_name BeckettRunTools

## The basic run loop (L3) — edit -> play -> read errors -> fix. Ships in EVERY
## edition (Lite included): the human plays and reports what they see; the agent
## launches the game, waits for state, and tails the log. The agent-drives-the-game
## loop (screenshot / input / asserts) lives in runtime_tools.gd — a Full module.
##
## CORE module: must stay self-contained (no imports from premium tool files).
## It may touch only the stable seam: registry.register(spec), server fields
## (bridge, plugin, registry), and the handler return conventions.

# Max main-thread block per wait_until call — see _wait_until for why.
const BLOCK_SLICE_MS := 1500
const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")  # poll_until (B2)
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags arrive as text from lenient clients
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the read rule for every path a caller names
const RuntimeBridge := preload("res://addons/beckett/core/runtime_bridge.gd")  # game_view_state: is this editor about to embed the game?

# Quiet play (v1.16 M5d). The launched game inherits the editor's environment (how BECKETT_RUNTIME_PORT reaches
# it), and runtime/quiet.gd applies what BECKETT_QUIET asks for. The editor sets it for the one play call (the
# engine spawns the game inside that call: measured, is_playing_scene() is already true when it returns) and puts
# it back right after, so the person's own F5 afterwards is not quiet.
const QUIET_ENV := "BECKETT_QUIET"
# The Game workspace embeds a game unless embedding is "unavailable", which it decides from the editor's in-memory
# project settings at the moment of the play (checked in the 4.4.1, 4.6.2 and 4.7 sources: a minimized window mode
# makes it unavailable). The GAME reads project.godot from disk, so its own window mode is not touched. The value is put back
# in the same call, and by a timer if this handler died first. It only ever applies to a quiet play.
const EMBED_GATE := "display/window/size/mode"
const EMBED_GATE_VALUE := 1  # DisplayServer.WINDOW_MODE_MINIMIZED
# The net behind that. NOT a deferred call and NOT a process_frame hook: measured on 4.4.1 with the embedded Game view, the editor
# iterates the main loop INSIDE play_custom_scene (before the game's process exists), so either of those fires in the middle of the
# launch and takes the environment and the gate away before the game is created (it then starts embedded and not quiet). A play
# call is milliseconds; a timer this long can only be the handler having died.
const QUIET_NET_SECS := 30.0

# Error breaks (v1.16). A script error in a game the editor launched breaks into the editor's debugger and parks the
# game there, where it cannot answer the runtime channel (core/break_watch.gd has the whole story). Godot 4.5+ has a
# launch flag for it, the one behind the Debugger panel's "Ignore Error Breaks" toggle: the error is still logged
# (game_logs returns it with its backtrace) and the game keeps running. A play_scene launch carries it by default, so an
# agent's loop never stalls on its own bug; the person's own F5 is untouched, and breakpoints still stop the game.
#
# HOW the flag reaches the game is the part that is easy to get wrong. A launch does not read the project setting
# editor/run/main_run_args: it reads the text of the Customize Run Instances dialog's "Main Run Args" field (4.4.1, 4.5,
# 4.6 and 4.7 agree), which copies the setting only when ProjectSettings emits settings_changed, and that signal is
# DEFERRED to the end of the frame. Setting the value and playing in one handler therefore launches WITHOUT the flag
# (measured on 4.6.2 and 4.7: the game's own command line did not carry it), and a restore in the same handler would
# race the deferred copy too. So the value is changed in memory, settings_changed is emitted by hand so the field
# follows at once, the game is launched, and the value is put back and the signal emitted again. Nothing is saved:
# project.godot is only written by ProjectSettings.save(), which cannot run inside this handler, and the value is
# back to what it was before the handler returns (measured: project.godot byte-identical, and a plain play right
# after carries only the person's own arguments). When the Main Run Args field has keyboard focus the dialog skips
# the copy, as it never overwrites what a person is typing, and that launch simply has no flag.
const IGNORE_BREAKS_FLAG := "--ignore-error-breaks"
const IGNORE_BREAKS_SETTING := "beckett/ignore_error_breaks"  # false opts out; absent means on
const IGNORE_BREAKS_ENV := "BECKETT_IGNORE_ERROR_BREAKS"      # 0 / 1; wins over the setting
const RUN_ARGS_SETTING := "editor/run/main_run_args"
const IGNORE_BREAKS_SINCE := 0x040500                          # Engine.get_version_info()["hex"] of 4.5.0
const BREAKS_NOTE := "script errors do not pause the game in the debugger (launched with --ignore-error-breaks): read them with game_logs"

var server  # mcp_server node (exposes .bridge)
var _args_saved: Variant = null     # [the text main_run_args had] while it carries our flag, else null
var _args_gen := 0                  # which arming a timer net belongs to: a net from an earlier call must not undo a later one
var _quiet_requested := false       # the play the agent last launched set quiet (true or false); get_play_state asks the game
var _quiet_plan: Dictionary = {}    # what this editor did for it, reported with what the game says it applied
var _env_saved: Variant = null      # [had BECKETT_QUIET, its value] while the environment is overridden, else null
var _gate_active := false           # the embed gate is overridden right now
var _gate_saved: Variant = 0        # its value to put back
var _quiet_settled := false         # the play call finished normally (the timer net then has nothing to do)
var _quiet_gen := 0                 # which arming a timer net belongs to: a net from an earlier call must not undo a later one


func _register(registry) -> void:
	registry.register({
		"name": "play_scene",
		"description": "Play a scene in the editor. 'scene' (res://) plays a specific scene; current=true plays the open scene; otherwise the project's main scene. Then wait_until condition=play_started, and logs_read for errors. on_ready queues runtime property writes applied the moment the new game connects — the restart boundary batch_execute cannot cross. quiet=true plays muted and off-screen so the person keeps working. Script errors do not pause the game (4.5+): game_logs has them. on_ready shape, retries, what quiet does per run mode: help(tool=\"play_scene\").",
		"help": "on_ready = [{path|class|name, property, value}, ...] — runtime writes queued now and applied automatically the moment the NEW game connects.\n\nWhy it exists: a restart is the one boundary batch_execute cannot cross. Without on_ready you re-issue the same camera pose, debug flags and spawn state by hand after every single play. With it, that is part of the play call.\n\nwait_until condition=game_connected then reports whether each write landed.\n\nA write whose target is still spawning is RETRIED for a few seconds and, if it never appears, reported as a failure — never silently dropped. So an on_ready that did not take shows up as a failure you can read, not as a game that quietly came up wrong.\n\nquiet = true (1.16) is for playing while the person keeps working on the same machine: the game is MUTED (the master bus, kept muted: a game that restores its saved volume in _ready is muted again within half a second), and its window is moved OFF every screen and flagged no-focus, so it neither covers their work nor takes their keystrokes. It is not minimized: a minimized window stops drawing, and screenshot and the playtest tools read the frames the game keeps drawing. What applies depends on how the editor runs the game:\n  separate window (a headless editor, or Game Embed Mode off): muted, parked off-screen, no focus. The game does this itself as its first act, so for the first moment of the launch the window is where the OS put it (a position given on the command line is clamped by the engine to keep a strip on screen: only the game moving itself takes it fully off).\n  embedded Game view (the default since 4.4): on every embedded play the engine either switches the editor to its Game tab or opens a floating Game window (a fresh project does the second), and offers no per-play setting against either. So quiet plays in its own window instead: for the one play call the editor makes the Game workspace see embedding as unavailable (the in-memory project setting display/window/size/mode, put back in the same call; the game reads project.godot, not that memory), and the reply says whether the editor view stayed as it was. If that cannot be done on an engine the game stays embedded, only the mute applies, and the reply says so.\n  headless game: there is no window, only the mute.\nwait_until condition=game_connected and get_play_state report what the GAME says is in force: muted, window position and flags, on screen or not, still drawing. quiet=false forces a normal play when the editor's environment carries BECKETT_QUIET. The person's own F5 afterwards is never quiet.\n\nError breaks (1.16): a script error in a game the editor launched normally PAUSES the game in the editor's debugger, and a paused game cannot answer the runtime channel until someone presses Continue. On Godot 4.5+ play_scene therefore launches with --ignore-error-breaks, the flag behind the Debugger panel's Ignore Error Breaks toggle: the error is still logged (game_logs returns it with its backtrace) and the game keeps running. Breakpoints still stop it, and the person's own F5 is untouched (the flag rides only on this one launch; nothing is saved to project.godot). Opt out with the project setting beckett/ignore_error_breaks=false or the environment variable BECKETT_IGNORE_ERROR_BREAKS=0 (=1 forces it on over a setting of false). Godot 4.4 and older have no such flag, and a game the person starts with F5 pauses on every version: get_play_state then shows debugger_break=true, and every runtime tool and wait_until condition=game_connected answer at once that the game is paused in the debugger, with the next step (Continue in the Debugger panel, or stop_scene and play_scene again).",
		# Bootstrap set (tool_registry.gd): the run half of the run-and-see loop. L3, so it only
		# rides when the dial is at Run or above.
		"always_load": true,
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "res:// path; omit for main/current"},
			"current": {"type": "boolean"},
			"on_ready": {"type": "array", "description": "property writes applied once the game connects (shape in help)"},
			"quiet": {"type": "boolean", "description": "mute the game and park its window off-screen without focus, so the person keeps working"},
		}},
		"handler": Callable(self, "_play_scene"),
	})
	registry.register({
		"name": "stop_scene",
		"description": "Stop the running play session.",
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_stop_scene"),
	})
	registry.register({
		"name": "get_play_state",
		"description": "Report whether a scene is playing, whether the runtime channel to the game is connected, and debugger_break (the game is paused in the editor's debugger).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_get_play_state"),
	})
	registry.register({
		"name": "wait_until",
		"description": "Wait for a condition. Blocks the editor at most ~1.5 s per call — longer would stall the editor's own game-launch pipeline and background jobs (they need main-thread frames). If not met yet it answers 'not yet': just call it again. condition = play_started | play_stopped | game_connected | seconds:N | file_exists:res://path.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"condition": {"type": "string"},
			"timeout_ms": {"type": "integer"},
		}, "required": ["condition"]},
		"handler": Callable(self, "_wait_until"),
	})
	registry.register({
		"name": "logs_read",
		"description": "Tail Godot's log FILE (the editor session and any played game log here). For the RUNNING game's errors/stack traces/prints in REAL TIME, prefer game_logs (runtime channel, no file needed) — this file reader is a fallback and needs file logging enabled (off by default; the result tells you how). Optional: level='error'|'warning', 'filter' substring, 'lines' (default 200), 'path' to override.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"lines": {"type": "integer", "description": "tail this many lines (default 200)"},
			"level": {"type": "string", "description": "error | warning — keep only matching lines"},
			"filter": {"type": "string", "description": "keep only lines containing this substring"},
			"path": {"type": "string", "description": "override log path (default the project's log_path)"},
		}},
		"handler": Callable(self, "_logs_read"),
	})


# ---------------------------------------------------------------- play session

func _play_scene(args: Dictionary) -> Dictionary:
	var scene := str(args.get("scene", ""))
	var guard: Dictionary = {}
	if not scene.is_empty():
		guard = PathGuard.check_read(scene)
		if guard.has("error"):
			return guard
		if not ResourceLoader.exists(scene):
			return {"error": "No scene at: %s" % scene}
	var queued := _queue_on_ready(args.get("on_ready"))
	if queued is String:
		return {"error": queued}
	# The flag goes on first and comes off last: arming it emits settings_changed (see IGNORE_BREAKS_FLAG), and that must
	# not happen while quiet's embed gate has the window mode overridden, which only has to hold for the play call itself.
	var breaks := _breaks_arm()
	var quiet_given: bool = args.has("quiet") and args.get("quiet") != null
	if quiet_given:
		_quiet_arm(CallArgs.flag(args, "quiet"))
	else:
		_quiet_requested = false
	var what := ""
	if not scene.is_empty():
		EditorInterface.play_custom_scene(scene)
		what = "playing %s" % scene
	elif CallArgs.flag(args, "current"):
		EditorInterface.play_current_scene()
		what = "playing current scene"
	else:
		EditorInterface.play_main_scene()
		what = "playing main scene"
	if quiet_given:
		_quiet_after_play()
		if _quiet_requested:
			what += "; " + str(_quiet_plan.get("note", "quiet"))
	_breaks_disarm()  # the launch has read the arguments: nothing else may see the flag on them
	if breaks:
		what += "; " + BREAKS_NOTE
	if int(queued) > 0:
		what += "; %d on_ready write(s) queued — they apply when the game connects, and wait_until condition=game_connected reports the result" % int(queued)
	return PathGuard.noted({"text": what}, guard)


# ---------------------------------------------------------------- quiet play (v1.16 M5d)

## Arm a play: the environment the launched game inherits, and for quiet, keeping the editor's Game workspace from
## embedding it (see EMBED_GATE). Everything armed is put back by _quiet_disarm right after the launch, and by
## a timer (QUIET_NET_SECS) if this handler died before it got there.
func _quiet_arm(on: bool) -> void:
	_quiet_disarm()  # leftovers of an earlier call can never ride into this one
	_quiet_settled = false
	_quiet_gen += 1
	_quiet_requested = on
	_quiet_plan = {}
	_env_saved = [OS.has_environment(QUIET_ENV), OS.get_environment(QUIET_ENV)]
	_quiet_net_arm(_quiet_gen)
	if not on:
		OS.unset_environment(QUIET_ENV)  # an explicit quiet=false is a normal play, whatever the editor's environment says
		return
	var gv: Dictionary = RuntimeBridge.game_view_state()
	var embedded := str(gv.get("mode", "")) == "embedded"
	var mode := "window"
	var avoided := false
	if embedded:
		avoided = _gate_on()
		if not avoided:
			mode = "embedded"
	elif str(gv.get("mode", "")) == "unknown":
		mode = "embedded"  # cannot tell whether the game will be embedded: leave its window alone, mute only
	_quiet_plan = {"mode": mode, "editor_embeds": embedded, "embed_avoided": avoided, "placement": str(gv.get("placement", "")), "view_before": _main_screen_kind(),
		"headless_editor": DisplayServer.get_name() == "headless"}
	OS.set_environment(QUIET_ENV, mode)


## The play call has returned: the game was spawned inside it, so the environment and the gate go back now.
func _quiet_after_play() -> void:
	_quiet_settled = true
	var spawned := EditorInterface.is_playing_scene()
	_quiet_disarm()
	if not _quiet_requested:
		return
	_quiet_plan["view_after"] = _main_screen_kind()
	_quiet_plan["note"] = quiet_note(_quiet_plan, spawned)


## Put the environment and the embed gate back as they were (a no-op when nothing is armed).
func _quiet_disarm() -> void:
	if _gate_active:
		ProjectSettings.set_setting(EMBED_GATE, _gate_saved)
		_gate_active = false
	if _env_saved != null:
		var prev: Array = _env_saved
		if bool(prev[0]):
			OS.set_environment(QUIET_ENV, str(prev[1]))
		else:
			OS.unset_environment(QUIET_ENV)
		_env_saved = null


## The net behind _quiet_arm: a timer, because anything that fires sooner can fire inside the play call (see QUIET_NET_SECS).
func _quiet_net_arm(gen: int) -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).create_timer(QUIET_NET_SECS).timeout.connect(_quiet_net_for.bind(gen))


## The timer of arming `gen` ran out: act only when no later arming has taken over.
func _quiet_net_for(gen: int) -> void:
	if gen == _quiet_gen:
		_quiet_net()


## When the play call died before _quiet_after_play, put everything back.
func _quiet_net() -> void:
	if not _quiet_settled:
		_quiet_disarm()


## Make the Game workspace see embedding as unavailable for this one play call. True when the gate is set.
func _gate_on() -> bool:
	if _gate_active:
		return true
	if not ProjectSettings.has_setting(EMBED_GATE):
		return false
	_gate_saved = ProjectSettings.get_setting(EMBED_GATE)
	ProjectSettings.set_setting(EMBED_GATE, EMBED_GATE_VALUE)
	_gate_active = true
	return true


## Which editor view is showing: the class of the visible main-screen control (CanvasItemEditor is 2D,
## Node3DEditor 3D, ScriptEditor Script, and the Game workspace has its own), "" when it cannot be read.
func _main_screen_kind() -> String:
	if not Engine.is_editor_hint():
		return ""  # no editor (the unit suite): there is no main screen to read
	var holder: Control = EditorInterface.get_editor_main_screen()
	if holder == null:
		return ""
	for c in holder.get_children():
		if c is Control and (c as Control).visible:
			return str(c.get_class())
	return ""


## What the editor did for a quiet play, in one sentence (the game's own account comes with wait_until
## condition=game_connected and get_play_state). Pure: the unit suite pins every branch.
static func quiet_note(plan: Dictionary, spawned: bool) -> String:
	var mode := str(plan.get("mode", "window"))
	var bits: Array = []
	if not spawned:
		bits.append("the game had not started when the call returned, so the quiet request may not have reached it: check get_play_state")
	if bool(plan.get("embed_avoided", false)):
		var would := "opened a floating Game window" if str(plan.get("placement", "main")) == "floating" else "switched to its Game tab"
		bits.append("quiet: the editor would have embedded the game and %s, so it plays in its own window instead, which the game mutes and parks off-screen without focus as it starts" % would)
	elif mode == "embedded":
		bits.append("quiet: the game is (or may be) embedded in the editor's Game view, which the engine offers no way to hide or silence from here, so only the mute applies and its window is left where the editor put it")
	elif bool(plan.get("headless_editor", false)):
		bits.append("quiet: the game mutes itself and parks its own window off-screen without focus as it starts")
	else:
		bits.append("quiet: the game plays in its own window, which it mutes and parks off-screen without focus as it starts")
	var before := str(plan.get("view_before", ""))
	var after := str(plan.get("view_after", ""))
	if not before.is_empty() and not after.is_empty():
		bits.append("editor view %s" % ("unchanged" if before == after else "switched from %s to %s" % [before, after]))
	return "; ".join(PackedStringArray(bits))


## One line of what the GAME reports is in force, for wait_until: {mode, muted, window{...}} -> text. Pure.
static func quiet_line(state: Dictionary) -> String:
	if not bool(state.get("requested", false)):
		return "quiet: the running game was not started quiet (it was launched some other way than play_scene quiet=true, or its runtime predates quiet): it plays normally"
	var bits: Array = ["muted" if bool(state.get("muted", false)) else "NOT muted"]
	var w: Variant = state.get("window", null)
	if w is Dictionary:
		var wd: Dictionary = w
		if wd.has("position"):
			var pos: Array = wd["position"]
			bits.append("window at (%d, %d) %s" % [int(pos[0]), int(pos[1]), "ON screen" if bool(wd.get("on_screen", true)) else "off every screen"])
			bits.append("no focus" if bool(wd.get("no_focus", false)) else "takes focus")
			bits.append("still drawing" if bool(wd.get("can_draw", false)) else "NOT drawing")
		elif bool(wd.get("embedded", false)):
			bits.append("embedded window left in place")
		elif bool(wd.get("headless", false)):
			bits.append("headless, no window")
	if int(state.get("remuted", 0)) > 0:
		bits.append("the game unmuted itself %d time(s) and was muted again" % int(state["remuted"]))
	return "quiet: " + ", ".join(PackedStringArray(bits))


# ---------------------------------------------------------------- error breaks (v1.16 B1)

## Is a play_scene launch to carry --ignore-error-breaks? {on: true, source} or {on: false, why}. Pure: the engine's
## version (Engine.get_version_info()["hex"]), the environment variable's text and the project setting's value (null
## when it is not set) are passed in, so the unit suite can pin every case. No flag exists before 4.5; the
## environment wins over the project setting, in both directions (=1 turns it back on over a committed false).
static func ignore_breaks_policy(version_hex: int, env: String, setting: Variant) -> Dictionary:
	if version_hex < IGNORE_BREAKS_SINCE:
		return {"on": false, "why": "this Godot version has no %s (4.5+)" % IGNORE_BREAKS_FLAG}
	match env.strip_edges().to_lower():
		"0", "false", "no", "off":
			return {"on": false, "why": "%s is off" % IGNORE_BREAKS_ENV}
		"1", "true", "yes", "on":
			return {"on": true, "source": IGNORE_BREAKS_ENV}
	if setting != null and not CallArgs.to_bool(setting, true):
		return {"on": false, "why": "the project setting %s is false" % IGNORE_BREAKS_SETTING}
	return {"on": true, "source": "default"}


## ignore_breaks_policy for this engine, this environment and this project (doctor reports it, _breaks_arm obeys
## it). `version_hex` -1 = the running engine; the unit suite passes the version it wants.
static func policy_now(version_hex: int = -1) -> Dictionary:
	if version_hex < 0:
		version_hex = int(Engine.get_version_info().get("hex", 0))
	var setting: Variant = ProjectSettings.get_setting(IGNORE_BREAKS_SETTING, null) if ProjectSettings.has_setting(IGNORE_BREAKS_SETTING) else null
	return ignore_breaks_policy(version_hex, OS.get_environment(IGNORE_BREAKS_ENV), setting)


## main_run_args with the flag added where Godot reads it as its own: at the end of the arguments that belong to the
## engine, which is everything after the first %command% when there is one (what stands before the placeholder is
## the wrapper program and its arguments), or the whole text when there is none; and before a bare "--" or "++",
## after which the engine takes every word for the GAME's own argument and ignores it. The text is otherwise the
## person's, untouched. Returned unchanged when it already carries the flag, and "" when the flag cannot be added:
## the arguments end inside a quote, which would swallow it.
static func with_ignore_flag(args: String) -> String:
	var from := 0
	var placeholder := args.find("%command%")
	if placeholder != -1:
		from = placeholder + "%command%".length()
	var split := _split_run_args(args.substr(from))
	if bool(split["open"]):
		return ""
	var at := -1
	for word in (split["words"] as Array):
		var text: String = word["text"]
		if text == IGNORE_BREAKS_FLAG:
			return args
		if text == "--" or text == "++":
			at = from + int(word["start"])
			break
	if at == -1:
		var head := args.rstrip(" ")
		return IGNORE_BREAKS_FLAG if head.strip_edges().is_empty() else head + " " + IGNORE_BREAKS_FLAG
	return args.substr(0, at) + IGNORE_BREAKS_FLAG + " " + args.substr(at)


## Godot's own split of the Main Run Args text (RunInstancesDialog::_split_cmdline_args in 4.4.1 through 4.7): on
## spaces outside quotes, a quote with a backslash right before it neither opens nor closes one.
## {words: [{text, start}], open: the text ends inside a quote}.
static func _split_run_args(s: String) -> Dictionary:
	var words: Array = []
	var start := 0
	var quote := ""
	for i in s.length():
		var c := s[i]
		if c == "\"" or c == "'":
			if i == 0 or s[i - 1] != "\\":
				if quote.is_empty():
					quote = c
				elif c == quote:
					quote = ""
		elif quote.is_empty() and c == " ":
			if i - start > 0:
				words.append({"text": s.substr(start, i - start), "start": start})
			start = i + 1
	if s.length() - start > 0:
		words.append({"text": s.substr(start), "start": start})
	return {"words": words, "open": not quote.is_empty()}


## Put the flag on the editor's Main Run Args for the one play call that follows. True when this launch carries it
## (armed now, or the person's own arguments already had it). _breaks_disarm puts the text back right after the
## call, and a timer does when this handler dies in between. `version_hex` is a seam for the unit suite (-1 = this engine).
func _breaks_arm(version_hex: int = -1) -> bool:
	_breaks_disarm()  # leftovers of an earlier call can never ride into this one
	if not bool(policy_now(version_hex).get("on", false)):
		return false
	if not ProjectSettings.has_setting(RUN_ARGS_SETTING) or not ProjectSettings.has_signal("settings_changed"):
		return false
	var orig: Variant = ProjectSettings.get_setting(RUN_ARGS_SETTING, "")
	var composed := with_ignore_flag(str(orig))
	if composed.is_empty():
		return false  # the person's arguments end inside a quote: a flag added there would be swallowed by it
	if composed == str(orig):
		return true  # their own arguments already carry it: nothing to change, nothing to put back
	ProjectSettings.set_setting(RUN_ARGS_SETTING, composed)
	if str(ProjectSettings.get_setting(RUN_ARGS_SETTING, "")) != composed:
		ProjectSettings.set_setting(RUN_ARGS_SETTING, orig)  # something pins the setting (override.cfg): leave it alone
		return false
	_args_saved = [orig]
	_args_gen += 1
	ProjectSettings.emit_signal("settings_changed")  # by hand: the dialog's copy of the setting only follows this signal
	_breaks_net_arm(_args_gen)
	return true


## Put the Main Run Args back as they were, and let the dialog's copy follow (a no-op when nothing is armed).
func _breaks_disarm() -> void:
	if _args_saved == null:
		return
	var prev: Array = _args_saved
	_args_saved = null
	ProjectSettings.set_setting(RUN_ARGS_SETTING, prev[0])
	ProjectSettings.emit_signal("settings_changed")


## The net behind _breaks_arm: a timer, for the reason QUIET_NET_SECS gives (anything that fires sooner can fire
## inside the play call, before the game has read its arguments).
func _breaks_net_arm(gen: int) -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).create_timer(QUIET_NET_SECS).timeout.connect(_breaks_net_for.bind(gen))


## The timer of arming `gen` ran out: act only when no later arming has taken over.
func _breaks_net_for(gen: int) -> void:
	if gen == _args_gen:
		_breaks_disarm()


## Validate and park the on_ready batch. Returns the queued count, or an error String.
func _queue_on_ready(raw: Variant) -> Variant:
	server.bridge.queue_on_ready([])
	if raw == null:
		return 0
	if not (raw is Array):
		return "on_ready must be an array of {path, property, value} objects"
	var items: Array = []
	for e in (raw as Array):
		if not (e is Dictionary):
			return "each on_ready entry must be an object with property + value and a path/name/class target"
		var d: Dictionary = e
		if str(d.get("property", "")).is_empty():
			return "on_ready entry is missing 'property'"
		if not d.has("value"):
			return "on_ready entry for '%s' is missing 'value'" % str(d.get("property"))
		if str(d.get("path", "")).is_empty() and str(d.get("name", "")).is_empty() and str(d.get("class", "")).is_empty():
			return "on_ready entry for '%s' needs a target (path, name or class)" % str(d.get("property"))
		items.append(d)
	server.bridge.queue_on_ready(items)
	return items.size()


func _stop_scene(_args: Dictionary) -> Dictionary:
	EditorInterface.stop_playing_scene()
	_quiet_requested = false  # the next game, however it is started, is not the one that was asked to be quiet
	return {"text": "stopped"}


## What the editor says about the game it is running, apart from the bridge: split out so the unit suite (which runs
## without an editor) can answer for it and test everything get_play_state builds around it.
func _editor_play_facts() -> Dictionary:
	return {"playing": EditorInterface.is_playing_scene(), "scene": EditorInterface.get_playing_scene()}


func _get_play_state(_args: Dictionary) -> Dictionary:
	var facts := _editor_play_facts()
	var out := {
		"playing": facts["playing"],
		"scene": facts["scene"],
		"game_connected": server.bridge.is_game_connected(),
	}
	# Paused in the editor's debugger (a script error or a breakpoint): connected and playing, but it answers nothing
	# until someone resumes it. The note is the same text every runtime tool answers with, next step included.
	var paused: String = server.bridge.break_text()
	out["debugger_break"] = not paused.is_empty()
	if not paused.is_empty():
		out["debugger_break_note"] = paused
	var report: Dictionary = server.bridge.on_ready_status()
	if not report.is_empty():
		out["on_ready"] = report
	if _quiet_requested and bool(out["game_connected"]) and paused.is_empty():
		var q := _quiet_state()
		if not q.is_empty():
			out["quiet"] = q
	return {"json": out}


## What the game says a quiet play has in force (its quiet_state reply, reduced to the fields quiet.gd writes, each
## of the right type: see quiet_fields), with what the editor did for it; {} when the game cannot be asked.
func _quiet_state() -> Dictionary:
	var r: Dictionary = server.bridge.send_command({"cmd": "quiet_state"}, 2000)
	if not bool(r.get("ok", false)):
		return {}
	var q := quiet_fields(r)
	if not _quiet_plan.is_empty():
		q["editor"] = {"embed_avoided": bool(_quiet_plan.get("embed_avoided", false)), "view_before": str(_quiet_plan.get("view_before", "")),
			"view_after": str(_quiet_plan.get("view_after", ""))}
	q["summary"] = quiet_line(q)
	return q


## The game's quiet_state answer cut down to the fields runtime/quiet.gd report() writes, each coerced to its type
## and every text capped. The game is another program, and what it says reaches a reply a model reads (and
## quiet_line indexes into it), so an extra key, a wrong type or a long string is dropped here, not forwarded. Pure.
static func quiet_fields(r: Dictionary) -> Dictionary:
	var q := {"requested": CallArgs.to_bool(r.get("requested", false))}
	if not bool(q["requested"]):
		return q
	q["mode"] = str(r.get("mode", "")).left(16)
	q["muted"] = CallArgs.to_bool(r.get("muted", false))
	if _whole(r.get("remuted", 0)) > 0:
		q["remuted"] = _whole(r["remuted"])
	var w: Variant = r.get("window", null)
	if w is Dictionary:
		var win := {}
		for k in ["position", "size"]:
			var v: Variant = (w as Dictionary).get(k, null)
			if v is Array and (v as Array).size() >= 2:
				win[k] = [_whole(v[0]), _whole(v[1])]
		for k in ["on_screen", "no_focus", "handed_back_focus", "can_draw", "embedded", "moved", "headless"]:
			if (w as Dictionary).has(k):
				win[k] = CallArgs.to_bool(w[k])
		for k in ["parked", "frames_drawn", "was_mode"]:
			if (w as Dictionary).has(k):
				win[k] = _whole(w[k])
		q["window"] = win
	return q


## A whole number from an answer that may hold anything: 0 for what is not a number.
static func _whole(v: Variant) -> int:
	return int(v) if (v is int or v is float) else 0


func _wait_until(args: Dictionary) -> Dictionary:
	var cond := str(args.get("condition", ""))
	var guard: Dictionary = {}
	if cond.begins_with("file_exists:"):  # a read of a caller-supplied path: an existence probe is still a probe
		guard = PathGuard.check_read(cond.substr(12))
		if guard.has("error"):
			return guard
	# Hard per-call cap. Blocking the main thread freezes the editor's OWN deferred
	# work — including the play-launch pipeline and background jobs — so a long wait
	# here deadlocks the very condition it polls (game launched in ~1 s once the
	# editor got frames back; a 40 s in-call wait never saw it). Yield instead and
	# let the agent re-call; each HTTP round-trip gives the editor frames.
	var budget: int = clampi(int(args.get("timeout_ms", BLOCK_SLICE_MS)), 100, BLOCK_SLICE_MS)
	if cond.begins_with("seconds:"):
		var ms := int(float(cond.substr(8)) * 1000.0)
		OS.delay_msec(clampi(ms, 0, budget))
		if ms > budget:
			return {"text": "waited %d ms of %s — call again for the remainder (per-call cap keeps the editor responsive)" % [budget, cond]}
		return {"text": "condition met: %s" % cond}
	# A game that broke into the editor's debugger before its runtime could connect never will until someone
	# resumes it (an error in the main scene's _ready is enough): waiting for it here would only answer "not yet",
	# call after call, until the agent gives up and runs the game somewhere else. The editor learns of a break a
	# frame after it happens, so this is checked before the wait, where it can be known, and not after it.
	if cond == "game_connected" and server.bridge != null and not _check(cond):
		var paused: String = server.bridge.break_text()
		if not paused.is_empty():
			return {"error": paused}
	# Pump the bridge each pass — we hold the main thread, so its _process can't run and
	# would otherwise never accept the game's incoming connection.
	var tick := func() -> Dictionary:
		return {"met": true} if _check(cond) else {}
	var pump := Callable(server.bridge, "poll_once") if server.bridge != null else Callable()
	var res: Dictionary = MCPJobsScript.poll_until(budget, 50, tick, pump)
	if res.has("met"):
		# game_connected is where a queued on_ready batch becomes visible: the agent asked
		# for those writes one call ago and has to learn whether they landed.
		var report: Dictionary = server.bridge.on_ready_status() if server.bridge != null else {}
		# A quiet play says what the GAME applied the first time its connection is waited for.
		var quiet_text := ""
		if cond == "game_connected" and _quiet_requested:
			var qs: Dictionary = _quiet_state()
			if not qs.is_empty():
				quiet_text = str(qs.get("summary", ""))
		if not report.is_empty():
			report["condition"] = cond
			if not quiet_text.is_empty():
				report["quiet"] = quiet_text
			return PathGuard.noted({"json": report}, guard)
		return PathGuard.noted({"text": "condition met: %s%s" % [cond, ("; " + quiet_text) if not quiet_text.is_empty() else ""]}, guard)
	return {"error": "not yet: %s (waited %d ms — per-call cap; the editor needs free frames between calls to launch the game and run jobs). Call wait_until again." % [cond, budget]}


func _check(cond: String) -> bool:
	if cond == "play_started":
		return EditorInterface.is_playing_scene()
	if cond == "play_stopped":
		return not EditorInterface.is_playing_scene()
	if cond == "game_connected":
		# Not "met" until any queued on_ready writes have been applied too — reporting the
		# connection while writes are still pending would hand back a half-built world.
		# The queue always empties (its grace window force-fails leftovers), so this ends.
		return server.bridge.is_game_connected() and server.bridge.on_ready_queue.is_empty()
	if cond.begins_with("file_exists:"):
		return FileAccess.file_exists(cond.substr(12))
	if cond.begins_with("seconds:"):
		return false  # handled purely by the timeout loop elapsing
	return false


# ---------------------------------------------------------------- logs_read

func _logs_read(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard: Dictionary = {}
	if path.is_empty():
		# The engine's own log, which Beckett locates (the default, user://logs/godot.log, is in user:// and
		# always passes). The project setting is what says where, and project.godot comes with a cloned
		# repository, so a log_path that names a file outside the project is read under the same rule.
		path = str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
		guard = PathGuard.check_read(path)
		if guard.has("error"):
			return {"error": "The log file comes from the project setting debug/file_logging/log_path. %s" % str(guard["error"]),
				"suggestion": "Point debug/file_logging/log_path back at user://logs/godot.log, or opt out of the read confinement as described above."}
	else:
		guard = PathGuard.check_read(path)
		if guard.has("error"):
			return guard
	if not FileAccess.file_exists(path):
		var newest := _newest_log(path.get_base_dir())
		if newest.is_empty():
			return {"error": "No log file at %s." % path,
				"suggestion": "For the RUNNING game's errors/stack traces/prints, use game_logs (runtime channel, real-time, no file needed). To enable this file log instead: set_project_setting setting=debug/file_logging/enable_file_logging value=true (takes effect next editor/game start)."}
		# The caller named a file that is not there, and this picked another one: the pick is judged like a path
		# they had named (a *.log that is a link out of the project must not be readable through a missing name).
		var picked: Dictionary = PathGuard.check_read(newest)
		if picked.has("error"):
			return picked
		if guard.is_empty():
			guard = picked
		path = newest
	var text := FileAccess.get_file_as_string(path)
	var all := text.split("\n")
	var level := str(args.get("level", "")).to_lower()
	var needle := str(args.get("filter", ""))
	var kept: Array = []
	for line in all:
		var l: String = line
		if not level.is_empty():
			var up := l.to_upper()
			if level == "error" and not up.contains("ERROR"):
				continue
			if level == "warning" and not (up.contains("WARNING") or up.contains("WARN")):
				continue
		if not needle.is_empty() and not l.contains(needle):
			continue
		kept.append(l)
	var n := int(args.get("lines", 200))
	var start := max(0, kept.size() - n)
	var tail: Array = kept.slice(start, kept.size())
	var header := "[%s] %d/%d lines%s" % [path, tail.size(), all.size(),
		(" (level=%s)" % level) if not level.is_empty() else ""]
	return PathGuard.noted({"text": header + "\n" + "\n".join(tail)}, guard)


## Newest godot_*.log in a directory (rotated logs), "" if none. A link that leads out of the project is not a
## candidate (PathGuard.walk_skip): its modified time is the outside file's, and it would win.
func _newest_log(dir_path: String) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	var best := ""
	var best_t := 0
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		var full := dir_path.path_join(e)
		if not dir.current_is_dir() and e.get_extension() == "log" and not PathGuard.walk_skip(full):
			var t := FileAccess.get_modified_time(full)
			if t >= best_t:
				best_t = t
				best = full
		e = dir.get_next()
	dir.list_dir_end()
	return best
