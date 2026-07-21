extends Node

## Game side of the runtime channel (B2). Registered as a project autoload by the
## plugin. NOT a @tool script — it runs ONLY in the played game, never in the editor.
## When a scene plays it dials the editor's BeckettRuntimeBridge and serves commands:
## screenshot, input simulation, live scene tree, runtime get/set/call.
##
## If the MCP server isn't running, the dial just fails and the game runs normally —
## zero impact when the bridge is off.

const RETRY_INTERVAL := 2.0

var _peer := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _port := 8771
var _since_retry := 0.0
var _was_connected := false
var _hello_sent := false  # handshake line sent for the CURRENT connection (v1.9.1)

# Input recording (record_input / replay_input over the bridge).
var _recording := false
var _rec: Array = []
var _rec_t0 := 0
var _rec_f0 := 0                  # Engine.get_physics_frames() at record_start; events stamp the frame delta 'f' for deterministic (frame-stepped) replay

# Deterministic playtest control (time_control tool). A stepping WINDOW can't run
# inside a single bridge handler — physics only advances between frames, and the
# handler blocks the frame it runs on — so `step`/`step_until` just OPEN the window
# (unpause + arm the flag) and reply immediately; _physics_process counts the ticks
# and closes it (re-pause), while the editor polls tc_status. Because this autoload is
# PROCESS_MODE_ALWAYS, its _physics_process fires even when the tree is paused, so the
# tick counter is gated on `not get_tree().paused` — it counts ONLY real, unpaused
# physics ticks during an open window (a naive counter would over-count paused frames).
var _stepping := false            # a step/step_until window is open
var _step_kind := ""              # "count" (fixed N frames) or "until" (condition)
var _step_target := 0             # frames to run for kind=count
var _step_count := 0              # unpaused physics ticks seen so far this window
var _step_deadline := 0          # Time.get_ticks_msec() cap for kind=until (timeout)
var _step_max_frames := 0         # optional frame cap for kind=until (0 = none)
var _step_cond := ""              # condition source for kind=until
var _step_expr: Object = null     # compiled Expression for the condition (game-side)
var _step_result := ""            # terminator that closed the last window: done|condition|timeout|max_frames
var _step_cond_value = null       # last evaluated condition value (for step_until reporting)
var _resume_paused := true        # re-pause when the window closes (step always leaves paused)
var _step_open_frame := 0         # Engine.get_physics_frames() snapshotted when the window opened (delta base)

# Deterministic input replay window (playtest op=run). Mirrors the stepping window above:
# unpause, run UNPAUSED physics ticks, inject each event when the tick index reaches its
# recorded frame stamp 'f', then re-pause so asserts read a settled, reproducible state.
# Injection happens mid-frame while UNPAUSED, so both _input() callbacks AND polled Input.*
# state see it (a paused inject would miss pausable nodes' _input).
var _replaying := false
var _replay_events: Array = []
var _replay_i := 0
var _replay_tick := 0
var _replay_end := 0
var _replay_injected := 0
# Perf capture across the replay window (v1.9 "measured, not estimated") — extracted to its
# own module in the v1.9.1 B7 split; see runtime/replay_perf.gd for the how and the why.
const ReplayPerf := preload("res://addons/beckett/runtime/replay_perf.gd")
var _replay_perf := ReplayPerf.new()
# Wire-format <-> InputEvent codec (recorder, `input` cmd, replay injection) — B7 split.
const InputCodec := preload("res://addons/beckett/runtime/input_codec.gd")
# UI snapshot + the occlusion hit test behind click_control's accuracy precheck
# (v1.10 UI-playtest pillar) — feature logic lives in ui_inspect.gd, dispatch here.
const UiInspect := preload("res://addons/beckett/runtime/ui_inspect.gd")
# ui_do macro window (v1.10 P1): one call = a whole click/type/wait/assert flow run
# game-side across frames. The machine lives in ui_do.gd; _process ticks it.
const UiDo := preload("res://addons/beckett/runtime/ui_do.gd")
var _ui_do := UiDo.new()
# Call-arg coercion shared VERBATIM with the editor's call_method (v1.10.2), so the
# two sides can't drift. core/callargs.gd is dependency-free on purpose: it parses in
# the game process and in export-template builds (no editor classes).
const CallArgs := preload("res://addons/beckett/core/callargs.gd")

# Per-frame typing window (v1.11): type_text per_frame=true queues its chars here and
# _process injects ONE per frame, so per-char handlers (text_changed each keystroke,
# typing minigames, char rate limits) see real typing instead of paste semantics.
# The editor tool polls cmd=type_status until the queue drains.
var _typing_ctrl: Control = null
var _typing_text := ""
var _typing_i := 0
var _typing_submit := false
var _typing_done := true
var _typing_error := ""

# Captured game output — runtime script errors WITH stack traces, push_error/warning,
# and print() — via a custom OS Logger installed in the played game. This is the
# real-time play->see-error->fix signal the agent reads through the game_logs tool;
# no file logging, no editor debugger needed (the engine routes built-in error/output
# to the internal debugger, not to EditorDebuggerPlugin captures — so we tap them here,
# at the source, in the game process itself).
#
# The Logger base class + OS.add_logger() are Godot 4.5+. On older engines (4.2–4.4)
# there's no such API, so capture gracefully no-ops and game_logs returns empty (see
# _install_log_sink). Everything Logger-typed is kept out of parse scope — typed Object
# here, the sink compiled at runtime — so this file still parses/loads on 4.2–4.4.
# Ring + runtime-compiled OS Logger — extracted to runtime/game_log_sink.gd (B7 split);
# the 4.5+ parse-safety story lives there now.
const GameLogSink := preload("res://addons/beckett/runtime/game_log_sink.gd")
var _log_sink := GameLogSink.new()


func _ready() -> void:
	# Duplicate-autoload guard (v1.9.1; found by the rpg-village heavy-game test): a project
	# upgraded across the godot_mcp->beckett rename can carry TWO autoload entries pointing
	# at this same script. Both twins would dial the bridge with the same valid session
	# token, and the newer one displaces the older MID-COMMAND — replay windows then report
	# frames=0 from the wrong twin. Tie-break on child INDEX, not _ready order (Godot adds
	# all autoloads before readying any, so the lowest-index twin is the deterministic
	# winner whether _ready fires incrementally or all-at-once); every later twin goes
	# dormant loudly. Comparing self.get_index() is order-independent — the earlier attempt
	# that gated on "a same-script sibling exists" made BOTH twins dormant.
	for sib in get_tree().root.get_children():
		if sib != self and sib.get_script() == get_script() and sib.get_index() < get_index():
			push_warning("[beckett] duplicate runtime autoload '%s' (twin of '%s') — staying dormant; remove the stale autoload entry from project.godot" % [name, sib.name])
			set_process(false)
			set_physics_process(false)
			set_process_input(false)
			return
	# Keep serving while the game is paused (get_tree().paused = true) — pause
	# menus and game-over screens are exactly when the agent needs to look at the
	# game and click buttons; an INHERIT-mode autoload would freeze the channel.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var p := OS.get_environment("BECKETT_RUNTIME_PORT")
	if p != "" and p.is_valid_int():
		_port = p.to_int()
	_dial()
	set_process(true)
	set_process_input(true)
	# Tap the game's own log stream (errors/warnings/stack traces/prints).
	# Logger + OS.add_logger() are Godot 4.5+; on 4.2–4.4 this is a graceful no-op.
	_log_sink.install()


func _exit_tree() -> void:
	_log_sink.uninstall()


