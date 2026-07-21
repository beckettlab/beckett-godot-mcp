extends SceneTree
## Beckett headless unit suite (v1.9 B3). Pure-logic coverage the smoke's HTTP probes can't
## give: exact framing, tier math, serializer shape, auth compare, codex upsert, perf math,
## and the B4 class_name mask — the bug classes that previously slipped between smoke's
## end-to-end checks (the structuredContent drop, the int-vs-float assert mismatch).
##
## Zero dependencies on purpose: no gdUnit4 addon to vendor/ship-strip, same invocation
## shape as everything else in tests/:
##
##   godot --headless --path <repo> --script tests/unit_tests.gd
##
## Exits non-zero on any failure. Wired into tests/smoke.ps1 (stage 1.5) and CI.

const JsonRpc := preload("res://addons/beckett/core/json_rpc.gd")
const Effort := preload("res://addons/beckett/core/effort.gd")
const Registry := preload("res://addons/beckett/core/tool_registry.gd")
const Jobs := preload("res://addons/beckett/core/jobs.gd")
const HttpServer := preload("res://addons/beckett/core/http_server.gd")
const ClientConfig := preload("res://addons/beckett/core/client_config.gd")
const MCPServer := preload("res://addons/beckett/core/mcp_server.gd")
const ScriptTools := preload("res://addons/beckett/tools/script_tools.gd")
const MCPRuntime := preload("res://addons/beckett/runtime/mcp_runtime.gd")
const ReplayPerf := preload("res://addons/beckett/runtime/replay_perf.gd")
const InputCodec := preload("res://addons/beckett/runtime/input_codec.gd")
const UiInspect := preload("res://addons/beckett/runtime/ui_inspect.gd")
const RuntimeBridge := preload("res://addons/beckett/core/runtime_bridge.gd")
const CallArgs := preload("res://addons/beckett/core/callargs.gd")
const GameLogSink := preload("res://addons/beckett/runtime/game_log_sink.gd")
# Full-only modules: loaded dynamically so this suite ALSO runs on the Lite repo's CI,
# where pack.ps1 physically trims them — their test groups then skip with a note.
const _PLAYTEST_TOOLS_PATH := "res://addons/beckett/tools/playtest_tools.gd"
const _PLAYTEST_RUNNER_PATH := "res://addons/beckett/runtime/playtest_runner.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	_t_json_rpc()
	_t_effort()
	_t_registry()
	_t_poll_until()
	_t_http_static()
	_t_client_config()
	_t_server_serializer()
	_t_secure_equals()
	_t_validate_args()
	_t_call_args()
	_t_error_echo()
	_t_class_name_mask()
	if ResourceLoader.exists(_PLAYTEST_TOOLS_PATH):
		_t_playtest_helpers()
		_t_perf_assert_eval()
	else:
		print("[unit] playtest groups skipped (Lite build: module trimmed)")
	if ResourceLoader.exists(_PLAYTEST_RUNNER_PATH):
		_t_perf_summary_runner()
	else:
		print("[unit] runner perf group skipped (Lite build: runner trimmed)")
	_t_perf_summary_runtime()
	_t_input_codec()
	await _t_ui_inspect()
	await _t_focus_graph()
	_t_type_stream()
	_t_bridge_compare()
	print("")
	if _fail > 0:
		print("[unit] FAIL: %d failed, %d passed" % [_fail, _pass])
	else:
		print("[unit] all %d checks passed" % _pass)
	quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)


# ---------------------------------------------------------------- json_rpc

func _t_json_rpc() -> void:
	print("[unit] json_rpc framing")
	var r: Dictionary = JSON.parse_string(JsonRpc.result(7, {"a": 1}))
	_ok(r.get("jsonrpc") == "2.0" and int(r.get("id")) == 7 and r.get("result", {}).get("a") == 1.0, "result() frames id + payload")
	var e: Dictionary = JSON.parse_string(JsonRpc.error(3, JsonRpc.INVALID_PARAMS, "bad"))
	_ok(int(e.get("error", {}).get("code")) == -32602 and e.get("error", {}).get("message") == "bad", "error() carries code + message")
	_ok(not (e.get("error", {}) as Dictionary).has("data"), "error() omits data when null")
	var n: Dictionary = JSON.parse_string(JsonRpc.make_notification("notifications/tools/list_changed"))
	_ok(n.get("method") == "notifications/tools/list_changed" and not n.has("id") and not n.has("params"), "make_notification() has no id and omits null params")


# ---------------------------------------------------------------- effort tiers

func _t_effort() -> void:
	print("[unit] effort tier map")
	_ok(Effort.tier_of("doctor") == 1, "doctor is L1 (survives any cap)")
	_ok(Effort.tier_of("playtest") == 5, "playtest is L5 premium")
	_ok(Effort.tier_of("export_project") == 6, "export_project is L6")
	_ok(Effort.tier_of("no_such_tool_xyz") == 1, "unmapped tool falls back to L1 (never hidden by accident)")
	_ok(Effort.allows("playtest", 5) and not Effort.allows("playtest", 4), "allows() honors the boundary")
	_ok(Effort.clamp_level(0) == 1 and Effort.clamp_level(99) == Effort.MAX_LEVEL, "clamp_level() bounds 1..MAX")
	_ok((Effort.adds_at(4) as Array).has("get_performance_monitors"), "L4 See unlocks get_performance_monitors")


# ---------------------------------------------------------------- tool registry

