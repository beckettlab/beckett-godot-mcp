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
const ProjectTools := preload("res://addons/beckett/tools/project_tools.gd")
const Captures := preload("res://addons/beckett/core/captures.gd")
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
	_t_idempotency_bounds()
	_t_instructions_skill_count()
	_t_http_content_type()
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
	_t_game_view_probe()
	_t_setting_type_mirror()
	_t_doctor_context()
	_t_property_owner()
	_t_winding()
	_t_screenshot_metric()
	_t_screenshot_cap()
	_t_compare_downscale_chain()
	_t_dock_tier_stats()
	_t_resolver_suggestions()
	_t_description_budget()
	_t_help_never_advertised()
	_t_output_schema()
	_t_captures()
	_t_deliver_modes()
	_t_ci_matrix()
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
	# v1.12: render diagnosis is SEEING the game, so it must stay inside the Lite ceiling;
	# hot-swapping shaders MUTATES it, so it must stay outside. A slip either way is a
	# silent edition leak that only pack.ps1's gate would catch, and only at build time.
	_ok(Effort.tier_of("render_probe") == 4, "render_probe is L4 (ships in Lite)")
	_ok(Effort.tier_of("set_debug_draw") == 4, "set_debug_draw is L4 (ships in Lite)")
	_ok(Effort.tier_of("reload_shader") == 5, "reload_shader is L5 premium (mutates the live game)")


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

	# v1.12.1 regression: the configured port had four copy-pasted resolvers and the dock's
	# Start button used none of them, so Stop→Start bound 8770 in a project set to 8772 while
	# every client config still pointed at 8772. Resolution now lives here alone.
	var had_port := ProjectSettings.has_setting("beckett/port")
	var prev_port: Variant = ProjectSettings.get_setting("beckett/port", null)
	var prev_env := OS.get_environment("BECKETT_PORT")
	OS.set_environment("BECKETT_PORT", "")
	ProjectSettings.set_setting("beckett/port", null)
	_ok(ClientConfig.configured_port() == ClientConfig.DEFAULT_PORT, "configured_port falls back to the default when unset")
	ProjectSettings.set_setting("beckett/port", 8772)
	_ok(ClientConfig.configured_port() == 8772, "configured_port honors the beckett/port project setting")
	OS.set_environment("BECKETT_PORT", "9001")
	_ok(ClientConfig.configured_port() == 9001, "BECKETT_PORT env overrides the project setting")
	OS.set_environment("BECKETT_PORT", "not-a-port")
	_ok(ClientConfig.configured_port() == 8772, "a junk BECKETT_PORT falls through to the project setting")
	OS.set_environment("BECKETT_PORT", prev_env)
	ProjectSettings.set_setting("beckett/port", prev_port if had_port else null)


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
	# v1.13 S1: text and json are independent. The if/elif dropped whichever came
	# second, which is why annotated screenshots used to hide their line in the json.
	var tb: Dictionary = s._tool_result({"text": "shot", "json": {"marks": [1]}})
	var tb_texts: Array = (tb["content"] as Array).filter(func(c): return str(c.get("type", "")) == "text")
	_ok(tb_texts.size() == 2 and str(tb_texts[0]["text"]) == "shot", "text block survives beside a json payload")
	_ok(tb.has("structuredContent") and (tb["structuredContent"] as Dictionary).has("marks"), "json still rides as structuredContent when text is present")
	# v1.13 S1: an error stays exclusive - no half-written text alongside a failure.
	var tex: Dictionary = s._tool_result({"error": "boom", "text": "half done"})
	_ok((tex["content"] as Array).size() == 1 and not str((tex["content"] as Array)[0]["text"]).contains("half done"), "error suppresses the handler's own text")
	# v1.13 S2: the json mirror is compact; the 2-space indent was pure token cost.
	var tc: Dictionary = s._tool_result({"json": {"a": {"b": 1}}})
	_ok(not str((tc["content"] as Array)[0]["text"]).contains("\n"), "json mirror is compact (no pretty-print newlines)")
	# v1.14 B1: resource_link rides beside the other blocks, but ONLY for a peer whose
	# negotiated revision knows the content type. The gate lives in the serializer so one
	# check covers every producer; verify BOTH directions or the gate is decoration.
	var links := [{"uri": "capture://0123456789abcdef.png", "name": "shot", "mimeType": "image/png"}]
	s._negotiated_version = "2025-06-18"
	var tl: Dictionary = s._tool_result({"text": "shot", "resource_links": links})
	var tl_kinds: Array = (tl["content"] as Array).map(func(c): return c["type"])
	_ok(tl_kinds.has("resource_link"), "resource_link block emitted on 2025-06-18")
	s._negotiated_version = "2025-03-26"
	var tl2: Dictionary = s._tool_result({"text": "shot", "resource_links": links})
	var tl2_kinds: Array = (tl2["content"] as Array).map(func(c): return c["type"])
	_ok(not tl2_kinds.has("resource_link"), "resource_link suppressed on 2025-03-26 (predates the content type)")
	_ok(tl2_kinds.has("text"), "the rest of the result survives the suppression")
	_ok(s.supports_resource_link() == false, "supports_resource_link() reports the gate honestly")
	# A malformed link entry must be skipped, not crash the whole result.
	s._negotiated_version = "2025-11-25"
	var tl3: Dictionary = s._tool_result({"text": "shot", "resource_links": [{"name": "no uri"}, "not a dict"]})
	_ok((tl3["content"] as Array).size() == 1, "link entries without a uri are dropped, not fatal")
	s.free()


# ---------------------------------------------------------------- v1.14 context diet

## Register every shipped tool module into a throwaway registry. Register-time code touches
## only the registry (handlers are bound Callables, never invoked here), so this needs no
## server, no editor and no game — which is what makes the description budget testable at all.
func _all_tool_specs() -> Array:
	var reg = Registry.new()
	for path in MCPServer.TOOL_MODULES:
		if not ResourceLoader.exists(path):
			continue  # Lite: pack.ps1 trimmed this module
		var mod = load(path).new()
		mod._register(reg)
	var out: Array = []
	for n in reg.names():
		out.append(reg.get_tool(n))
	return out


func _t_description_budget() -> void:
	print("[unit] v1.14 description budget (the context diet)")
	var specs := _all_tool_specs()
	_ok(specs.size() > 40, "tool modules registered (%d tools)" % specs.size())
	# 600/130 restate the diet RULE rather than its target: v1.14 rewrote every description
	# over 600 chars down to ~400, and every argument description over 110 down to ~90. The
	# guard fires on the next one that crosses the line, not on a 402-char rewrite — a guard
	# that cries at the target is a guard someone deletes. doctor is exempt: it is the tool
	# whose job is to explain a capped surface, and v1.13.0 grew it deliberately (effort.gd
	# L1 note). This check found animation_manage (906), which the byte-level survey missed.
	var fat: Array = []
	var fat_args: Array = []
	for t in specs:
		var name := str(t["name"])
		if name != "doctor" and str(t["description"]).length() > 600:
			fat.append("%s (%d)" % [name, str(t["description"]).length()])
		var props: Dictionary = (t.get("input_schema", {}) as Dictionary).get("properties", {})
		for k in props:
			var decl = props[k]
			if decl is Dictionary and str((decl as Dictionary).get("description", "")).length() > 130:
				fat_args.append("%s.%s (%d)" % [name, str(k), str((decl as Dictionary)["description"]).length()])
	_ok(fat.is_empty(), "no tool description over 600 chars except doctor%s" % ("" if fat.is_empty() else ": " + ", ".join(fat)))
	_ok(fat_args.is_empty(), "no argument description over 130 chars%s" % ("" if fat_args.is_empty() else ": " + ", ".join(fat_args)))
	# A pointer to nothing is worse than no pointer: it teaches the model a call that
	# returns the same text it already read.
	var dangling: Array = []
	for t in specs:
		if str(t["description"]).contains("help(tool="):
			if not t.has("help"):
				dangling.append(str(t["name"]) + " (no help key)")
			elif str(t["help"]).length() <= str(t["description"]).length():
				dangling.append(str(t["name"]) + " (help no longer than the description)")
	_ok(dangling.is_empty(), "every help(tool=...) pointer resolves to a longer long form%s" % ("" if dangling.is_empty() else ": " + ", ".join(dangling)))


