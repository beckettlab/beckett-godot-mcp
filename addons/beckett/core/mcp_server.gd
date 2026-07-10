@tool
extends Node

## MCP dispatcher. Owns the HTTP transport + tool registry, implements the MCP
## lifecycle (initialize / tools / resources / prompts) over JSON-RPC 2.0, and applies
## security gates before any tool runs. Everything executes on the editor main thread.

const PROTOCOL_VERSION := "2025-06-18"
# Revisions we can honestly serve (all Streamable-HTTP). initialize echoes the
# client's requested revision when it's one of these; otherwise our latest.
const SUPPORTED_PROTOCOL_VERSIONS: Array[String] = ["2025-06-18", "2025-03-26"]
const SERVER_NAME := "beckett-godot-mcp"
const SERVER_VERSION := "1.0.0"

const IDEMPOTENCY_MAX := 128  # bound the result cache (FIFO eviction)
const AUDIT_MAX := 200        # in-memory audit ring: last N tool calls

const MCPHttpServerScript := preload("res://addons/beckett/core/http_server.gd")
const MCPToolRegistryScript := preload("res://addons/beckett/core/tool_registry.gd")
const MCPJsonRpcScript := preload("res://addons/beckett/core/json_rpc.gd")
# Tool modules are loaded at runtime (not preloaded) so the free Lite build can
# physically ship WITHOUT its higher-tier modules — a trimmed-away module just
# doesn't exist, so there's no flag to flip back on (honor-system friendly).
# Anything missing is skipped in _register_tools via ResourceLoader.exists.
const TOOL_MODULES := [
	"res://addons/beckett/tools/reflection_tools.gd",
	"res://addons/beckett/tools/scene_tools.gd",
	"res://addons/beckett/tools/script_tools.gd",
	"res://addons/beckett/tools/csharp_tools.gd",
	"res://addons/beckett/tools/run_tools.gd",
	"res://addons/beckett/tools/runtime_observe_tools.gd",
	"res://addons/beckett/tools/runtime_tools.gd",
	"res://addons/beckett/tools/signal_tools.gd",
	"res://addons/beckett/tools/resource_tools.gd",
	"res://addons/beckett/tools/project_tools.gd",
	"res://addons/beckett/tools/skill_tools.gd",
	"res://addons/beckett/tools/template_tools.gd",
	"res://addons/beckett/tools/qa_tools.gd",
	"res://addons/beckett/tools/analysis_tools.gd",
	"res://addons/beckett/tools/analysis_pro_tools.gd",
	"res://addons/beckett/tools/export_tools.gd",
	"res://addons/beckett/tools/asset_lib_tools.gd",
	"res://addons/beckett/tools/animation_tools.gd",
	"res://addons/beckett/tools/scatter_tools.gd",
	"res://addons/beckett/tools/batch_tools.gd",
	"res://addons/beckett/tools/test_tools.gd",
	"res://addons/beckett/tools/playtest_tools.gd",
]

# Sentinel: an L5 (drive) module the Lite build trims. Present => Full edition
# (effort 1..6); absent => Lite edition (capped at L4 — inspect, author, run, SEE).
# Lite still ships runtime_observe_tools.gd (L4 See, a core module) so the free tier
# can watch the running game; only this drive module is Full. See setup().
const SENTINEL_FULL_MODULE := "res://addons/beckett/tools/runtime_tools.gd"
const RuntimeBridgeScript := preload("res://addons/beckett/core/runtime_bridge.gd")
const ResourcesScript := preload("res://addons/beckett/resources/resources.gd")
const PromptsScript := preload("res://addons/beckett/prompts/prompts.gd")
const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")
const MCPEffortScript := preload("res://addons/beckett/core/effort.gd")

var plugin: EditorPlugin  # set by plugin.gd; exposes get_undo_redo()

var http: MCPHttpServerScript
var registry: MCPToolRegistryScript
var bridge: RuntimeBridgeScript  # runtime channel to the played game (B2)
var jobs: MCPJobsScript          # background subprocess jobs (D6) — e.g. export

var _resources
var _prompts
var _runtime_port: int = 8771