func _t_registry() -> void:
	print("[unit] tool registry")
	var reg = Registry.new()
	reg.register({"name": "doctor", "description": "d", "readonly": true, "handler": Callable(self, "_ok")})
	reg.register({"name": "playtest", "description": "p", "destructive": true, "handler": Callable(self, "_ok")})
	_ok(reg.has("doctor") and not reg.has("nope"), "has() reflects registration")
	var l4: Array = reg.list_specs(4)
	var l4_names: Array = l4.map(func(s): return s["name"])
	_ok(l4_names.has("doctor") and not l4_names.has("playtest"), "list_specs(4) filters by tier")
	var l6: Array = reg.list_specs(6)
	_ok(l6.size() == 2, "list_specs(6) advertises everything")
	var doc: Dictionary = l4[0]
	_ok(doc.get("annotations", {}).get("readOnlyHint") == true, "annotations carry readOnlyHint")


# ---------------------------------------------------------------- poll_until (B2)

func _t_poll_until() -> void:
	print("[unit] jobs.poll_until (B2)")
	var hits: Array = [0]
	var r1: Dictionary = Jobs.poll_until(1000, 1, func() -> Dictionary:
		hits[0] += 1
		return {"done": hits[0]} if hits[0] >= 3 else {})
	_ok(int(r1.get("done", 0)) == 3 and hits[0] == 3, "tick result ends the wait")
	var pumped: Array = [0]
	var r2: Dictionary = Jobs.poll_until(30, 5, func() -> Dictionary:
		return {},
		func() -> void: pumped[0] += 1)
	_ok(bool(r2.get("timeout", false)), "deadline returns {timeout:true}")
	_ok(pumped[0] >= 1, "pump runs each pass (ran %d times)" % pumped[0])


# ---------------------------------------------------------------- http static helpers

func _t_http_static() -> void:
	print("[unit] http_server statics")
	var buf := "POST /mcp HTTP/1.1\r\nA: b\r\n\r\nBODY".to_utf8_buffer()
	var sep: int = HttpServer._find_header_end(buf)
	_ok(sep == buf.size() - 8, "_find_header_end locates CRLFCRLF")
	_ok(HttpServer._find_header_end("no separator here".to_utf8_buffer()) == -1, "_find_header_end returns -1 when absent")
	_ok(HttpServer._reason(401) == "Unauthorized" and HttpServer._reason(405) == "Method Not Allowed", "_reason maps auth/method codes")


# ---------------------------------------------------------------- client_config (B1 urls + codex upsert)

func _t_client_config() -> void:
	print("[unit] client_config")
	_ok(ClientConfig.mcp_url(8770) == "http://127.0.0.1:8770/mcp", "mcp_url tokenless")
	_ok(ClientConfig.mcp_url(8770, "tok") == "http://127.0.0.1:8770/mcp/tok", "mcp_url carries the token as a path segment")
	_ok(str(ClientConfig.entry(8770, "tok")["url"]).ends_with("/mcp/tok"), "entry() uses the tokened url")
	_ok(str((ClientConfig.desktop_entry(8770, "tok")["args"] as Array)[1]).ends_with("/mcp/tok"), "desktop_entry bridges the tokened url")
	_ok(ClientConfig.cline_entry(8770)["type"] == "streamableHttp", "cline entry keeps its type")

	var fresh: Dictionary = ClientConfig._codex_upsert("", 8770, "tok")
	_ok(bool(fresh["changed"]) and str(fresh["text"]).contains("url = \"http://127.0.0.1:8770/mcp/tok\""), "codex upsert: fresh file gets our table")
	var again: Dictionary = ClientConfig._codex_upsert(str(fresh["text"]), 8770, "tok")
	_ok(not bool(again["changed"]), "codex upsert: identical table is a no-op (no churn)")
	var other := "[model]\nname = \"o\"\n\n[mcp_servers.beckett]\nurl = \"http://127.0.0.1:1/mcp\"\nenabled = true\n\n[mcp_servers.zed]\nurl = \"x\"\n"
	var replaced: Dictionary = ClientConfig._codex_upsert(other, 8770, "")
	var txt := str(replaced["text"])
	_ok(txt.contains("url = \"http://127.0.0.1:8770/mcp\""), "codex upsert: our table is rewritten")
	_ok(txt.contains("[model]") and txt.contains("[mcp_servers.zed]") and txt.contains("url = \"x\""), "codex upsert: other tables survive verbatim")


# ---------------------------------------------------------------- serializer (mcp_server._tool_result)

func _t_server_serializer() -> void:
	print("[unit] mcp_server._tool_result serializer")
	var s = MCPServer.new()
	var tr: Dictionary = s._tool_result({"json": {"k": 1}})
	_ok(tr.has("structuredContent") and tr["structuredContent"].get("k") == 1, "json dict rides as structuredContent")
	_ok((tr["content"] as Array)[0]["type"] == "text", "json dict also renders as text for every client")
	var te: Dictionary = s._tool_result({"error": "boom", "suggestion": "fix"})
	_ok(bool(te["isError"]) and str((te["content"] as Array)[0]["text"]).contains("boom") and str((te["content"] as Array)[0]["text"]).contains("fix"), "error carries message + suggestion, isError=true")
	var ti: Dictionary = s._tool_result({"image_png_base64": "QUJD", "text": "shot"})
	var kinds: Array = (ti["content"] as Array).map(func(c): return c["type"])
	_ok(kinds.has("text") and kinds.has("image"), "image + text both present")
	# v1.10 P1: explicit-mime images (jpeg/webp screenshots) + a json legend alongside
	var tm: Dictionary = s._tool_result({"image_base64": "QUJD", "image_mime": "image/jpeg", "json": {"marks": []}})
	var img_c: Dictionary = {}
	for c in (tm["content"] as Array):
		if str(c.get("type", "")) == "image":
			img_c = c
	_ok(str(img_c.get("mimeType", "")) == "image/jpeg", "image_base64 carries its explicit mime")
	_ok(tm.has("structuredContent") and (tm["structuredContent"] as Dictionary).has("marks"), "json legend rides beside the image")
	var tn: Dictionary = s._tool_result({})
	_ok(str((tn["content"] as Array)[0]["text"]) == "(no output)", "empty result says so instead of vanishing")
	s.free()