func _t_help_never_advertised() -> void:
	print("[unit] v1.14 the long form never ships on tools/list")
	var reg = Registry.new()
	reg.register({"name": "z_diet", "description": "short", "help": "the long form", "handler": Callable(self, "_ok")})
	var spec: Dictionary = (reg.list_specs(6) as Array)[0]
	_ok(not spec.has("help"), "list_specs omits the help key (that IS the diet)")
	_ok(str(spec["description"]) == "short", "the short description is what ships")
	_ok(reg.help_for("z_diet") == "the long form", "help_for returns the long form")
	_ok(reg.help_for("z_missing") == "", "help_for on an unknown tool is empty, not an error")
	_ok(reg.documented_names() == ["z_diet"], "documented_names lists only tools with a long form")
	reg.register({"name": "z_plain", "description": "only this", "handler": Callable(self, "_ok")})
	_ok(reg.help_for("z_plain") == "only this", "a tool with no long form falls back to its description")


func _t_output_schema() -> void:
	print("[unit] v1.14 outputSchema is a promise we can keep")
	var reg = Registry.new()
	reg.register({"name": "z_typed", "description": "d", "output_schema": {"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}, "handler": Callable(self, "_ok")})
	var spec: Dictionary = (reg.list_specs(6) as Array)[0]
	_ok(spec.has("outputSchema"), "output_schema is advertised as outputSchema")
	var declared: Array = []
	for t in _all_tool_specs():
		if not t.has("output_schema"):
			continue
		declared.append(str(t["name"]))
		var sc: Dictionary = t["output_schema"]
		var props: Dictionary = sc.get("properties", {})
		_ok(str(sc.get("type", "")) == "object", "%s outputSchema is type object (only Dictionaries are promoted)" % str(t["name"]))
		_ok(not sc.has("additionalProperties"), "%s outputSchema does not close the object" % str(t["name"]))
		var undeclared: Array = []
		for r in sc.get("required", []):
			if not props.has(str(r)):
				undeclared.append(str(r))
		_ok(undeclared.is_empty(), "%s required keys are all declared as properties" % str(t["name"]))
	_ok(declared.size() >= 1, "at least one tool declares an outputSchema (%s)" % ", ".join(declared))
	# The failure mode that parked this feature: a declared schema on a path that returns
	# text. Prove the contract end to end — a representative all-json result MUST survive
	# _tool_result as non-null structuredContent carrying every required key.
	var s = MCPServer.new()
	for t in _all_tool_specs():
		if not t.has("output_schema"):
			continue
		var sample: Dictionary = {}
		for k in (t["output_schema"] as Dictionary).get("required", []):
			sample[str(k)] = null
		var res: Dictionary = s._tool_result({"json": sample})
		var sc_out = res.get("structuredContent")
		var all_present := sc_out is Dictionary
		if all_present:
			for k in (t["output_schema"] as Dictionary).get("required", []):
				if not (sc_out as Dictionary).has(str(k)):
					all_present = false
		_ok(all_present, "%s: a schema-shaped result survives _tool_result as structuredContent" % str(t["name"]))
	s.free()


func _t_captures() -> void:
	print("[unit] v1.14 capture store")
	_ok(Captures.is_valid_id("0123456789abcdef.png"), "a well-formed id validates")
	_ok(not Captures.is_valid_id("../../etc/passwd"), "traversal is rejected")
	_ok(not Captures.is_valid_id("0123456789ABCDEF.png"), "uppercase hex is rejected (one canonical form)")
	_ok(not Captures.is_valid_id("0123456789abcdef.exe"), "an unknown extension is rejected")
	_ok(not Captures.is_valid_id("0123456789abcde.png"), "a 15-digit id is rejected")
	_ok(Captures.path_for("../secret") == "", "path_for refuses to build a path for a bad id")
	_ok(Captures.ext_for_mime("image/jpeg") == "jpg" and Captures.ext_for_mime("image/webp") == "webp", "mime maps to an extension")
	_ok(Captures.ext_for_mime("nonsense") == "png", "an unknown mime falls back to png")
	_ok(Captures.mime_for_id("0123456789abcdef.webp") == "image/webp", "id maps back to a mime")
	# Round trip through the real filesystem: store, read, compare.
	var payload := Marshalls.raw_to_base64("BeckettCaptureRoundTrip".to_utf8_buffer())
	var stored: Dictionary = Captures.store(payload, "image/png")
	_ok(not stored.has("error"), "store() wrote a capture%s" % ("" if not stored.has("error") else ": " + str(stored.get("error"))))
	if not stored.has("error"):
		_ok(str(stored["uri"]).begins_with("capture://"), "store() returns a capture:// uri")
		_ok(str(stored["path"]).is_absolute_path(), "store() returns an ABSOLUTE path for the text channel")
		var back: Dictionary = Captures.read_id(str(stored["id"]))
		_ok(bool(back.get("ok", false)) and str(back.get("blob", "")) == payload, "read_id round-trips the exact bytes as a blob")
		_ok(not back.has("text"), "a binary resource carries blob, never text")
		DirAccess.remove_absolute(Captures.DIR + "/" + str(stored["id"]))
	var missing: Dictionary = Captures.read_id("ffffffffffffffff.png")
	_ok(not bool(missing.get("ok", true)), "reading a capture that is gone fails honestly")
	var bad: Dictionary = Captures.read_id("nope")
	_ok(not bool(bad.get("ok", true)), "read_id validates before touching the filesystem")
	_ok(Captures.store("", "image/png").has("error"), "empty data is rejected rather than written")
	# The prune. Untested when v1.14.0 shipped, which is the whole reason it is here: a store
	# that never evicts fills a disk one playtest loop at a time, and nothing else would say so.
	var made: Array = []
	for i in range(Captures.MAX_KEEP + 5):
		var st: Dictionary = Captures.store(Marshalls.raw_to_base64(("prune-probe-%d" % i).to_utf8_buffer()), "image/png")
		if st.has("error"):
			break
		made.append(str(st["id"]))
	_ok(made.size() == Captures.MAX_KEEP + 5, "wrote %d captures to exercise the cap" % made.size())
	var kept := Captures.list_entries()
	_ok(kept.size() <= Captures.MAX_KEEP, "the store pruned itself to at most %d (held %d)" % [Captures.MAX_KEEP, kept.size()])
	var kept_ids := {}
	for e in kept:
		kept_ids[str((e as Dictionary)["id"])] = true
	# Assert the ORDERING GUARANTEE directly, not just its consequence. The consequence check
	# below passed on a Windows dev box and failed on both macOS CI lanes, because a faster
	# machine mints every capture inside one millisecond; a strictly-increasing assert is
	# timing-independent and fails on the dev box too.
	var strictly_increasing := true
	for i in range(1, made.size()):
		if not (str(made[i]) > str(made[i - 1])):
			strictly_increasing = false
	_ok(strictly_increasing, "ids mint strictly increasing, however fast the machine is")
	var newest_survived := true
	for i in range(made.size() - Captures.MAX_KEEP, made.size()):
		if not kept_ids.has(str(made[i])):
			newest_survived = false
	_ok(newest_survived, "the NEWEST captures are the ones that survived")
	_ok(not kept_ids.has(str(made[0])), "the oldest capture was evicted")
	for e in kept:
		DirAccess.remove_absolute(Captures.DIR + "/" + str((e as Dictionary)["id"]))
	_ok(Captures.list_entries().is_empty(), "probe captures cleaned up")


func _t_deliver_modes() -> void:
	print("[unit] v1.14 screenshot deliver= modes")
	var mod = load("res://addons/beckett/tools/runtime_observe_tools.gd").new()
	# No deliver argument at all: today's behaviour, untouched, no note appended.
	var out1 := {"image_base64": "QUJD", "image_mime": "image/png"}
	_ok(mod._apply_delivery({}, out1, "shot") == "shot", "no deliver argument leaves the line alone")
	_ok(out1.has("image_base64"), "...and leaves the inline image alone")
	var out2 := {"image_base64": "QUJD", "image_mime": "image/png"}
	_ok(mod._apply_delivery({"deliver": "inline"}, out2, "shot") == "shot", "deliver=inline is a no-op")
	# An unknown mode must be REPORTED. Before this check it read exactly like inline, so a
	# typo left the caller believing it had a link.
	var out3 := {"image_base64": "QUJD", "image_mime": "image/png"}
	var d3: String = mod._apply_delivery({"deliver": "lnik"}, out3, "shot")
	_ok(d3.contains("not a known mode") and d3.contains("lnik"), "an unknown deliver mode is named in the result")
	_ok(out3.has("image_base64"), "...and the picture still rides inline")
	# both: link AND image. link: link only.
	var out4 := {"image_base64": Marshalls.raw_to_base64("both-mode".to_utf8_buffer()), "image_mime": "image/png"}
	var d4: String = mod._apply_delivery({"deliver": "both"}, out4, "shot")
	_ok(out4.has("resource_links") and out4.has("image_base64"), "deliver=both keeps the image AND adds the link")
	_ok(d4.contains("capture://"), "deliver=both names the uri in the line")
	var out5 := {"image_png_base64": Marshalls.raw_to_base64("editor-mode".to_utf8_buffer())}
	var d5: String = mod._apply_delivery({"deliver": "both"}, out5, "editor viewport 100x100", "image/png")
	_ok(out5.has("resource_links"), "the EDITOR key shape (image_png_base64) is delivered too")
	_ok(d5.contains("capture://"), "...and names its uri")
	for o in [out4, out5]:
		for rl in (o as Dictionary).get("resource_links", []):
			DirAccess.remove_absolute(Captures.DIR + "/" + str((rl as Dictionary)["uri"]).substr(10))


# ---------------------------------------------------------------- idempotency cache bounds (v1.13 S3)

func _t_idempotency_bounds() -> void:
	print("[unit] mcp_server idempotency cache is bounded by bytes, not just entries")
	var s = MCPServer.new()
	var big := ""
	for i in 64:
		big += "0123456789abcdef".repeat(1024)  # 1 MB of base64-ish payload
	var one: Dictionary = {"content": [{"type": "image", "data": big}], "isError": false}
	_ok(s._result_bytes(one) > 1000000, "_result_bytes counts image payloads")
	for i in 200:
		s._idempotency_put("k%d" % i, {"content": [{"type": "image", "data": big}], "isError": false})
	_ok(s._idempotency.size() <= MCPServer.IDEMPOTENCY_MAX, "entry bound still holds")
	_ok(s._idempotency_bytes <= MCPServer.IDEMPOTENCY_MAX_BYTES, "byte ceiling holds after 200 image results")
	_ok(s._idempotency.size() == s._idempotency_sizes.size(), "size bookkeeping stays in step with the cache")
	# A result larger than the whole ceiling is skipped, not cached at any cost.
	var huge := big.repeat(9)
	s._idempotency_put("huge", {"content": [{"type": "image", "data": huge}], "isError": false})
	_ok(not s._idempotency.has("huge"), "an oversized result is not cached")
	# Small results still cache and replay.
	s._idempotency_put("small", {"content": [{"type": "text", "text": "ok"}], "isError": false})
	_ok(s._idempotency.has("small"), "a small result still caches")
	s.free()


# ---------------------------------------------------------------- instructions (v1.13 S4)

func _t_instructions_skill_count() -> void:
	print("[unit] initialize instructions derive the skill-pack count from disk")
	var s = MCPServer.new()
	var on_disk := 0
	var dir := DirAccess.open("res://addons/beckett/skills")
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".md"):
				on_disk += 1
	_ok(s._skill_pack_count() == on_disk, "_skill_pack_count matches the .md files on disk (%d)" % on_disk)
	if on_disk == 0:
		# Lite: pack.ps1 trims addons/beckett/skills entirely, and the Lite instructions
		# never quote a pack count. Same shape as the playtest groups above.
		print("[unit] instructions pack-count assert skipped (Lite build: skills trimmed)")
		s.free()
		return
	# _max_effort defaults to 6, so a bare server renders the Full instructions.
	var instr := s._instructions()
	_ok(instr.contains("%d knowledge packs" % on_disk), "instructions quote the real pack count (%d)" % on_disk)
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
	# v1.12 W3.5: device ids are 4.7+. The gate must agree with the ENGINE, never invent a
	# device 0 - the static-initialiser trap made doctor claim "stamped (keyboard=0)" on an
	# engine with no such constant, which is a tool reporting a capability it does not have.
	var ids: Dictionary = InputCodec.device_ids()
	var has_kb := ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	_ok((int(ids.get("keyboard", -1)) >= 0) == has_kb, "device-id availability matches ClassDB (no phantom device 0)")
	_ok((int(ids.get("mouse", -1)) >= 0) == ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_MOUSE"), "mouse device id likewise")
	if has_kb:
		_ok(int(ids["keyboard"]) == ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD"), "keyboard id is the engine's own value")
		_ok((InputCodec.build_event({"type": "key", "keycode": "A", "pressed": true}) as InputEventKey).device == int(ids["keyboard"]), "a synthesized key carries the keyboard device id")
	else:
		_ok((InputCodec.build_event({"type": "key", "keycode": "A", "pressed": true}) as InputEventKey).device == 0, "pre-4.7 keeps the old device 0 (behaviour unchanged)")


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


# ---------------------------------------------------------------- v1.12 honesty + render diagnosis

## set_project_setting used to persist a client's "2" as the STRING "2" (and a JSON number
## as 0.0), which Godot reads as neither the enum nor an int - the setting silently did
## nothing. Mirroring is deliberately only done against a KNOWN existing type; guessing
## would break application/config/name = "2048".
func _t_setting_type_mirror() -> void:
	print("[unit] set_project_setting type mirror (v1.12)")
	_ok(ProjectTools._setting_value("2", 0) == 2 and typeof(ProjectTools._setting_value("2", 0)) == TYPE_INT,
		"string '2' onto an int setting stores int 2")
	_ok(is_equal_approx(float(ProjectTools._setting_value("0.35", 0.0)), 0.35) and typeof(ProjectTools._setting_value("0.35", 0.0)) == TYPE_FLOAT,
		"string '0.35' onto a float setting stores a float")
	_ok(ProjectTools._setting_value("true", false) == true, "string 'true' onto a bool setting stores a bool")
	_ok(ProjectTools._setting_value("2048", "name") == "2048", "a numeric-looking string onto a STRING setting stays a String")
	_ok(typeof(ProjectTools._setting_value("2", null)) == TYPE_STRING, "no existing type -> no guess (stays a String)")
	# JSON has one number type, so an integral value arrives as a float.
	_ok(typeof(ProjectTools._setting_value(0.0, 4)) == TYPE_INT and ProjectTools._setting_value(0.0, 4) == 0,
		"JSON number 0.0 onto an int setting stores int 0 (not 0.0)")
	_ok(typeof(ProjectTools._setting_value(2.0, 0.5)) == TYPE_FLOAT, "number onto a float setting stays a float")
	_ok(ProjectTools._setting_value(1.5, 4) == 1.5, "a lossy float onto an int setting is NOT silently truncated")
	var psa: Variant = ProjectTools._setting_value("[\"res://addons/x/plugin.cfg\"]", null)
	_ok(psa is PackedStringArray and (psa as PackedStringArray).size() == 1, "stringified array still recovers as PackedStringArray")


## The bridge `set` used to answer ok for writes that never landed: Object.set() is silent
## on an unknown name and blind to ':' sub-resource paths.
func _t_property_owner() -> void:
	print("[unit] runtime property resolution + write verify (v1.12)")
	var rt = MCPRuntime.new()
	var we := WorldEnvironment.new()
	we.environment = Environment.new()

	var r: Dictionary = rt._property_owner(we, "environment:fog_density")
	_ok(bool(r.get("ok", false)) and r.get("owner") == we.environment and str(r.get("leaf")) == "fog_density",
		"a ':' path resolves to the sub-resource that OWNS the leaf")
	_ok(not bool(r.get("indexed", true)), "an object hop uses a plain set, not set_indexed")

	var bad: Dictionary = rt._property_owner(we, "environment:fog_densty")
	_ok(not bool(bad.get("ok", true)), "a typo in the leaf is an error, not a silent null")
	_ok(str(bad.get("suggestion", "")).contains("fog_density"), "the error suggests the right name")
	_ok(str(bad.get("error", "")).contains("Environment"), "the error names the class that actually owns the leaf")

	var bad_head: Dictionary = rt._property_owner(we, "envirnoment:fog_density")
	_ok(not bool(bad_head.get("ok", true)) and str(bad_head.get("error", "")).contains("envirnoment"),
		"a typo in an intermediate hop names THAT hop, not the whole path")

	var n3 := Node3D.new()
	var struct_hop: Dictionary = rt._property_owner(n3, "position:y")
	_ok(bool(struct_hop.get("ok", false)) and bool(struct_hop.get("indexed", false)) and str(struct_hop.get("leaf")) == "position:y",
		"a built-in struct hop falls back to the whole path via set_indexed")

	var nulled := WorldEnvironment.new()
	var missing: Dictionary = rt._property_owner(nulled, "environment:fog_density")
	_ok(not bool(missing.get("ok", true)) and str(missing.get("error", "")).contains("null"),
		"a null intermediate says so instead of writing nowhere")

	# Read-back verify: equality is approximate for floats, so an engine storing 0.1 as
	# 0.100000001 still counts as honouring the write.
	_ok(rt._value_eq(0.1, 0.1 + 1e-9), "float compare is approximate")
	_ok(not rt._value_eq(0.1, 0.2), "genuinely different floats differ")
	_ok(rt._value_eq(Vector3(1, 2, 3), Vector3(1, 2, 3)) and not rt._value_eq(Vector3.ZERO, Vector3.ONE), "vector compare works")
	_ok(not rt._value_eq(1, 1.0), "int and float are not conflated (type change means the write was reshaped)")

	var set_ok: Dictionary = rt._set_cmd(we, {"prop": "environment:volumetric_fog_density", "value": "0.02"})
	_ok(bool(set_ok.get("ok", false)), "a nested write reports ok")
	_ok(is_equal_approx(we.environment.volumetric_fog_density, 0.02), "THE regression: the value actually reaches the Environment")
	_ok(set_ok.has("before") and set_ok.has("after"), "the response always carries before/after")
	_ok(bool(set_ok.get("changed", false)), "a real change is reported as changed")
	var set_bad: Dictionary = rt._set_cmd(we, {"prop": "environment:nope", "value": 1})
	_ok(not bool(set_bad.get("ok", true)), "writing an unknown property is an error, never a silent ok")

	# Godot's set() accepts garbage for a typed property and stores the type's DEFAULT, so
	# `global_transform = "nonsense"` used to ZERO the transform and report success. Found
	# live while probing the fix itself; refusing beats destroying data.
	_ok(rt._coercion_error(Transform3D.IDENTITY, "nonsense") != "", "an uncoercible value for a typed property is refused")
	_ok(rt._coercion_error(0.0, 1.5) == "", "a matching type passes")
	_ok(rt._coercion_error(null, "anything") == "", "a null current value cannot pin a type, so nothing is refused")
	_ok(rt._coercion_error(Vector3.ZERO, Vector3.ONE) == "", "same-type struct passes")
	var n3b := Node3D.new()
	n3b.position = Vector3(3, 0, 0)
	var wreck: Dictionary = rt._set_cmd(n3b, {"prop": "transform", "value": "nonsense"})
	_ok(not bool(wreck.get("ok", true)), "THE data-loss regression: garbage for a Transform3D is refused")
	_ok(n3b.position == Vector3(3, 0, 0), "...and the original transform is left intact")
	n3b.free()

	n3.free()
	nulled.free()
	we.free()
	rt.free()


## Godot's front face is CLOCKWISE, so the outward normal is (v2-v0) x (v1-v0) - the
## REVERSE of the habitual cross product. Verified against BoxMesh/SphereMesh/CylinderMesh/
## PlaneMesh; if this ever flips, render_probe would confidently accuse healthy geometry.
func _t_winding() -> void:
	print("[unit] render_probe winding math (v1.12)")
	var rt = MCPRuntime.new()
	var plane := PlaneMesh.new()

	# surface_get_primitive_type lives on ArrayMesh only — calling it blind crashed the
	# surface walk on every PrimitiveMesh, which is most of what a scene is built from.
	_ok(rt._primitive_of(plane, 0) == Mesh.PRIMITIVE_TRIANGLES, "a PrimitiveMesh reports triangles without ArrayMesh's method")

	var good: Dictionary = rt._winding_report(plane, Transform3D.IDENTITY, null)
	_ok(int(good.get("triangles", 0)) == 2 and int(good.get("sampled", 0)) == 2, "both triangles sampled")
	_ok(str(good.get("vs_normals", "")) == "agree", "a stock PlaneMesh agrees with its own normals")
	_ok(int(good.get("degenerate", -1)) == 0, "no degenerate triangles in a stock mesh")

	# Reverse the index order only — normals untouched. This is the meadow bug exactly.
	var arr: Array = plane.surface_get_arrays(0)
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var flipped := PackedInt32Array()
	for t in range(idx.size() / 3):
		flipped.append(idx[t * 3 + 2])
		flipped.append(idx[t * 3 + 1])
		flipped.append(idx[t * 3])
	arr[Mesh.ARRAY_INDEX] = flipped
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var bad: Dictionary = rt._winding_report(am, Transform3D.IDENTITY, null)
	_ok(str(bad.get("vs_normals", "")) == "reversed", "a reversed index buffer is detected against unchanged normals")
	_ok(int(bad.get("triangles", 0)) == 2, "the reversed mesh still reports its real triangle count")

	# The warning text is what the agent actually reads, so pin it.
	var warns: Array = []
	rt._winding_warnings({"sampled": 2, "facing_camera": 0, "vs_normals": "reversed", "degenerate": 0},
		[{"index": 0, "cull_mode": "back"}], warns)
	_ok(str(warns).contains("reversed index buffer"), "0-facing + back-face culling names the reversed index buffer")
	var none: Array = []
	rt._winding_warnings({"sampled": 2, "facing_camera": 2, "vs_normals": "agree", "degenerate": 0},
		[{"index": 0, "cull_mode": "back"}], none)
	_ok(none.is_empty(), "healthy winding produces no warning (signal stays high)")
	var off: Array = []
	rt._winding_warnings({"sampled": 2, "facing_camera": 0, "vs_normals": "agree", "degenerate": 0},
		[{"index": 0, "cull_mode": "disabled (render_mode cull_disabled)"}], off)
	_ok(off.is_empty(), "0-facing with culling DISABLED is not a bug (both sides draw)")

	_ok(rt.DEBUG_DRAW_MODES.has("wireframe") and rt.DEBUG_DRAW_MODES.has("unshaded"), "debug draw modes expose the two workhorse views")
	_ok(rt._debug_draw_name(Viewport.DEBUG_DRAW_DISABLED) == "normal", "debug draw names round-trip for the previous-mode report")
	rt.free()


## W2: the screenshot assert's threshold has to mean something. These pin peak_snr against
## the REAL engine so a future default change cannot quietly make the assert vacuous (the
## old 64x64 downsample-and-sum could pass a completely misdrawn character).
func _t_screenshot_metric() -> void:
	print("[unit] screenshot assert metric (v1.12 W2)")
	var base := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	base.fill(Color(0.2, 0.4, 0.6))
	if not base.has_method("compute_image_metrics"):
		print("  (skip: this Godot has no Image.compute_image_metrics)")
		return
	var same := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	same.fill(Color(0.2, 0.4, 0.6))
	var want := 30.0  # playtest_tools.SNR_DEFAULT
	var snr_same := float((base.call("compute_image_metrics", same, false) as Dictionary).get("peak_snr", 0.0))
	_ok(snr_same >= want, "identical frames pass the default threshold (snr %.0f)" % snr_same)
	var one_px := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	one_px.fill(Color(0.2, 0.4, 0.6))
	one_px.set_pixel(0, 0, Color(1, 1, 1))
	var snr_px := float((base.call("compute_image_metrics", one_px, false) as Dictionary).get("peak_snr", 0.0))
	_ok(snr_px >= want, "a single changed pixel still passes (AA-tolerant, snr %.1f)" % snr_px)
	var different := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	different.fill(Color(0.9, 0.1, 0.1))
	var snr_diff := float((base.call("compute_image_metrics", different, false) as Dictionary).get("peak_snr", 0.0))
	_ok(snr_diff < want, "a genuinely different frame FAILS (snr %.1f < %.0f)" % [snr_diff, want])
	# Half the image changed is the regression shape that matters most: a real visual break.
	var half := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	half.fill(Color(0.2, 0.4, 0.6))
	for y in 32:
		for x in 64:
			half.set_pixel(x, y, Color(0.9, 0.1, 0.1))
	var snr_half := float((base.call("compute_image_metrics", half, false) as Dictionary).get("peak_snr", 0.0))
	_ok(snr_half < want, "half the frame changed FAILS (snr %.1f)" % snr_half)


# ---------------------------------------------------------------- capture bytes (v1.13 S5/S7)

## S5: the default resolution cap is folded INTO the resize factor, because that same factor
## draws the Set-of-Mark boxes and remaps the legend rects. A cap applied anywhere else
## desyncs the boxes from the returned picture, and nothing else in the suite would see it.
func _t_screenshot_cap() -> void:
	print("[unit] screenshot resolution cap (v1.13 S5)")
	_ok(is_equal_approx(MCPRuntime._capped_scale(1.0, 2560, 1440, 1280), 0.5), "2560x1440 capped at 1280 -> 0.5")
	_ok(is_equal_approx(MCPRuntime._capped_scale(1.0, 1440, 2560, 1280), 0.5), "portrait frames cap on the long edge too")
	_ok(is_equal_approx(MCPRuntime._capped_scale(1.0, 1024, 768, 1280), 1.0), "a frame already under the cap is untouched")
	_ok(is_equal_approx(MCPRuntime._capped_scale(1.0, 2560, 1440, 0), 1.0), "max_dim=0 is the explicit opt-out")
	_ok(is_equal_approx(MCPRuntime._capped_scale(0.25, 2560, 1440, 1280), 0.25), "an explicit smaller scale still wins")
	_ok(is_equal_approx(MCPRuntime._capped_scale(0.8, 2560, 1440, 1280), 0.5), "the cap wins when it is the smaller factor")
	_ok(is_equal_approx(MCPRuntime._capped_scale(9.0, 2560, 1440, 0), 1.0), "scale is still clamped to 1.0")
	_ok(is_equal_approx(MCPRuntime._capped_scale(0.0, 2560, 1440, 0), 0.05), "scale is still clamped up to 0.05")
	# Now the part only pixels can prove: crop -> capped scale -> annotate -> legend remap.
	var img := Image.create(2560, 1440, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.2, 0.3))
	var marks: Array = [{"i": 1, "path": "/root/Main/Btn", "rect": [1000, 600, 400, 200]}]
	var off := Vector2(200.0, 100.0)  # as if region=[200,100,2000,1200] had been requested
	img = img.get_region(Rect2i(200, 100, 2000, 1200))
	var scale: float = MCPRuntime._capped_scale(1.0, img.get_width(), img.get_height(), 1280)
	_ok(is_equal_approx(scale, 0.64), "post-crop 2000x1200 capped at 1280 -> 0.64")
	img.resize(maxi(1, roundi(img.get_width() * scale)), maxi(1, roundi(img.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	_ok(img.get_width() == 1280 and img.get_height() == 768, "the returned frame is %dx%d" % [img.get_width(), img.get_height()])
	UiInspect.annotate_image(img, marks, off, scale)
	var r4: Array = marks[0]["rect"]
	var lx := roundi((float(r4[0]) - off.x) * scale)
	var ly := roundi((float(r4[1]) - off.y) * scale)
	var lw := roundi(float(r4[2]) * scale)
	var lh := roundi(float(r4[3]) * scale)
	_ok(lx + lw <= img.get_width() and ly + lh <= img.get_height(), "the legend rect fits inside the capped picture")
	_ok(img.get_pixel(lx + 1, ly + 1).is_equal_approx(UiInspect.MARK_COLOR), "the legend corner lands ON the drawn box")
	_ok(img.get_pixel(lx + lw - 1, ly + lh / 2).is_equal_approx(UiInspect.MARK_COLOR), "the legend right edge lands ON the drawn box")
	_ok(not img.get_pixel(lx + 1, maxi(0, ly - 3)).is_equal_approx(UiInspect.MARK_COLOR), "3 px above the legend rect is still background")


## S7: compare_screenshots now pulls a quarter-res frame, so the baseline has to travel the
## SAME downscale before both collapse to 64x64. Godot's bilinear resize does not pre-filter,
## so one-step and two-step downscales of the same picture land on different samples - which
## would otherwise fail every existing baseline the moment the capture got smaller.
func _t_compare_downscale_chain() -> void:
	print("[unit] compare_screenshots downscale chain (v1.13 S7)")
	var w := 512
	var h := 288
	var src := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99  # fixed: this check must not be able to flake
	for y in h:
		for x in w:
			var v := float((x / 32 + y / 32) % 3) / 3.0
			if x % 17 == 0 or y % 23 == 0:
				v = 1.0  # thin bright lines: the detail a mismatched chain samples differently
			v = clampf(v + rng.randf() * 0.25, 0.0, 1.0)
			src.set_pixel(x, y, Color(v, v * 0.6, 1.0 - v))
	var cur := src.duplicate() as Image  # what the game now returns at scale=0.25
	cur.resize(maxi(1, roundi(w * 0.25)), maxi(1, roundi(h * 0.25)), Image.INTERPOLATE_BILINEAR)
	var small := cur.duplicate() as Image
	small.resize(64, 64)
	var naive := src.duplicate() as Image
	naive.resize(64, 64)
	var matched := src.duplicate() as Image
	matched.resize(cur.get_width(), cur.get_height(), Image.INTERPOLATE_BILINEAR)
	matched.resize(64, 64)
	var d_matched := _img_diff_pct(matched, small)
	var d_naive := _img_diff_pct(naive, small)
	_ok(d_matched < 0.001, "baseline down the same chain compares clean (diff %.4f%%)" % d_matched)
	_ok(d_naive > d_matched, "a mismatched chain does NOT (diff %.4f%% on an unchanged frame)" % d_naive)


## qa_tools._compare_screenshots' metric, in one place so the check above measures what
## the tool measures.
func _img_diff_pct(a: Image, b: Image) -> float:
	var ad := a.get_data()
	var bd := b.get_data()
	var d := 0
	for i in ad.size():
		d += abs(int(ad[i]) - int(bd[i]))
	return 100.0 * float(d) / float(ad.size() * 255)


# ---------------------------------------------------------------- transport (v1.13 S8)

func _t_http_content_type() -> void:
	print("[unit] http_server content-type")
	# S8: JSON is UTF-8 by definition, so a client that trusts a MISSING charset over the
	# spec guesses Latin-1 and mangles every em-dash in a tool description - which is how
	# the published glama/tools.json got corrupted. Smoke checks the header on the wire;
	# this pins the literal so the declaration cannot be dropped by accident.
	var ct: String = HttpServer._JSON_CONTENT_TYPE
	_ok(ct.begins_with("application/json"), "default Content-Type is still JSON")
	_ok(ct.to_lower().contains("charset=utf-8"), "default Content-Type declares charset=utf-8")


# ---------------------------------------------------------------- game view + Suspend (v1.13 S11/S12)

## Stands in for EditorSettings: the probe only ever reaches it through has_method + call,
## so a plain script object exercises the whole mapping with no editor to boot.
class FakeEditorSettings:
	var meta := {}

	func get_project_metadata(section: String, key: String, default_value: Variant) -> Variant:
		return meta.get(section + "/" + key, default_value)


## The Game workspace has embedded the game BY DEFAULT since 4.4, so this probe answers the
## common case, not an exotic one - and getting the mapping backwards would make doctor lie
## about whether a window-mode assert can ever pass. Two booleans, never one mode string.
func _t_game_view_probe() -> void:
	print("[unit] game_view probe + Suspend diagnosis (v1.13 S11/S12)")
	var live: Dictionary = RuntimeBridge.game_view_state()
	_ok(["embedded", "windowed", "unknown"].has(str(live.get("mode", ""))), "mode is one of embedded|windowed|unknown")
	_ok(str(live.get("mode", "")) == "unknown", "outside the editor the probe answers unknown, never a guess")
	_ok(not str(live.get("source", "")).is_empty(), "unknown still names the read that was unavailable")
	_ok(live.has("placement") and live.has("note"), "payload always carries placement + note")

	var es := FakeEditorSettings.new()
	var disabled: Dictionary = RuntimeBridge._game_view_from_setting(es, -1)
	_ok(str(disabled["mode"]) == "windowed" and str(disabled["source"]).contains("Disabled"), "-1 Disabled -> windowed")
	var embed: Dictionary = RuntimeBridge._game_view_from_setting(es, 1)
	_ok(str(embed["mode"]) == "embedded" and str(embed["placement"]) == "main", "1 Embed Game -> embedded / main")
	# The case the original design had backwards: a FLOATING Game workspace is still embedded.
	var floating: Dictionary = RuntimeBridge._game_view_from_setting(es, 2)
	_ok(str(floating["mode"]) == "embedded" and str(floating["placement"]) == "floating", "2 Make Game Workspace Floating -> embedded / floating")
	# Mode 0 is the shipped default and resolves from per-project metadata that no real
	# project stores, so it must resolve to the ENGINE default and say which it used.
	var untouched: Dictionary = RuntimeBridge._game_view_from_setting(es, 0)
	_ok(str(untouched["mode"]) == "embedded", "0 Use Per-Project Configuration on an untouched project -> embedded")
	_ok(str(untouched["source"]).contains("engine default"), "...and the source says the value was defaulted, not stored")
	es.meta["game_view/embed_on_play"] = false
	var opted_out: Dictionary = RuntimeBridge._game_view_from_setting(es, 0)
	_ok(str(opted_out["mode"]) == "windowed" and str(opted_out["source"]).contains("set in this project"), "a stored embed_on_play=false is honoured and named")
	es.meta["game_view/embed_on_play"] = true
	es.meta["game_view/make_floating_on_play"] = false
	_ok(str(RuntimeBridge._game_view_from_setting(es, 0)["placement"]) == "main", "stored make_floating_on_play=false -> main placement")
	var alien: Dictionary = RuntimeBridge._game_view_from_setting(es, 7)
	_ok(str(alien["mode"]) == "unknown", "a value outside the documented set reads as unknown (the Android editor ships its own hints)")

	# S12: the timeout an embedded game produces must name the Suspend button, and both
	# placements are embedded so both get the line.
	var bare := RuntimeBridge._timeout_message(4000, {"mode": "windowed", "placement": "own_window"})
	_ok(bare == "runtime timeout after 4000 ms", "a windowed game keeps the bare timeout")
	var jam := RuntimeBridge._timeout_message(4000, {"mode": "embedded", "placement": "floating"})
	_ok(jam.begins_with("runtime timeout after 4000 ms"), "the embedded message still leads with the timeout")
	_ok(jam.contains("Suspend") and jam.contains("floating"), "an embedded timeout names the Suspend button + the placement")
	_ok(jam.contains("time_control op=freeze"), "...and distinguishes it from freeze, which leaves the channel alive")


# ---------------------------------------------------------------- doctor context block (v1.13 S10)

## Only what _doctor actually reaches for. A synthetic surface keeps the tier maths
## deterministic (a real registry would drift with every tool edit).
class DoctorStubServer:
	const PROTOCOL_VERSION := "2025-11-25"
	var registry
	var http = null
	var bridge = null
	var error_echo = null
	var effort := 6
	var ceiling := 6

	func get_effort() -> int: return effort
	func max_effort() -> int: return ceiling
	func is_lite() -> bool: return ceiling < 6
	func is_running() -> bool: return false
	func auth_enabled() -> bool: return true
	func auth_token() -> String: return ""
	func is_readonly() -> bool: return false
	func disabled_tools() -> PackedStringArray: return PackedStringArray()
	func effective_specs(level: int) -> Array: return registry.list_specs(level)


## doctor prices the surface in the SAME bytes the wire carries, so a user can check it
## against a live tools/list. String.length() would count code points and quietly under-report
## the non-ASCII prose, which is exactly the mistake this check exists to prevent.
func _t_doctor_context() -> void:
	print("[unit] doctor context block (v1.13 S10)")
	var reg = Registry.new()
	for pair in [["doctor", 1], ["write_file", 2], ["play_scene", 3], ["screenshot", 4], ["playtest", 5], ["export_project", 6]]:
		reg.register({
			"name": str(pair[0]),
			"description": "tier %d probe — em-dash included so the byte count has non-ASCII to trip on" % int(pair[1]),
			"readonly": true,
			"handler": Callable(self, "_ok"),
		})
	var srv := DoctorStubServer.new()
	srv.registry = reg
	var pt = ProjectTools.new()
	pt.server = srv

	var j: Dictionary = (pt._doctor({}) as Dictionary)["json"]
	_ok(j.has("context"), "doctor carries a context block")
	var ctx: Dictionary = j["context"]
	var per_tier: Array = ctx["per_tier"]
	_ok(per_tier.size() == Effort.MAX_LEVEL, "per_tier covers every tier this build can reach (%d)" % per_tier.size())
	_ok(int(per_tier[0]["level"]) == 1 and str(per_tier[0]["name"]) == "Inspect", "tiers are numbered and named from the effort map")
	_ok(int(per_tier[5]["tools"]) == 6 and int(per_tier[0]["tools"]) == 1, "tool counts are cumulative per tier")
	# THE convention: raw UTF-8 bytes of the compact array, which is what tools/list ships.
	var l6_bytes: int = JSON.stringify(srv.effective_specs(6)).to_utf8_buffer().size()
	_ok(int(per_tier[5]["bytes"]) == l6_bytes, "per_tier bytes equal JSON.stringify(specs) in UTF-8 bytes")
	_ok(l6_bytes > JSON.stringify(srv.effective_specs(6)).length(), "bytes exceed code points on a non-ASCII surface (String.length would under-report)")
	_ok(int(per_tier[5]["approx_tokens"]) == int(l6_bytes / 4.0), "approx_tokens is bytes/4, the stated ratio")
	_ok(int(ctx["bytes"]) == int(per_tier[5]["bytes"]), "context.bytes is the tier the dial actually sits on")
	_ok(int(ctx["advertised_tools"]) == 6 and str(ctx["ratio_note"]).contains("approximate"), "context names the advertised count and labels the ratio as approximate")
	# The block must never make a healthy install report not-ok: `ok` is warnings.is_empty().
	var before: int = (j["warnings"] as Array).size()
	srv.effort = 4
	srv.ceiling = 4
	var lite: Dictionary = (pt._doctor({}) as Dictionary)["json"]
	_ok((lite["context"]["per_tier"] as Array).size() == 4, "a Lite ceiling reports 4 tiers, not 6")
	_ok(int(lite["context"]["bytes"]) == int((lite["context"]["per_tier"] as Array)[3]["bytes"]), "context.bytes tracks the dial on a capped build")
	_ok(bool(lite["ok"]) == (lite["warnings"] as Array).is_empty(), "ok stays exactly warnings.is_empty()")
	_ok((lite["warnings"] as Array).size() == before, "neither the context block nor game_view appends a warning")
	_ok(j.has("game_view") and ["embedded", "windowed", "unknown"].has(str(j["game_view"]["mode"])), "doctor mounts game_view beside game_bridge")


# ---------------------------------------------------------------- dock tier stats (v1.13 S13)

## S13: the dock's effort read-out. Two things are easy to get subtly wrong here: the byte
## convention has to be the one doctor reports (UTF-8 bytes, not code points), and the saving
## has to be named against THIS build's ceiling — Lite tops out at L4 "See", so a hardcoded
## "Max" would name a tier that build cannot reach.
func _t_dock_tier_stats() -> void:
	print("[unit] dock tier stats (v1.13 S13)")
	var dock_script := load("res://addons/beckett/panel/panel.gd")  # load, not preload: dock UI, not a core module
	var p = dock_script.new()
	var specs := [{"name": "a", "description": "an em dash — costs 3 bytes, not 1"}]
	var raw := JSON.stringify(specs)
	_ok(raw.to_utf8_buffer().size() > raw.length(), "the sample really carries multi-byte characters")
	_ok(p._spec_tokens(specs) == int(raw.to_utf8_buffer().size() / 4.0), "_spec_tokens counts UTF-8 bytes (doctor's convention)")

	p._tier_stats = Label.new()
	p.server = _DockStub.new()
	# Lite shape: the ceiling is L4 "See".
	p.server.ceiling = 4
	p._eff_cur = 2
	p._update_tier_stats()
	var txt := str(p._tier_stats.text)
	_ok(txt.begins_with("2 tools · ~"), "line 1 stays the live tool/token cost")
	_ok(txt.contains("vs See") and not txt.contains("vs Max"), "the saving names the edition ceiling, never the literal Max")
	_ok(txt.contains("\n-"), "the saving rides a second line (a wider label would widen the dock)")
	# At the ceiling there is nothing to save — a fresh Lite install sits here.
	p._eff_cur = 4
	p._update_tier_stats()
	_ok(not str(p._tier_stats.text).contains(" vs "), "no saving clause at the ceiling")
	# Full shape: same code path, ceiling L6 "Max".
	p.server.ceiling = 6
	p._eff_cur = 4
	p._update_tier_stats()
	_ok(str(p._tier_stats.text).contains("vs Max"), "Full names Max, the ceiling it really has")
	p._tier_stats.free()
	p.free()


## Stand-in for MCPServer: just enough surface for _update_tier_stats (a non-null registry,
## an edition ceiling, and per-tier specs that grow with the level).
class _DockStub extends RefCounted:
	var registry := RefCounted.new()
	var ceiling := 6

	func max_effort() -> int:
		return ceiling

	func effective_specs(level: int) -> Array:
		var out: Array = []
		for i in range(level):
			out.append({"name": "t%d" % i, "description": "a description long enough to cost real tokens — %d" % i})
		return out


# ---------------------------------------------------------------- ci engine matrix (v1.13 S14/S15)

func _t_ci_matrix() -> void:
	print("[unit] ci.yml engine matrix")
	# ci.yml is the one non-addon file pack.ps1 stages byte-identical into the Lite repo,
	# so this group runs in both CIs. README/INSTALL are NOT staged (the Lite repo keeps
	# its own), which is why the pin-vs-prose cross-check lives in smoke.ps1 instead.
	var f := FileAccess.open("res://.github/workflows/ci.yml", FileAccess.READ)
	if f == null:
		print("  skip .github/workflows/ci.yml absent (addon-only checkout)")
		return
	var yml := f.get_as_text()
	f.close()

	# \r tolerated: a contributor cloning with core.autocrlf=true must not read as a broken matrix.
	var row_re := RegEx.create_from_string("(?m)^[ \\t]*- os: (\\S+)[ \\t\\r]*\\n[ \\t]*godot: '([^']+)'")
	var rows := row_re.search_all(yml)
	_ok(rows.size() == 8, "matrix declares 8 lanes (got %d)" % rows.size())
	# An unquoted "godot: 4.7" is a YAML float and interpolates as "4.7", silently
	# fetching the wrong tag. The quotes are load-bearing, so assert none went missing.
	_ok(RegEx.create_from_string("(?m)^[ \\t]*godot: [^'\"\\s]").search(yml) == null,
			"every godot pin is quoted")

	var pins := {}
	for m in rows:
		pins[m.get_string(2)] = true
	_ok(pins.has("4.4.1"), "the 4.4.1 parse-time floor is still a lane")
	_ok(pins.size() >= 3, "at least 3 distinct engine pins (got %d)" % pins.size())

	# Exactly one warn-only lane. continue-on-error on a stable row would let a real
	# break ship under a green badge, which is the whole hazard this lane introduces.
	var exp := RegEx.create_from_string("experimental: true").search_all(yml)
	_ok(exp.size() == 1, "exactly one experimental lane (got %d)" % exp.size())
	_ok(yml.contains("continue-on-error: ${{ matrix.experimental == true }}"),
			"warn-only is gated on matrix.experimental, not hardcoded true")
	_ok(yml.contains("(experimental)"), "the job name flags the experimental lane")

	# S14: pre-release tags live in godotengine/godot-builds, stable ones in
	# godotengine/godot. Without the branch the snapshot lane 404s.
	_ok(yml.contains("godotengine/godot-builds"), "fetch step knows the pre-release channel")
	_ok(yml.contains("-(dev|beta|rc)"), "fetch step detects a pre-release version")
	_ok(not yml.contains("$ver-stable_linux"),
			"asset names interpolate the derived tag, not a hardcoded -stable")

	# The two count-site anchors release.ps1 pins on (Get-CountSites). Adding matrix
	# rows must never disturb them, or -FixCounts reports a missing site.
	_ok(RegEx.create_from_string("the full \\d+-tool Lite").search(yml) != null,
			"count-site anchor 'the full N-tool Lite' intact")
	_ok(RegEx.create_from_string("-ExpectedTools \\d+").search(yml) != null,
			"count-site anchor '-ExpectedTools N' intact")


# ---------------------------------------------------------------- resolver suggestions (v1.13 S17)

func _t_resolver_suggestions() -> void:
	print("[unit] resolver did-you-mean (S17)")
	var R = load("res://addons/beckett/core/reflection.gd")
	_ok(R._lev("kitten", "sitting") == 3, "_lev: kitten/sitting costs 3")
	_ok(R._lev("", "abc") == 3 and R._lev("abc", "") == 3, "_lev: an empty side costs the other's length")
	_ok(R._lev("player", "player") == 0, "_lev: identical costs nothing")
	var scene := ["Player", "PlayerSprite", "Enemy", "HUD"]
	_ok(R.nearest("Playr", scene, 3) == ["Player"], "nearest: one typo hits, the unrelated names do not")
	_ok(R.nearest("player", scene, 3) == ["Player"], "nearest: a case-only slip scores 0")
	_ok(R.nearest("Zzzzzz", scene, 3).is_empty(), "nearest: nothing close suggests nothing")
	_ok(R.nearest("", scene, 3).is_empty() and R.nearest("Playr", [], 3).is_empty(), "nearest: empty query / candidates are safe")
	_ok(R.nearest("x".repeat(200), scene, 3).is_empty(), "nearest: an over-long query is refused before the DP")
	_ok(R.nearest("Sprite2", ["Sprite3D", "Sprite2D", "Sprite2DX"], 3)[0] == "Sprite2D", "nearest: the closest candidate ranks first")
	_ok(R.nearest("Playr", scene, 1).size() == 1, "nearest: limit is honoured")
	var classes: Array = []
	for c in ClassDB.get_class_list():
		classes.append(String(c))
	_ok(R.nearest("Sprit2D", classes, 5).has("Sprite2D"), "nearest: Sprit2D -> Sprite2D across the whole ClassDB")
	var rt = load("res://addons/beckett/tools/reflection_tools.gd").new()
	_ok(str(rt._did_you_mean("Sprit2D")).contains("Sprite2D"), "describe_class: a typo now names the class (was the generic fallback)")
	_ok(str(rt._did_you_mean("Sprite")).contains("Sprite2D"), "describe_class: substring still wins for a prefix query")
	_ok(str(rt._did_you_mean("Zzzqqqwww")).contains("find_classes"), "describe_class: a hopeless query still gets the generic advice")
	# describe_object answers for the RUNNING game too, so its miss must suggest live nodes.
	# Two stub instances, never one pointing at itself: a self-cycle leaks at exit.
	var gd := GDScript.new()
	gd.source_code = "\n".join([
		"extends RefCounted",
		"var bridge",
		"func is_game_connected() -> bool:",
		"\treturn true",
		"func send_command(_c: Dictionary) -> Dictionary:",
		"\treturn {'ok': true, 'nodes': [{'path': 'World/Player'}, {'path': 'HUD/Score'}]}",
		"",
	])
	gd.reload()
	var srv = gd.new()
	srv.bridge = gd.new()
	rt.server = srv
	var live: String = rt._did_you_mean_target("Playr", true)
	_ok(live.contains("World/Player") and live.contains("RUNNING"), "describe_object miss: candidates come from the running game when the bridge is up")
	_ok(str(rt._did_you_mean_target("/root/Main/Playr", true)).contains("World/Player"), "describe_object miss: an absolute live path matches on its last segment")
	_ok(str(rt._did_you_mean_target("res://nope.tscn", true)).is_empty(), "a res:// miss is a load failure, not a typo: no suggestion")
	_ok(str(rt._did_you_mean_target("Zzzqqq", true)).is_empty(), "no live node is close: no suggestion")