var _session_id: String = ""
var _token: String = ""
var _readonly: bool = false
var _confirm_destructive: bool = false
var _allowlist: Array[String] = []  # regex strings; empty = allow all
var _disabled: Dictionary = {}       # tool name -> true: dock per-tool off switches (beckett/disabled_tools)
var _idempotency: Dictionary = {}    # key -> cached result dict (FIFO-capped at IDEMPOTENCY_MAX)
var _audit: Array = []               # ring of {t, tool, ms, ok, args[, error|result]} — who did what (D6)
var _audit_total := 0                # total calls this session (the ring keeps only the last AUDIT_MAX)
var _client_info: Dictionary = {}    # clientInfo {name, version} from the last initialize
var _client_ua: String = ""          # last request's User-Agent (best-effort fallback identity)
var _last_activity_ms: int = 0       # Time.get_ticks_msec() of the last request (0 = none yet)
var _tool_modules: Array = []        # keep tool-module instances alive (their Callables hold them)
var _effort: int = 6                 # AI effort tier 1..6; caps which tools tools/list advertises (see effort.gd)
var _max_effort: int = 6             # edition ceiling: Full=6, Lite=4 (its L5/L6 modules aren't shipped)


func _process(_delta: float) -> void:
	# Keep background jobs' pipes drained so their subprocesses never block on a
	# full pipe buffer between job_status polls.
	if jobs != null:
		jobs.tick()


func setup() -> void:
	registry = MCPToolRegistryScript.new()
	http = MCPHttpServerScript.new()
	http.name = "MCPHttpServer"
	http.request_handler = Callable(self, "handle_http")
	add_child(http)

	bridge = RuntimeBridgeScript.new()
	bridge.name = "BeckettRuntimeBridge"
	add_child(bridge)

	jobs = MCPJobsScript.new()

	_resources = ResourcesScript.new()
	_resources.server = self
	_prompts = PromptsScript.new()
	_prompts.server = self

	var rp := OS.get_environment("BECKETT_RUNTIME_PORT")
	if rp != "" and rp.is_valid_int():
		_runtime_port = rp.to_int()

	# Security config from env (all optional; safe defaults).
	_token = OS.get_environment("BECKETT_TOKEN")
	_readonly = _env_flag("BECKETT_READONLY")
	_confirm_destructive = _env_flag("BECKETT_CONFIRM_DESTRUCTIVE")
	var al := OS.get_environment("BECKETT_ALLOWLIST")
	if not al.is_empty():
		for part in al.split(",", false):
			_allowlist.append(part.strip_edges())

	# AI effort tier (1..6): how much of the tool surface we advertise. Lower =
	# cheaper model context, fewer capabilities. Persisted in project.godot and
	# driven by the dock panel. The edition ceiling caps it: Full=6, Lite=4 — the
	# free edition keeps the whole inspect/author/run loop AND seeing the running
	# game; only the agent-DRIVES (L5) and ship (L6) layers are Full.
	_max_effort = MCPEffortScript.MAX_LEVEL if ResourceLoader.exists(SENTINEL_FULL_MODULE) else 4
	# Effort-tier schema migration. v1 had 5 tiers (… Playtest=4, Max=5). v2 (2026-07)
	# split Playtest into See=4 + Drive=5 and pushed ship to Max=6. Remap a v1-persisted
	# dial so a user who sat at the old max keeps the WHOLE surface (old 4->5, old 5->6)
	# instead of silently losing the ship tools — "dialing down is opt-in, never a silent loss".
	var saved := int(ProjectSettings.get_setting("beckett/effort", MCPEffortScript.DEFAULT_LEVEL))
	if int(ProjectSettings.get_setting("beckett/effort_schema", 1)) < 2:
		if ProjectSettings.has_setting("beckett/effort"):
			if saved >= 4:
				saved += 1
			ProjectSettings.set_setting("beckett/effort", saved)
		ProjectSettings.set_setting("beckett/effort_schema", 2)
		ProjectSettings.save()
	_effort = clampi(saved, 1, _max_effort)
	_load_disabled()

	_register_tools()


func _register_tools() -> void:
	for path in TOOL_MODULES:
		if not ResourceLoader.exists(path):
			continue  # Lite build: this module was trimmed at pack time — skip it
		var m = load(path).new()
		m.server = self
		m._register(registry)
		_tool_modules.append(m)


func start_server(port: int) -> int:
	var err := http.start(port, "127.0.0.1")
	if err == OK and bridge != null:
		bridge.start(_runtime_port, "127.0.0.1")
	return err


