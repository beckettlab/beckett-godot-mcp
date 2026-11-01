@tool
extends Node

## MCP dispatcher. Owns the HTTP transport + tool registry, implements the MCP
## lifecycle (initialize / tools / resources / prompts) over JSON-RPC 2.0, and applies
## security gates before any tool runs. Everything executes on the editor main thread.

const PROTOCOL_VERSION := "2025-11-25"
# Revisions we can honestly serve (all Streamable-HTTP). initialize echoes the
# client's requested revision when it's one of these; otherwise our latest.
#
# 2025-11-25 is advertised because the two things it MANDATES of a server shaped like this
# are both true here: input-validation failures come back as tool RESULTS with isError so
# the model can self-correct (SEP-1303 — see _call_tool's _validate_args gate), and an
# invalid Origin answers 403 (see _check_origin). The revision's other additions are
# optional (icons), client-side (sampling tools, elicitation), experimental (tasks), or
# about OAuth flows this server does not use — it authenticates with a local bearer token.
const SUPPORTED_PROTOCOL_VERSIONS: Array[String] = ["2025-11-25", "2025-06-18", "2025-03-26"]
const SERVER_NAME := "beckett-godot-mcp"

const IDEMPOTENCY_MAX := 128  # bound the result cache (FIFO eviction)
# ...and bound it by BYTES too. An entry count alone is not a bound when a single
# screenshot result is ~5 MB of base64: 128 of those parked ~700 MB in the editor.
# A result larger than the ceiling is simply not cached (the repeat call re-runs).
const IDEMPOTENCY_MAX_BYTES := 8 * 1024 * 1024
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
	"res://addons/beckett/tools/help_tools.gd",
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
const MCPClientConfigScript := preload("res://addons/beckett/core/client_config.gd")
const MCPVersionScript := preload("res://addons/beckett/core/version.gd")  # serverInfo.version: the one reader of plugin.cfg
const PathGuardScript := preload("res://addons/beckett/core/path_guard.gd")  # the project check spells and echoes folders the way the read rule does
# Shared with the game runtime: the same log-sink module gives the EDITOR process a
# per-call engine-error window (v1.11 error echo). Logger API is 4.5+; graceful no-op below.
const LogSinkScript := preload("res://addons/beckett/runtime/game_log_sink.gd")

var error_echo = null  # LogSinkScript instance while serving; null = echo off (env/stopped)

# Auth-token file (v1.9): lives in a self-gitignored project dir so the secret never lands
# in VCS. File present == auth on; the dock's enable/rotate/disable buttons manage it.
const AUTH_TOKEN_FILE := "res://.beckett/token"

# ---- which editor (1.17) ----------------------------------------------------------------
# On 2026-10-09 an editor opened on a COPY of a project was started with BECKETT_PORT=8890, found
# 8890 held by another session's editor on the original, walked to 8891 and said nothing. Its client
# configs followed it, but that session's helper scripts kept calling 8890: they pushed shader code
# into the other editor and restarted its game, and the project name could not tell the two apart.
# Three answers live here: BECKETT_PORT is exact (start_server), every surface says which folder this
# editor serves (identity()), and a request that names another folder runs nothing (handle_http).

## Beside res://.beckett/port, which keeps the bare number: which editor serves this folder and how to
## reach it (identity() plus serving, requested_port, auth and the header to send). Never the token.
const ENDPOINT_FILE := "endpoint.json"
## The initialize result's _meta key that carries identity() (the registry name's reverse-DNS prefix).
const IDENTITY_META_KEY := "io.github.beckettlab/identity"
## The header a raw caller names its project folder with. http_server lowercases every header name.
const PROJECT_HEADER := "beckett-project"
const PROJECT_HEADER_SHOWN := "Beckett-Project"
## JSON-RPC error for a request meant for a project folder this editor does not serve. -32000 to -32099 is
## the implementation-defined server band; MCP uses -32002 and -32042 there and the TypeScript SDK -32000
## and -32001 on the client side, so -32010 names this one case and nothing else.
const WRONG_PROJECT := -32010
## How many distinct folders a refusal is logged for (once each): a client that keeps sending new ones
## cannot flood the Output panel.
const REFUSED_WARN_MAX := 16
## With BECKETT_PORT, "1" or "true" brings back the walk past a busy port.
const PORT_WALK_ENV := "BECKETT_PORT_WALK"

var plugin: EditorPlugin  # set by plugin.gd; exposes get_undo_redo()

var http: MCPHttpServerScript
var registry: MCPToolRegistryScript
var bridge: RuntimeBridgeScript  # runtime channel to the played game (B2)
var jobs: MCPJobsScript          # background subprocess jobs (D6) — e.g. export

var _resources
var _prompts
var _runtime_port: int = 8771

var _session_id: String = ""  # minted at initialize, echoed by clients, never checked (see handle_http)
# The revision `initialize` actually agreed on. Computed since forever, PERSISTED since
# v1.14: the resource_link serializer branch has to know whether the peer can read one
# (resource_link is 2025-06-18+, and we still serve 2025-03-26 clients). Defaults to our
# latest so a client that skipped the handshake gets the modern shape rather than a
# silently degraded one.
var _negotiated_version: String = PROTOCOL_VERSION
var _token: String = ""
var _runtime_token: String = ""  # game-channel handshake secret (v1.9.1; see start_server)
var _readonly: bool = false
var _confirm_destructive: bool = false
var _allowlist: Array[String] = []  # regex strings; empty = allow all
var _disabled: Dictionary = {}       # tool name -> true: dock per-tool off switches (beckett/disabled_tools)
var _idempotency: Dictionary = {}    # key -> cached result dict (FIFO-capped at IDEMPOTENCY_MAX)
var _idempotency_sizes: Dictionary = {}  # same keys -> approx byte size, so eviction can hold a byte ceiling
var _idempotency_bytes := 0          # running total of _idempotency_sizes (see IDEMPOTENCY_MAX_BYTES)
var _audit: Array = []               # ring of {t, tool, ms, ok, args[, error|result]} — who did what (D6)
var _audit_total := 0                # total calls this session (the ring keeps only the last AUDIT_MAX)
var _client_info: Dictionary = {}    # clientInfo {name, version} from the last initialize
var _client_ua: String = ""          # last request's User-Agent (best-effort fallback identity)
var _last_activity_ms: int = 0       # Time.get_ticks_msec() of the last request (0 = none yet)
var _tool_modules: Array = []        # keep tool-module instances alive (their Callables hold them)
var _effort: int = 6                 # AI effort tier 1..6; caps which tools tools/list advertises (see effort.gd)
var _max_effort: int = 6             # edition ceiling: Full=6, Lite=4 (its L5/L6 modules aren't shipped)
var _served: String = ""             # the project folder this editor serves (served_path), filled on first use
var _refused_warned: Dictionary = {} # folder key -> true: refusals already logged once (at most REFUSED_WARN_MAX)
var _requested_port: int = 0         # the port start_server was last asked for (0: not yet, or an OS-assigned one)
var _start_error: String = ""        # why the last start_server did not serve; "" when it did
var _runtime_requested: int = 0      # BECKETT_RUNTIME_PORT as this editor was started with it
var _runtime_from_env: bool = false  # ...and whether it was set at all (a walked bridge is only news then)
var _wrote_discovery: bool = false   # this process wrote endpoint.json, so a stop may mark it not serving


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
		# Kept before start_server re-exports the variable with the port it actually bound.
		_runtime_requested = _runtime_port
		_runtime_from_env = true

	# Security config (env still wins for CI; see _resolve_auth_token for the file-token
	# and fresh-setup default-on logic behind the v1.9 loopback auth).
	_token = _resolve_auth_token()
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