# ---------------------------------------------------------------- constant-time compare (B1)

func _t_secure_equals() -> void:
	print("[unit] mcp_server._secure_equals (B1)")
	_ok(MCPServer._secure_equals("abc123", "abc123"), "equal strings match")
	_ok(not MCPServer._secure_equals("abc123", "abc124"), "one differing byte rejects")
	_ok(not MCPServer._secure_equals("abc", "abc1"), "length mismatch rejects")
	_ok(MCPServer._secure_equals("", ""), "empty == empty")


# ---------------------------------------------------------------- input validation gate

func _t_validate_args() -> void:
	print("[unit] mcp_server._validate_args")
	var s = MCPServer.new()
	var tool := {"input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "n": {"type": "integer"}}, "required": ["path"]}}
	_ok(s._validate_args(tool, {}) != "", "missing required arg rejected")
	_ok(s._validate_args(tool, {"path": [1, 2]}) != "", "array where string expected rejected")
	_ok(s._validate_args(tool, {"path": "res://x", "n": "5"}) == "", "numeric string passes the lenient gate")
	s.free()


# ---------------------------------------------------------------- B4 class_name mask

func _t_class_name_mask() -> void:
	print("[unit] script_tools class_name mask (B4)")
	var st = ScriptTools.new()
	var src := "class_name BeckettJobs\nextends RefCounted\nfunc f():\n\treturn 1\n"
	var own: Dictionary = st._mask_registered_class_name(src, "res://addons/beckett/core/jobs.gd")
	_ok(not own.has("conflict") and str(own.get("content", "")).begins_with("class_name __BeckettValidate"), "registered name + own path: renamed in place")
	_ok(str(own.get("content", "")).split("\n").size() == src.split("\n").size(), "mask preserves line count")
	var other: Dictionary = st._mask_registered_class_name(src, "res://somewhere/else.gd")
	_ok(other.has("conflict") and str(other["conflict"]).contains("BeckettJobs"), "registered name + different path: real conflict reported")
	var unreg: Dictionary = st._mask_registered_class_name("class_name TotallyNewName\nextends Node\n", "res://new.gd")
	_ok(str(unreg.get("content", "")).begins_with("class_name TotallyNewName"), "unregistered name: untouched (self-refs need it)")
	var inline: Dictionary = st._mask_registered_class_name("class_name BeckettJobs extends RefCounted\nfunc f():\n\treturn 1\n", "res://addons/beckett/core/jobs.gd")
	_ok(str(inline.get("content", "")).begins_with("class_name __BeckettValidate extends RefCounted"), "one-line form keeps its extends half")
	var abs: Dictionary = st._mask_registered_class_name("@abstract class_name BeckettJobs extends RefCounted\n@abstract func f() -> int\n", "res://addons/beckett/core/jobs.gd")
	_ok(str(abs.get("content", "")).begins_with("@abstract class_name __BeckettValidate extends RefCounted"), "4.5+ same-line @abstract form keeps its annotation (empirically compile-verified shape)")
	var v: Dictionary = st._compile(FileAccess.get_file_as_string("res://addons/beckett/core/jobs.gd"), "res://addons/beckett/core/jobs.gd")
	_ok(bool(v["valid"]), "THE regression: re-validating a real registered script compiles clean")


# ---------------------------------------------------------------- playtest helpers

func _t_playtest_helpers() -> void:
	print("[unit] playtest helpers")
	var pt = load(_PLAYTEST_TOOLS_PATH).new()
	_ok(pt._values_equal(1, 1.0), "int 1 matches JSON float 1.0 (the parity bug class)")
	_ok(not pt._values_equal(1, 2.0) and pt._values_equal("a", "a"), "unequal numbers / equal strings behave")
	_ok(pt._sanitize("../../evil") == "evil" or not pt._sanitize("../../evil").contains(".."), "sanitize strips traversal")
	_ok(pt._sanitize("my test!") == "my_test_", "sanitize keeps only safe filename chars")
	var diff: Dictionary = pt._perf_diff({"frame_ms_avg": 10.0, "orphan_delta": 0.0}, {"frame_ms_avg": 12.0, "orphan_delta": 2.0, "extra": 5.0})
	_ok(is_equal_approx(float(diff["frame_ms_avg"]["delta"]), 2.0) and is_equal_approx(float(diff["frame_ms_avg"]["delta_pct"]), 20.0), "perf_diff computes delta + pct")
	_ok(not (diff["orphan_delta"] as Dictionary).has("delta_pct"), "zero baseline omits delta_pct")
	_ok(not diff.has("extra"), "metrics missing from the baseline do not diff")


# ---------------------------------------------------------------- perf assert eval (A2)

func _t_perf_assert_eval() -> void:
	print("[unit] perf assert evaluation (A2)")
	var pt = load(_PLAYTEST_TOOLS_PATH).new()
	var perf := {"frame_ms_p95": 12.5, "memory_delta": 1024.0}
	var p: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "frame_ms_p95", "max": 16.7}, perf, false)
	_ok(str(p["status"]) == "pass", "within max passes")
	var f: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "frame_ms_p95", "max": 10.0}, perf, false)
	_ok(str(f["status"]) == "fail", "over max fails")
	var fmin: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "memory_delta", "min": 4096.0}, perf, false)
	_ok(str(fmin["status"]) == "fail", "under min fails")
	var unk: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "nope", "max": 1.0}, perf, false)
	_ok(str(unk["status"]) == "fail" and str(unk["detail"]).contains("unknown perf metric"), "unknown metric is a loud fail")
	var hs: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "frame_ms_p95", "max": 16.7}, perf, true)
	_ok(str(hs["status"]) == "skip", "headless game skips rendering-cost metrics")
	var hm: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "memory_delta", "max": 999999.0}, perf, true)
	_ok(str(hm["status"]) == "pass", "headless game still evaluates memory metrics")
	var nop: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "frame_ms_p95", "max": 16.7}, {}, false)
	_ok(str(nop["status"]) == "skip", "no capture -> skip with guidance")
	var nobound: Dictionary = pt._eval_perf_assert({"type": "perf", "metric": "frame_ms_p95"}, perf, false)
	_ok(str(nobound["status"]) == "fail", "assert without max/min is a loud fail")