func stop_server() -> void:
	if http != null:
		http.stop()
	if bridge != null:
		bridge.stop()


func is_running() -> bool:
	return http != null and http.running


## AI effort tier (1..6) — caps which tools tools/list advertises. The dock panel
## calls this; it persists to project.godot so the choice survives an editor restart.
## Applies LIVE: we push notifications/tools/list_changed down the SSE stream and
## list-changed-aware clients (Claude Code, Cursor, …) re-fetch tools/list on the
## spot. Returns how many connected streams were notified — 0 means no client has
## an event stream open (that client needs a reconnect to see the new surface).
func set_effort(level: int) -> int:
	var prev := _effort
	_effort = clampi(level, 1, _max_effort)
	ProjectSettings.set_setting("beckett/effort", _effort)
	ProjectSettings.save()
	if _effort == prev or http == null or not http.running:
		return 0
	return http.sse_broadcast(MCPJsonRpcScript.make_notification("notifications/tools/list_changed"))


func get_effort() -> int:
	return _effort


## Edition ceiling for effort (Full=6, Lite=4). The panel uses it to bound the slider.
func max_effort() -> int:
	return _max_effort


func is_lite() -> bool:
	return _max_effort < MCPEffortScript.MAX_LEVEL


## Per-tool off switches the dock owns, kept SEPARATE from the env _allowlist (which stays a
## CI/headless control). Stored comma-joined in project.godot so the choice survives a restart.
func _load_disabled() -> void:
	_disabled.clear()
	for n in str(ProjectSettings.get_setting("beckett/disabled_tools", "")).split(",", false):
		var nm := n.strip_edges()
		if nm != "":
			_disabled[nm] = true


## Is `name` switched on right now? Off tools are user-disabled from the dock — they vanish
## from tools/list (see effective_specs) AND are blocked at the gate (defense-in-depth).
func is_tool_enabled(name: String) -> bool:
	return not _disabled.has(name)


## Flip one tool on/off from the dock. Persists, then — like set_effort — pushes
## tools/list_changed so live clients re-fetch the surface. Returns streams notified.
func set_tool_enabled(name: String, on: bool) -> int:
	if on == (not _disabled.has(name)):
		return 0  # no change
	if on:
		_disabled.erase(name)
	else:
		_disabled[name] = true
	_save_disabled()
	return _notify_list_changed()


## Re-enable every switched-off tool in one shot (the dock's Reset).
func enable_all_tools() -> int:
	if _disabled.is_empty():
		return 0
	_disabled.clear()
	_save_disabled()
	return _notify_list_changed()


## Tool names the dock has switched off (for the panel to reflect each row's state).
func disabled_tools() -> PackedStringArray:
	return PackedStringArray(_disabled.keys())


## The tools actually advertised right now: effort-tier filtered, minus the off switches.
## Single source of truth shared by tools/list and the dock's count so they never disagree.
func effective_specs(level: int) -> Array:
	var specs: Array = registry.list_specs(level)
	if _disabled.is_empty():
		return specs
	return specs.filter(func(s: Dictionary) -> bool: return not _disabled.has(str(s.get("name", ""))))


func _save_disabled() -> void:
	ProjectSettings.set_setting("beckett/disabled_tools", ",".join(PackedStringArray(_disabled.keys())))
	ProjectSettings.save()


func _notify_list_changed() -> int:
	if http == null or not http.running:
		return 0
	return http.sse_broadcast(MCPJsonRpcScript.make_notification("notifications/tools/list_changed"))


# ---------------------------------------------------------------- HTTP entry