## Start the HTTP endpoint + the runtime bridge. v1.9 (B5): on a bind failure both walk up
## to 10 ports from their base, so two editors side by side just work. The actual bound ports
## land in http.port / _runtime_port; BECKETT_RUNTIME_PORT is (re)exported into THIS editor
## process's environment so games it launches dial the RIGHT bridge (children inherit env:
## without this, editor B's games would connect to editor A's default-port bridge). The live
## HTTP port is also dropped in res://.beckett/port, and who serves it in endpoint.json.
##
## `strict` (1.17, port_is_strict: the port came from BECKETT_PORT): that port or nothing. A script
## that set BECKETT_PORT dials that number afterwards and reaches whoever holds it either way; serving
## one port up only hid that (the 2026-10-09 incident, see the top of this file). The failure is loud
## instead: push_error, an editor toast on 4.4+, the dock's status line, endpoint.json serving:false.
## What makes the holder refuse such a script is the Beckett-Project header (handle_http).
func start_server(port: int, strict: bool = false) -> int:
	_requested_port = port
	_start_error = ""
	var attempts := 1 if strict else 10
	var err := ERR_CANT_CREATE
	for offset in attempts:
		err = http.start(port + offset, "127.0.0.1")
		if err == OK:
			break
	# BECKETT_PORT=0 asks the OS for a port, so a different one is the answer, not a busy one.
	if err == OK and port != 0 and http.port != port:
		print("[beckett] port %d busy: serving on %d (client configs follow the live port; res://.beckett/endpoint.json names it)" % [port, http.port])
	# The bridge starts even when the endpoint did not. A game this editor launches inherits
	# BECKETT_RUNTIME_PORT from it, and with no bridge of its own here it would dial another
	# editor's (the default port, or one this editor inherited), whose tools would then act on it.
	_start_bridge()
	if err != OK:
		# This project's own client configs that still send a client to those ports (a copy brings its original's).
		var held := configs_naming(port, attempts)
		_start_error = start_error_text(port, attempts, err, held)
		_report_start_failure(_start_error, port, attempts, held)
		_write_not_serving()
		return err
	_write_port_discovery(http.port)
	# v1.11 error echo: run an OS log sink in the EDITOR process so engine errors that
	# fire while a tool handler runs get attached to that call's response (the "ok:true
	# but the engine errored" class). 4.5+ only; BECKETT_ERROR_ECHO=0 opts out.
	if error_echo == null and OS.get_environment("BECKETT_ERROR_ECHO") != "0":
		error_echo = LogSinkScript.new()
		error_echo.install()
	return OK


## The runtime bridge half of start_server: walk up to 10 ports from _runtime_port, export the bound one
## (and the handshake secret) into this editor's environment for the games it launches.
func _start_bridge() -> void:
	if bridge == null:
		return
	var rp_err := ERR_CANT_CREATE
	for offset in 10:
		rp_err = bridge.start(_runtime_port + offset, "127.0.0.1")
		if rp_err == OK:
			_runtime_port = bridge.port
			break
	if rp_err != OK:
		push_error("[beckett] runtime bridge could not bind %d..%d: play-session tools will not connect" % [_runtime_port, _runtime_port + 9])
	elif _runtime_from_env and bridge.port != _runtime_requested:
		print("[beckett] runtime bridge port %d busy: serving games on %d (games this editor launches find it on their own; a game started by hand needs BECKETT_RUNTIME_PORT=%d)" % [_runtime_requested, bridge.port, bridge.port])
	OS.set_environment("BECKETT_RUNTIME_PORT", str(_runtime_port))
	# v1.9.1: per-session shared secret for the game handshake, delivered to launched
	# games the same way the port is (children inherit this editor's environment).
	# BECKETT_AUTH=0 disables it alongside HTTP auth; a preset BECKETT_RUNTIME_TOKEN
	# (e.g. wiring up a standalone game run) is honored instead of minting one.
	var kill := OS.get_environment("BECKETT_AUTH").to_lower()
	if kill == "0" or kill == "false":
		_runtime_token = ""
	elif not OS.get_environment("BECKETT_RUNTIME_TOKEN").is_empty():
		_runtime_token = OS.get_environment("BECKETT_RUNTIME_TOKEN")
	else:
		_runtime_token = Crypto.new().generate_random_bytes(16).hex_encode()
	bridge.expected_token = _runtime_token
	if not _runtime_token.is_empty():
		OS.set_environment("BECKETT_RUNTIME_TOKEN", _runtime_token)


## Why start_server did not serve, in words a person can act on. `attempts` 1 is the strict rule
## (BECKETT_PORT, no walk); more is the walk that ran out of ports. bind cannot tell a port another
## process holds from one the OS reserves (Windows excluded port ranges): the engine answers
## ERR_ALREADY_IN_USE for any bind failure on 4.4.1, 4.6.2 and 4.7 alike, so the text names both.
## `held` (configs_naming) are this project's client configs that still send a client to those ports.
static func start_error_text(port: int, attempts: int, err: int, held: PackedStringArray = PackedStringArray()) -> String:
	var why := " (%s)" % error_string(err)
	var note := configs_note(port, attempts, held)
	if attempts <= 1:
		return ("not serving: port %d could not be bound (another program holds it, most likely another Godot editor running Beckett, or the OS reserves it) and BECKETT_PORT asks for exactly that port,"
			+ " so this editor stays off instead of serving unnoticed on another one: a script aimed at %d reaches whoever holds it.") % [port, port] + note \
			+ (" Free the port, start this editor with another BECKETT_PORT, or set %s=1 to take the next free port (res://.beckett/endpoint.json then names it)."
			+ " Scripts that send the header %s: <project folder> are refused by any editor that serves another folder.") % [PORT_WALK_ENV, PROJECT_HEADER_SHOWN] + why
	return "not serving: ports %d to %d could not be bound (each is held by another program or reserved by the OS)." % [port, port + attempts - 1] + note \
		+ " Set the project setting beckett/port or BECKETT_PORT to a free port." + why


## This project's own client configs (".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json") whose URL names a
## port from `port` on (`count` of them). After a start that could not take those ports such a file, most
## often one a copy brought along from its original, sends a client started here to whoever holds the port:
## nothing refuses it, since only the Beckett-Project header names a folder. `root` is for the unit suite.
static func configs_naming(port: int, count: int, root: String = "res://") -> PackedStringArray:
	var out := PackedStringArray()
	for f in MCPClientConfigScript.PROJECT_CONFIG_FILES:
		var rel := str(f).trim_prefix("res://")
		var path := root.path_join(rel)
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		for i in count:
			if text.contains(MCPClientConfigScript.mcp_url(port + i)):  # a tokened URL (/mcp/<token>) contains it too
				out.append(rel)
				break
	return out