# ---------------------------------------------------------------- perf summary math (A2, both engines)

func _t_perf_summary_runner() -> void:
	print("[unit] playtest_runner._perf_summary (headless CI engine)")
	var r = load(_PLAYTEST_RUNNER_PATH).new()
	r._perf_mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
	r._perf_orphan0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	for i in range(1, 101):
		r._perf_ms.append(float(i))
		r._perf_fps.append(60.0)
	var s: Dictionary = r._perf_summary()
	_ok(int(s["frames"]) == 100, "frames counted")
	_ok(is_equal_approx(float(s["frame_ms_min"]), 1.0) and is_equal_approx(float(s["frame_ms_max"]), 100.0), "min/max exact")
	_ok(is_equal_approx(float(s["frame_ms_avg"]), 50.5), "avg exact")
	_ok(is_equal_approx(float(s["frame_ms_p95"]), 95.0), "p95 = ceil-rank percentile")
	_ok(is_equal_approx(float(s["fps_avg"]), 60.0) and is_equal_approx(float(s["fps_min"]), 60.0), "fps series reduces")
	r.free()


func _t_perf_summary_runtime() -> void:
	print("[unit] runtime/replay_perf.gd (game-side engine, B7 module)")
	var rp = ReplayPerf.new()
	_ok((rp.summary() as Dictionary).is_empty(), "no samples -> empty summary (not fabricated zeros)")
	rp.begin()
	for i in range(1, 101):
		rp._ms.append(float(i))
		rp._fps.append(120.0)
	var s: Dictionary = rp.summary()
	_ok(is_equal_approx(float(s["frame_ms_p95"]), 95.0) and int(s["frames"]) == 100, "game-side p95 matches the runner's math")
	_ok(s.has("memory_delta") and s.has("orphan_delta") and s.has("draw_calls_end"), "summary carries the flat baseline-diff keys")
	rp.begin()
	_ok((rp.summary() as Dictionary).is_empty(), "begin() resets the capture")


func _t_input_codec() -> void:
	print("[unit] runtime/input_codec.gd round-trip (B7 module)")
	var key: InputEvent = InputCodec.build_event({"type": "key", "keycode": "Right", "pressed": true})
	_ok(key is InputEventKey and (key as InputEventKey).pressed, "key builds")
	var key_wire: Dictionary = InputCodec.serialize_event(key)
	_ok(str(key_wire.get("type")) == "key" and str(key_wire.get("keycode")) == "Right" and bool(key_wire.get("pressed")), "key round-trips through serialize")
	var ja: InputEvent = InputCodec.build_event({"type": "joy_axis", "axis": 1, "value": 2.5, "device": 3})
	_ok(ja is InputEventJoypadMotion and is_equal_approx((ja as InputEventJoypadMotion).axis_value, 1.0), "joy_axis clamps value to -1..1")
	var ja_wire: Dictionary = InputCodec.serialize_event(ja)
	_ok(int(ja_wire.get("axis")) == 1 and int(ja_wire.get("device")) == 3, "joy_axis round-trips axis + device")
	var td: InputEvent = InputCodec.build_event({"type": "touch_drag", "index": 2, "position": [10, 20], "relative": [1, 2]})
	var td_wire: Dictionary = InputCodec.serialize_event(td)
	_ok(str(td_wire.get("type")) == "touch_drag" and int(td_wire.get("index")) == 2 and float((td_wire.get("position") as Array)[1]) == 20.0, "touch_drag round-trips index + position")
	_ok(InputCodec.build_event({"type": "nope"}) == null, "unknown type builds null (skipped, not crashed)")
	var echo := InputEventKey.new()
	echo.keycode = KEY_A
	echo.echo = true
	_ok((InputCodec.serialize_event(echo) as Dictionary).is_empty(), "echo keys serialize to {} (dropped)")
	# v1.10: unicode rides on key events (type_text + recorded typing round-trip)
	var uk: InputEvent = InputCodec.build_event({"type": "key", "unicode": 104, "pressed": true})
	_ok(uk is InputEventKey and (uk as InputEventKey).unicode == 104, "key builds with unicode (int)")
	var uk2: InputEvent = InputCodec.build_event({"type": "key", "unicode": "h", "pressed": true})
	_ok(uk2 is InputEventKey and (uk2 as InputEventKey).unicode == 104, "key builds with unicode (1-char string)")
	var uk_wire: Dictionary = InputCodec.serialize_event(uk)
	_ok(int(uk_wire.get("unicode", 0)) == 104, "unicode round-trips through serialize")
	var plain: InputEvent = InputCodec.build_event({"type": "key", "keycode": "Right", "pressed": true})
	_ok(not (InputCodec.serialize_event(plain) as Dictionary).has("unicode"), "unicode key omitted when zero")


