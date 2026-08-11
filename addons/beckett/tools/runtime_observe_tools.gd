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

## Long-edge cap applied to a screenshot call that asked for no framing of its own (1.13).
## A bare capture of a 1440p game moved 5.5 MB of base64 for a picture the model reads just
## as well at 1280 px; any explicit sizing argument opts out (see _screenshot).
const DEFAULT_MAX_DIM := 1280


func _register(registry) -> void:
	registry.register({
		"name": "screenshot",
		"description": "Capture an image the agent can see. target=game (default) screenshots the RUNNING game via the runtime channel; target=editor captures the 2D editor viewport (PNG only). Token-cost dials (game target, 1.10+): scale=0.5 quarters the pixels; max_dim (1.13+) caps the long edge in px, and a call passing NO framing argument defaults to max_dim=1280, so pass scale=1.0, region, max_dim=0, format or save_to to opt out; format=jpeg|webp with quality (default 0.8) compresses far below PNG for game frames; region=[x,y,w,h] crops (clamped). annotate=ui draws numbered Set-of-Mark boxes over every visible interactive control and ALSO returns the legend as structured {marks:[{i, path, rect, text?}]} — one glance answers both 'does it look right' and 'what can I click where'; follow up with click_control path=<legend path>. For pure functional state, ui_snapshot is cheaper than any image.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string", "description": "game | editor"},
			"region": {"type": "array", "description": "[x,y,w,h] pixel crop"},
			"scale": {"type": "number", "description": "0.05..1.0 downscale before encode (game target; default 1.0)"},
			"max_dim": {"type": "integer", "description": "cap the long edge in px (default 1280 on a call with no other framing argument; 0 = no cap)"},
			"format": {"type": "string", "description": "png (default) | jpeg | webp (game target)"},
			"quality": {"type": "number", "description": "jpeg/webp quality 0.1..1.0 (default 0.8)"},
			"annotate": {"type": "string", "description": "'ui' = draw numbered marks on interactive controls + return the legend (game target)"},
			"max_marks": {"type": "integer", "description": "cap on annotate marks (default 40)"},
			"save_to": {"type": "string", "description": "also write the frame to this path (res://, user:// or absolute) so later captures can be diffed against it — the agent still gets the image inline"},
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
		"name": "ui_snapshot",
		"description": "One-call UI snapshot of the RUNNING game: every visible Control as structured data — path, class (+custom class_name), text, rect [x,y,w,h] (gui space, ints), and the semantic state pixels can't tell you: disabled, focused, checked (toggles), value + range (sliders/spin/progress), selected (+selected_text / tabs / item_count), editable / placeholder / secret (text fields), tooltip, mouse_ignore. Interactive controls also get honesty flags: clipped (scrolled out of view) and occluded_by (another control would swallow the click — popup/modal/overlay). Top level: focus owner, open popup/dialog windows (exclusive = modal), viewport size, and a stable content 'hash' — pass it back as since_hash and an unchanged UI returns {unchanged:true} for ~free. For functional UI checks this replaces the screenshot + find_ui_elements + get_control_rect + runtime_get_property round-trips (keep screenshot for VISUAL/render bugs). Walks the whole SceneTree root (autoload HUD layers and popups included); scope with path=, slim with interactive_only=true, cap with max_nodes (default 400).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "subtree root to scope the walk (name, relative, or /root/...)"},
			"interactive_only": {"type": "boolean", "description": "only buttons/sliders/text fields/lists/tabs + focusables (default false: all visible controls, labels included)"},
			"occlusion": {"type": "boolean", "description": "compute occluded_by for interactive controls (default true; one hit-test walk per interactive control)"},
			"max_nodes": {"type": "integer", "description": "cap on emitted controls (default 150)"},
			"since_hash": {"type": "string", "description": "hash from a previous call — unchanged UI returns {unchanged:true} instead of the payload"},
		}},
		"handler": Callable(self, "_ui_snapshot"),
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
	registry.register({
		"name": "render_probe",
		"description": "Ask WHY a 3D node is or is not on screen, as data instead of pixels. Answers the 'the node exists, visible is true, the log is clean, and I still see nothing' case: visibility chain, world AABB, frustum test, distance vs far plane and visibility range, layers vs the camera cull_mask, per-surface material + cull mode, and the triangle winding the camera actually sees (facing_camera=0 with back-face culling means a reversed index buffer — Godot treats CLOCKWISE winding as the FRONT face). Returns a 'warnings' list naming the stage that broke, or a verdict saying the geometry does reach the camera. USE THIS BEFORE tuning lighting, fog, exposure or palette on anything you cannot clearly see — those are invisible-mesh symptoms far more often than they are art problems.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "node path or name in the running game"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"nth": {"type": "integer"}, "under": {"type": "string"},
		}},
		"handler": Callable(self, "_render_probe"),
	})
	registry.register({
		"name": "set_debug_draw",
		"description": "Switch the RUNNING game's viewport debug draw mode, then screenshot to see one render stage in isolation. unshaded = albedo only (clears lighting/fog/exposure as suspects in one shot). wireframe = is the geometry even there (culled or degenerate meshes show as nothing). overdraw = transparency cost. normal_buffer = flipped or NaN normals. lighting = light contribution only. normal = back to the real image. Reach for this FIRST when the picture is wrong; render_probe then answers the same question in numbers.",
		"input_schema": {"type": "object", "properties": {
			"mode": {"type": "string", "description": "normal | unshaded | lighting | overdraw | wireframe | normal_buffer"},
		}, "required": ["mode"]},
		"handler": Callable(self, "_set_debug_draw"),
	})