## The sentence a failed start adds for configs_naming's files ("" for none). The plugin writes no client
## config while the server does not serve (plugin.gd _start_serving), so these are files it found, not wrote.
static func configs_note(port: int, count: int, files: PackedStringArray) -> String:
	if files.is_empty():
		return ""
	var names := files[files.size() - 1]
	if files.size() > 1:
		names = ", ".join(files.slice(0, files.size() - 1)) + " and " + names
	return (" This project's %s still %s %s, so a client started here reaches whoever holds it (a Beckett editor there names the folder it serves in its initialize), and no client config is written while this editor does not serve."
		% [names, "names" if files.size() == 1 else "name", ("port %d" % port) if count <= 1 else "one of those ports"])


## A failed start is loud on every surface a person looks at: the Output panel (stderr when headless),
## a toast in the editor, the dock's status line (panel.gd reads last_start_error) and endpoint.json.
## push_error alone does not toast in a stable editor with default settings, hence the explicit one.
func _report_start_failure(text: String, port: int, attempts: int, held: PackedStringArray) -> void:
	push_error("[beckett] " + text)
	if not Engine.is_editor_hint():
		return
	# EditorInterface.get_editor_toaster() exists from 4.4: reached by name, because naming it would not
	# parse on 4.2 and 4.3, where the dock's status line carries the news on its own.
	if not EditorInterface.has_method("get_editor_toaster"):
		return
	var toaster: Object = EditorInterface.call("get_editor_toaster")
	if toaster != null and toaster.has_method("push_toast"):
		var taken: String = ("port %d is taken" % port) if attempts <= 1 else ("ports %d to %d are taken" % [port, port + attempts - 1])
		if not held.is_empty():
			taken += ". This project's client config still points there"
		toaster.call("push_toast", "Beckett is not serving: %s. The Output panel and the Beckett dock say why." % taken, 2, text)  # 2 = EditorToaster.SEVERITY_ERROR


## Persist the live HTTP port next to the auth token (same self-gitignored dir) so external
## tooling can find a negotiated port without parsing editor logs. `port` keeps the bare number;
## endpoint.json beside it (1.17) says which editor that is and the header to send it.
func _write_port_discovery(bound: int) -> void:
	# Not through a link: a `port` or ENDPOINT_FILE (or a whole .beckett) that links elsewhere would have that file overwritten.
	var base := AUTH_TOKEN_FILE.get_base_dir()
	if not MCPClientConfigScript.linked_part(base + "/port").is_empty() or not MCPClientConfigScript.linked_part(base + "/" + ENDPOINT_FILE).is_empty():
		return
	var dir := _ensure_beckett_dir()
	var f := FileAccess.open(dir + "/port", FileAccess.WRITE)
	if f != null:
		f.store_string(str(bound) + "\n")
		f.close()
	_write_endpoint(endpoint_record(identity(), true, _requested_port, auth_enabled(), ""))


## A start that did not serve says so in endpoint.json and takes res://.beckett/port away, unless a live
## editor on this SAME folder owns the record (a second editor on one project): its files stay, and only
## this editor's own surfaces carry the failure. A port file left behind names a port this editor does not
## hold (most often one a copy brought from its original), so a script reading it would act on whoever
## holds that port; with no file it finds nothing instead. A stop leaves the file as it always has.
func _write_not_serving() -> void:
	if not replace_on_failure(_read_endpoint(), served_path(), OS.get_process_id()):
		return
	var port_file := AUTH_TOKEN_FILE.get_base_dir() + "/port"
	if FileAccess.file_exists(port_file) and MCPClientConfigScript.linked_part(port_file).is_empty():
		DirAccess.remove_absolute(port_file)
	_write_endpoint(endpoint_record(identity(), false, _requested_port, auth_enabled(), _start_error))


## A stop marks the record not serving, when this process wrote it and nobody has written it since.
func _write_stopped() -> void:
	if not _wrote_discovery:
		return
	if _num(_read_endpoint().get("pid", 0)) != OS.get_process_id():
		return
	_write_endpoint(endpoint_record(identity(), false, _requested_port, auth_enabled(), ""))


func _write_endpoint(rec: Dictionary) -> void:
	var path := AUTH_TOKEN_FILE.get_base_dir() + "/" + ENDPOINT_FILE
	if not MCPClientConfigScript.linked_part(path).is_empty():
		return
	_ensure_beckett_dir()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(rec, "  ") + "\n")
	f.close()
	_wrote_discovery = true


## The record on disk, {} when there is none, it is not a JSON object, or it sits behind a link. Parsed
## with JSON.new() so a damaged file costs no error line.
func _read_endpoint() -> Dictionary:
	var path := AUTH_TOKEN_FILE.get_base_dir() + "/" + ENDPOINT_FILE
	if not FileAccess.file_exists(path) or not MCPClientConfigScript.linked_part(path).is_empty():
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not (parser.data is Dictionary):
		return {}
	return parser.data


## What endpoint.json holds: identity() plus whether it serves, the port asked for, whether a token is
## needed, the exact header to send and, after a failed start, why. Never the token itself.
static func endpoint_record(ident: Dictionary, serving: bool, requested: int, auth_on: bool, error_text: String) -> Dictionary:
	var folder := str(ident.get("folder", ""))
	var rec := {
		"serving": serving,
		"folder": folder,
		"name": str(ident.get("name", "")),
		"port": _num(ident.get("port", 0)) if serving else 0,
		"runtime_port": _num(ident.get("runtime_port", 0)),
		"requested_port": requested,
		"pid": _num(ident.get("pid", 0)),
		"build": str(ident.get("build", "")),
		"auth": "token" if auth_on else "off",
		"request_header": {PROJECT_HEADER_SHOWN: header_value(folder)},
	}
	if not error_text.is_empty():
		rec["error"] = error_text
	return rec


## May a failed start overwrite `existing`? Not when it is a live record of another editor on the same
## folder (serving, another pid): that editor is the one serving this project. Everything else (no
## record, a stopped or failed one, this process's own, a record a copy brought from another folder) yes.
static func replace_on_failure(existing: Dictionary, mine: String, pid: int) -> bool:
	var serving: Variant = existing.get("serving", false)
	if not (serving is bool and serving) or _num(existing.get("pid", 0)) == pid:
		return true
	return PathGuardScript.folder_key(str(existing.get("folder", ""))) != PathGuardScript.folder_key(mine)


## The Beckett-Project value to send for `folder`: the folder itself while it is printable ASCII, else
## its percent-encoded UTF-8 (Windows PowerShell refuses a header value outside Latin-1, and raw
## non-ASCII header bytes are not portable). The check accepts either spelling.
static func header_value(folder: String) -> String:
	for i in folder.length():
		var c := folder.unicode_at(i)
		if c < 0x20 or c > 0x7E:
			return folder.uri_encode()
	return folder


static func _num(v: Variant) -> int:
	return int(v) if (v is int or v is float) else 0


## res://.beckett/ — project-local runtime state (token, live port), seeded with a
## self-gitignore so none of it ever lands in VCS. Returns the dir path.
func _ensure_beckett_dir() -> String:
	var dir := AUTH_TOKEN_FILE.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var gi_path := dir + "/.gitignore"
	if not FileAccess.file_exists(gi_path):
		var gi := FileAccess.open(gi_path, FileAccess.WRITE)
		if gi != null:
			gi.store_string("*\n")
			gi.close()
	return dir


func stop_server() -> void:
	if http != null:
		http.stop()
	if bridge != null:
		bridge.stop()
	if error_echo != null:
		error_echo.uninstall()
		error_echo = null
	_write_stopped()


func is_running() -> bool:
	return http != null and http.running