# ---------------------------------------------------------------- ui_inspect (v1.10)

## Real Controls on the live SceneTree root — layout math, the hit test, and the
## snapshot walker all run headless (no RHI needed: rects and state are simulation-side).
func _t_ui_inspect() -> void:
	print("[unit] runtime/ui_inspect.gd (ui_snapshot walker + occlusion hit test)")
	if root == null:
		_ok(false, "SceneTree root unavailable — ui_inspect group cannot run")
		return
	# The headless --script root window is pinned at 64x64 (window_set_size no-ops on the
	# headless DisplayServer), so the whole stage lives INSIDE 64x64 — a point outside the
	# viewport would rightly read as clipped.
	var host := Control.new()
	host.name = "Host"
	host.position = Vector2.ZERO
	host.size = Vector2(60, 60)
	root.add_child(host)
	var btn := Button.new()
	btn.name = "Play"
	btn.text = "Play"
	btn.position = Vector2(2, 2)
	btn.size = Vector2(20, 10)
	host.add_child(btn)
	var slider := HSlider.new()
	slider.name = "Volume"
	slider.min_value = 0
	slider.max_value = 10
	slider.value = 7
	slider.position = Vector2(2, 40)
	slider.size = Vector2(40, 8)
	host.add_child(slider)
	# is_visible_in_tree stays false until the tree runs a frame (headless --script quirk;
	# a real play session — windowed OR headless CI — is always frames-deep). One tick:
	await process_frame
	var center: Vector2 = btn.get_global_rect().get_center()

	# --- hit test
	_ok(UiInspect.pick_at(root, root, center) == btn, "pick_at finds the button at its center")
	var overlay := ColorRect.new()
	overlay.name = "Overlay"
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(60, 60)
	host.add_child(overlay)  # later sibling = painted on top
	_ok(UiInspect.pick_at(root, root, center) == overlay, "covering sibling (STOP) receives the point")
	_ok(not UiInspect.click_reaches(overlay, btn), "click_reaches refuses the covered button")
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ok(UiInspect.pick_at(root, root, center) == btn, "overlay with IGNORE is click-through")
	var icon := ColorRect.new()
	icon.name = "Icon"
	icon.mouse_filter = Control.MOUSE_FILTER_PASS
	icon.position = Vector2.ZERO
	icon.size = btn.size  # the button's REAL size (min-size clamp beat the 20x10 request)
	btn.add_child(icon)
	var deep: Node = UiInspect.pick_at(root, root, center)
	_ok(deep == icon, "PASS child is the raw receiver")
	_ok(UiInspect.click_reaches(icon, btn), "PASS child bubbles the click up to the button")
	var layer := CanvasLayer.new()
	layer.layer = 5
	root.add_child(layer)
	var modal := ColorRect.new()
	modal.name = "Modal"
	modal.position = Vector2.ZERO
	modal.size = Vector2(60, 60)
	layer.add_child(modal)
	_ok(UiInspect.pick_at(root, root, center) == modal, "higher CanvasLayer overlay wins the pick")
	root.remove_child(layer)
	layer.free()

	# --- disabled probe
	btn.disabled = true
	_ok(UiInspect.is_disabled(btn), "is_disabled sees BaseButton.disabled")
	btn.disabled = false
	_ok(not UiInspect.is_disabled(slider), "is_disabled false on a control without the property")

	# --- snapshot: entries, state, hash stability, since_hash short-circuit
	var snap: Dictionary = UiInspect.snapshot(root, root, host, host, {})
	_ok(bool(snap.get("ok", false)), "snapshot ok")
	var by_path := {}
	for e in snap.get("controls", []):
		by_path[str((e as Dictionary).get("path", ""))] = e
	_ok(by_path.has("Play") and str((by_path["Play"] as Dictionary).get("text", "")) == "Play", "snapshot carries the button + text")
	var gr := btn.get_global_rect()
	var play_rect: Array = (by_path.get("Play", {}) as Dictionary).get("rect", [])
	_ok(play_rect == [roundi(gr.position.x), roundi(gr.position.y), roundi(gr.size.x), roundi(gr.size.y)],
		"snapshot rect mirrors the live global rect (ints)")
	var vol: Dictionary = by_path.get("Volume", {})
	_ok(is_equal_approx(float(vol.get("value", -1)), 7.0) and vol.get("range", []) == [0.0, 10.0], "snapshot carries slider value + range")
	var snap2: Dictionary = UiInspect.snapshot(root, root, host, host, {})
	_ok(str(snap.get("hash")) == str(snap2.get("hash")), "hash is stable for an unchanged UI")
	var snap3: Dictionary = UiInspect.snapshot(root, root, host, host, {"since_hash": str(snap.get("hash"))})
	_ok(bool(snap3.get("unchanged", false)), "since_hash short-circuits to unchanged")
	btn.text = "Start"
	var snap4: Dictionary = UiInspect.snapshot(root, root, host, host, {"since_hash": str(snap.get("hash"))})
	_ok(not bool(snap4.get("unchanged", false)) and str(snap4.get("hash")) != str(snap.get("hash")), "a text change changes the hash")

	# --- snapshot occlusion flag
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var snap5: Dictionary = UiInspect.snapshot(root, root, host, host, {})
	var covered := {}
	for e in snap5.get("controls", []):
		covered[str((e as Dictionary).get("path", ""))] = e
	_ok(str((covered.get("Play", {}) as Dictionary).get("occluded_by", "")) == "Overlay", "snapshot flags the covered button with occluded_by")

	# --- ui_audit checks on a planted-bug stage (all inside the 64x64 window)
	var stage := Control.new()
	stage.name = "AuditStage"
	stage.size = Vector2(60, 60)
	root.add_child(stage)
	var oa := TextureButton.new()
	oa.name = "OA"
	oa.position = Vector2(2, 2)
	oa.size = Vector2(20, 12)
	stage.add_child(oa)
	var ob := TextureButton.new()
	ob.name = "OB"
	ob.position = Vector2(12, 6)  # overlaps OA by half
	ob.size = Vector2(20, 12)
	stage.add_child(ob)
	var far := TextureButton.new()
	far.name = "Far"
	far.position = Vector2(200, 200)  # entirely outside the 64x64 viewport
	far.size = Vector2(10, 10)
	stage.add_child(far)
	var lbl := Label.new()
	lbl.name = "Trunc"
	lbl.text = "far too long for twenty pixels"
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.position = Vector2(2, 30)
	lbl.size = Vector2(20, 12)
	stage.add_child(lbl)
	var mo := Button.new()
	mo.name = "MouseOnly"
	mo.text = "m"
	mo.focus_mode = Control.FOCUS_NONE
	mo.position = Vector2(2, 44)
	stage.add_child(mo)
	await process_frame
	var au: Dictionary = UiInspect.audit(root, root, stage, stage, {"touch_min": 15})
	_ok(bool(au.get("ok", false)), "audit ok")
	var found := {}
	for is_ in au.get("issues", []):
		found[str((is_ as Dictionary).get("type", ""))] = true
	_ok(found.has("overlap"), "audit finds the overlapping pair")
	_ok(found.has("offscreen"), "audit finds the offscreen control")
	_ok(found.has("text_overflow"), "audit finds the trimmed label (font-measured, not min-size)")
	_ok(found.has("small_target"), "audit flags sub-touch_min targets")
	_ok(found.has("mouse_only"), "audit flags focus_mode NONE buttons")
	root.remove_child(stage)
	stage.free()

	# --- Set-of-Mark drawing onto a captured Image (no scene, pure pixels)
	var canvas := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0))
	UiInspect.annotate_image(canvas, [{"i": 1, "path": "x", "rect": [4, 4, 24, 16]}], Vector2.ZERO, 1.0)
	_ok(canvas.get_pixel(4, 4).is_equal_approx(UiInspect.MARK_COLOR), "annotate draws the box outline")
	_ok(canvas.get_pixel(40, 40).is_equal_approx(Color(0, 0, 0)), "annotate leaves pixels outside the mark alone")
	var tagged := false
	for py in range(4, 22):
		for px in range(4, 30):
			if canvas.get_pixel(px, py).is_equal_approx(UiInspect.TAG_FG):
				tagged = true
	_ok(tagged, "annotate stamps the digit tag")

	root.remove_child(host)
	host.free()