func _input(event: InputEvent) -> void:
	if not _recording:
		return
	var d: Dictionary = InputCodec.serialize_event(event)
	if not d.is_empty():
		d["t"] = float(Time.get_ticks_msec() - _rec_t0)
		d["f"] = Engine.get_physics_frames() - _rec_f0
		_rec.append(d)


func _dial() -> void:
	_peer = StreamPeerTCP.new()
	_hello_sent = false
	_peer.connect_to_host("127.0.0.1", _port)


func _process(delta: float) -> void:
	_peer.poll()
	var st := _peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTED:
		if not _hello_sent:
			_hello_sent = true
			# v1.9.1 handshake: identify to the editor bridge with the session token the
			# editor exported into our environment (empty when auth is off — the bridge
			# accepts either per its own expected_token). Sent exactly once per connection;
			# the bridge consumes it before promoting us to the live peer.
			_peer.put_data((JSON.stringify({"hello": OS.get_environment("BECKETT_RUNTIME_TOKEN")}) + "\n").to_utf8_buffer())
		_was_connected = true
		var avail := _peer.get_available_bytes()
		if avail > 0:
			var res: Array = _peer.get_partial_data(avail)
			if res[0] == OK:
				_buf.append_array(res[1])
		while true:
			var nl := _buf.find(10)
			if nl == -1:
				break
			var line := _buf.slice(0, nl).get_string_from_utf8()
			_buf = _buf.slice(nl + 1)
			_handle(line)
		# Advance an open ui_do macro window one attempt per frame (after command
		# handling, so an open/abort from this very frame is already applied).
		_ui_do.tick()
		# Per-frame typing window (v1.11): inject one queued char per frame.
		_type_tick()
	elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
		# Reconnect on DROP too, not just before the first connect. A mid-session drop
		# (bridge restart, editor focus loss) used to be permanent — the old retry was
		# gated on `not _was_connected`, so once connected it never re-dialed until a
		# stop+replay. Now we re-dial on the same interval whenever the link is down.
		if _was_connected:
			# Just lost an established link: reset read state and re-dial promptly.
			_was_connected = false
			_buf = PackedByteArray()
			_since_retry = RETRY_INTERVAL
		_since_retry += delta
		if _since_retry >= RETRY_INTERVAL:
			_since_retry = 0.0
			_dial()


# Drive an open stepping window forward one physics tick at a time. Runs in
# PROCESS_MODE_ALWAYS, so it also fires while the tree is paused — we count ONLY
# ticks that happen while the tree is genuinely UNPAUSED, so a step of N advances
# the game by exactly N physics frames (paused ticks in between never count).
func _physics_process(_delta: float) -> void:
	if _replaying:
		var rtree := get_tree()
		if rtree != null and not rtree.paused:
			_replay_step_tick()
		return
	if not _stepping:
		return
	var tree := get_tree()
	if tree == null:
		return
	# Only a real, UNPAUSED physics tick advances the game — count that one. This gate is
	# why an ALWAYS-mode autoload doesn't over-count: its _physics_process fires even while
	# the tree is paused, but those ticks are skipped here.
	if tree.paused:
		return
	_step_count += 1
	match _step_kind:
		"count":
			if _step_count >= _step_target:
				_close_step("done")
		"until":
			# Evaluate the condition AFTER this tick's simulation — the moment it is true we
			# pause. (An already-true condition is handled at open time with 0 frames run.)
			if _eval_step_condition():
				_close_step("condition")
			elif _step_max_frames > 0 and _step_count >= _step_max_frames:
				_close_step("max_frames")
			elif Time.get_ticks_msec() >= _step_deadline:
				_close_step("timeout")


## Close the open stepping window: record the terminator and (for step, always) re-pause
## the tree so the game holds exactly where the step left it. The reported frame delta is
## derived as open_frame + _step_count (see _tc_step_status), so it always equals the
## number of real ticks that ran, even though the raw engine counter keeps ticking while
## paused between this close and the editor's status poll.
func _close_step(reason: String) -> void:
	_stepping = false
	_step_result = reason
	_step_expr = null
	var tree := get_tree()
	if tree != null and _resume_paused:
		tree.paused = true


## Evaluate the step_until condition against the running scene, game-side, once.
## Uses a GDScript Expression bound to the current scene root (its properties and
## methods are in scope, e.g. "get_node(\"Player\").position.y > 500"). Any parse/exec
## error is treated as "not yet" and stashed so the terminator report can surface it.
func _eval_step_condition() -> bool:
	if _step_expr == null:
		return false
	var root := _root()
	var base: Object = root if root != null else self
	var v: Variant = _step_expr.execute([], base, true)
	if _step_expr.has_execute_failed():
		_step_cond_value = "error: " + _step_expr.get_error_text()
		return false
	_step_cond_value = _safe(v)
	return bool(v)


