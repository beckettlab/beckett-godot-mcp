@tool
extends RefCounted
class_name BeckettRuntimeObserveTools

## The READ-ONLY half of the play-test loop (L4 See): observe the RUNNING game —
## screenshot, live scene tree, find nodes, read a runtime property, wait for a
## node, sample a property over frames, perf counters, and the runtime log stream.
## Everything here reaches the running game through the BeckettRuntimeBridge but
## only READS it — nothing injects input or mutates state.
##
## This is a CORE module: it ships in the free Lite edition, so Lite can SEE the
## running game (screenshot, live tree, runtime reads). DRIVING it — input, clicks,
## drag/scroll, runtime writes, assertions — is the Full-edition layer in
## runtime_tools.gd. Keeping observe here (core) and drive there (the trimmed
## sentinel) is what lets Lite see the game without shipping the drive code as source.

var server  # mcp_server node (exposes .bridge)

const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")  # poll_until (B2)


func _register(registry) -> void:
	registry.register({
		"name": "screenshot",
		"description": "Capture an image the agent can see (inline PNG). target=game (default) screenshots the RUNNING game via the runtime channel; target=editor captures the 2D editor viewport. region=[x,y,w,h] in pixels crops to that rect (clamped) to save tokens — screenshot full once to learn the size, then crop.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string", "description": "game | editor"},
			"region": {"type": "array", "description": "[x,y,w,h] pixel crop"},
		}},
		"handler": Callable(self, "_screenshot"),
	})
	registry.register({
		"name": "get_remote_tree",
		"description": "Dump the live scene tree of the RUNNING game (runtime counterpart of get_scene_tree). SCOPE IT to stay under token limits — a full game tree blows the budget. path=subtree root (name, relative, or absolute /root/...); depth=levels (-1=all); max_nodes (default 250); max_children per node (default 50); collapse=true groups runs of identical leaf siblings (e.g. '8x CPUParticles2D'). Returns {tree, node_count, truncated?}.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"},
			"depth": {"type": "integer"},
			"max_nodes": {"type": "integer"},
			"max_children": {"type": "integer"},
			"collapse": {"type": "boolean"},
		}},
		"handler": Callable(self, "_get_remote_tree"),
	})
	registry.register({
		"name": "find_nodes",
		"description": "Find LIVE nodes in the RUNNING game by type and/or name; returns their paths to feed into runtime_call/runtime_get_property/runtime_set_property. 'class' matches native classes AND custom class_name scripts (is_class alone misses custom nodes — they read as @Node@NN). name=substring on the node name. path=scope root (default scene root). recursive=true. max=cap (default 100).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"class": {"type": "string"}, "name": {"type": "string"},
			"path": {"type": "string"}, "recursive": {"type": "boolean"},
			"max": {"type": "integer"},
		}},
		"handler": Callable(self, "_find_nodes"),
	})
	registry.register({
		"name": "runtime_get_property",
		"description": "Read a property of a node in the RUNNING game. Address by path (node path/name) OR a live selector: class (native or custom class_name) / name / text [+ nth, default 0]. The selector resolves fresh each call — no need to re-fetch volatile @Node@NN paths. Returns the value plus the 'resolved' path that matched.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "property": {"type": "string"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}, "required": ["property"]},
		"handler": Callable(self, "_runtime_get"),
	})
	registry.register({
		"name": "wait_for_node",
		"description": "Block until a node appears in the RUNNING game (by path/name) or timeout. Use after play_scene to sync before driving.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "timeout_ms": {"type": "integer"},
		}, "required": ["path"]},
		"handler": Callable(self, "_wait_for_node"),
	})
	registry.register({
		"name": "monitor_properties",
		"description": "Sample a node's property in the running game over several frames (detect movement/changes). Returns the sample series.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "property": {"type": "string"},
			"samples": {"type": "integer"}, "interval_ms": {"type": "integer"},
		}, "required": ["path", "property"]},
		"handler": Callable(self, "_monitor_properties"),
	})
	registry.register({
		"name": "get_performance_monitors",
		"description": "Profiling: read Performance monitors (fps, frame time, memory, object/node counts, draw calls, video mem, physics) — measured engine counters, never estimates. target=game (default when a play session is connected) reads the RUNNING game; target=editor reads the editor. duration_s>0 (game only, max 30) SAMPLES OVER TIME: polls every interval_ms (default 100, min 30) while the game keeps running, then returns per-monitor stats {min,avg,p95,max} — e.g. fps.p95 or process_time.max over a stress window; series=true also returns the raw per-sample series (token-heavy). Editor-target sampling is refused honestly: a tool call blocks the editor's own loop, so an over-time editor read would only measure a stalled editor.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string", "description": "game | editor | auto"},
			"duration_s": {"type": "number", "description": "sampling window in seconds (0 = single snapshot; max 30; game target only)"},
			"interval_ms": {"type": "integer", "description": "sampling interval (default 100, min 30)"},
			"series": {"type": "boolean", "description": "include the raw per-sample series, capped at 300 samples (default false)"},
		}},
		"handler": Callable(self, "_get_perf"),
	})
	registry.register({
		"name": "game_logs",
		"description": "Read the RUNNING game's captured output off the runtime channel (real-time, no file logging): runtime SCRIPT errors WITH stack traces, push_error/push_warning, and print(). This is the play->see-error->fix signal — the blind spot logs_read (file-based) can't reliably cover. level=error (default: errors+script+shader) | warning (adds warnings) | all (adds print/stderr). limit=newest N (default 100), filter=substring, clear=true empties the buffer after reading.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"level": {"type": "string", "description": "error | warning | all"},
			"limit": {"type": "integer"}, "filter": {"type": "string"},
			"clear": {"type": "boolean"},
		}},
		"handler": Callable(self, "_game_logs"),
	})