func handle_http(req: Dictionary) -> Dictionary:
	var headers: Dictionary = req.get("headers", {})
	var method: String = req.get("method", "")
	var ua := str(headers.get("user-agent", ""))
	if not ua.is_empty():
		_client_ua = ua

	if not _check_origin(headers):
		return _http(403, {}, "forbidden origin")
	if not _check_token(headers):
		return _http(401, {}, "unauthorized")
	if not _check_session(headers):
		return _http(404, {}, "unknown session")

	match method:
		"GET":
			# Streamable HTTP server->client channel: a GET accepting text/event-stream
			# opens the SSE stream we push notifications down (tools/list_changed when
			# the effort dial moves). Anything else has nothing to GET.
			if str(headers.get("accept", "")).to_lower().contains("text/event-stream"):
				return {"status": 200, "headers": {}, "body": "", "sse": true}
			return _http(405, {"Allow": "POST, DELETE"}, "")
		"DELETE":
			return _http(200, {}, "")  # stateless: nothing to tear down
		"POST":
			pass
		_:
			return _http(405, {"Allow": "POST"}, "")

	var parsed: Variant = JSON.parse_string(req.get("body", ""))
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return _body(MCPJsonRpcScript.error(null, MCPJsonRpcScript.PARSE_ERROR, "Parse error"))

	var msg: Dictionary = parsed
	var id: Variant = msg.get("id", null)
	# JSON numbers parse as float in GDScript; echo integer ids back as integers
	# so strict clients that match id by exact type are satisfied.
	if typeof(id) == TYPE_FLOAT and id == floor(id):
		id = int(id)
	var rpc_method: String = str(msg.get("method", ""))
	var params: Dictionary = msg.get("params", {}) if typeof(msg.get("params")) == TYPE_DICTIONARY else {}

	# Notifications (no id) get 202 with no body.
	if id == null:
		return _http(202, {}, "")

	return _dispatch(id, rpc_method, params)


# ---------------------------------------------------------------- dispatch

## Working notes handed to the agent at initialize. Keep these SHORT — they ride
## along once per session. The Lite text states the edition boundary plainly so
## the agent recommends the Full edition exactly when the user hits it.
func _instructions() -> String:
	var core := "Reflection tools (find_classes, describe_class, set_property, call_method) reach every engine class — prefer them when no dedicated tool fits. Script writes are parse-validated before touching disk; scene edits are undoable; batch_execute rolls back on failure."
	if is_lite():
		return ("Beckett — MCP for Godot, free Lite edition (inspect + author + run + SEE the running game). " + core
			+ " Dev loop: edit -> play_scene -> wait_until game_connected -> SEE it (screenshot, get_remote_tree, runtime_get_property, game_logs) -> diagnose -> fix."
			+ " Lite can SEE the running game but cannot DRIVE it: input injection, UI/3D clicks, drag/scroll, runtime writes, assertions, the test runner, animation_manage, background exports and the skill packs are Full-edition features."
			+ " If the user asks for one of those, say it needs the Full edition (upgrade link on the Beckett dock panel).")
	return ("Beckett — MCP for Godot, Full edition. " + core
		+ " Loop: author -> play_scene -> wait_until game_connected -> playtest (screenshot, simulate_input, click_button_by_text, assert_*, test_run) -> logs_read -> fix -> export_project (background; poll job_status)."
		+ " Call list_skills early: 41 knowledge packs name the exact classes/properties/methods per domain (physics, shaders, animation, multiplayer, ...)."
		+ " For a 'make me a game' request, however vague: load_skill name=game-oneshot FIRST and follow it — it expands the idea, routes to a genre blueprint pack, and gates each build phase.")