## Open a deterministic replay window: sort events by frame stamp, unpause, and let
## _physics_process inject them tick-by-tick. The editor polls replay_status until it closes.
func _replay_open(msg: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	if _stepping:
		return {"ok": false, "error": "a time_control step window is open — finish/unfreeze it before replay"}
	var evs: Array = msg.get("events", []) if msg.get("events", []) is Array else []
	var ordered := evs.duplicate()
	ordered.sort_custom(func(a, b): return int(a.get("f", 0)) < int(b.get("f", 0)))
	_replay_events = ordered
	_replay_i = 0
	_replay_tick = 0
	_replay_injected = 0
	_replay_perf.begin()
	var settle: int = maxi(0, int(msg.get("settle_frames", 4)))
	var last_f := 0
	if ordered.size() > 0:
		last_f = int(ordered[ordered.size() - 1].get("f", 0))
	_replay_end = last_f + settle
	_replaying = true
	_resume_paused = true
	tree.paused = false
	return {"ok": true, "started": true, "events": ordered.size(), "end_frame": _replay_end}


## One UNPAUSED physics tick of the replay window (called from _physics_process): fire every
## event whose recorded frame 'f' has arrived, advance the tick, and re-pause once all events
## have fired and the settle margin has elapsed.
func _replay_step_tick() -> void:
	_replay_perf.tick()
	while _replay_i < _replay_events.size():
		var ev: Dictionary = _replay_events[_replay_i]
		if int(ev.get("f", 0)) > _replay_tick:
			break
		var ie: InputEvent = InputCodec.build_event(ev)
		if ie != null:
			Input.parse_input_event(ie)
			_replay_injected += 1
		_replay_i += 1
	_replay_tick += 1
	if _replay_i >= _replay_events.size() and _replay_tick > _replay_end:
		_replaying = false
		var tree := get_tree()
		if tree != null:
			tree.paused = true


func _handle(line: String) -> void:
	var msg: Variant = JSON.parse_string(line)
	if not (msg is Dictionary):
		return
	var resp := _dispatch(msg)
	# Echo the editor's sequence id so a late reply (this handler ran past the editor's
	# read deadline) is recognised as stale on the next command instead of desyncing.
	if (msg as Dictionary).has("_id"):
		resp["_id"] = (msg as Dictionary)["_id"]
	_peer.put_data((JSON.stringify(resp) + "\n").to_utf8_buffer())


func _dispatch(msg: Dictionary) -> Dictionary:
	match str(msg.get("cmd", "")):
		"ping":
			return {"ok": true, "scene": _scene_name()}
		"tree":
			return _tree_cmd(msg)
		"screenshot":
			return _screenshot(msg)
		"input":
			return _run_input(msg.get("events", []))
		"get":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			return {"ok": true, "value": _safe(n.get(str(msg.get("prop", "")))), "resolved": str(_root().get_path_to(n))}
		"set":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			var prop := str(msg.get("prop", ""))
			n.set(prop, _coerce_value(n, prop, msg.get("value")))
			return {"ok": true, "resolved": str(_root().get_path_to(n))}
		"call":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			return _call_cmd(n, msg)
		"exists":
			return {"ok": true, "exists": _resolve_target(msg) != null}
		"find":
			return _find(msg)
		"click_text":
			return _click_text(msg)
		"click_control":
			return _click_control(msg)
		"control_rect":
			return _control_rect(msg)
		"ui_snapshot":
			return _ui_snapshot(msg)
		"type_text":
			return _type_text(msg)
		"type_status":
			return _type_status()
		"ui_audit":
			return _ui_audit(msg)
		"ui_do_open":
			if _stepping or _replaying:
				return {"ok": false, "error": "a time_control/replay window is open — close it before ui_do"}
			return _ui_do.open(self, msg)
		"ui_do_status":
			return _ui_do.status()
		"ui_do_abort":
			return _ui_do.abort()
		"click_node3d":
			return _click_node3d(msg)
		"click_world":
			return _click_world(msg)
		"scroll":
			return _scroll_cmd(msg)
		"drag":
			return _drag_cmd(msg)
		"perf":
			return {"ok": true, "monitors": _perf_monitors()}
		"logs":
			return _log_sink.snapshot(msg)
		"record_start":
			_recording = true
			_rec = []
			_rec_t0 = Time.get_ticks_msec()
			_rec_f0 = Engine.get_physics_frames()
			return {"ok": true}
		"record_stop":
			_recording = false
			return {"ok": true, "events": _rec.duplicate()}
		"eval":
			var er := _root()
			var eb: Object = er if er != null else self
			var eex := Expression.new()
			if eex.parse(str(msg.get("expr", ""))) != OK:
				return {"ok": false, "error": "expr parse error: %s" % eex.get_error_text()}
			var eval_v: Variant = eex.execute([], eb, true)
			if eex.has_execute_failed():
				return {"ok": false, "error": "expr exec error: %s" % eex.get_error_text()}
			return {"ok": true, "value": _safe(eval_v)}
		"replay_open":
			if _ui_do.active:
				return {"ok": false, "error": "a ui_do window is open — let it finish (ui_do_status) or ui_do_abort first"}
			return _replay_open(msg)
		"replay_status":
			return {"ok": true, "replaying": _replaying, "injected": _replay_injected, "frames": _replay_tick, "total_events": _replay_events.size(), "remaining": _replay_events.size() - _replay_i, "paused": (get_tree() != null and get_tree().paused), "perf": _replay_perf.summary()}
		"tc_freeze":
			return _tc_freeze()
		"tc_unfreeze":
			return _tc_unfreeze()
		"tc_step":
			if _ui_do.active:
				return {"ok": false, "error": "a ui_do window is open — let it finish (ui_do_status) or ui_do_abort first"}
			return _tc_step(msg)
		"tc_step_until":
			if _ui_do.active:
				return {"ok": false, "error": "a ui_do window is open — let it finish (ui_do_status) or ui_do_abort first"}
			return _tc_step_until(msg)
		"tc_step_status":
			return _tc_step_status()
		"tc_time_scale":
			return _tc_time_scale(msg)
		"tc_status":
			return _tc_state()
		_:
			return {"ok": false, "error": "unknown cmd"}


# ---------------------------------------------------------------- runtime ops

func _root() -> Node:
	var t := get_tree()
	if t == null:
		return null
	return t.current_scene if t.current_scene != null else t.root


func _scene_name() -> String:
	var r := _root()
	return str(r.name) if r != null else ""


## Resolve a node by path/name. Base is the current scene, but ALSO accepts an
## absolute SceneTree path (/root/...) and falls back to a tree-wide name search,
## so both "Player" and "/root/Main/Player" work (the #1 'node not found' trap).
func _resolve(path: String) -> Node:
	var root := _root()
	if root == null:
		return null
	if path.is_empty() or path == "." or path == root.name:
		return root
	var tree := get_tree()
	# Absolute SceneTree path (/root/...).
	if path.begins_with("/root") and tree != null:
		var abs := tree.root.get_node_or_null(NodePath(path))
		if abs != null:
			return abs
	# Relative to the current scene.
	var n := root.get_node_or_null(NodePath(path))
	if n != null:
		return n
	n = root.find_child(path, true, false)
	if n != null:
		return n
	# Last resort: name search from the SceneTree root (covers autoloads / overlays).
	if tree != null and tree.root != null:
		n = tree.root.find_child(path, true, false)
	return n


## Custom class_name of a node's script (Godot 4.3+), "" if none / built-in.
func _script_global_name(n: Node) -> String:
	var s = n.get_script()
	if s == null:
		return ""
	if s.has_method("get_global_name"):
		var gn = s.get_global_name()
		if gn != null and str(gn) != "":
			return str(gn)
	return ""


## Resolve a node from a command: by "path" if given, else by a live SELECTOR
## (class / name / text [+ nth]) — so the agent can address a node without re-fetching
## volatile auto-generated paths (@Node@NN) every session. class matches custom
## class_name too (see _class_match).
## All live nodes matching a command's target spec, in document (DFS pre-order) order.
## Spec = "path" (exact, 0/1 result; supports /root and %UniqueName) OR a selector:
## class (native or custom class_name) / name / text, optionally scoped to a subtree
## via "under". ONE resolver for every tool that takes a target (click_control,
## click_node3d/world, runtime_get/set/call) so nth never means different things.
func _resolve_matches(msg: Dictionary) -> Array:
	var path := str(msg.get("path", ""))
	if not path.is_empty():
		var direct := _resolve(path)
		return [direct] if direct != null else []
	var cls := str(msg.get("class", ""))
	var name_q := str(msg.get("name", ""))
	var text_q := str(msg.get("text", ""))
	if cls == "" and name_q == "" and text_q == "":
		return []
	var scope := _root()
	var under := str(msg.get("under", ""))
	if not under.is_empty():
		scope = _resolve(under)
	if scope == null:
		return []
	var out: Array = []
	_select_walk(scope, cls, name_q, text_q, out)
	return out


func _resolve_target(msg: Dictionary) -> Node:
	var matches := _resolve_matches(msg)
	if matches.is_empty():
		return null
	var nth := int(msg.get("nth", 0))
	if nth < 0 or nth >= matches.size():
		return null
	return matches[nth]


## Coerce a JSON value to the live property's current type before set — a value that
## arrives as a JSON string ("19", "[1,0,0]") must not be stored raw, or game code like
## `coins += 1` errors ("String + int") and aborts the dispatch (no response → the editor's
## runtime channel times out and desyncs). Parse stringified arrays/objects, then mirror scalars.
func _coerce_value(obj: Object, prop: String, value: Variant) -> Variant:
	if value is String:
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	match typeof(obj.get(prop)):
		TYPE_INT:
			return int(value) if (value is String or value is float) else value
		TYPE_FLOAT:
			return float(value) if (value is String or value is int) else value
		TYPE_BOOL:
			if value is String:
				return (value as String).to_lower() in ["true", "1", "yes"]
			return bool(value)
		TYPE_STRING:
			return str(value)
		TYPE_VECTOR2:
			return InputCodec.vec2(value)
		TYPE_VECTOR3:
			return _vec3(value)
		TYPE_COLOR:
			if value is Array and value.size() >= 3:
				return Color(value[0], value[1], value[2], value[3] if value.size() > 3 else 1.0)
			if value is String:
				return Color(value)
	return value


## runtime "call" = the editor call_method's twin gate (v1.10.2). A raw callv on
## mis-typed args does NOT run the method - the engine pushes an error (visible in
## game_logs) and returns null, which this dispatch used to report as ok:true.
func _call_cmd(n: Node, msg: Dictionary) -> Dictionary:
	var method := str(msg.get("method", ""))
	if not n.has_method(method):
		return {"ok": false, "error": "%s has no method '%s'" % [n.get_class(), method]}
	var raw: Variant = msg.get("args", [])
	var args: Array = raw if raw is Array else []
	var prep: Dictionary = CallArgs.prepare(n, method, args, self)
	if not bool(prep.get("ok", false)):
		return {"ok": false, "error": "%s.%s: %s" % [n.get_class(), method, str(prep.get("error", "argument mismatch"))]}
	var resp := {"ok": true, "result": _safe(n.callv(method, prep["args"])), "resolved": str(_root().get_path_to(n))}
	var warn := _stale_gd_warning(n)
	if not warn.is_empty():
		resp["warning"] = warn
	return resp


func _resolve_object_arg(spec: String) -> Node:
	return _resolve(spec)


## The running game keeps whatever script version it loaded; a .gd edited on disk
## mid-play means live results no longer match the file. Surface that instead of
## letting the mismatch masquerade as a game bug.
func _stale_gd_warning(n: Node) -> String:
	var scr = n.get_script()
	if scr == null or not (scr is GDScript):
		return ""
	var path: String = scr.resource_path
	if not path.begins_with("res://") or not FileAccess.file_exists(path):
		return ""
	var disk := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	var loaded := str(scr.source_code).replace("\r\n", "\n")
	if disk.is_empty() or loaded.is_empty() or disk == loaded:
		return ""
	return "script %s changed on disk after the game loaded it - the running game may still be on the old version (restart the scene to be sure)" % path


func _select_walk(node: Node, cls: String, name_q: String, text_q: String, out: Array) -> void:
	var ok := true
	if cls != "" and not _class_match(node, cls):
		ok = false
	if ok and name_q != "" and str(node.name).findn(name_q) == -1:
		ok = false
	if ok and text_q != "" and _node_text(node).findn(text_q) == -1:
		ok = false
	if ok:
		out.append(node)
	for c in node.get_children():
		_select_walk(c, cls, name_q, text_q, out)


## Human-readable reason a _resolve_target call failed (path vs selector).
func _not_found(msg: Dictionary) -> String:
	var path := str(msg.get("path", ""))
	if not path.is_empty():
		return "node not found: %s" % path
	var sel: Array = []
	for k in ["class", "name", "text"]:
		var v := str(msg.get(k, ""))
		if v != "":
			sel.append("%s=%s" % [k, v])
	if sel.is_empty():
		return "no path or selector (class/name/text) given"
	return "no node matches selector %s (nth=%d)" % [", ".join(sel), int(msg.get("nth", 0))]


# ---------------------------------------------------------------- time control (deterministic playtest)

## Common state block returned by every time_control op so the agent always sees the
## same shape: is the game running, is the tree paused, current Engine.time_scale,
## the physics frame counter, and whether a step window is currently open.
func _tc_state() -> Dictionary:
	var tree := get_tree()
	var paused := tree != null and tree.paused
	return {
		"ok": true,
		"running": tree != null,
		"paused": paused,
		"time_scale": Engine.time_scale,
		"physics_frames": Engine.get_physics_frames(),
		"in_step": _stepping,
	}


func _tc_freeze() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	# A pending step window is abandoned by an explicit freeze — the user wants a hard stop.
	_stepping = false
	_step_expr = null
	tree.paused = true
	return _tc_state()


func _tc_unfreeze() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	_stepping = false
	_step_expr = null
	tree.paused = false
	return _tc_state()


## OPEN a fixed-count step window. From ANY state: force paused (known baseline), record
## the physics frame counter, then unpause with the window armed. _physics_process counts
## exactly N unpaused ticks and re-pauses. Replies immediately with started=... ; the editor
## polls tc_step_status until in_step=false, then reads the delta.
func _tc_step(msg: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	var frames: int = maxi(1, int(msg.get("frames", 1)))
	# Baseline: ensure paused so no stray ticks land before the window opens.
	tree.paused = true
	_step_kind = "count"
	_step_target = frames
	_step_count = 0
	_step_result = ""
	_step_cond_value = null
	_resume_paused = true
	_step_open_frame = Engine.get_physics_frames()
	_stepping = true
	# Unpause so the very next physics tick begins the run.
	tree.paused = false
	return {"ok": true, "started": true, "kind": "count", "frames_requested": frames,
		"physics_frames_before": _step_open_frame}


## OPEN a condition step window. Compile the GDScript Expression, evaluate it ONCE
## against the current state — if already true, close with 0 frames — otherwise unpause
## with the window armed; _physics_process re-checks each tick and closes on condition,
## max_frames, or timeout, then re-pauses.
func _tc_step_until(msg: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	var cond := str(msg.get("condition", "")).strip_edges()
	if cond.is_empty():
		return {"ok": false, "error": "step_until needs a 'condition' expression"}
	var expr := Expression.new()
	var perr := expr.parse(cond)
	if perr != OK:
		return {"ok": false, "error": "condition parse error: %s" % expr.get_error_text()}
	_step_cond = cond
	_step_expr = expr
	_step_kind = "until"
	_step_count = 0
	_step_result = ""
	_step_cond_value = null
	_resume_paused = true
	_step_max_frames = maxi(0, int(msg.get("max_frames", 0)))
	var timeout_sec: float = clampf(float(msg.get("timeout_sec", 10.0)), 0.1, 120.0)
	_step_deadline = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	_step_open_frame = Engine.get_physics_frames()
	# Already true? Close immediately with zero frames run — pause and report.
	if _eval_step_condition():
		_step_result = "condition"
		_stepping = false
		_step_expr = null
		tree.paused = true
		return {"ok": true, "started": false, "kind": "until", "immediate": true,
			"terminator": "condition", "frames": 0,
			"physics_frames_before": _step_open_frame,
			"condition_value": _step_cond_value}
	_stepping = true
	tree.paused = false
	return {"ok": true, "started": true, "kind": "until", "immediate": false,
		"timeout_sec": timeout_sec, "max_frames": _step_max_frames,
		"physics_frames_before": _step_open_frame}


## Poll target for an open step window. While in_step is true the editor keeps polling;
## once it flips false, this carries the terminator, frames actually run, the physics
## frame counter before/after (delta must equal frames for kind=count), and — for
## step_until — the final condition value.
func _tc_step_status() -> Dictionary:
	var out := _tc_state()
	out["kind"] = _step_kind
	out["frames"] = _step_count
	# before was snapshotted at open; after = before + counted ticks. Computed (not read live)
	# so after-before == frames both mid-window and after close, immune to the raw engine
	# counter drifting while paused between close and this poll.
	out["physics_frames_before"] = _step_open_frame
	out["physics_frames_after"] = _step_open_frame + _step_count
	if not _stepping:
		out["terminator"] = _step_result
		if _step_kind == "until":
			out["condition"] = _step_cond
			out["condition_value"] = _step_cond_value
	return out


## Set Engine.time_scale. Clamp to [0.01, 10.0]; a value of 0 is rejected (freeze is the
## way to stop time, and a 0 scale wedges tweens/timers). Reports the clamped value.
func _tc_time_scale(msg: Dictionary) -> Dictionary:
	if not msg.has("value"):
		return {"ok": false, "error": "time_scale needs a 'value'"}
	var requested := float(msg.get("value", 1.0))
	if requested == 0.0:
		return {"ok": false, "error": "time_scale 0 is not allowed — use freeze to stop time (a 0 scale wedges tweens/timers)"}
	var clamped: float = clampf(requested, 0.01, 10.0)
	Engine.time_scale = clamped
	var st := _tc_state()
	st["requested"] = requested
	st["clamped"] = clamped
	return st


# ---------------------------------------------------------------- tree (scoped)

func _tree_cmd(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	var start := root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		start = _resolve(p)
		if start == null:
			return {"ok": false, "error": "node not found: %s" % p}
	var depth := int(msg.get("depth", -1))
	var max_nodes := int(msg.get("max_nodes", 250))
	if max_nodes <= 0:
		max_nodes = 1 << 30
	var max_children := int(msg.get("max_children", 50))
	if max_children <= 0:
		max_children = 1 << 30
	var ctx := {"count": 0, "max": max_nodes, "max_children": max_children,
		"collapse": bool(msg.get("collapse", true)), "truncated": false}
	var tree := _tree2(start, root, depth, ctx)
	var out := {"ok": true, "tree": tree, "node_count": int(ctx["count"])}
	if bool(ctx["truncated"]):
		out["truncated"] = true
		out["hint"] = "output capped — narrow with path=, lower depth=, or raise max_nodes="
	return out


func _tree2(n: Node, root: Node, depth: int, ctx: Dictionary) -> Dictionary:
	ctx["count"] = int(ctx["count"]) + 1
	var d: Dictionary = {"name": str(n.name), "class": n.get_class()}
	var gn := _script_global_name(n)
	if gn != "":
		d["script"] = gn
	var child_count := n.get_child_count()
	if child_count == 0:
		return d
	if depth == 0:
		d["children_omitted"] = child_count
		return d
	var kids := n.get_children()
	var out_kids: Array = []
	var shown := 0
	var i := 0
	while i < kids.size():
		if int(ctx["count"]) >= int(ctx["max"]):
			ctx["truncated"] = true
			break
		if shown >= int(ctx["max_children"]):
			out_kids.append({"more": kids.size() - i})
			ctx["truncated"] = true
			break
		var c: Node = kids[i]
		# Collapse a run of identical childless leaf siblings (e.g. 8 CPUParticles2D)
		# into one entry — the #1 source of token-bloat in real scene trees.
		if bool(ctx["collapse"]) and c.get_child_count() == 0 and _script_global_name(c) == "":
			var cls := c.get_class()
			var j := i
			while j < kids.size() and kids[j].get_child_count() == 0 \
					and kids[j].get_class() == cls and _script_global_name(kids[j]) == "":
				j += 1
			var run := j - i
			if run >= 5:
				ctx["count"] = int(ctx["count"]) + run
				out_kids.append({"class": cls, "count": run, "collapsed": true,
					"first": str(c.name), "last": str(kids[j - 1].name)})
				shown += 1
				i = j
				continue
		out_kids.append(_tree2(c, root, depth - 1, ctx))
		shown += 1
		i += 1
	if not out_kids.is_empty():
		d["children"] = out_kids
	return d


func _screenshot(msg: Dictionary = {}) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var tex := vp.get_texture()
	if tex == null:
		return {"ok": false, "error": "no viewport texture (headless / no RHI?)"}
	var img := tex.get_image()
	if img == null:
		return {"ok": false, "error": "could not read viewport image (headless / no RHI?)"}
	var full_w := img.get_width()
	var full_h := img.get_height()
	# Set-of-Mark legend is collected BEFORE crop/scale — marks live in full-image
	# pixel space; the drawer maps them through (xy - crop_offset) * scale.
	var annotate := str(msg.get("annotate", "")) == "ui"
	var marks_list: Array = []
	if annotate:
		marks_list = UiInspect.marks(vp, get_tree().root, _root(), int(msg.get("max_marks", 40)))
	var off := Vector2.ZERO
	var rg: Variant = msg.get("region", null)
	if rg is Array and (rg as Array).size() >= 4:
		off = Vector2(float(clampi(int(rg[0]), 0, full_w - 1)), float(clampi(int(rg[1]), 0, full_h - 1)))
	img = _maybe_crop(img, msg)
	var scale := clampf(float(msg.get("scale", 1.0)), 0.05, 1.0)
	if scale < 1.0:
		img.resize(maxi(1, roundi(img.get_width() * scale)), maxi(1, roundi(img.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	if not marks_list.is_empty():
		UiInspect.annotate_image(img, marks_list, off, scale)
	var fmt := str(msg.get("format", "png")).to_lower()
	var quality := clampf(float(msg.get("quality", 0.8)), 0.1, 1.0)
	var data: PackedByteArray
	var mime := "image/png"
	var note := ""
	if fmt == "jpeg" or fmt == "jpg":
		# save_jpg_to_buffer is duck-checked: older 4.x without it falls back honestly.
		if img.has_method("save_jpg_to_buffer"):
			data = img.save_jpg_to_buffer(quality)
			mime = "image/jpeg"
		else:
			data = img.save_png_to_buffer()
			note = "jpeg unsupported on this engine — png returned"
	elif fmt == "webp":
		data = img.save_webp_to_buffer(true, quality)
		mime = "image/webp"
	else:
		data = img.save_png_to_buffer()
	var out := {"ok": true, "data": Marshalls.raw_to_base64(data), "mime": mime,
		"w": img.get_width(), "h": img.get_height(), "full_w": full_w, "full_h": full_h}
	if mime == "image/png":
		out["png"] = out["data"]  # legacy key — playtest/compare baseline readers use it
	if note != "":
		out["note"] = note
	if annotate:
		# Legend rects are remapped into FINAL image pixels so a follow-up region= crop
		# or a click plan can reuse them directly against the returned picture.
		var legend: Array = []
		for m in marks_list:
			var md := m as Dictionary
			var r4: Array = md["rect"]
			var e := {"i": md["i"], "path": md["path"],
				"rect": [roundi((float(r4[0]) - off.x) * scale), roundi((float(r4[1]) - off.y) * scale),
					roundi(float(r4[2]) * scale), roundi(float(r4[3]) * scale)]}
			if md.has("text"):
				e["text"] = md["text"]
			legend.append(e)
		out["marks"] = legend
	return out


## ui_audit: deterministic layout QA over the live UI (checks in ui_inspect.gd).
func _ui_audit(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	if _root() == null:
		return {"ok": false, "error": "no current scene"}
	var scope: Node = get_tree().root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		scope = _resolve(p)
		if scope == null:
			return {"ok": false, "error": "node not found: %s" % p}
	return UiInspect.audit(vp, get_tree().root, _root(), scope, msg)


## Crop to region=[x,y,w,h] (pixels, clamped to bounds) to save tokens; returns the
## image unchanged when no valid region is given.
func _maybe_crop(img: Image, msg: Dictionary) -> Image:
	var r = msg.get("region", null)
	if not (r is Array and r.size() >= 4):
		return img
	var x := clampi(int(r[0]), 0, img.get_width() - 1)
	var y := clampi(int(r[1]), 0, img.get_height() - 1)
	var w := clampi(int(r[2]), 1, img.get_width() - x)
	var h := clampi(int(r[3]), 1, img.get_height() - y)
	return img.get_region(Rect2i(x, y, w, h))


func _run_input(events: Array) -> Dictionary:
	var count := 0
	for e in events:
		if not (e is Dictionary):
			continue
		var ev: InputEvent = InputCodec.build_event(e)
		if ev != null:
			Input.parse_input_event(ev)
			count += 1
	return {"ok": true, "dispatched": count}


# ---------------------------------------------------------------- find (live nodes)

func _find(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	var scope := root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		scope = _resolve(p)
		if scope == null:
			return {"ok": false, "error": "node not found: %s" % p}
	var cls := str(msg.get("class", ""))
	var text_q := str(msg.get("text", ""))
	var name_q := str(msg.get("name", ""))
	var recursive := bool(msg.get("recursive", true))
	var maxn := int(msg.get("max", 100))
	var out: Array = []
	for c in scope.get_children():
		if out.size() >= maxn:
			break
		if recursive:
			_find_walk(c, root, cls, text_q, name_q, out, maxn)
		else:
			_match_into(c, root, cls, text_q, name_q, out)
	return {"ok": true, "nodes": out, "count": out.size()}


func _find_walk(node: Node, root: Node, cls: String, text_q: String, name_q: String, out: Array, maxn: int) -> void:
	if out.size() >= maxn:
		return
	_match_into(node, root, cls, text_q, name_q, out)
	for c in node.get_children():
		if out.size() >= maxn:
			return
		_find_walk(c, root, cls, text_q, name_q, out, maxn)


func _match_into(node: Node, root: Node, cls: String, text_q: String, name_q: String, out: Array) -> void:
	if not _class_match(node, cls):
		return
	var ntext := _node_text(node)
	if text_q != "" and ntext.findn(text_q) == -1:
		return
	if name_q != "" and str(node.name).findn(name_q) == -1:
		return
	var entry := {"path": str(root.get_path_to(node)), "class": node.get_class()}
	var gn := _script_global_name(node)
	if gn != "":
		entry["script"] = gn
	if ntext != "":
		entry["text"] = ntext
	out.append(entry)


## Match a class filter against BOTH the native class chain AND the custom script
## class_name — is_class() alone misses custom nodes (they read as @Node@NN).
func _class_match(node: Node, cls: String) -> bool:
	if cls == "":
		return true
	if node.is_class(cls):
		return true
	var gn := _script_global_name(node)
	return gn != "" and gn.nocasecmp_to(cls) == 0


func _node_text(n: Node) -> String:
	for p in n.get_property_list():
		if str(p.get("name", "")) == "text":
			return str(n.get("text"))
	return ""


# ---------------------------------------------------------------- click

func _click_text(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	# Same resolver as click_control, scoped to buttons: the two tools agree on the
	# match set and nth ordering (a bare text selector elsewhere also scopes to BaseButton).
	var sel := msg.duplicate()
	if str(sel.get("class", "")) == "":
		sel["class"] = "BaseButton"
	var matches := _resolve_matches(sel)
	var text := str(msg.get("text", ""))
	if matches.is_empty():
		var where := (" under %s" % str(msg.get("under", ""))) if str(msg.get("under", "")) != "" else ""
		return {"ok": false, "error": "no button with text containing '%s'%s" % [text, where]}
	if bool(msg.get("all", false)):
		var list: Array = []
		for b in matches:
			list.append({"path": str(root.get_path_to(b)), "text": _node_text(b), "class": b.get_class()})
		return {"ok": true, "matches": list, "count": list.size()}
	var idx := int(msg.get("nth", 0))
	if idx < 0 or idx >= matches.size():
		return {"ok": false, "error": "nth %d out of range (%d match(es) for '%s')" % [idx, matches.size(), text]}
	var btn: Node = matches[idx]
	# v1.10 accuracy: a disabled button never fires in the real UI — emitting its
	# 'pressed' anyway would hand the agent a fabricated success.
	if UiInspect.is_disabled(btn):
		return {"ok": true, "clicked": false, "path": str(root.get_path_to(btn)),
			"warning": "button is disabled — 'pressed' not emitted (the real UI would ignore this click)"}
	btn.emit_signal("pressed")
	return {"ok": true, "clicked": true, "path": str(root.get_path_to(btn)), "match_count": matches.size()}


## Click a Control by injecting press+release at its center straight into the
## viewport in GUI space (push_input local). This bypasses the content-scale /
## stretch transform that makes Input.parse_input_event miss buttons in containers.
##
## Guards the false-positive where the target is scrolled out of a ScrollContainer:
## a click there would silently miss (clipped) yet look successful. If the center is
## clipped/off-screen we scroll it into view and report clicked=false (the re-sort is
## deferred one frame) so the caller calls again to land the click — never a fake hit.
func _click_control(msg: Dictionary) -> Dictionary:
	# Clicking by bare text means "a button": scope it to BaseButton so nth indexes the
	# SAME set/order as click_button_by_text. Without this, a text-only selector also
	# counts Labels and other text-bearing nodes, shifting nth onto the wrong control.
	if str(msg.get("text", "")) != "" and str(msg.get("class", "")) == "" \
			and str(msg.get("path", "")) == "" and str(msg.get("name", "")) == "":
		msg = msg.duplicate()
		msg["class"] = "BaseButton"
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s) — use simulate_input for non-Control targets" % n.get_class()}
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var ctrl := n as Control
	var path := str(_root().get_path_to(ctrl))
	if not ctrl.is_visible_in_tree():
		return {"ok": true, "clicked": false, "path": path,
			"warning": "control is hidden (not visible in tree) — nothing to click"}
	var center: Vector2 = ctrl.get_global_rect().get_center()
	# v1.10 accuracy: a disabled control swallows clicks — pushing anyway would report
	# a success the real UI can never produce.
	if UiInspect.is_disabled(ctrl):
		return {"ok": true, "clicked": false, "path": path, "at": [center.x, center.y],
			"warning": "control is disabled — the click would be ignored (enable it first, or pick another control)"}
	if _is_point_clipped(ctrl, center, vp):
		if not _scroll_into_view(ctrl):
			return {"ok": true, "clicked": false, "scrolled": false, "path": path, "at": [center.x, center.y],
				"warning": "control is off-screen/clipped and has no ScrollContainer ancestor to bring it into view"}
		# Flush the deferred re-sort so the scrolled position applies THIS call (no retry).
		_force_sort(ctrl)
		center = ctrl.get_global_rect().get_center()
		if _is_point_clipped(ctrl, center, vp):
			return {"ok": true, "clicked": false, "scrolled": true, "path": path, "at": [center.x, center.y],
				"warning": "scrolled toward view but still clipped (nested scroll?) — call click_control again to land the click"}
	# v1.10 accuracy: whoever is TOP-MOST at the point receives the event. If that is
	# not the target (a popup on top, a modal overlay, a covering ColorRect with
	# mouse_filter STOP), pushing would activate the WRONG control — refuse and name
	# the blocker instead. Skipped for controls inside embedded Windows (their rects
	# are window-local; the main-canvas hit test does not apply — pre-1.10 push kept).
	# receiver == null with a visible non-IGNORE target means our approximation missed
	# (custom _has_point override?) — fall through to the push, never block on a guess.
	var receiver: Node = null
	var ignore_note := ""
	if not UiInspect.inside_embedded_window(ctrl, get_tree().root):
		receiver = UiInspect.pick_at(vp, get_tree().root, center)
		if receiver != null and receiver != ctrl and not UiInspect.click_reaches(receiver, ctrl):
			if ctrl.mouse_filter == Control.MOUSE_FILTER_IGNORE:
				ignore_note = "target has mouse_filter=IGNORE — the click was delivered at its position; %s received it" \
					% UiInspect.path_of(receiver, _root())
			else:
				return {"ok": true, "clicked": false, "path": path, "at": [center.x, center.y],
					"occluded_by": UiInspect.path_of(receiver, _root()),
					"warning": "occluded by %s (%s) — that control would receive the click instead; close/dismiss it, or click it" \
						% [UiInspect.path_of(receiver, _root()), receiver.get_class()]}
	var button := int(msg.get("button", 1))
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = center
	down.global_position = center
	vp.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = center
	up.global_position = center
	vp.push_input(up, true)
	var out := {"ok": true, "clicked": true, "path": path, "at": [center.x, center.y]}
	if receiver != null and receiver != ctrl:
		out["received_by"] = UiInspect.path_of(receiver, _root())
	if ignore_note != "":
		out["note"] = ignore_note
	return out


## True if point p (GUI space) is outside the viewport OR clipped by a clip_contents
## ancestor (ScrollContainer and friends) — i.e. a click there would not reach ctrl.
func _is_point_clipped(ctrl: Control, p: Vector2, vp: Viewport) -> bool:
	if not vp.get_visible_rect().has_point(p):
		return true
	var a := ctrl.get_parent()
	while a != null:
		if a is Control and (a as Control).clip_contents and not (a as Control).get_global_rect().has_point(p):
			return true
		a = a.get_parent()
	return false


## Scroll every ScrollContainer ancestor so ctrl becomes visible. Returns true if at
## least one did (the position update is deferred to the next layout pass).
func _scroll_into_view(ctrl: Control) -> bool:
	var did := false
	var a := ctrl.get_parent()
	while a != null:
		if a is ScrollContainer:
			(a as ScrollContainer).ensure_control_visible(ctrl)
			did = true
		a = a.get_parent()
	return did


## Force every Container ancestor to re-sort its children NOW, instead of waiting for
## the queued sort next frame — lets click_control scroll a control into view and click
## it in the SAME call. Best-effort: if positions still aren't settled, the caller falls
## back to the call-again path.
func _force_sort(ctrl: Control) -> void:
	var a := ctrl.get_parent()
	while a != null:
		if a is Container:
			a.notification(Container.NOTIFICATION_SORT_CHILDREN)
		a = a.get_parent()


## Report a Control's rect in BOTH GUI/canvas space and screen space (content-scale
## applied), so the agent can click with the right coordinates — or just call click_control.
func _control_rect(msg: Dictionary) -> Dictionary:
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s)" % n.get_class()}
	var ctrl := n as Control
	var gr: Rect2 = ctrl.get_global_rect()
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	# local -> canvas (gui) -> output(physical). The final_transform carries the
	# content-scale/stretch, so screen_rect matches screenshot pixels (gui_rect doesn't
	# when the window is larger than the canvas, e.g. a 1.735x stretch).
	var xf := vp.get_final_transform() * ctrl.get_global_transform_with_canvas()
	var s0: Vector2 = xf * Vector2.ZERO
	var s1: Vector2 = xf * ctrl.size
	var sr := Rect2(s0, s1 - s0).abs()
	return {"ok": true, "rect": {
		"path": str(_root().get_path_to(ctrl)),
		"gui_rect": [gr.position.x, gr.position.y, gr.size.x, gr.size.y],
		"gui_center": [gr.get_center().x, gr.get_center().y],
		"screen_rect": [sr.position.x, sr.position.y, sr.size.x, sr.size.y],
		"screen_center": [sr.get_center().x, sr.get_center().y],
	}}


## One-call accessibility snapshot of the visible UI (v1.10) — the walker lives in
## ui_inspect.gd; this just resolves the scope. Walks the whole SceneTree root by
## default so autoload HUD layers and popup Windows outside the current scene show up.
func _ui_snapshot(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	if _root() == null:
		return {"ok": false, "error": "no current scene"}
	var scope: Node = get_tree().root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		scope = _resolve(p)
		if scope == null:
			return {"ok": false, "error": "node not found: %s" % p}
	return UiInspect.snapshot(vp, get_tree().root, _root(), scope, msg)


## Type a string into a focusable Control as REAL key events (each char an
## InputEventKey carrying `unicode`), so text_changed / validation / max-length all
## fire — unlike a programmatic `text =` set, which fires none of them. All chars land
## within ONE frame, so LineEdit's deferred text_changed coalesces to a single emission
## (paste semantics — same as a player hitting Ctrl+V). clear=true (default) replaces
## the content (select_all first, so the first char overwrites); '\n' chars and
## submit=true press Enter (LineEdit fires text_submitted).
func _type_text(msg: Dictionary) -> Dictionary:
	# A new call supersedes any open per-frame stream (no interleaving).
	_typing_done = true
	_typing_ctrl = null
	# 'text' is the PAYLOAD to type here, not the text selector — strip it from the
	# resolve spec or it would filter targets by their current text content.
	var spec := msg.duplicate()
	spec.erase("text")
	var n := _resolve_target(spec)
	if n == null:
		return {"ok": false, "error": _not_found(spec)}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s) — type_text drives focusable text inputs" % n.get_class()}
	var ctrl := n as Control
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var path := str(_root().get_path_to(ctrl))
	if not ctrl.is_visible_in_tree():
		return {"ok": true, "typed": 0, "path": path, "warning": "control is hidden — nothing typed"}
	if UiInspect.is_disabled(ctrl):
		return {"ok": true, "typed": 0, "path": path, "warning": "control is disabled — nothing typed"}
	if "editable" in ctrl and not bool(ctrl.get("editable")):
		return {"ok": true, "typed": 0, "path": path, "warning": "control is not editable — nothing typed"}
	if ctrl.focus_mode == Control.FOCUS_NONE:
		return {"ok": false, "error": "%s has focus_mode NONE — it cannot take keyboard input; set focus_mode, or write the property with runtime_set_property (no signals)" % path}
	ctrl.grab_focus()
	if vp.gui_get_focus_owner() != ctrl:
		return {"ok": false, "error": "could not focus %s — another control refuses to release focus" % path}
	var text := str(msg.get("text", ""))
	if bool(msg.get("clear", true)):
		if ctrl.has_method("select_all"):
			ctrl.call("select_all")
			if text.is_empty():
				_push_key(vp, KEY_BACKSPACE, 0)
		elif "text" in ctrl:
			ctrl.set("text", "")
	# v1.11 per_frame: queue the chars and let _process inject ONE per frame, so
	# per-char handlers see real typing. The editor tool polls cmd=type_status.
	if bool(msg.get("per_frame", false)):
		_typing_ctrl = ctrl
		_typing_text = text
		_typing_i = 0
		_typing_submit = bool(msg.get("submit", false))
		_typing_done = text.is_empty() and not _typing_submit
		_typing_error = ""
		return {"ok": true, "per_frame": true, "path": path,
			"queued": text.length() + (1 if bool(msg.get("submit", false)) else 0)}
	var typed := 0
	for i in text.length():
		var code := text.unicode_at(i)
		if code == 10:
			_push_key(vp, KEY_ENTER, 0)  # newline: TextEdit inserts a break, LineEdit submits
		else:
			_push_key(vp, 0, code)
		typed += 1
	if bool(msg.get("submit", false)):
		_push_key(vp, KEY_ENTER, 0)
	var out := {"ok": true, "typed": typed, "path": path, "submitted": bool(msg.get("submit", false))}
	# Read the text back so the agent sees what the field ACCEPTED (max_length,
	# filters, and text_changed handlers included) without a second call.
	if "text" in ctrl:
		out["text_after"] = str(ctrl.get("text"))
	return out


## Press+release one key straight into the viewport. keycode may be 0 when the event
## only carries text (`unicode`) — exactly how IME/soft-keyboard input arrives, and
## what LineEdit/TextEdit insert from.
func _push_key(vp: Viewport, keycode: int, unicode: int) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.unicode = unicode
	down.pressed = true
	vp.push_input(down)
	var up := InputEventKey.new()
	up.keycode = keycode
	up.physical_keycode = keycode
	up.pressed = false
	vp.push_input(up)


## v1.11 per-frame typing: inject exactly one queued char (or the trailing Enter) per
## process frame. Distinct frames = distinct deferred text_changed emissions - the
## whole point; one-frame injection coalesces them into paste semantics.
func _type_tick() -> void:
	if _typing_done:
		return
	if _typing_ctrl == null or not is_instance_valid(_typing_ctrl) or not _typing_ctrl.is_visible_in_tree():
		_typing_error = "target vanished mid-typing (%d of %d chars in)" % [_typing_i, _typing_text.length()]
		_typing_done = true
		_typing_ctrl = null
		return
	var vp := get_viewport()
	if vp == null:
		_typing_error = "no viewport"
		_typing_done = true
		return
	if vp.gui_get_focus_owner() != _typing_ctrl:
		_typing_ctrl.grab_focus()  # something stole focus between frames; take it back
	if _typing_i < _typing_text.length():
		var code := _typing_text.unicode_at(_typing_i)
		if code == 10:
			_push_key(vp, KEY_ENTER, 0)
		else:
			_push_key(vp, 0, code)
		_typing_i += 1
		return
	if _typing_submit:
		_push_key(vp, KEY_ENTER, 0)  # the submit Enter gets its own frame too
		_typing_submit = false
		return
	_typing_done = true


func _type_status() -> Dictionary:
	var out := {"ok": true, "done": _typing_done, "typed": _typing_i}
	if not _typing_error.is_empty():
		out["warning"] = _typing_error
	if _typing_ctrl != null and is_instance_valid(_typing_ctrl):
		var r := _root()
		if r != null:
			out["path"] = str(r.get_path_to(_typing_ctrl))
		if "text" in _typing_ctrl:
			out["text_after"] = str(_typing_ctrl.get("text"))
	return out


## Click a 3D node by projecting its world origin to the screen via the active
## Camera3D, then injecting motion+press+release there — for games that do their own
## mouse picking (CollisionObject3D._input_event / a camera raycast from the cursor).
func _click_node3d(msg: Dictionary) -> Dictionary:
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Node3D):
		return {"ok": false, "error": "not a Node3D (%s)" % n.get_class()}
	var n3 := n as Node3D
	# Target the visible CENTER for meshes: their origin is often at (0,0,0) while the
	# geometry sits elsewhere, so projecting the bare origin misses the screen. Use the
	# world-space AABB center when the node is a VisualInstance3D.
	var world: Vector3 = n3.global_position
	if n3 is VisualInstance3D:
		var ab: AABB = (n3 as VisualInstance3D).get_aabb()
		if ab.size != Vector3.ZERO:
			world = n3.global_transform * ab.get_center()
	return _world_click(world, int(msg.get("button", 1)), str(_root().get_path_to(n3)))


## Click at a 3D WORLD position (unprojected to the screen via the active Camera3D).
func _click_world(msg: Dictionary) -> Dictionary:
	var p: Variant = msg.get("position", null)
	if not (p is Array and (p as Array).size() >= 3):
		return {"ok": false, "error": "position must be [x, y, z]"}
	return _world_click(_vec3(p), int(msg.get("button", 1)), "world")


func _world_click(world: Vector3, button: int, label: String) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var cam := vp.get_camera_3d()
	if cam == null:
		return {"ok": false, "error": "no active Camera3D in the running scene"}
	if cam.is_position_behind(world):
		return {"ok": true, "clicked": false, "target": label,
			"warning": "world point is behind the camera — not on screen"}
	var screen: Vector2 = cam.unproject_position(world)
	if not vp.get_visible_rect().has_point(screen):
		return {"ok": true, "clicked": false, "target": label, "at": [screen.x, screen.y],
			"warning": "world point projects off-screen at (%d, %d)" % [int(screen.x), int(screen.y)]}
	# Hover first (pickers track the moused-over object), then press+release.
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	motion.global_position = screen
	vp.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = screen
	down.global_position = screen
	vp.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = screen
	up.global_position = screen
	vp.push_input(up, true)
	return {"ok": true, "clicked": true, "target": label,
		"at": [screen.x, screen.y], "world": [world.x, world.y, world.z]}


func _vec3(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(v[0], v[1], v[2])
	if v is Dictionary:
		return Vector3(v.get("x", 0), v.get("y", 0), v.get("z", 0))
	return Vector3.ZERO


## Mouse-wheel scroll at a target Control's center (path/selector) or an explicit
## gui-space position. amount>0 scrolls down, <0 up; |amount| = wheel notches.
func _scroll_cmd(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var pos: Vector2
	if msg.has("position"):
		pos = InputCodec.vec2(msg.get("position", []))
	else:
		var n := _resolve_target(msg)
		if n == null:
			return {"ok": false, "error": _not_found(msg)}
		if not (n is Control):
			return {"ok": false, "error": "scroll target must be a Control, or give position=[x,y]"}
		pos = (n as Control).get_global_rect().get_center()
	var amount := int(msg.get("amount", 1))
	if amount == 0:
		amount = 1
	var btn := MOUSE_BUTTON_WHEEL_UP if amount < 0 else MOUSE_BUTTON_WHEEL_DOWN
	var notches := absi(amount)
	for i in notches:
		var down := InputEventMouseButton.new()
		down.button_index = btn
		down.pressed = true
		down.factor = 1.0
		down.position = pos
		down.global_position = pos
		vp.push_input(down, true)
		var up := InputEventMouseButton.new()
		up.button_index = btn
		up.pressed = false
		up.position = pos
		up.global_position = pos
		vp.push_input(up, true)
	return {"ok": true, "scrolled": notches, "direction": "up" if amount < 0 else "down", "at": [pos.x, pos.y]}


## Press at `from`, glide through interpolated motion to `to`, release — for sliders,
## drag-and-drop, camera pans. Coordinates are gui-space (like click_control).
func _drag_cmd(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var f: Variant = msg.get("from", null)
	var t: Variant = msg.get("to", null)
	if not (f is Array and (f as Array).size() >= 2 and t is Array and (t as Array).size() >= 2):
		return {"ok": false, "error": "from and to must both be [x, y]"}
	var from := InputCodec.vec2(f)
	var to := InputCodec.vec2(t)
	var button := int(msg.get("button", 1))
	var mask := 1 << (button - 1)
	var steps: int = clampi(int(msg.get("steps", 8)), 1, 60)
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = from
	down.global_position = from
	vp.push_input(down, true)
	var prev := from
	for i in range(1, steps + 1):
		var p: Vector2 = from.lerp(to, float(i) / float(steps))
		var mm := InputEventMouseMotion.new()
		mm.position = p
		mm.global_position = p
		mm.relative = p - prev
		mm.button_mask = mask
		vp.push_input(mm, true)
		prev = p
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = to
	up.global_position = to
	vp.push_input(up, true)
	return {"ok": true, "dragged": true, "from": [from.x, from.y], "to": [to.x, to.y], "steps": steps}


func _safe(v: Variant) -> Variant:
	var t := typeof(v)
	if t == TYPE_OBJECT:
		return str(v)
	# Stringify built-in math structs — JSON can't encode them and they'd come back
	# as null (the global_rect / transform 'returns null' trap).
	var structs := [TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I,
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_COLOR, TYPE_RECT2, TYPE_RECT2I,
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION,
		TYPE_AABB, TYPE_PLANE, TYPE_PROJECTION]
	if t in structs:
		return str(v)
	return v


func _perf_monitors() -> Dictionary:
	var pairs := [
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
	var out: Dictionary = {}
	for p in pairs:
		out[p[0]] = Performance.get_monitor(p[1])
	return out


# ---------------------------------------------------------------- log capture
# (extracted to runtime/game_log_sink.gd in the v1.9.1 B7 split; `logs` cmd delegates)


# (input codec + Logger sink construction both live in their own runtime/ modules now —
# input_codec.gd and game_log_sink.gd; see the B7 split notes there.)