func _t_bridge_compare() -> void:
	print("[unit] runtime_bridge handshake compare (v1.9.1)")
	_ok(RuntimeBridge._secure_equals("tok-abc", "tok-abc"), "matching hello accepted")
	_ok(not RuntimeBridge._secure_equals("tok-abc", "tok-abd"), "wrong hello rejected")
	_ok(not RuntimeBridge._secure_equals("", "tok-abc"), "empty hello vs required token rejected")


# ---------------------------------------------------------------- callargs (v1.10.2)

## Typed probe: script param types flow through get_method_list exactly like ClassDB
## types do for native methods, so this exercises the REAL prepare() path end-to-end
## (including callv actually executing with the coerced args).
class CallArgsProbe:
	func take_vec3i(pos: Vector3i, item: int, orientation: int = 0) -> Vector3i:
		return pos if item >= 0 and orientation >= 0 else Vector3i.ZERO

	func take_vec3(v: Vector3) -> Vector3:
		return v

	func take_color(c: Color) -> Color:
		return c

	func take_sname(n: StringName) -> bool:
		return n == &"jump"

	func take_untyped(a, b := 5) -> Array:
		return [a, b]

	func take_pv2(points: PackedVector2Array) -> int:
		return points.size()

	func take_obj(o: Object) -> bool:
		return o != null