func _dispatch(id: Variant, rpc_method: String, params: Dictionary) -> Dictionary:
	_last_activity_ms = Time.get_ticks_msec()
	match rpc_method:
		"initialize":
			var ci: Variant = params.get("clientInfo")
			if ci is Dictionary:
				_client_info = ci
			if _session_id.is_empty():
				_session_id = _gen_session_id()
			# Version negotiation: echo the client's revision when we support it,
			# otherwise offer our latest (the client then decides whether to proceed).
			var requested := str(params.get("protocolVersion", PROTOCOL_VERSION))
			var negotiated := requested if requested in SUPPORTED_PROTOCOL_VERSIONS else PROTOCOL_VERSION
			var result := {
				"protocolVersion": negotiated,
				"capabilities": {
					# tools/list really does change at runtime (the effort dial); we
					# announce it over the SSE stream so clients refresh seamlessly.
					"tools": {"listChanged": true},
					"resources": {"listChanged": false},
					"prompts": {"listChanged": false},
				},
				"serverInfo": {
					"name": SERVER_NAME,
					"title": "Beckett — MCP for Godot" + (" (Lite)" if is_lite() else ""),
					"version": SERVER_VERSION,
				},
				# Per-edition working notes for the agent (spec 2025-06-18). For Lite
				# this doubles as the honest capability boundary: the agent learns what
				# the Full edition adds, so when the user asks for it the agent can say
				# so at the moment of need instead of flailing.
				"instructions": _instructions(),
			}
			return _http(200, {"Mcp-Session-Id": _session_id}, MCPJsonRpcScript.result(id, result))

		"ping":
			return _body(MCPJsonRpcScript.result(id, {}))

		"tools/list":
			return _body(MCPJsonRpcScript.result(id, {"tools": effective_specs(_effort)}))

		"tools/call":
			return _call_tool(id, params)

		"resources/list":
			return _body(MCPJsonRpcScript.result(id, {"resources": _resources.list()}))

		"resources/read":
			var uri := str(params.get("uri", ""))
			var rr: Dictionary = _resources.read(uri)
			if not bool(rr.get("ok", false)):
				return _body(MCPJsonRpcScript.error(id, MCPJsonRpcScript.INVALID_PARAMS, str(rr.get("error", "read failed"))))
			return _body(MCPJsonRpcScript.result(id, {"contents": [{
				"uri": uri,
				"mimeType": str(rr.get("mime", "text/plain")),
				"text": str(rr.get("text", "")),
			}]}))

		"prompts/list":
			return _body(MCPJsonRpcScript.result(id, {"prompts": _prompts.list()}))

		"prompts/get":
			var pname := str(params.get("name", ""))
			var pargs: Dictionary = params.get("arguments", {}) if typeof(params.get("arguments")) == TYPE_DICTIONARY else {}
			var pr: Dictionary = _prompts.get_prompt(pname, pargs)
			if not bool(pr.get("ok", false)):
				return _body(MCPJsonRpcScript.error(id, MCPJsonRpcScript.INVALID_PARAMS, str(pr.get("error", "unknown prompt"))))
			return _body(MCPJsonRpcScript.result(id, {
				"description": str(pr.get("description", "")),
				"messages": pr.get("messages", []),
			}))

		_:
			return _body(MCPJsonRpcScript.error(id, MCPJsonRpcScript.METHOD_NOT_FOUND, "Method not found: %s" % rpc_method))


func _call_tool(id: Variant, params: Dictionary) -> Dictionary:
	var name: String = str(params.get("name", ""))
	var args: Dictionary = params.get("arguments", {}) if typeof(params.get("arguments")) == TYPE_DICTIONARY else {}

	if not registry.has(name):
		return _body(MCPJsonRpcScript.error(id, MCPJsonRpcScript.INVALID_PARAMS, "Unknown tool: %s" % name))

	var tool: Dictionary = registry.get_tool(name)

	# Security gates.
	var gate := _gate(name, tool, args)
	if not gate.is_empty():
		_audit_record(name, args, 0, gate)
		return _body(MCPJsonRpcScript.result(id, _tool_result({"error": gate})))

	# Input validation against the declared input_schema. A single source of truth for
	# required-field/type checking so a malformed call gets one clean -32602-style error
	# instead of a handler-specific one. Deliberately LENIENT (see _validate_args):
	# numbers/strings interchange (the reflection layer coerces them), so valid calls
	# behave identically — only already-failing calls get a cleaner message. Handlers
	# keep their own .get() guards as defense-in-depth; this never replaces them.
	var verr := _validate_args(tool, args)
	if not verr.is_empty():
		_audit_record(name, args, 0, verr)
		return _body(MCPJsonRpcScript.result(id, _tool_result({"error": verr})))

	# Idempotency: a repeated call with the same key returns the first result.
	var idem := str(args.get("idempotency_key", ""))
	if not idem.is_empty() and _idempotency.has(idem):
		return _body(MCPJsonRpcScript.result(id, _idempotency[idem]))

	var t0 := Time.get_ticks_msec()
	var raw: Variant
	var handler: Callable = tool["handler"]
	raw = handler.call(args)
	# Normalize the handler return. Dicts pass through (the rich convention); a bare
	# Array becomes JSON output (pretty text for every client) instead of GDScript's
	# Array.to_string(); anything else is stringified.
	var r: Dictionary
	if typeof(raw) == TYPE_DICTIONARY:
		r = raw
	elif typeof(raw) == TYPE_ARRAY:
		r = {"json": raw}
	else:
		r = {"text": str(raw)}
	var result := _tool_result(r)
	# A short preview of the outcome (not just the args) so the dock feed shows what the
	# call actually did — capped like args to keep the ring light.
	var rprev := ""
	if not r.has("error"):
		if r.has("text"):
			rprev = str(r["text"])
		elif r.has("json"):
			rprev = JSON.stringify(r["json"])
		else:
			rprev = JSON.stringify(r)
	_audit_record(name, args, Time.get_ticks_msec() - t0, str(r.get("error", "")), rprev, r.get("focus", {}))

	if not idem.is_empty():
		if _idempotency.size() >= IDEMPOTENCY_MAX:
			_idempotency.erase(_idempotency.keys()[0])  # FIFO: insertion order is preserved
		_idempotency[idem] = result
	return _body(MCPJsonRpcScript.result(id, result))