# ---------------------------------------------------------------- which editor (1.17)

## Where the port to serve on comes from: "BECKETT_PORT" when the environment names it (env_port_set, the
## test configured_port takes the port by), else "beckett/port" when the project sets one, else "default".
static func port_source() -> String:
	if MCPClientConfigScript.env_port_set():
		return "BECKETT_PORT"
	if ProjectSettings.has_setting("beckett/port"):
		return "beckett/port"
	return "default"


## The port rule: exact (true) only for a port from BECKETT_PORT, unless BECKETT_PORT_WALK says 1 or true.
## A project setting or the default port keeps the walk, so two editors side by side still both serve:
## their client configs follow the live port, while an environment port is what a script dials afterwards.
static func strict_port(source: String, walk_env: String) -> bool:
	return source == "BECKETT_PORT" and not (walk_env.strip_edges().to_lower() in ["1", "true"])


static func port_is_strict() -> bool:
	return strict_port(port_source(), OS.get_environment(PORT_WALK_ENV))


## The folder this editor serves, the one spelling identity(), endpoint.json and the project check use:
## ProjectSettings.globalize_path("res://") without its trailing slash. On Windows that is the folder as
## the editor was opened (no junction, subst drive or 8.3 name resolved). On Linux and macOS the engine
## changes into the --path folder and reads the working folder back, so it is the physical path, links
## resolved (macOS reports /private/tmp/x for /tmp/x). A script should read it back from endpoint.json
## or the initialize _meta instead of spelling it itself.
static func project_folder() -> String:
	var p := ProjectSettings.globalize_path("res://")
	if p.length() > 1 and p.ends_with("/") and not p.ends_with(":/"):
		p = p.substr(0, p.length() - 1)
	return p


func served_path() -> String:
	if _served.is_empty():
		_served = project_folder()
	return _served


## Which editor this is: the one source for initialize _meta, endpoint.json, status://connection, doctor
## and the refusal. The folder is what tells two copies of a project apart; name, pid and the ports are
## reported, never matched. Never the token.
func identity() -> Dictionary:
	return {
		"folder": served_path(),
		"name": str(ProjectSettings.get_setting("application/config/name", "")),
		"build": MCPVersionScript.display(),
		"edition": "Lite" if is_lite() else "Full",
		"pid": OS.get_process_id(),
		"port": http.port if is_running() else 0,
		"runtime_port": bridge.port if bridge != null and bridge.running else 0,
	}


func requested_port() -> int:
	return _requested_port


func last_start_error() -> String:
	return _start_error


func runtime_requested_port() -> int:
	return _runtime_requested


func runtime_port_from_env() -> bool:
	return _runtime_from_env


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


func is_readonly() -> bool:
	return _readonly


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
## The per-tool `_meta` hints ride only to a peer whose negotiated revision defines Tool._meta
## (see supports_tool_meta), so doctor's and the dock's byte figures stay the wire figure.
func effective_specs(level: int) -> Array:
	var specs: Array = registry.list_specs(level, supports_tool_meta())
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
		return _refuse(403, "forbidden origin")
	if not _check_host(headers):
		return _refuse(403, "forbidden host (this server only answers to a loopback Host)")
	if not _check_token(headers, str(req.get("path", ""))):
		return _refuse(401, "unauthorized")
	# Deliberately NO session gate. Through v1.15.1 a _check_session() here answered 404 to any
	# Mcp-Session-Id other than the one minted at initialize. That id names no server-side
	# state (every client shares it, DELETE tears nothing down, a restart forgets it), so all
	# the 404 could do was punish a client for an editor restart: A keeps its old id, B
	# initializes and mints a new one, A's next request is refused. Live-tested 2026-09-19:
	# Claude Code 2.1.275 echoes the id on every request and retries its event stream with
	# the stale one; the 404 left that stream dead until a manual reconnect, and a client
	# that treats one 404 as fatal (Claude Code #94273) drops the server outright. A 404 is
	# only owed for a session the server TERMINATED, and this server never terminates one.

	# 1.17: a request may name the project folder it is meant for (Beckett-Project). Checked after the
	# token, so a caller without it learns nothing about this editor. A mismatch runs nothing: -32010 on
	# a request with an id (_wrong_project_reply), 412 in plain words where there is no id to answer.
	var wrong := _project_mismatch(headers)

	match method:
		"GET":
			if not wrong.is_empty():
				return _refuse(412, str(wrong["message"]))  # before the stream: no stream for another project
			# Streamable HTTP server->client channel: a GET accepting text/event-stream
			# opens the SSE stream we push notifications down (tools/list_changed when
			# the effort dial moves). Anything else has nothing to GET.
			if str(headers.get("accept", "")).to_lower().contains("text/event-stream"):
				return {"status": 200, "headers": {}, "body": "", "sse": true}
			return _http(405, {"Allow": "POST, DELETE"}, "")
		"DELETE":
			if not wrong.is_empty():
				return _refuse(412, str(wrong["message"]))
			return _http(200, {}, "")  # stateless: nothing to tear down
		"POST":
			# A browser can send a cross-origin POST without a CORS preflight only as a
			# "simple request": Content-Type text/plain, application/x-www-form-urlencoded,
			# multipart/form-data, or none at all. This server never approves a preflight, so a
			# page that has to send application/json can never reach dispatch. That matters for
			# loopback pages (another local dev server): the Origin gate lets those through by
			# design, and this is what keeps their text/plain "simple" POSTs out. Clients with no
			# Origin header (Claude Code, Cursor, curl) are not browsers and never trip it.
			if headers.has("origin") and not is_json_content_type(str(headers.get("content-type", ""))):
				return _refuse(415, "unsupported media type (a POST that carries an Origin header must be Content-Type: application/json)")
		_:
			return _http(405, {"Allow": "POST"}, "")

	var parsed: Variant = JSON.parse_string(req.get("body", ""))
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		if not wrong.is_empty():
			return _refuse(412, str(wrong["message"]))
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
		if not wrong.is_empty():
			return _refuse(412, str(wrong["message"]))
		return _http(202, {}, "")

	if not wrong.is_empty():
		return _wrong_project_reply(id, rpc_method, params, wrong)
	return _dispatch(id, rpc_method, params)


## {} when the request names no project folder or names this one; else {expected, message}. Only the
## header counts (the client configs Beckett writes stay as they were: a committed .mcp.json is shared).
func _project_mismatch(headers: Dictionary) -> Dictionary:
	if not headers.has(PROJECT_HEADER):
		return {}
	var want := str(headers[PROJECT_HEADER])
	if project_matches(want, served_path()):
		return {}
	return {"expected": want, "message": wrong_project_text(want, identity())}