func _t_call_args() -> void:
	print("[unit] callargs arg coercion (v1.10.2 silent-argument fix)")
	var p := CallArgsProbe.new()
	# The field-review trap verbatim: [1,0,0] for a Vector3i param used to no-op as ok.
	var r: Dictionary = CallArgs.prepare(p, "take_vec3i", [[1, 0, 0], 60.0, 16])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Vector3i(1, 0, 0), "[x,y,z] coerces to Vector3i")
	_ok(typeof(r["args"][1]) == TYPE_INT and r["args"][1] == 60, "JSON 60.0 coerces to int for an int param")
	_ok(p.callv("take_vec3i", r["args"]) == Vector3i(1, 0, 0), "prepared args execute through callv")
	r = CallArgs.prepare(p, "take_vec3", [{"x": 1, "y": 2, "z": 3}])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Vector3(1, 2, 3), "{x,y,z} coerces to Vector3")
	r = CallArgs.prepare(p, "take_vec3", ["1 2 3"])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Vector3(1, 2, 3), "\"x y z\" string coerces to Vector3")
	r = CallArgs.prepare(p, "take_vec3", ["Vector3(4, 5, 6)"])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Vector3(4, 5, 6), "Godot literal string coerces to Vector3")
	r = CallArgs.prepare(p, "take_vec3i", [[1, 0], 1])
	_ok(not bool(r.get("ok", false)) and str(r.get("error", "")).contains("arg 0"), "wrong-size vector array errors (no silent zero)")
	r = CallArgs.prepare(p, "take_vec3i", [true, 1])
	_ok(not bool(r.get("ok", false)), "garbage for a vector param errors (no silent zero)")
	r = CallArgs.prepare(p, "take_vec3i", [[1, 0, 0]])
	_ok(not bool(r.get("ok", false)) and str(r.get("error", "")).contains("at least"), "too few args errors instead of a silent no-op")
	r = CallArgs.prepare(p, "take_vec3i", [[1, 0, 0], 1, 0, 9])
	_ok(not bool(r.get("ok", false)) and str(r.get("error", "")).contains("at most"), "too many args errors")
	r = CallArgs.prepare(p, "take_color", ["#ff0000"])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Color("#ff0000"), "hex string coerces to Color")
	r = CallArgs.prepare(p, "take_color", [[1, 0, 0]])
	_ok(bool(r.get("ok", false)) and r["args"][0] == Color(1, 0, 0, 1), "[r,g,b] coerces to Color")
	r = CallArgs.prepare(p, "take_sname", ["jump"])
	_ok(bool(r.get("ok", false)) and typeof(r["args"][0]) == TYPE_STRING_NAME and p.callv("take_sname", r["args"]), "String coerces to StringName")
	r = CallArgs.prepare(p, "take_untyped", [{"hp": 1}])
	_ok(bool(r.get("ok", false)) and r["args"][0] is Dictionary and p.callv("take_untyped", r["args"])[1] == 5, "untyped params pass through; defaults still fill")
	r = CallArgs.prepare(p, "take_pv2", [[[0, 0], [1, 0], [1, 1]]])
	_ok(bool(r.get("ok", false)) and p.callv("take_pv2", r["args"]) == 3, "[[x,y],..] coerces to PackedVector2Array")
	r = CallArgs.prepare(p, "take_obj", [null])
	_ok(bool(r.get("ok", false)) and p.callv("take_obj", r["args"]) == false, "null passes for an object param")
	r = CallArgs.prepare(p, "take_obj", ["Player"])
	_ok(not bool(r.get("ok", false)), "object param from a string errors without a resolver (no silent null)")
	r = CallArgs.prepare(p, "no_such_method_here", [1, 2])
	_ok(bool(r.get("ok", false)), "metadata-less call falls back to raw passthrough")
	var c: Dictionary = CallArgs.coerce("UI/Health", TYPE_NODE_PATH)
	_ok(bool(c.get("ok", false)) and c["value"] is NodePath, "String coerces to NodePath")
	c = CallArgs.coerce(1.5, TYPE_INT)
	_ok(not bool(c.get("ok", false)), "fractional float for an int param errors")
	c = CallArgs.coerce("Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 7, 8, 9)", TYPE_TRANSFORM3D)
	_ok(bool(c.get("ok", false)) and (c["value"] as Transform3D).origin == Vector3(7, 8, 9), "Transform3D literal string parses")
	c = CallArgs.coerce([255, 128, 0], TYPE_PACKED_INT32_ARRAY)
	_ok(bool(c.get("ok", false)) and c["value"] is PackedInt32Array, "int array coerces to PackedInt32Array")


# ---------------------------------------------------------------- error echo (v1.11)

func _t_error_echo() -> void:
	print("[unit] error echo (v1.11 - engine errors attached to the causing call)")
	var sink = GameLogSink.new()
	# Window semantics, fed directly (no OS Logger needed).
	var m0: int = sink.mark()
	sink._on_error("do_thing", "res://game.gd", 12, "ERR", "boom happened", 0, [])
	var ech: Array = sink.echo_since(m0)
	_ok(ech.size() == 1 and str(ech[0]["severity"]) == "error" and str(ech[0]["message"]) == "boom happened", "an error in the window is echoed")
	_ok(str(ech[0]["where"]).contains("res://game.gd:12"), "echo carries file:line")
	_ok(sink.echo_since(sink.mark()).is_empty(), "a fresh mark sees nothing")
	sink._on_message("just a print", false)
	_ok(sink.echo_since(m0).size() == 1, "prints are not echoed")
	sink._on_error("f", "w.gd", 1, "W", "warn", 1, [])
	var ech2: Array = sink.echo_since(m0)
	_ok(str(ech2[1]["severity"]) == "warning", "severity maps warning")
	var m1: int = sink.mark()
	for k in range(12):
		sink._on_error("f", "x.gd", k, "E", "spam %d" % k, 2, [])
	var capped: Array = sink.echo_since(m1)
	_ok(capped.size() == 9 and str(capped[8]["severity"]) == "note" and str(capped[8]["message"]).contains("+4 more"), "echo caps at 8 + a count note")
	_ok(str(capped[0]["severity"]) == "script", "severity maps script errors")
	# The REAL capture path on this engine (4.5+ runner): install -> push_error -> echoed.
	sink.install()
	if sink.capture_active():
		var m2: int = sink.mark()
		push_error("[beckett unit probe - intentional error, ignore]")
		var live: Array = sink.echo_since(m2)
		_ok(not live.is_empty() and str(live[0]["message"]).contains("intentional error"), "a real push_error lands in the window")
		sink.uninstall()
		var m3: int = sink.mark()
		push_error("[beckett unit probe 2 - after uninstall, ignore]")
		_ok(sink.echo_since(m3).is_empty(), "uninstall stops the capture")
	else:
		print("  (skip live-capture checks: Logger API needs Godot 4.5+)")
	# Serializer: engine_errors ride text + structuredContent; isError untouched.
	var s = MCPServer.new()
	var tr: Dictionary = s._tool_result({"text": "done", "engine_errors": [{"severity": "error", "message": "kaboom", "where": "a.gd:1 in f"}]})
	_ok(not bool(tr["isError"]), "engine_errors stay advisory (isError false)")
	var texts: Array = (tr["content"] as Array).filter(func(c): return str(c.get("type", "")) == "text")
	_ok(texts.size() == 2 and str(texts[1]["text"]).contains("kaboom"), "engine errors render as a text block")
	_ok(tr.has("structuredContent") and (tr["structuredContent"] as Dictionary).has("engine_errors"), "engine_errors ride structuredContent")
	var tj: Dictionary = s._tool_result({"json": {"result": 1}, "engine_errors": [{"severity": "error", "message": "x"}]})
	_ok((tj["structuredContent"] as Dictionary).has("result") and (tj["structuredContent"] as Dictionary).has("engine_errors"), "engine_errors merge beside a json payload")
	s.free()


