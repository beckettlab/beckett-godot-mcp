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
const RuntimeBridge := preload("res://addons/beckett/core/runtime_bridge.gd")
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


func _t_bridge_compare() -> void:
	print("[unit] runtime_bridge handshake compare (v1.9.1)")
	_ok(RuntimeBridge._secure_equals("tok-abc", "tok-abc"), "matching hello accepted")
	_ok(not RuntimeBridge._secure_equals("tok-abc", "tok-abd"), "wrong hello rejected")
	_ok(not RuntimeBridge._secure_equals("", "tok-abc"), "empty hello vs required token rejected")