# ---------------------------------------------------------------- runtime-channel (read)

func _screenshot(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", "game"))
	if target == "editor":
		return _editor_screenshot(args)
	var cmd := {"cmd": "screenshot"}
	for k in ["region", "scale", "format", "quality", "annotate", "max_marks", "max_dim"]:
		if args.has(k):
			cmd[k] = args[k]
	# Cap the DEFAULT capture only. Any argument that frames or sizes the frame means the
	# caller already decided what they want back: scale/region/max_dim are explicit sizing,
	# format is a deliberate quality call, and save_to is how a baseline gets minted, which
	# must be native. annotate is deliberately NOT in that list: the cap rides in `scale`
	# runtime-side, so the marks and their legend stay correct at any factor.
	if not (args.has("scale") or args.has("region") or args.has("max_dim") \
			or args.has("format") or args.has("save_to")):
		cmd["max_dim"] = DEFAULT_MAX_DIM
	# Big frames + jpeg/webp encode + the annotate walk can push a cold heavy scene
	# past the 4 s default — same reasoning as ui_snapshot's longer deadline.
	var r: Dictionary = server.bridge.send_command(cmd, 10000)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "screenshot failed"))}
	var desc := "game screenshot %dx%d (%s)" % [int(r.get("w", 0)), int(r.get("h", 0)), str(r.get("mime", "image/png"))]
	if int(r.get("w", 0)) != int(r.get("full_w", r.get("w", 0))) or int(r.get("h", 0)) != int(r.get("full_h", r.get("h", 0))):
		desc += " (from %dx%d)" % [int(r.get("full_w", 0)), int(r.get("full_h", 0))]
	if r.has("note"):
		desc += " — " + str(r.get("note", ""))
	var out := {"image_base64": str(r.get("data", r.get("png", ""))), "image_mime": str(r.get("mime", "image/png"))}
	if args.has("save_to"):
		# The bytes are already here — saving them server-side costs nothing and removes the
		# only reason an agent ever had to edit the GAME (adding a capture() helper to the
		# deliverable) just to look at it. It also gives compare_screenshots a baseline.
		var saved := _save_capture(str(out["image_base64"]), str(args["save_to"]))
		if saved.is_empty():
			desc += " → saved %s" % str(args["save_to"])
		else:
			desc += " (save failed: %s)" % saved
	out["text"] = desc
	if r.has("marks"):
		# Legend rides as structuredContent, beside the plain line. Before v1.13.0 the
		# serializer's if/elif made these exclusive, so annotated captures had to bury
		# the readable line inside the json to keep both - and the line is not repeated
		# in here now that it does not have to be.
		out["json"] = {"marks": r.get("marks", [])}
	return out


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
	var desc := "editor viewport %dx%d" % [img.get_width(), img.get_height()]
	if args.has("save_to"):
		var saved := _save_capture(b64, str(args["save_to"]))
		desc += (" → saved %s" % str(args["save_to"])) if saved.is_empty() else (" (save failed: %s)" % saved)
	return {"image_png_base64": b64, "text": desc}


## Write a base64 capture to disk. Returns "" on success, else the reason — a failed save
## must never look like a successful one, and must never lose the image either (the caller
## still returns the frame inline).
func _save_capture(b64: String, path: String) -> String:
	if path.is_empty():
		return "empty path"
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var derr := DirAccess.make_dir_recursive_absolute(dir)
		if derr != OK:
			return "cannot create %s: %s" % [dir, error_string(derr)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return error_string(FileAccess.get_open_error())
	f.store_buffer(Marshalls.base64_to_raw(b64))
	f.close()
	return ""


func _ui_snapshot(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "ui_snapshot"}
	for k in ["path", "interactive_only", "occlusion", "max_nodes", "since_hash"]:
		if args.has(k):
			cmd[k] = args[k]
	# A cold heavy scene can stall frames past the default 4 s deadline (measured on a
	# real RPG right after load) — a snapshot is worth the longer wait, never a desync.
	var r: Dictionary = server.bridge.send_command(cmd, 10000)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "ui_snapshot failed"))}
	var out := r.duplicate()
	out.erase("ok")
	out.erase("_id")
	return {"json": out}


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


## --- render diagnosis (v1.12) ------------------------------------------------
## Observation, so it lives in the CORE module and ships in Lite: the free edition's whole
## promise is that the AI can SEE the running game, and "I can see it is wrong but not why"
## was the largest remaining hole in that promise.

func _render_probe(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."}
	var cmd := {"cmd": "render_probe"}
	_add_target(cmd, args)
	# Sampling the index buffer of a dense mesh reads its arrays once — worth a longer
	# deadline than a plain property read, same reasoning as ui_snapshot.
	var r: Dictionary = server.bridge.send_command(cmd, 10000)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "render_probe failed")), "suggestion": str(r.get("suggestion", ""))}
	var out := r.duplicate()
	out.erase("ok")
	out.erase("_id")
	return {"json": out}


func _set_debug_draw(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."}
	var r: Dictionary = server.bridge.send_command({"cmd": "debug_draw", "mode": str(args.get("mode", "normal"))})
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "set_debug_draw failed")), "suggestion": str(r.get("suggestion", ""))}
	var text := "debug draw: %s (was %s)" % [str(r.get("mode", "")), str(r.get("previous", ""))]
	if r.has("note"):
		text += " — " + str(r["note"])
	text += ". Take a screenshot to see it; set_debug_draw mode=normal restores the real image."
	return {"text": text}


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