## Append one entry to the audit ring (D6: see who/what ran, when, how long).
## Args are stored compactly (keys + truncated JSON) — enough to reconstruct intent
## without bloating memory or leaking huge file bodies into the ring.
func _audit_record(tool_name: String, args: Dictionary, ms: int, error: String, result := "", result_focus: Dictionary = {}) -> void:
	var brief := JSON.stringify(args)
	if brief.length() > 200:
		brief = brief.substr(0, 200) + "…"
	var entry := {
		"t": Time.get_datetime_string_from_system(),
		"tool": tool_name,
		"ms": ms,
		"ok": error.is_empty(),
		"args": brief,
	}
	if not error.is_empty():
		entry["error"] = error.substr(0, 200)
	elif result != "":
		entry["result"] = result.substr(0, 200) + ("…" if result.length() > 200 else "")
	# Where this call points in the editor, for the dock's reveal button — a handler-supplied
	# focus (exact node) wins over the tool+args guess. Resolved live; scene stamped for jumps.
	var focus: Dictionary = result_focus if not result_focus.is_empty() else _focus_hint(tool_name, args)
	if not focus.is_empty():
		if focus.get("kind") == "node" and not focus.has("scene") and Engine.is_editor_hint():
			var root := EditorInterface.get_edited_scene_root()
			if root != null and root.scene_file_path != "":
				focus["scene"] = root.scene_file_path
		entry["focus"] = focus
	_audit.append(entry)
	_audit_total += 1
	if _audit.size() > AUDIT_MAX:
		_audit.pop_front()


## Map a tool call to a "reveal this in the editor" hint for the dock's activity feed —
## {kind, target|path|name}. Pure function of tool + args; the dock resolves the target
## against the live scene at click time. Returns {} for tools with no editor subject
## (reads of class API, runtime/L4 calls on the played game, exports, batch).
static func _focus_hint(tool_name: String, args: Dictionary) -> Dictionary:
	# nodes — the arg holds the node path directly (these don't move the node).
	if tool_name in ["set_property", "call_method", "attach_script", "set_resource", "list_signals"]:
		var t := str(args.get("target", ""))
		return {"kind": "node", "target": t} if t != "" else {}
	# nodes — the emitter side of a signal wiring.
	if tool_name in ["connect_signal", "disconnect_signal"]:
		var f := str(args.get("from", ""))
		return {"kind": "node", "target": f} if f != "" else {}
	# Node create/move tools return their own exact focus from the handler (root.get_path_to,
	# see scene_tools.gd); this parent is only a create_node/instance_scene fallback.
	if tool_name in ["create_node", "instance_scene"]:
		var p := str(args.get("parent", ""))
		return {"kind": "node", "target": p if p != "" else "."}
	# scripts — open in the script editor.
	if tool_name in ["write_script", "read_script", "script_patch", "validate_script"]:
		var p := str(args.get("path", ""))
		return {"kind": "script", "path": p} if p != "" else {}
	# resource — open in the inspector.
	if tool_name == "create_resource":
		var p := str(args.get("path", ""))
		return {"kind": "resource", "path": p} if p != "" else {}
	# scenes — open it (save_scene only carries a path on save-as).
	if tool_name in ["open_scene", "save_scene"]:
		var p := str(args.get("path", ""))
		return {"kind": "scene", "path": p} if p != "" else {}
	# files — reveal in the FileSystem dock.
	if tool_name in ["write_file", "read_file", "list_dir"]:
		var p := str(args.get("path", ""))
		return {"kind": "file", "path": p} if p != "" else {}
	# main-screen switches.
	if tool_name in ["asset_lib_search", "asset_lib_info", "asset_lib_install"]:
		return {"kind": "screen", "name": "AssetLib"}
	# runtime/playtest tools act on the played game — jump to the Game view (dock gates it on playing).
	if tool_name in ["screenshot", "compare_screenshots", "simulate_input", "click_button_by_text", "click_control", "click_node3d", "click_world", "scroll", "drag", "get_control_rect", "find_ui_elements", "record_input", "replay_input", "runtime_call", "runtime_get_property", "runtime_set_property", "get_remote_tree", "find_nodes", "wait_for_node", "monitor_properties", "assert_node_state", "assert_screen_text"]:
		return {"kind": "screen", "name": "Game"}
	return {}