# ---------------------------------------------------------------- runtime-channel (read)

func _screenshot(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", "game"))
	if target == "editor":
		return _editor_screenshot(args)
	var cmd := {"cmd": "screenshot"}
	if args.has("region"):
		cmd["region"] = args["region"]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "screenshot failed"))}
	var note := ""
	if int(r.get("w", 0)) != int(r.get("full_w", r.get("w", 0))) or int(r.get("h", 0)) != int(r.get("full_h", r.get("h", 0))):
		note = " (cropped from %dx%d)" % [int(r.get("full_w", 0)), int(r.get("full_h", 0))]
	return {"image_png_base64": str(r.get("png", "")), "text": "game screenshot %dx%d%s" % [int(r.get("w", 0)), int(r.get("h", 0)), note]}


func _editor_screenshot(args: Dictionary) -> Dictionary:
	var vp := EditorInterface.get_editor_viewport_2d()
	if vp == null:
		return {"error": "no editor 2D viewport available"}
	var img := vp.get_texture().get_image()
	if img == null:
		return {"error": "could not read editor viewport (headless / no RHI?)"}
	var rg = args.get("region", null)
	if rg is Array and rg.size() >= 4:
		var x := clampi(int(rg[0]), 0, img.get_width() - 1)
		var y := clampi(int(rg[1]), 0, img.get_height() - 1)
		var w := clampi(int(rg[2]), 1, img.get_width() - x)
		var h := clampi(int(rg[3]), 1, img.get_height() - y)
		img = img.get_region(Rect2i(x, y, w, h))
	var b64 := Marshalls.raw_to_base64(img.save_png_to_buffer())
	return {"image_png_base64": b64, "text": "editor viewport %dx%d" % [img.get_width(), img.get_height()]}


func _get_remote_tree(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "tree"}
	for k in ["path", "depth", "max_nodes", "max_children", "collapse"]:
		if args.has(k):
			cmd[k] = args[k]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "tree failed"))}
	var out := {"tree": r.get("tree", {}), "node_count": r.get("node_count", 0)}
	if bool(r.get("truncated", false)):
		out["truncated"] = true
		out["hint"] = str(r.get("hint", ""))
	return {"json": out}


func _find_nodes(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "find"}
	for k in ["class", "name", "path", "recursive", "max"]:
		if args.has(k):
			cmd[k] = args[k]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "find failed"))}
	return {"json": {"nodes": r.get("nodes", []), "count": r.get("count", 0)}}


