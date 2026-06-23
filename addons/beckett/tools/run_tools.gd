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

var server  # mcp_server node (exposes .bridge)


func _register(registry) -> void:
	registry.register({
		"name": "play_scene",
		"description": "Play a scene in the editor. 'scene' (res://) plays a specific scene; current=true plays the open scene; otherwise the project's main scene. Then wait_until condition=play_started, and logs_read for errors.",
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "res:// path; omit for main/current"},
			"current": {"type": "boolean"},
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
		"description": "Report whether a scene is playing and whether the runtime channel to the game is connected.",
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
	if not scene.is_empty():
		if not ResourceLoader.exists(scene):
			return {"error": "No scene at: %s" % scene}
		EditorInterface.play_custom_scene(scene)
		return {"text": "playing %s" % scene}
	if bool(args.get("current", false)):
		EditorInterface.play_current_scene()
		return {"text": "playing current scene"}
	EditorInterface.play_main_scene()
	return {"text": "playing main scene"}


func _stop_scene(_args: Dictionary) -> Dictionary:
	EditorInterface.stop_playing_scene()
	return {"text": "stopped"}


func _get_play_state(_args: Dictionary) -> Dictionary:
	return {"json": {
		"playing": EditorInterface.is_playing_scene(),
		"scene": EditorInterface.get_playing_scene(),
		"game_connected": server.bridge.is_game_connected(),
	}}


func _wait_until(args: Dictionary) -> Dictionary:
	var cond := str(args.get("condition", ""))
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
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < budget:
		# Pump the bridge — we hold the main thread, so its _process can't run and
		# would otherwise never accept the game's incoming connection.
		if server.bridge != null:
			server.bridge.poll_once()
		if _check(cond):
			return {"text": "condition met: %s" % cond}
		OS.delay_msec(50)
	return {"error": "not yet: %s (waited %d ms — per-call cap; the editor needs free frames between calls to launch the game and run jobs). Call wait_until again." % [cond, budget]}


func _check(cond: String) -> bool:
	if cond == "play_started":
		return EditorInterface.is_playing_scene()
	if cond == "play_stopped":
		return not EditorInterface.is_playing_scene()
	if cond == "game_connected":
		return server.bridge.is_game_connected()
	if cond.begins_with("file_exists:"):
		return FileAccess.file_exists(cond.substr(12))
	if cond.begins_with("seconds:"):
		return false  # handled purely by the timeout loop elapsing
	return false


# ---------------------------------------------------------------- logs_read

func _logs_read(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		path = str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
	if not FileAccess.file_exists(path):
		var newest := _newest_log(path.get_base_dir())
		if newest.is_empty():
			return {"error": "No log file at %s." % path,
				"suggestion": "For the RUNNING game's errors/stack traces/prints, use game_logs (runtime channel, real-time, no file needed). To enable this file log instead: set_project_setting setting=debug/file_logging/enable_file_logging value=true (takes effect next editor/game start)."}
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
	return {"text": header + "\n" + "\n".join(tail)}


## Newest godot_*.log in a directory (rotated logs), "" if none.
func _newest_log(dir_path: String) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	var best := ""
	var best_t := 0
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if not dir.current_is_dir() and e.get_extension() == "log":
			var full := dir_path.path_join(e)
			var t := FileAccess.get_modified_time(full)
			if t >= best_t:
				best_t = t
				best = full
		e = dir.get_next()
	dir.list_dir_end()
	return best