## The answer to a request meant for another folder: JSON-RPC -32010 over HTTP 200, with what this editor
## serves in error.data. SDKs surface it as "MCP error -32010: ..." (to the user on initialize, to the
## model on tools/call) and a script reads it off the reply without catching an HTTP failure. A refused
## tools/call lands in the audit ring, so the dock's activity feed shows the attempt, and the Output panel
## gets one line per distinct folder (REFUSED_WARN_MAX of them at most).
func _wrong_project_reply(id: Variant, rpc_method: String, params: Dictionary, wrong: Dictionary) -> Dictionary:
	var expected := PathGuardScript._plain(str(wrong["expected"]))
	if rpc_method == "tools/call":
		var args: Dictionary = params.get("arguments", {}) if typeof(params.get("arguments")) == TYPE_DICTIONARY else {}
		# The name is the caller's text. Only a registered tool goes into the ring by name, as on the normal path,
		# where _call_tool turns an unknown name away before anything is recorded.
		var called := str(params.get("name", ""))
		if registry == null or not registry.has(called):
			called = "(unknown tool)"
		_audit_record(called, args, 0, "refused: meant for project folder " + expected)
	var key := PathGuardScript.folder_key(expected)
	if key.is_empty():
		key = expected
	if not _refused_warned.has(key) and _refused_warned.size() < REFUSED_WARN_MAX:
		_refused_warned[key] = true
		push_warning("[beckett] refused a request meant for project folder %s: this editor serves %s (refused tool calls are in the Beckett dock's activity feed)" % [PathGuardScript._shown(expected), PathGuardScript._shown(served_path())])
	return _body(MCPJsonRpcScript.error(id, WRONG_PROJECT, str(wrong["message"]), {"serving": identity(), "expected": expected}))


## Is `want` (a Beckett-Project value) the folder `served` names? Compared through PathGuard.folder_key,
## the read rule's own spelling: either slash and any case on Windows, exact elsewhere, a trailing
## project.godot dropped, a relative or ".." path never. A value that is an absolute folder as it stands is
## taken literally ("C:/a%20b" is a folder of its own, not "C:/a b"). Only one that is not, and holds a "%",
## is tried decoded as percent-encoded UTF-8: header_value encodes a non-ASCII folder whole, its ":" and
## "/" included, so that spelling is never absolute before decoding.
static func project_matches(want: String, served: String) -> bool:
	var mine := PathGuardScript.folder_key(served)
	if mine.is_empty():
		return false
	var key := PathGuardScript.folder_key(want)
	if not key.is_empty():
		return key == mine
	return want.contains("%") and PathGuardScript.folder_key(pct_decode(want)) == mine


## The refusal, naming what this editor serves (folder, name, port, process) and what the request named.
## Both are filesystem text a cloned repository can choose, so they go out quoted and cut short.
static func wrong_project_text(expected: String, me: Dictionary) -> String:
	var head := "Wrong editor: this is Beckett for project folder %s (name %s, port %d, pid %d), and the request names %s" % [
		PathGuardScript._shown(str(me.get("folder", ""))), PathGuardScript._shown(str(me.get("name", ""))),
		_num(me.get("port", 0)), _num(me.get("pid", 0)), PathGuardScript._shown(expected)]
	if PathGuardScript.folder_key(expected).is_empty() and PathGuardScript.folder_key(pct_decode(expected)).is_empty():
		return head + ", which is not an absolute folder path. Nothing was run. Send the folder the way that project's res://.beckett/endpoint.json spells it (request_header)."
	return head + ". Nothing was run. The editor serving that folder names its port in .beckett/endpoint.json inside it."


## Percent-decoding for a Beckett-Project value: "%" and two hex digits (either case) become that byte, and
## everything else, a "+" or a lone "%" included, stays as it is. Not String.uri_decode: that one turns
## every "+" into a space and reads only uppercase hex (4.4.1, 4.6.2 and 4.7 alike), and uri_file_decode is
## absent on 4.4.1 (present from 4.6.2 on). Bytes that are not well-formed UTF-8, or hold a NUL, decode to ""
## (so they match no folder): get_string_from_utf8 would stop at the NUL, letting this folder followed by
## anything match, and print an engine error for each bad sequence.
static func pct_decode(s: String) -> String:
	var src := s.to_utf8_buffer()
	var out := PackedByteArray()
	var i := 0
	while i < src.size():
		if src[i] == 0x25 and i + 2 < src.size():
			var hi := _hex_digit(src[i + 1])
			var lo := _hex_digit(src[i + 2])
			if hi >= 0 and lo >= 0:
				out.append(hi * 16 + lo)
				i += 3
				continue
		out.append(src[i])
		i += 1
	return out.get_string_from_utf8() if utf8_clean(out) else ""


## Is `b` well-formed UTF-8 with no NUL byte? Shortest forms only, no UTF-16 surrogates, nothing past U+10FFFF.
static func utf8_clean(b: PackedByteArray) -> bool:
	var n := b.size()
	var i := 0
	while i < n:
		var c: int = b[i]
		if c == 0:
			return false
		if c < 0x80:
			i += 1
			continue
		var more := 0
		var lo := 0x80
		var hi := 0xBF
		if c >= 0xC2 and c <= 0xDF:
			more = 1
		elif c >= 0xE0 and c <= 0xEF:
			more = 2
			if c == 0xE0:
				lo = 0xA0
			elif c == 0xED:
				hi = 0x9F
		elif c >= 0xF0 and c <= 0xF4:
			more = 3
			if c == 0xF0:
				lo = 0x90
			elif c == 0xF4:
				hi = 0x8F
		else:
			return false
		if i + more >= n:
			return false
		for k in more:
			var cc: int = b[i + 1 + k]
			if cc < (lo if k == 0 else 0x80) or cc > (hi if k == 0 else 0xBF):
				return false
		i += 1 + more
	return true


static func _hex_digit(c: int) -> int:
	if c >= 0x30 and c <= 0x39:
		return c - 0x30
	if c >= 0x61 and c <= 0x66:
		return c - 0x61 + 10
	if c >= 0x41 and c <= 0x46:
		return c - 0x41 + 10
	return -1


# ---------------------------------------------------------------- dispatch

## The working notes handed to the agent at initialize: the identity line, then the edition's notes.
func _instructions() -> String:
	return _identity_line() + " " + _edition_notes()


## The same text, for doctor's price of it.
func instructions_text() -> String:
	return _instructions()


## The one line of the instructions that says which project this editor serves (1.17). The folder, not the
## project name: application/config/name comes with a cloned repo and a copy shares it with its original,
## while the folder tells two copies apart (and is what Claude Code already shows as its working directory).
## It is filesystem text a cloned repository chooses, so it goes out quoted and cut at 160 characters
## (PathGuard._shown). The build stays out: serverInfo.version and _meta carry it, and this line stays the
## same across an edit and a restart.
func _identity_line() -> String:
	return "Serving project folder %s. Raw HTTP callers: send header %s: <that folder> and any other editor refuses the request." % [PathGuardScript._shown(served_path()), PROJECT_HEADER_SHOWN]


## Working notes handed to the agent at initialize. Keep these SHORT — they ride
## along once per session. The Lite text states the edition boundary plainly so
## the agent recommends the Full edition exactly when the user hits it.
func _edition_notes() -> String:
	var core := "Reflection tools (find_classes, describe_class, set_property, call_method) reach every engine class — prefer them when no dedicated tool fits. Script writes are parse-validated before touching disk and read back after (disk_verified); scene edits are undoable and reply persisted:false when a save would drop them (edits inside an instanced scene, deleting or reordering what an inherited scene gets from its base); batch_execute rolls back on failure."
	if is_lite():
		return ("Beckett — MCP for Godot, free Lite edition (inspect + author + run + SEE the running game). " + core
			+ " Dev loop: edit -> play_scene -> wait_until game_connected -> SEE it (screenshot, get_remote_tree, runtime_get_property, game_logs) -> diagnose -> fix."
			+ " Lite can SEE the running game but cannot DRIVE it: input injection, UI/3D clicks, drag/scroll, runtime writes, assertions, the test runner, animation_manage, background exports and the skill packs are Full-edition features."
			+ " If the user asks for one of those, say it needs the Full edition (upgrade link on the Beckett dock panel).")
	var packs := _skill_pack_count()
	return ("Beckett — MCP for Godot, Full edition. " + core
		+ " Loop: author -> play_scene -> wait_until game_connected -> playtest (screenshot, simulate_input, click_button_by_text, assert_*, test_run) -> logs_read -> fix -> export_project (background; poll job_status)."
		+ " Call list_skills early: " + ("%d knowledge packs" % packs if packs > 0 else "knowledge packs") + " name the exact classes/properties/methods per domain (physics, shaders, animation, multiplayer, ...)."
		+ " For a 'make me a game' request, however vague: load_skill name=game-oneshot FIRST and follow it — it expands the idea, routes to a genre blueprint pack, and gates each build phase.")