## Copy path + selector fields (class/name/text/nth) from tool args into a bridge cmd,
## so every runtime node op accepts either a path or a live selector. (Also in
## runtime_tools.gd — a tiny helper shared by the observe and drive halves.)
func _add_target(cmd: Dictionary, args: Dictionary) -> void:
	for k in ["path", "class", "name", "text", "nth", "under"]:
		if args.has(k):
			cmd[k] = args[k]


func _runtime_get(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "get", "prop": str(args.get("property", ""))}
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "get failed"))}
	return {"json": {"value": r.get("value"), "resolved": r.get("resolved", "")}}


func _wait_for_node(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running"}
	var path := str(args.get("path", ""))
	var timeout: int = clampi(int(args.get("timeout_ms", 5000)), 100, 60000)
	var tick := func() -> Dictionary:
		var r: Dictionary = server.bridge.send_command({"cmd": "exists", "path": path}, 1000)
		return {"found": true} if bool(r.get("exists", false)) else {}
	var res: Dictionary = MCPJobsScript.poll_until(timeout, 120, tick, Callable(server.bridge, "poll_once"))
	if res.has("timeout"):
		return {"error": "timeout waiting for node: %s" % path}
	return {"text": "node appeared: %s" % path}


func _monitor_properties(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running"}
	var path := str(args.get("path", ""))
	var prop := str(args.get("property", ""))
	var n: int = clampi(int(args.get("samples", 10)), 1, 120)
	var interval: int = clampi(int(args.get("interval_ms", 50)), 10, 2000)
	var series: Array = []  # captured by reference into the tick lambda
	var tick := func() -> Dictionary:
		var r: Dictionary = server.bridge.send_command({"cmd": "get", "path": path, "prop": prop}, 1000)
		series.append(r.get("value"))
		return {"done": true} if series.size() >= n else {}
	MCPJobsScript.poll_until(n * interval + 5000, interval, tick, Callable(server.bridge, "poll_once"))
	return {"json": {"path": path, "property": prop, "samples": series}}


func _get_perf(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", "auto"))
	var use_game: bool = target == "game" or (target == "auto" and server.bridge != null and server.bridge.is_game_connected())
	var duration_s: float = clampf(float(args.get("duration_s", 0.0)), 0.0, 30.0)
	if duration_s > 0.0:
		if not use_game:
			return {"error": "duration_s sampling needs target=game with a play session connected — a tool call blocks the editor's own loop, so an over-time editor sample would only measure a stalled editor. Use single snapshots for the editor."}
		return _sample_perf(duration_s, clampi(int(args.get("interval_ms", 100)), 30, 2000), bool(args.get("series", false)))
	if use_game:
		var r: Dictionary = server.bridge.send_command({"cmd": "perf"})
		if not bool(r.get("ok", false)):
			return {"error": str(r.get("error", "perf failed"))}
		return {"json": {"target": "game", "monitors": r.get("monitors", {})}}
	var out: Dictionary = {}
	for pair in _perf_pairs():
		out[pair[0]] = Performance.get_monitor(pair[1])
	return {"json": {"target": "editor", "monitors": out}}


## Sample the running game's monitors over a window (v1.9): poll cmd=perf every interval,
## then reduce each numeric monitor to {min, avg, p95, max}. The handler blocks the EDITOR
## for the window (sync-handler constraint) while the GAME — its own process — keeps running
## frames, so the numbers are real gameplay measurements. Measured, never modeled.
func _sample_perf(duration_s: float, interval_ms: int, want_series: bool) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running (runtime channel not connected) — play_scene, then wait_until game_connected"}
	var series: Array = []  # captured by reference; poll_until's timeout IS the window end
	var t0 := Time.get_ticks_msec()
	var tick := func() -> Dictionary:
		var r: Dictionary = server.bridge.send_command({"cmd": "perf"}, 1000)
		if bool(r.get("ok", false)) and r.get("monitors", {}) is Dictionary:
			series.append(r.get("monitors"))
		return {}
	MCPJobsScript.poll_until(int(duration_s * 1000.0), interval_ms, tick, Callable(server.bridge, "poll_once"))
	if series.is_empty():
		return {"error": "no samples collected — the game stopped answering during the window"}
	var stats: Dictionary = {}
	var first: Dictionary = series[0]
	for key in first:
		var vals := PackedFloat64Array()
		for s in series:
			var v: Variant = (s as Dictionary).get(key)
			if v is int or v is float:
				vals.append(float(v))
		if vals.is_empty():
			continue
		vals.sort()
		var total := 0.0
		for v in vals:
			total += v
		stats[key] = {
			"min": vals[0],
			"avg": total / float(vals.size()),
			"p95": vals[clampi(int(ceil(float(vals.size()) * 0.95)) - 1, 0, vals.size() - 1)],
			"max": vals[vals.size() - 1],
		}
	var out := {"target": "game", "samples": series.size(), "window_ms": Time.get_ticks_msec() - t0, "interval_ms": interval_ms, "stats": stats}
	if want_series:
		out["series"] = series.slice(0, 300)
	return {"json": out}


func _perf_pairs() -> Array:
	return [
		["fps", Performance.TIME_FPS],
		["process_time", Performance.TIME_PROCESS],
		["physics_process_time", Performance.TIME_PHYSICS_PROCESS],
		["memory_static", Performance.MEMORY_STATIC],
		["memory_static_max", Performance.MEMORY_STATIC_MAX],
		["object_count", Performance.OBJECT_COUNT],
		["resource_count", Performance.OBJECT_RESOURCE_COUNT],
		["node_count", Performance.OBJECT_NODE_COUNT],
		["orphan_node_count", Performance.OBJECT_ORPHAN_NODE_COUNT],
		["draw_calls", Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME],
		["render_objects", Performance.RENDER_TOTAL_OBJECTS_IN_FRAME],
		["render_primitives", Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME],
		["video_mem_used", Performance.RENDER_VIDEO_MEM_USED],
		["texture_mem", Performance.RENDER_TEXTURE_MEM_USED],
		["buffer_mem", Performance.RENDER_BUFFER_MEM_USED],
		["physics_2d_active", Performance.PHYSICS_2D_ACTIVE_OBJECTS],
		["physics_3d_active", Performance.PHYSICS_3D_ACTIVE_OBJECTS],
	]


func _game_logs(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running (runtime channel not connected) — play_scene, then wait_until game_connected"}
	var cmd := {"cmd": "logs"}
	for k in ["level", "limit", "filter", "clear"]:
		if args.has(k):
			cmd[k] = args[k]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "logs failed"))}
	var entries: Array = r.get("entries", [])
	var level := str(args.get("level", "error"))
	var meta := "buffer=%d, dropped=%d" % [int(r.get("buffer_size", 0)), int(r.get("dropped", 0))]
	# On Godot < 4.5 the game side can't install the log sink (the Logger API is 4.5+), so
	# the buffer is always empty. Say so explicitly — an empty result here must NOT read as
	# "the game logged no errors" when it really means capture isn't available on this engine.
	if not bool(r.get("capture_active", true)):
		return {"text": "game_logs is unavailable on this Godot version — real-time capture needs the Logger API (OS.add_logger), which is Godot 4.5+. The running game's errors/warnings/prints are NOT captured here; use logs_read (file log) instead, or run on Godot 4.5+."}
	if entries.is_empty():
		return {"text": "no log entries at level=%s (%s)" % [level, meta]}
	var lines: Array = []
	for e in entries:
		lines.append(_fmt_log(e))
	return {"text": "%d entr(ies) (level=%s, %s):\n%s" % [entries.size(), level, meta, "\n".join(lines)]}


func _fmt_log(e: Dictionary) -> String:
	var ty := str(e.get("type", ""))
	if ty == "print" or ty == "stderr":
		return "[%s] %s" % [ty.to_upper(), str(e.get("text", "")).strip_edges()]
	var head := "[%s] %s:%d" % [ty.to_upper(), str(e.get("file", "?")), int(e.get("line", 0))]
	var fn := str(e.get("function", ""))
	if fn != "":
		head += " in %s()" % fn
	var rat := str(e.get("rationale", ""))
	if rat != "":
		head += " — " + rat
	var bt := str(e.get("backtrace", ""))
	if bt != "":
		head += "\n" + bt
	return head