# ---------------------------------------------------------------- focus graph (v1.11)

func _t_focus_graph() -> void:
	print("[unit] ui_audit focus graph (v1.11)")
	var stage := Control.new()
	stage.name = "FocusStage"
	stage.size = Vector2(60, 60)
	root.add_child(stage)
	var a := Button.new()
	a.name = "FA"
	a.position = Vector2(0, 0)
	a.size = Vector2(10, 8)
	stage.add_child(a)
	var b := Button.new()
	b.name = "FB"
	b.position = Vector2(0, 12)
	b.size = Vector2(10, 8)
	stage.add_child(b)
	var island := Button.new()
	island.name = "Island"
	island.position = Vector2(40, 40)
	island.size = Vector2(10, 8)
	stage.add_child(island)
	await process_frame
	# Pin the graph explicitly: A <-> B closed loop, Island points only at itself -
	# unreachable from the entry AND a dead end.
	for ctl: Control in [a, b, island]:
		var to: Control = b if ctl == a else (a if ctl == b else island)
		ctl.focus_next = to.get_path()
		ctl.focus_previous = to.get_path()
		ctl.focus_neighbor_left = to.get_path()
		ctl.focus_neighbor_top = to.get_path()
		ctl.focus_neighbor_right = to.get_path()
		ctl.focus_neighbor_bottom = to.get_path()
	var au: Dictionary = UiInspect.audit(root, root, stage, stage, {})
	var found := {}
	for is_ in au.get("issues", []):
		found[str((is_ as Dictionary).get("type", ""))] = str((is_ as Dictionary).get("path", ""))
	_ok(found.has("no_initial_focus"), "nothing focused -> no_initial_focus flagged")
	_ok(found.has("focus_unreachable") and str(found.get("focus_unreachable", "")).contains("Island"), "the island is unreachable from the entry")
	_ok(found.has("focus_dead_end") and str(found.get("focus_dead_end", "")).contains("Island"), "the island is a dead end (all moves stay on it)")
	var fs: Dictionary = au.get("focus", {})
	_ok(int(fs.get("focusable", 0)) == 3 and int(fs.get("reachable", 0)) == 2, "focus summary counts focusable=3 reachable=2")
	_ok(str(fs.get("entry", "")).contains("FA"), "entry defaults to the first focusable in tree order")
	a.grab_focus()
	await process_frame
	var au2: Dictionary = UiInspect.audit(root, root, stage, stage, {})
	var found2 := {}
	for is2 in au2.get("issues", []):
		found2[str((is2 as Dictionary).get("type", ""))] = true
	_ok(not found2.has("no_initial_focus"), "with focus granted, no_initial_focus clears")
	_ok(not found2.has("focus_unreachable") or str(found.get("focus_unreachable", "")).contains("Island"), "A/B stay reachable (only the island flags)")
	root.remove_child(stage)
	stage.free()


# ---------------------------------------------------------------- per-frame typing (v1.11)

func _t_type_stream() -> void:
	print("[unit] per-frame typing window (v1.11)")
	var rt = MCPRuntime.new()
	root.add_child(rt)
	var field := LineEdit.new()
	field.name = "TypeField"
	root.add_child(field)
	rt._typing_ctrl = field
	rt._typing_text = "abc"
	rt._typing_i = 0
	rt._typing_submit = true
	rt._typing_done = false
	rt._typing_error = ""
	rt._type_tick()
	_ok(rt._typing_i == 1 and not rt._typing_done, "tick 1 injects exactly one char")
	rt._type_tick()
	rt._type_tick()
	_ok(rt._typing_i == 3 and not rt._typing_done, "chars pace one per tick")
	rt._type_tick()
	_ok(rt._typing_submit == false and not rt._typing_done, "the submit Enter takes its own frame")
	rt._type_tick()
	_ok(rt._typing_done, "the stream closes after the queue drains")
	var st: Dictionary = rt._type_status()
	_ok(bool(st.get("done", false)) and int(st.get("typed", -1)) == 3, "type_status reports done + typed count")
	# Vanish mid-stream: stop honestly instead of typing into the void.
	rt._typing_ctrl = field
	rt._typing_text = "xy"
	rt._typing_i = 0
	rt._typing_done = false
	rt._typing_submit = false
	field.hide()
	rt._type_tick()
	_ok(rt._typing_done and str(rt._typing_error).contains("vanished"), "a vanished target ends the stream with a warning")
	root.remove_child(field)
	field.free()
	root.remove_child(rt)
	rt.free()