## Count the knowledge packs actually on disk, bundled plus any project overrides, the
## same way list_skills does. Derived rather than written down: the literal that used to
## live in the instructions had already drifted one pack behind the addon.
func _skill_pack_count() -> int:
	var names := {}
	for dir_path in ["res://addons/beckett/skills", "res://.beckett/skills"]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.ends_with(".md"):
				names[f.get_basename()] = true
	return names.size()


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
			_negotiated_version = negotiated
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
					# 1.17: the exact build ("1.17.0-dev+3f9a2c1d"); the part before "+" is plugin.cfg's version.
					"version": MCPVersionScript.display(),
				},
				# Per-edition working notes for the agent (spec 2025-06-18). For Lite
				# this doubles as the honest capability boundary: the agent learns what
				# the Full edition adds, so when the user asks for it the agent can say
				# so at the moment of need instead of flailing. It opens with the one
				# line that names the project folder this editor serves.
				"instructions": _instructions(),
				# 1.17: which editor answered, for scripts and clients (Result._meta exists in every
				# revision served here); the model is not shown _meta, so it costs no context.
				"_meta": {IDENTITY_META_KEY: identity()},
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
			# Binary resources (v1.14 captures) carry `blob` — base64, per the MCP resource
			# contents shape — and a text resource carries `text`. They are mutually
			# exclusive in the spec, so pick one rather than emitting an empty sibling.
			var rcontent := {"uri": uri, "mimeType": str(rr.get("mime", "text/plain"))}
			if rr.has("blob"):
				rcontent["blob"] = str(rr["blob"])
			else:
				rcontent["text"] = str(rr.get("text", ""))
			return _body(MCPJsonRpcScript.result(id, {"contents": [rcontent]}))

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
	# v1.11 error echo: engine errors pushed while THIS handler runs belong in its
	# response. Handlers are synchronous on the main thread, so the window is tight.
	var echo_mark: int = error_echo.mark() if error_echo != null else 0
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
	if r.get("error") is String:
		r["error"] = explain_error(r["error"])
	if error_echo != null and not r.has("engine_errors"):
		var echoes: Array = error_echo.echo_since(echo_mark)
		if not echoes.is_empty():
			r["engine_errors"] = echoes
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
		_idempotency_put(idem, result)
	return _body(MCPJsonRpcScript.result(id, result))


## "game not running" is what every runtime tool's own pre-check says when the channel has no peer. For a game that
## broke into the editor's debugger before its runtime could say hello that is the wrong news (it IS running, and
## playing it again meets the same wall), so the places every tool answer passes through (this one, and
## batch_execute's steps) swap it for what is really going on. Any other error comes back as it was.
func explain_error(err: String) -> String:
	if bridge != null and err.begins_with("game not running"):
		var paused: String = bridge.break_text()
		if not paused.is_empty():
			return paused
	return err

## Cache a result under an idempotency key, holding BOTH bounds (entry count and total
## bytes). Oversized results are skipped rather than evicting the whole cache for one
## screenshot; the repeat call just re-runs, which is the pre-cache behaviour.
func _idempotency_put(key: String, result: Dictionary) -> void:
	var size := _result_bytes(result)
	if size > IDEMPOTENCY_MAX_BYTES:
		return
	if _idempotency.has(key):
		_idempotency_bytes -= int(_idempotency_sizes.get(key, 0))
		_idempotency.erase(key)
		_idempotency_sizes.erase(key)
	while not _idempotency.is_empty() and (_idempotency.size() >= IDEMPOTENCY_MAX or _idempotency_bytes + size > IDEMPOTENCY_MAX_BYTES):
		var oldest: String = str(_idempotency.keys()[0])  # FIFO: insertion order is preserved
		_idempotency_bytes -= int(_idempotency_sizes.get(oldest, 0))
		_idempotency.erase(oldest)
		_idempotency_sizes.erase(oldest)
	_idempotency[key] = result
	_idempotency_sizes[key] = size
	_idempotency_bytes += size


## Approximate the wire size of a tool result without re-serializing it: String.length()
## is O(1) in Godot, and text + base64 image data are where every byte that matters is.
func _result_bytes(result: Dictionary) -> int:
	var total := 0
	var content: Variant = result.get("content", [])
	if content is Array:
		for c in content:
			if c is Dictionary:
				total += str(c.get("text", "")).length()
				total += str(c.get("data", "")).length()
	if result.has("structuredContent"):
		total += 512  # structured payloads are small next to a capture; charge a flat estimate
	return total