## Read-only view for the audit:// resource and the dock panel.
func audit_log() -> Array:
	return _audit


## Total calls this session — may exceed audit_log().size(), which caps at AUDIT_MAX.
func audit_total() -> int:
	return _audit_total


## Who is connected, for the dock. name/version come from the client's initialize
## handshake (clientInfo); idle_ms is time since the last request (-1 = none yet this
## run). NOTE: MCP carries NO model identity — the model lives in the client, so it is
## deliberately absent here; the panel says as much.
func client_status() -> Dictionary:
	var idle := -1
	if _last_activity_ms > 0:
		idle = Time.get_ticks_msec() - _last_activity_ms
	return {
		"name": str(_client_info.get("name", "")),
		"version": str(_client_info.get("version", "")),
		"ua": _client_ua,
		"idle_ms": idle,
	}


## Returns "" if allowed, otherwise an error message explaining the block.
func _gate(name: String, tool: Dictionary, args: Dictionary) -> String:
	# Edition cap (Lite=4): a tool above the edition's ceiling may not run even if
	# it somehow got registered (defense-in-depth — premium modules are also
	# physically absent from the Lite package). Note this checks _max_effort (the
	# edition), NOT _effort (the user's context dial): dialing effort down only
	# trims what tools/list advertises, it never blocks a call.
	if MCPEffortScript.tier_of(name) > _max_effort:
		return "Tool '%s' requires the Full edition (this build is capped at L%d)." % [name, _max_effort]
	if _readonly and not bool(tool.get("readonly", false)):
		return "Server is in read-only mode; '%s' is a mutating tool." % name
	if _disabled.has(name):
		return "Tool '%s' is switched off in the Beckett dock; turn it back on there to use it." % name
	if not _allowlist.is_empty():
		var ok := false
		for pat in _allowlist:
			var re := RegEx.new()
			if re.compile(pat) == OK and re.search(name) != null:
				ok = true
				break
		if not ok:
			return "Tool '%s' is not in the allowlist." % name
	if _confirm_destructive and bool(tool.get("destructive", false)):
		if str(args.get("confirm", "")).to_lower() != "true":
			return "Destructive tool '%s' requires confirm:\"true\"." % name
	return ""


## Validate call args against a tool's input_schema. Returns "" if OK, else an error.
## Lenient by design (see _call_tool): enforces `required` presence and rejects only
## hard JSON-kind clashes (an object/array where a scalar is wanted, or vice versa).
## string<->number<->bool are accepted because the reflection layer coerces them, so
## no previously-valid call is rejected. Extra keys (idempotency_key, confirm, ...) pass.
func _validate_args(tool: Dictionary, args: Dictionary) -> String:
	var schema: Dictionary = tool.get("input_schema", {}) if typeof(tool.get("input_schema")) == TYPE_DICTIONARY else {}
	if schema.is_empty():
		return ""
	for req in schema.get("required", []):
		var key := str(req)
		if not args.has(key):
			return "Missing required parameter: '%s'." % key
	var props: Dictionary = schema.get("properties", {}) if typeof(schema.get("properties")) == TYPE_DICTIONARY else {}
	for key in args:
		if not props.has(key):
			continue
		var decl: Dictionary = props[key] if typeof(props[key]) == TYPE_DICTIONARY else {}
		var want := str(decl.get("type", ""))
		if want.is_empty():
			continue
		var why := _type_mismatch(want, args[key])
		if not why.is_empty():
			return "Parameter '%s': %s" % [key, why]
	return ""