## Append one entry to the audit ring (D6: see who/what ran, when, how long).
## Args are stored compactly (keys + truncated JSON) — enough to reconstruct intent
## without bloating memory or leaking huge file bodies into the ring.
func _audit_record(tool_name: String, args: Dictionary, ms: int, error: String, result := "", result_focus: Dictionary = {}) -> void:
	var brief := JSON.stringify(args)
	if brief.length() > 200:
		brief = brief.substr(0, 200) + "…"
	var entry := {
		"t": Time.get_datetime_string_from_system(),
		"tool": tool_name.substr(0, 200),  # capped like args and error: the dock copies it into labels and tooltips
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
## Handler dict conventions: {text} | {json} | {image_png_base64[,text]} |
## {image_base64, image_mime[,text|json]} (v1.10: jpeg/webp screenshots ride with an
## explicit mime; json alongside an image carries e.g. the Set-of-Mark legend) |
## {error[,suggestion]}
func _tool_result(r: Dictionary) -> Dictionary:
	var content: Array = []
	var is_error := false
	var structured: Variant = null
	if r.has("error"):
		# An error stays exclusive: a failed handler's half-written text must not ride
		# along and read like a partial success.
		is_error = true
		var msg := "Error: " + str(r["error"])
		if r.has("suggestion"):
			msg += "\nSuggestion: " + str(r["suggestion"])
		content.append({"type": "text", "text": msg})
	else:
		# text and json are INDEPENDENT (they were an if/elif until v1.13.0, which
		# silently dropped whichever came second - an annotated screenshot had to hide
		# its human-readable line inside the json to survive).
		if r.has("text"):
			content.append({"type": "text", "text": str(r["text"])})
		if r.has("json"):
			# Text for every client + structuredContent (spec 2025-06-18) for the ones
			# that can consume machine-readable results directly. Compact on purpose:
			# the 2-space indent was pure token cost for the model that reads this.
			content.append({"type": "text", "text": JSON.stringify(r["json"])})
			if typeof(r["json"]) == TYPE_DICTIONARY:
				structured = r["json"]
	if r.has("image_png_base64"):
		content.append({"type": "image", "data": str(r["image_png_base64"]), "mimeType": "image/png"})
	elif r.has("image_base64"):
		content.append({"type": "image", "data": str(r["image_base64"]), "mimeType": str(r.get("image_mime", "image/png"))})
	# v1.14 resource_link: hand the client a URI instead of a megabyte of base64. The
	# revision gate lives HERE and not in any tool, so one check covers every present and
	# future producer — resource_link is a 2025-06-18 content type and we still serve
	# 2025-03-26 peers, which would choke on an unknown block. A producer that cares about
	# the degradation (screenshot's deliver=link) inspects supports_resource_link() itself
	# and keeps a readable channel; everything else just loses the link, never the result.
	if r.has("resource_links") and r["resource_links"] is Array and supports_resource_link():
		for rl in r["resource_links"]:
			if not (rl is Dictionary) or not rl.has("uri"):
				continue
			var block := {"type": "resource_link", "uri": str(rl["uri"])}
			for k in ["name", "description", "mimeType"]:
				if rl.has(k):
					block[k] = str(rl[k])
			content.append(block)
	# v1.11 error echo: engine errors captured during the handler ride BOTH channels -
	# a text block every client can read, structuredContent.engine_errors for parsers.
	# Advisory by design: isError is untouched (the handler DID complete); the agent
	# decides whether the errors invalidate the effect.
	if r.has("engine_errors") and r["engine_errors"] is Array and not (r["engine_errors"] as Array).is_empty():
		var elines: Array = []
		for e in r["engine_errors"]:
			var ed: Dictionary = e if e is Dictionary else {"message": str(e)}
			var eline := "- [%s] %s" % [str(ed.get("severity", "error")), str(ed.get("message", ""))]
			var ewhere := str(ed.get("where", ""))
			if not ewhere.is_empty():
				eline += " (%s)" % ewhere
			elines.append(eline)
		content.append({"type": "text", "text": "Engine errors during this call (it still ran - verify its effect):\n" + "\n".join(elines)})
		if structured is Dictionary:
			structured["engine_errors"] = r["engine_errors"]
		elif structured == null:
			structured = {"engine_errors": r["engine_errors"]}
	if content.is_empty():
		content.append({"type": "text", "text": "(no output)"})
	var out := {"content": content, "isError": is_error}
	if structured != null:
		out["structuredContent"] = structured
	return out


## Can the peer read a `resource_link` content block? It arrived in spec 2025-06-18 and we
## still serve 2025-03-26. The revisions are ISO dates, so a string compare IS the ordering
## — no table to keep in sync when a revision is added to SUPPORTED_PROTOCOL_VERSIONS.
func supports_resource_link() -> bool:
	return _negotiated_version >= "2025-06-18"


## Can the peer read `_meta` on a Tool? Tool._meta was added in the same revision as
## resource_link, so this is the same ISO-date compare; it is a separate name so each call
## site says which capability it is gating.
func supports_tool_meta() -> bool:
	return _negotiated_version >= "2025-06-18"


# ---------------------------------------------------------------- security helpers

func _check_origin(headers: Dictionary) -> bool:
	# Anti DNS-rebind: reject any cross-origin browser request. Non-browser clients
	# (Claude Code, Cursor) send no Origin — allow those. 403 is what spec 2025-11-25
	# requires for an invalid Origin (it was previously unstated).
	if not headers.has("origin"):
		return true
	return origin_is_loopback(str(headers["origin"]))


## Is `origin` (an Origin header value) a loopback WEB origin? Parsed, not prefix-matched:
## through v1.15.2 this was `begins_with("http://127.0.0.1")` and two siblings, which also
## admits http://127.0.0.1.evil.com and http://localhost.evil.com, the exact flaw behind
## CVE-2026-102878 (mcp-chrome-bridge, origin.startsWith). Accepted: scheme http or https; host
## exactly 127.0.0.1, localhost or [::1]; an optional port of 1-5 digits; one trailing "/".
## Everything else is a no: userinfo, a path, query or fragment, the literal "null" that
## sandboxed iframes and file:// pages send, and anything that does not parse.
static func origin_is_loopback(origin: String) -> bool:
	var o := origin.to_lower()
	if o.ends_with("/"):
		o = o.substr(0, o.length() - 1)
	var sep := o.find("://")
	if sep == -1:
		return false
	var scheme := o.substr(0, sep)
	if scheme != "http" and scheme != "https":
		return false
	var authority := o.substr(sep + 3)
	# Only the characters a host[:port] can carry. That one rule already rules out userinfo
	# (@), a path (/), a query (?), a fragment (#), backslashes, whitespace and control bytes.
	const AUTHORITY_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789.-:[]"
	for i in authority.length():
		if AUTHORITY_CHARS.find(authority[i]) == -1:
			return false
	var host := authority
	var port := ""
	var has_port := false
	var bracketed := authority.begins_with("[")
	if bracketed:                                    # [::1]:8080
		var close := authority.find("]")
		if close == -1:
			return false
		host = authority.substr(1, close - 1)
		var rest := authority.substr(close + 1)
		if not rest.is_empty():
			if not rest.begins_with(":"):
				return false                         # [::1].evil.com
			has_port = true
			port = rest.substr(1)
	else:
		var colon := authority.find(":")
		if colon != -1:
			host = authority.substr(0, colon)
			has_port = true
			port = authority.substr(colon + 1)
	if bracketed:
		if host != "::1":
			return false
	elif host != "127.0.0.1" and host != "localhost":
		return false
	if has_port:
		if port.is_empty() or port.length() > 5:
			return false
		for i in port.length():
			if port[i] < "0" or port[i] > "9":
				return false
		if port.to_int() > 65535:
			return false
	return true


## Does a Content-Type header value declare JSON? "application/json" alone or followed by
## parameters ("; charset=utf-8"), case-insensitive. "application/jsonp" and friends are not.
static func is_json_content_type(content_type: String) -> bool:
	var ct := content_type.strip_edges().to_lower()
	if not ct.begins_with("application/json"):
		return false
	var rest := ct.substr("application/json".length()).strip_edges()
	return rest.is_empty() or rest.begins_with(";")


## The other half of the DNS-rebinding gate, and the half that actually closes it.
## Origin CANNOT close it on its own: a legitimate non-browser client sends no Origin, so
## Origin-less requests must pass — and that is exactly the shape a rebinding attack takes.
## The HOST header is what the browser was TOLD to connect to, and in an attack it carries
## the attacker's name, never a loopback literal. Mirrors official SDK >= 0.25 behaviour
## (CVE-2026-11624). Runs before the token check, so it holds with BECKETT_AUTH=0 too.
func _check_host(headers: Dictionary) -> bool:
	if not headers.has("host"):
		return true  # HTTP/1.0 or a hand-rolled client: nothing was asserted to check
	var host := str(headers["host"]).to_lower().strip_edges()
	var host_name := host
	var host_port := ""
	if host_name.begins_with("["):            # [::1]:8770
		var close := host_name.find("]")
		if close != -1:
			host_port = host_name.substr(close + 1).lstrip(":")
			host_name = host_name.substr(1, close - 1)
	else:
		var colon := host_name.rfind(":")
		if colon != -1:
			host_port = host_name.substr(colon + 1)
			host_name = host_name.substr(0, colon)
	if not (host_name in ["127.0.0.1", "localhost", "::1"]):
		return false
	# A port that disagrees with the socket the request actually arrived on means the
	# client was aimed somewhere else; only compare when we know our own port.
	if not host_port.is_empty() and http != null and http.port > 0:
		return host_port == str(http.port)
	return true


func _check_token(headers: Dictionary, path: String = "") -> bool:
	if _token.is_empty():
		return true
	var auth := str(headers.get("authorization", ""))
	if auth.begins_with("Bearer ") and _secure_equals(auth.substr(7), _token):
		return true
	# URL-path form (/mcp/<token>): the universal carrier — every client config can hold a
	# URL, only some can hold custom headers. client_config writes this form on setup.
	var p := path.split("?")[0]
	while p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	return _secure_equals(p.get_file(), _token)


## Constant-time string compare for auth: never early-outs on the first differing byte, so
## response timing leaks nothing about how much of a guessed token matched (length excepted).
static func _secure_equals(a: String, b: String) -> bool:
	var ab := a.to_utf8_buffer()
	var bb := b.to_utf8_buffer()
	var diff := ab.size() ^ bb.size()
	for i in mini(ab.size(), bb.size()):
		diff |= ab[i] ^ bb[i]
	return diff == 0


# ---------------------------------------------------------------- auth token (v1.9)

## Resolve the auth token at startup: env kill-switch > env token (CI/headless) > project
## token file > first-run generation. Only a FRESH setup (no project client config carries
## our entry yet) gets a generated token by default — an upgraded project keeps auth off
## until the dock enables it, so existing client configs never start 401ing after an update.
func _resolve_auth_token() -> String:
	var kill := OS.get_environment("BECKETT_AUTH").to_lower()
	if kill == "0" or kill == "false":
		return ""
	var envt := OS.get_environment("BECKETT_TOKEN")
	if not envt.is_empty():
		return envt
	# The token file is not read, tightened or written through a link (see _token_link_text).
	var linked := token_link()
	if not linked.is_empty():
		push_warning("[beckett] " + _token_link_text(linked))
		return ""
	if FileAccess.file_exists(AUTH_TOKEN_FILE):
		# Tokens minted before v1.16 were left at the umask default (world-readable on a shared
		# Unix box); tighten them here, best effort, so an upgrade does not need a rotate.
		restrict_to_owner(AUTH_TOKEN_FILE)
		return FileAccess.get_file_as_string(AUTH_TOKEN_FILE).strip_edges()
	if MCPClientConfigScript.any_entry_in_project():
		return ""  # upgrade path: tokenless configs already point at us
	return _write_new_token()


## Generate + persist a fresh token (32 hex chars) under res://.beckett/, seeding the dir
## with a self-gitignore so the secret stays out of VCS. Returns the token ("" on IO failure,
## which degrades to auth-off rather than a wedged server).
func _write_new_token() -> String:
	var linked := token_link()
	if not linked.is_empty():
		push_error("[beckett] " + _token_link_text(linked))
		return ""
	_ensure_beckett_dir()
	var tok := Crypto.new().generate_random_bytes(16).hex_encode()
	var f := FileAccess.open(AUTH_TOKEN_FILE, FileAccess.WRITE)
	if f == null:
		push_error("[beckett] could not write auth token file %s (%s) — auth stays off" % [AUTH_TOKEN_FILE, error_string(FileAccess.get_open_error())])
		return ""
	f.store_string(tok + "\n")
	f.close()
	# After the close, not before: the editor writes through a temp file and renames it into
	# place, so only now does the path name the finished file.
	var perr := restrict_to_owner(AUTH_TOKEN_FILE)
	if perr != OK:
		push_warning("[beckett] could not restrict %s to its owner (%s): other local users may be able to read the token" % [AUTH_TOKEN_FILE, error_string(perr)])
	return tok


## Owner read/write only (0600) on Unix-likes: a token every local user can read is a token
## every local user holds. Windows has no such bit (the file inherits its folder's ACL), so
## there is nothing to set there and the answer is OK. Static so the unit suite can run it
## against a scratch file instead of the project's real token.
static func restrict_to_owner(path: String) -> Error:
	if OS.get_name() == "Windows":
		return OK
	# chmod follows a link: through one it would change the mode of whatever file the link names.
	if not MCPClientConfigScript.linked_part(path).is_empty():
		return ERR_UNAUTHORIZED
	return FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


## The link between the project and the token file, as an OS path, or "": the file itself, or the
## .beckett folder that holds it. A link can point anywhere, so through one the file would be read as
## the token (whatever file the link names would end up in every client config's URL), chmod-ed (any
## file of the user's) or rewritten (any file of the user's, overwritten with a token).
static func token_link() -> String:
	return MCPClientConfigScript.linked_part(AUTH_TOKEN_FILE)


static func _token_link_text(linked: String) -> String:
	return "%s is a symbolic link or junction, so the auth token file was not read, changed or written through it (a link can point anywhere) and token auth stays OFF. Replace it with a regular file or folder, or set BECKETT_TOKEN to use a token without a token file." % linked


func auth_token() -> String:
	return _token


func auth_enabled() -> bool:
	return not _token.is_empty()


## Dock: enable (or rotate) token auth — mint a fresh token, persist it, apply it live.
## The caller then re-writes client configs (ensure_all with the new token) or connected
## clients start 401ing. Returns the new token ("" on IO failure = still off).
func rotate_auth_token() -> String:
	_token = _write_new_token()
	_refresh_endpoint_auth()
	return _token


## Dock: turn token auth off and keep it off across restarts (removes the token file).
func set_auth_disabled() -> void:
	_token = ""
	if FileAccess.file_exists(AUTH_TOKEN_FILE):
		DirAccess.remove_absolute(AUTH_TOKEN_FILE)
	_refresh_endpoint_auth()


## endpoint.json says whether a caller needs the token; keep that true when the dock flips it.
func _refresh_endpoint_auth() -> void:
	if is_running():
		_write_endpoint(endpoint_record(identity(), true, _requested_port, auth_enabled(), ""))


# ---------------------------------------------------------------- small utils

func get_undo_redo() -> EditorUndoRedoManager:
	return plugin.get_undo_redo() if plugin != null else null


func _http(status: int, headers: Dictionary, body: String) -> Dictionary:
	return {"status": status, "headers": headers, "body": body}


func _body(json_string: String) -> Dictionary:
	return {"status": 200, "headers": {}, "body": json_string}


## A refusal from the gates at the top of handle_http: the reason in plain words, sent as the
## text/plain it is. Those gates run before the body is parsed, so there is no request id a
## JSON-RPC error could answer and the reason stays a bare sentence. It has to carry its own
## Content-Type because http_server stamps the JSON default on any unlabeled body: through
## v1.15.1 these went out as application/json over a body like `unauthorized`, and a client
## that picks its parser from that header reported a JSON parse error instead of the 401/403
## it was actually given.
func _refuse(status: int, reason: String) -> Dictionary:
	return _http(status, {"Content-Type": "text/plain; charset=utf-8"}, reason)


static func _env_flag(key: String) -> bool:
	var v := OS.get_environment(key).to_lower()
	return v == "1" or v == "true"


static func _gen_session_id() -> String:
	var chars := "0123456789abcdef"
	var s := ""
	for i in range(32):
		s += chars[randi() % 16]
	return s