## "" if `value` can satisfy a JSON-schema `type` (after lenient coercion), else a
## short reason. Unknown/compound type declarations fall through as OK (never stricter
## than the old per-handler behavior).
func _type_mismatch(want: String, value: Variant) -> String:
	var t := typeof(value)
	match want:
		"string":
			if t == TYPE_ARRAY or t == TYPE_DICTIONARY:
				return "expected a string."
		"number", "integer":
			if t == TYPE_INT or t == TYPE_FLOAT:
				return ""
			if t == TYPE_STRING and (str(value).is_valid_float() or str(value).is_valid_int()):
				return ""
			return "expected a number."
		"boolean":
			if t == TYPE_BOOL:
				return ""
			if t == TYPE_STRING and str(value).to_lower() in ["true", "false", "1", "0", "yes", "no"]:
				return ""
			return "expected a boolean."
		"array":
			if t != TYPE_ARRAY:
				return "expected an array."
		"object":
			if t != TYPE_DICTIONARY:
				return "expected an object."
	return ""


# ---------------------------------------------------------------- result formatting

## Convert a handler's return dict into an MCP tool result {content:[...], isError}.
## Handler dict conventions: {text} | {json} | {image_png_base64[,text]} | {error[,suggestion]}
func _tool_result(r: Dictionary) -> Dictionary:
	var content: Array = []
	var is_error := false
	var structured: Variant = null
	if r.has("error"):
		is_error = true
		var msg := "Error: " + str(r["error"])
		if r.has("suggestion"):
			msg += "\nSuggestion: " + str(r["suggestion"])
		content.append({"type": "text", "text": msg})
	elif r.has("text"):
		content.append({"type": "text", "text": str(r["text"])})
	elif r.has("json"):
		# Text for every client + structuredContent (spec 2025-06-18) for the ones
		# that can consume machine-readable results directly.
		content.append({"type": "text", "text": JSON.stringify(r["json"], "  ")})
		if typeof(r["json"]) == TYPE_DICTIONARY:
			structured = r["json"]
	if r.has("image_png_base64"):
		content.append({"type": "image", "data": str(r["image_png_base64"]), "mimeType": "image/png"})
	if content.is_empty():
		content.append({"type": "text", "text": "(no output)"})
	var out := {"content": content, "isError": is_error}
	if structured != null:
		out["structuredContent"] = structured
	return out


# ---------------------------------------------------------------- security helpers

func _check_origin(headers: Dictionary) -> bool:
	# Anti DNS-rebind: reject any cross-origin browser request. Non-browser clients
	# (Claude Code, Cursor) send no Origin — allow those.
	if not headers.has("origin"):
		return true
	var origin: String = str(headers["origin"]).to_lower()
	return origin.begins_with("http://127.0.0.1") \
		or origin.begins_with("http://localhost") \
		or origin.begins_with("http://[::1]")


func _check_token(headers: Dictionary) -> bool:
	if _token.is_empty():
		return true
	return str(headers.get("authorization", "")) == "Bearer " + _token


## Validate the session header ONLY when the client actually sends one. The spec lets
## the server assign an id at initialize and have the client echo it back; we reject a
## *mismatched* id (404 -> the client re-initializes) but never REQUIRE its presence,
## so clients that omit it (e.g. Claude Code) keep working unchanged.
func _check_session(headers: Dictionary) -> bool:
	var sid := str(headers.get("mcp-session-id", ""))
	if sid.is_empty() or _session_id.is_empty():
		return true
	return sid == _session_id


# ---------------------------------------------------------------- small utils

func get_undo_redo() -> EditorUndoRedoManager:
	return plugin.get_undo_redo() if plugin != null else null


func _http(status: int, headers: Dictionary, body: String) -> Dictionary:
	return {"status": status, "headers": headers, "body": body}


func _body(json_string: String) -> Dictionary:
	return {"status": 200, "headers": {}, "body": json_string}


static func _env_flag(key: String) -> bool:
	var v := OS.get_environment(key).to_lower()
	return v == "1" or v == "true"


static func _gen_session_id() -> String:
	var chars := "0123456789abcdef"
	var s := ""
	for i in range(32):
		s += chars[randi() % 16]
	return s
