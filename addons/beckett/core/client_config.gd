@tool
extends RefCounted
class_name BeckettClientConfig

## One-click client setup (onboarding moat). Writes/merges MCP client config files in the
## project so an agent connects with zero hand-editing. Merge-not-clobber: never touches
## other servers, and skips writing when the entry is already correct (no VCS churn).
##
## Transport is MCP Streamable HTTP, so any HTTP-capable MCP client connects directly.
## stdio-only clients (e.g. Claude Desktop) bridge via `npx -y mcp-remote@<MCP_REMOTE_VERSION> <url>`.
##
## Every writer ends in _write_text (v1.16): it refuses a symbolic link and replaces the target
## atomically, so a config is either the old file or the new one, never half of either. A format
## we cannot read is never rewritten blind: JSON is backed up first (and read by _json_read, which
## hands every number and key back as the file had it), TOML is refused (see _toml_scan), and a YAML
## writer, if one is ever added, follows the TOML rule.

const SERVER_KEY := "beckett"
const DEFAULT_PORT := 8770
const PathGuardScript := preload("res://addons/beckett/core/path_guard.gd")  # is_link_path: the engine-version-safe link probe both modules use

## The two siblings a safe write may create beside its target (see _write_text and _swap_in).
const TMP_SUFFIX := ".beckett-tmp"
const OLD_SUFFIX := ".beckett-old"

## The tag a whole number carries through a JSON parse (see _json_read): a control-character prefix no
## config holds. In the JSON text it is spelled as the escape \u0001, which the parser reads back as
## that one character; _restore_ints turns a string starting with it back into an int.
const _INT_TAG := "\u0001int:"
const _INT_TAG_ESCAPED := "\\u0001int:"

## The mcp-remote release the Claude Desktop entry runs, as an EXACT version. An unpinned
## `npx mcp-remote` executes whatever npm serves under that name on every Claude Desktop
## launch, with the endpoint URL (and the auth token in it) in argv: one hijacked publish and
## it runs on every user's machine. Bumped deliberately, once per release: look up the
## current `npm view mcp-remote version`, read what changed, edit this one line. Never float it.
const MCP_REMOTE_VERSION := "0.14.3"

## Every file INSIDE the project that the writers below put our endpoint URL into. With auth
## on, that URL carries the token (/mcp/<token>), so core/export_filter.gd keeps all of them
## out of exports. A new project-local writer adds its path here; the unit suite fails when a
## `_merge("res://...` or `_merge(root.path_join("...` call site in this file is missing from the list.
const PROJECT_CONFIG_FILES := ["res://.mcp.json", "res://.cursor/mcp.json", "res://.vscode/mcp.json"]


## The one place the CONFIGURED port is resolved: env override → project setting → default.
## It lives beside mcp_url because everyone who needs the port needs it to build an endpoint —
## the plugin at boot, the dock's Start button, the config writers, doctor. This used to be
## copy-pasted into each of them and the copies drifted: the dock's Start button fell back to
## the bare default, so in a project set to `beckett/port=8772` a Stop→Start bound 8770 while
## every client config still said 8772. One resolver, no drift.
##
## This is the port we ASK for. The port actually bound can differ (start_server walks up to
## 10 ports past a busy one), so anything reporting on a RUNNING server must read http.port.
static func configured_port() -> int:
	var penv := OS.get_environment("BECKETT_PORT")
	if penv != "" and penv.is_valid_int():
		return penv.to_int()
	return int(ProjectSettings.get_setting("beckett/port", DEFAULT_PORT))


## The one place the endpoint URL is built. With auth on (v1.9), the token rides as a URL
## path segment (/mcp/<token>) rather than a header — every client can carry a URL, while
## only some config schemas can carry custom headers. The server accepts either form.
static func mcp_url(port: int, token: String = "") -> String:
	if token.is_empty():
		return "http://127.0.0.1:%d/mcp" % port
	return "http://127.0.0.1:%d/mcp/%s" % [port, token]


static func entry(port: int, token: String = "") -> Dictionary:
	return {"type": "http", "url": mcp_url(port, token)}


## stdio bridge for clients that can't speak HTTP directly (Claude Desktop, etc.). The package
## is pinned (see MCP_REMOTE_VERSION); `-y` skips npx's install prompt, so a client that spawns
## it with no terminal attached never waits on one.
static func desktop_entry(port: int, token: String = "") -> Dictionary:
	return {"command": "npx", "args": ["-y", "mcp-remote@" + MCP_REMOTE_VERSION, mcp_url(port, token)]}


static func config_json(port: int, token: String = "") -> String:
	return JSON.stringify({"mcpServers": {SERVER_KEY: entry(port, token)}}, "  ")


## Snippet for Claude Desktop's claude_desktop_config.json (global; user pastes it).
static func desktop_json(port: int, token: String = "") -> String:
	return JSON.stringify({"mcpServers": {SERVER_KEY: desktop_entry(port, token)}}, "  ")


# ---------------------------------------------------------------- detection

static func _home() -> String:
	return OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")


## Per-OS application-data dir for `app` (e.g. "Code", "Claude").
static func _appdata_dir(app: String) -> String:
	match OS.get_name():
		"Windows":
			return OS.get_environment("APPDATA").path_join(app)
		"macOS":
			return _home().path_join("Library/Application Support").path_join(app)
		_:
			return _home().path_join(".config").path_join(app)


## Claude Desktop's global config file (a global file outside the project — like Cline's).
static func desktop_config_path() -> String:
	return _appdata_dir("Claude").path_join("claude_desktop_config.json")


## Cline (VS Code extension `saoudrizwan.claude-dev`) keeps its OWN global MCP list — it does
## NOT read the project's `.vscode/mcp.json` (that file is Copilot's / VS Code-native). Its
## settings live in VS Code's per-user globalStorage, so we write there too on Connect.
static func _cline_storage_dir() -> String:
	return _appdata_dir("Code").path_join("User/globalStorage/saoudrizwan.claude-dev")


static func cline_settings_path() -> String:
	return _cline_storage_dir().path_join("settings/cline_mcp_settings.json")


## Cline wants `type:"streamableHttp"` (not `"http"`) for a Streamable-HTTP server.
static func cline_entry(port: int, token: String = "") -> Dictionary:
	return {"url": mcp_url(port, token), "type": "streamableHttp"}


## Any PROJECT-LOCAL config already carrying our server entry? This is the fresh-setup test
## behind default-on auth (v1.9): a project whose configs predate tokens must NOT get one
## silently — that would 401 every already-connected client on upgrade. Enable via the dock.
static func any_entry_in_project() -> bool:
	return _configured("res://.mcp.json", "mcpServers") \
		or _configured("res://.cursor/mcp.json", "mcpServers") \
		or _configured("res://.vscode/mcp.json", "servers")


## Per-client config freshness (doctor, v1.9): for each config file that mentions our entry,
## does it carry the CURRENT endpoint URL (port + token)? A crude text scan on purpose — one
## check that works across every schema shape (url / serverUrl / httpUrl / args / TOML)
## instead of nine parsers. Tokenless expectation matches a tokened file too, which is right:
## with auth off the server accepts any /mcp/* path.
##
## A Claude Desktop row also carries `unpinned` (the offending argument) when its bridge runs
## mcp-remote without an exact version: entries written before 1.16 did, and they keep doing it
## until Connect rewrites them, so doctor has to be able to say so.
static func staleness(port: int, token: String = "") -> Array:
	var expect := mcp_url(port, token)
	var files := _staleness_files()
	var out: Array = []
	for cname in files:
		var row := _staleness_row(str(cname), str(files[cname]), expect)
		if not row.is_empty():
			out.append(row)
	return out


## One client's row for staleness(), or {} when its file is missing or never mentions us.
## Split out so the unit suite can feed it a scratch config instead of the machine's real one.
static func _staleness_row(cname: String, path: String, expect: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if not text.contains(SERVER_KEY):
		return {}
	var row := {"client": cname, "path": path, "current": text.contains(expect)}
	if cname == "Claude Desktop":
		var bare := unpinned_bridge_arg(desktop_bridge_args(path))
		if bare != "":
			row["unpinned"] = bare
	return row


## Client name -> the config file staleness() reads. Its own function so the unit suite can check
## that every client we write is also one doctor checks.
static func _staleness_files() -> Dictionary:
	return {
		"Claude Code": "res://.mcp.json",
		"Cursor": "res://.cursor/mcp.json",
		"VS Code": "res://.vscode/mcp.json",
		"VS Code (Cline)": cline_settings_path(),
		"Claude Desktop": desktop_config_path(),
		"Codex": codex_config_path(),
		"Windsurf": windsurf_config_path(),
		"Devin Desktop": devin_config_path(),
		"Gemini CLI": gemini_config_path(),
		"Antigravity": antigravity_config_path(),
	}


## Our server's entry in the JSON config at `path` (under `root_key`), or null when the file, the
## section or the entry is missing or unreadable. Read only: a caller that writes goes through _merge.
static func _entry_at(path: String, root_key: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = _json_read(FileAccess.get_file_as_string(path), false)
	if not (parsed is Dictionary):
		return null
	var servers: Variant = (parsed as Dictionary).get(root_key)
	if not (servers is Dictionary):
		return null
	return (servers as Dictionary).get(SERVER_KEY)


## The `args` array of the beckett entry in Claude Desktop's config at `path`, or [] when the
## file, the entry or the array is missing or unreadable.
static func desktop_bridge_args(path: String) -> Array:
	var ent: Variant = _entry_at(path, "mcpServers")
	if not (ent is Dictionary):
		return []
	var args: Variant = (ent as Dictionary).get("args")
	return args if args is Array else []


## The argument that makes a bridge unpinned: `mcp-remote` with no version, or with one that is
## not an exact release (`@latest`, `@^0.14`, a dist-tag). "" when the args name no mcp-remote at
## all, or name it at an exact version (an OLDER exact pin is a stale pin, not an unpinned one).
## Every argument is looked at, not just the second: Windows setups wrap the call as
## ["/c", "npx", "-y", "mcp-remote", url].
static func unpinned_bridge_arg(args: Array) -> String:
	var exact := RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+(?:[-+][0-9A-Za-z.+-]+)?$")
	for a in args:
		var s := str(a)
		if s == "mcp-remote":
			return s
		if s.begins_with("mcp-remote@") and exact.search(s.substr(11)) == null:
			return s
	return ""


## Is VS Code wired to this project? Either file does it: it reads the workspace-root
## `.mcp.json` natively (1.138+), and an older setup may still carry its own `.vscode/mcp.json`
## (key "servers"). `root` is the project folder, injectable so the unit suite can use a scratch one.
static func _vscode_configured(root: String) -> bool:
	return _configured(root.path_join(".vscode/mcp.json"), "servers") \
		or _configured(root.path_join(".mcp.json"), "mcpServers")


## Does `path`'s config already carry our server entry (any port)?
static func _configured(path: String, root_key: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = _json_read(FileAccess.get_file_as_string(path), false)
	if not (parsed is Dictionary):
		return false
	var root: Variant = (parsed as Dictionary).get(root_key)
	return root is Dictionary and (root as Dictionary).has(SERVER_KEY)


## What MCP clients live on this machine / in this project? The panel renders this
## and `ensure_all` writes configs for exactly these. Detection is cheap dir checks
## (each client's app-data dir), so it can run on a UI refresh tick.
static func detect() -> Array:
	return [
		{"id": "claude_code", "name": "Claude Code",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".claude")),
			"configured": _configured("res://.mcp.json", "mcpServers")},
		{"id": "cursor", "name": "Cursor",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".cursor")),
			"configured": _configured("res://.cursor/mcp.json", "mcpServers")},
		{"id": "vscode", "name": "VS Code",
			"installed": DirAccess.dir_exists_absolute(_appdata_dir("Code")),
			"configured": _vscode_configured("res://")},
		{"id": "cline", "name": "VS Code (Cline)",
			"installed": DirAccess.dir_exists_absolute(_cline_storage_dir()),
			"configured": _configured(cline_settings_path(), "mcpServers")},
		{"id": "desktop", "name": "Claude Desktop",
			"installed": DirAccess.dir_exists_absolute(_appdata_dir("Claude")),
			"configured": _configured(desktop_config_path(), "mcpServers")},
		{"id": "codex", "name": "Codex",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".codex")),
			"configured": _toml_has_section(codex_config_path())},
		{"id": "windsurf", "name": "Windsurf",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".codeium/windsurf")),
			"configured": _configured(windsurf_config_path(), "mcpServers")},
		{"id": "devin", "name": "Devin Desktop",
			"installed": DirAccess.dir_exists_absolute(devin_config_dir()),
			"configured": _configured(devin_config_path(), "mcpServers")},
		{"id": "gemini_cli", "name": "Gemini CLI",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".gemini")),
			"configured": _configured(gemini_config_path(), "mcpServers")},
		{"id": "antigravity", "name": "Antigravity",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".gemini/config")) \
				or DirAccess.dir_exists_absolute(_home().path_join(".gemini/antigravity")),
			"configured": _configured(antigravity_config_path(), "mcpServers")},
	]


# ---------------------------------------------------------------- one-shot connect

## Zero-click path (plugin start): project `.mcp.json` always; Cursor only when that app exists
## on this machine (so we never drop a junk config dir into a project for an editor the user
## doesn't have). VS Code is never CREATED a file here: since 1.138 it reads the workspace-root
## `.mcp.json` itself, and a second `.vscode/mcp.json` would list Beckett twice. A
## `.vscode/mcp.json` that ALREADY carries our entry is merged like any other, so an older setup
## keeps a fresh port and token. Claude Desktop is NOT auto-written: it's a global file and its
## entry needs an `npx` bridge (Node.js); see ensure_all.
static func ensure_auto(port: int, token: String = "") -> Array:
	return _ensure_project(port, token, "res://",
		DirAccess.dir_exists_absolute(_home().path_join(".cursor")),
		DirAccess.dir_exists_absolute(_appdata_dir("Code")))


## ensure_auto with its three machine inputs injected: the project folder and which editors are
## installed. The unit suite runs the real decisions against a scratch folder this way, on a
## machine with or without VS Code, and never touches the repo's own `.mcp.json`.
static func _ensure_project(port: int, token: String, root: String, cursor_installed: bool, vscode_installed: bool) -> Array:
	var out: Array = []
	out.append(_tag("Claude Code", ensure_mcp_json(port, token, root)))
	if cursor_installed:
		out.append(_tag("Cursor", ensure_cursor(port, token, root)))
	if vscode_installed and _configured(root.path_join(".vscode/mcp.json"), "servers"):
		out.append(_tag("VS Code", ensure_vscode(port, token, root)))
	return out


## The panel's one-button connect: everything ensure_auto covers PLUS the global configs
## (Cline's globalStorage, Claude Desktop) when those apps are installed — merge-not-clobber,
## same as the rest. These are outside the project, so they're button-only (never auto).
static func ensure_all(port: int, token: String = "") -> Array:
	var out := ensure_auto(port, token)
	if DirAccess.dir_exists_absolute(_cline_storage_dir()):
		out.append(_tag("VS Code (Cline)", ensure_cline(port, token)))
	if DirAccess.dir_exists_absolute(_appdata_dir("Claude")):
		out.append(_tag("Claude Desktop", ensure_desktop(port, token)))
	# Home-dir clients (Codex / Windsurf / Gemini CLI / Antigravity): global configs like Cline
	# & Desktop, so button-only (never auto). Each gated on its own dir so we don't seed a config
	# for a client the user doesn't have.
	if DirAccess.dir_exists_absolute(_home().path_join(".codex")):
		out.append(_tag("Codex", ensure_codex(port, token)))
	if DirAccess.dir_exists_absolute(_home().path_join(".codeium/windsurf")):
		out.append(_tag("Windsurf", ensure_windsurf(port, token)))
	if DirAccess.dir_exists_absolute(devin_config_dir()):
		out.append(_tag("Devin Desktop", ensure_devin(port, token)))
	if DirAccess.dir_exists_absolute(_home().path_join(".gemini")):
		out.append(_tag("Gemini CLI", ensure_gemini(port, token)))
	if DirAccess.dir_exists_absolute(_home().path_join(".gemini/config")) \
			or DirAccess.dir_exists_absolute(_home().path_join(".gemini/antigravity")):
		out.append(_tag("Antigravity", ensure_antigravity(port, token)))
	return out


static func _tag(client_name: String, r: Dictionary) -> Dictionary:
	r["name"] = client_name
	return r


# The three project writers take the project folder as `root` (default: this project) so the
# unit suite can aim them at a scratch folder.

# Claude Code: res://.mcp.json   (key "mcpServers"). VS Code reads this one too (1.138+).
static func ensure_mcp_json(port: int, token: String = "", root: String = "res://") -> Dictionary:
	return _merge(root.path_join(".mcp.json"), "mcpServers", entry(port, token))


# Cursor / Windsurf: res://.cursor/mcp.json   (key "mcpServers")
static func ensure_cursor(port: int, token: String = "", root: String = "res://") -> Dictionary:
	_mkdir(root, ".cursor")
	return _merge(root.path_join(".cursor/mcp.json"), "mcpServers", entry(port, token))


# VS Code (Copilot / VS Code-native): res://.vscode/mcp.json   (key "servers", not "mcpServers").
# Only an explicit call CREATES this file now: ensure_auto leaves it alone (a current VS Code
# reads .mcp.json, and two registrations list Beckett twice) and only refreshes an existing one.
# Still here for the VS Code that predates the workspace-root .mcp.json.
static func ensure_vscode(port: int, token: String = "", root: String = "res://") -> Dictionary:
	_mkdir(root, ".vscode")
	return _merge(root.path_join(".vscode/mcp.json"), "servers", entry(port, token))


# Cline: its global cline_mcp_settings.json (key "mcpServers"). Field-merge so the user's
# autoApprove/disabled/timeout on our entry survive a re-Connect — see _merge_into_entry.
static func ensure_cline(port: int, token: String = "") -> Dictionary:
	return _merge_into_entry(cline_settings_path(), "mcpServers", cline_entry(port, token))


# Claude Desktop: its global claude_desktop_config.json (key "mcpServers"), a stdio bridge. An entry
# that already runs mcp-remote is edited IN PLACE (field-merge: only the command and arguments are
# ours, see desktop_fields); any other entry is replaced by the plain bridge, as it always was, since
# a stale `url` or a bridge of some other kind beside our command would only confuse the client.
# `path` overrides the real config file (the unit suite writes a scratch one).
static func ensure_desktop(port: int, token: String = "", path: String = "") -> Dictionary:
	if path == "":
		path = desktop_config_path()
	var existing: Variant = _entry_at(path, "mcpServers")
	var fields := desktop_fields(existing, port, token)
	if _bridge_arg_at(existing) == -1:
		return _merge(path, "mcpServers", fields)
	return _merge_into_entry(path, "mcpServers", fields)


## Where the mcp-remote argument sits in a Claude Desktop entry's `args`, or -1 when the entry is not
## a dictionary with an args array that names mcp-remote (bare, or with a version).
static func _bridge_arg_at(existing: Variant) -> int:
	if not (existing is Dictionary) or not ((existing as Dictionary).get("args") is Array):
		return -1
	var args: Array = (existing as Dictionary)["args"]
	for i in args.size():
		var s := str(args[i])
		if s == "mcp-remote" or s.begins_with("mcp-remote@"):
			return i
	return -1


## The `command` and `args` Connect writes into Claude Desktop's entry. With no bridge there yet, the
## plain `npx -y mcp-remote@<pin> <url>` (desktop_entry). With one, the entry the user already runs
## is edited IN PLACE: the mcp-remote argument gets the pinned version and the URL after it the
## current endpoint, and everything else stays as it was: the command (a Windows `cmd /c npx`
## wrapper is often what makes the bridge start at all), every other argument (mcp-remote flags)
## and, since ensure_desktop merges fields, the `env` block and any other key of the entry. An entry
## that names no mcp-remote at all is not a bridge we know how to edit, so it gets the plain one.
static func desktop_fields(existing: Variant, port: int, token: String = "") -> Dictionary:
	var plain := desktop_entry(port, token)
	var at := _bridge_arg_at(existing)
	if at == -1:
		return plain
	var args: Array = ((existing as Dictionary)["args"] as Array).duplicate()
	args[at] = "mcp-remote@" + MCP_REMOTE_VERSION
	var url_at := -1
	for i in range(at + 1, args.size()):
		if str(args[i]).begins_with("http"):
			url_at = i
			break
	if url_at == -1:
		args.insert(at + 1, mcp_url(port, token))
	else:
		args[url_at] = mcp_url(port, token)
	var cmd: Variant = (existing as Dictionary).get("command")
	return {"command": cmd if cmd is String and not (cmd as String).is_empty() else plain["command"], "args": args}


# ---------------------------------------------------------------- home-dir clients
# Codex / Windsurf / Devin Desktop / Gemini CLI / Antigravity all keep a GLOBAL config under the
# user's home (not the project), so, like Cline / Claude Desktop, they're button-only via
# ensure_all, never auto-written on plugin start. Paths + URL-field names below are each
# client's own schema (not interchangeable): Windsurf/Antigravity use `serverUrl`, Gemini CLI
# uses `httpUrl`, Devin Desktop uses `url`, Codex is TOML with a `url`. The JSON ones reuse
# _merge_into_entry (creates the dir, field-merges, preserves user-set keys, backs up
# unparseable files).

static func windsurf_config_path() -> String:
	return _home().path_join(".codeium/windsurf/mcp_config.json")


static func gemini_config_path() -> String:
	return _home().path_join(".gemini/settings.json")


static func antigravity_config_path() -> String:
	return _home().path_join(".gemini/config/mcp_config.json")


static func codex_config_path() -> String:
	return _home().path_join(".codex/config.toml")


# Windsurf speaks Streamable HTTP through a `serverUrl` field (not `url`). Kept for installs
# that still run it; Devin Desktop (below) is what Windsurf became.
static func ensure_windsurf(port: int, token: String = "") -> Dictionary:
	return _merge_into_entry(windsurf_config_path(), "mcpServers", {"serverUrl": mcp_url(port, token)})


# Devin Desktop is Windsurf renamed (docs.windsurf.com now redirects to docs.devin.ai), and its
# Cascade agent was removed in 3.9.19. It keeps ONE global MCP file, outside `.codeium`:
# %APPDATA%\devin\mcp_config.json on Windows, ~/.config/devin/mcp_config.json on macOS and Linux
# (macOS too, unlike _appdata_dir), under $XDG_CONFIG_HOME when that is set. Servers sit under
# `mcpServers.<name>`, and a Streamable-HTTP one takes `url` (transport defaults to http; the old
# Cascade page's `serverUrl` belongs to the removed agent). Field-merged, so a `headers` or
# `disabled` the user added to our entry survives a re-Connect.
static func devin_config_dir() -> String:
	return _devin_dir_for(OS.get_name(), OS.get_environment("APPDATA"), _home(), OS.get_environment("XDG_CONFIG_HOME"))


static func devin_config_path() -> String:
	return devin_config_dir().path_join("mcp_config.json")


## devin_config_dir with the machine inputs passed in, so each OS's answer is testable from any OS.
static func _devin_dir_for(os_name: String, appdata: String, home: String, xdg_config_home: String) -> String:
	if os_name == "Windows":
		return appdata.path_join("devin")
	return (xdg_config_home if xdg_config_home != "" else home.path_join(".config")).path_join("devin")


## `path` overrides the real config file (the unit suite writes a scratch one).
static func ensure_devin(port: int, token: String = "", path: String = "") -> Dictionary:
	return _merge_into_entry(path if path != "" else devin_config_path(), "mcpServers", {"url": mcp_url(port, token)})


# Gemini CLI keys a streamable-HTTP server under `httpUrl`.
static func ensure_gemini(port: int, token: String = "") -> Dictionary:
	return _merge_into_entry(gemini_config_path(), "mcpServers", {"httpUrl": mcp_url(port, token)})


# Antigravity (Google's agentic IDE) shares Gemini's tree but under config/, and uses `serverUrl`
# like Windsurf. We leave `disabled` unset — absent == enabled — so re-Connect never stomps a
# user who toggled the server off in the UI.
static func ensure_antigravity(port: int, token: String = "") -> Dictionary:
	return _merge_into_entry(antigravity_config_path(), "mcpServers", {"serverUrl": mcp_url(port, token)})


## Codex is TOML, not JSON, so it needs its own minimal upsert: rewrite (or append) exactly our
## [mcp_servers.beckett] table and touch nothing else — Codex users routinely keep model/approval
## settings and other MCP servers in this file. We only ever replace our own section, never
## blind-overwrite, and skip the write when it is already correct (no churn), mirroring _merge.
## Unlike JSON, a TOML file we cannot read is not backed up and rewritten: it is left exactly as
## it is and the result says why (see _toml_scan), because nothing here could rebuild it.
## `path` overrides the real config file (the unit suite writes a scratch one).
static func ensure_codex(port: int, token: String = "", path: String = "") -> Dictionary:
	if path == "":
		path = codex_config_path()
	var existed := FileAccess.file_exists(path)
	var existing := FileAccess.get_file_as_string(path) if existed else ""
	var res := _codex_upsert(existing, port, token)
	if res.has("error"):
		var lead: String
		if bool(res.get("form", false)):
			# The file reads fine, but it defines our server in a spelling this writer does not rewrite.
			lead = "%s defines the %s server in a form Beckett does not rewrite (%s)" % [path, SERVER_KEY, res["error"]]
		else:
			lead = "%s could not be read as TOML (%s)" % [path, res["error"]]
		return {"ok": false, "path": path, "error": "%s, so Beckett left it exactly as it is. Fix that, or add the [mcp_servers.%s] table by hand (the dock's Copy URL button has the endpoint), then connect again." % [lead, SERVER_KEY]}
	if not bool(res["changed"]):
		return {"ok": true, "action": "unchanged", "path": path}
	var refusal := link_refusal(path)
	if refusal != "":
		return {"ok": false, "error": refusal, "path": path}
	var w := _write_text(path, String(res["text"]))
	if not bool(w["ok"]):
		return w
	return {"ok": true, "action": ("merged" if existed else "created"), "path": path}


## Pure text transform behind ensure_codex (no file IO) — so the section-replace is unit-testable
## and provably never disturbs other tables. Rewrites exactly our [mcp_servers.<name>] table (from
## its header to the next TOML table header, as _toml_scan reads it, or EOF); everything else is
## copied verbatim. Returns {text, changed}; changed=false when our table is already present
## exactly (skip the write). A file _toml_scan cannot read, one that declares our table twice, and
## one that defines it in a form this cannot rewrite (a dotted key, an inline table or an array of
## tables: appending a [mcp_servers.beckett] header there would declare it a second time, which is
## invalid TOML and leaves Codex with no config at all) comes back as
## {text: existing, changed: false, error: why} and must not be written; `form` is true for the last
## kind, where the file reads fine.
static func _codex_upsert(existing: String, port: int, token: String = "") -> Dictionary:
	var header := "[mcp_servers.%s]" % SERVER_KEY
	# A file with Windows line endings keeps them: our table is spelled with the same ending, so one
	# that is already right compares equal (it was rewritten on every Connect) and the file stays uniform.
	var eol := "\r" if existing.contains("\r\n") else ""
	var desired: Array[String] = [header + eol, ("url = \"%s\"" % mcp_url(port, token)) + eol, "enabled = true" + eol]

	var lines: Array[String] = []
	if existing != "":
		for l in existing.split("\n"):
			lines.append(l)

	var scan := _toml_scan(lines)
	if str(scan["error"]) != "":
		return {"text": existing, "changed": false, "error": str(scan["error"])}

	# Locate our table: its header line → up to the next table header or EOF. The headers come
	# from the scan, so a "[" inside a multi-line string or array is never taken for one.
	var found := _toml_ours(scan)
	var what := header.trim_prefix("[").trim_suffix("]")
	if bool(found["array"]):
		return {"text": existing, "changed": false, "form": true, "error": "it declares %s as an array of tables ([[%s]])" % [what, what]}
	if int(found["key_line"]) != -1:
		return {"text": existing, "changed": false, "form": true, "error": "line %d defines %s with a dotted key or an inline table, and a [%s] header added beside that would declare it twice" % [found["key_line"], what, what]}
	var heads: Array = scan["headers"]
	var starts: Array = found["headers"]
	var start := -1
	var stop := lines.size()
	if starts.size() > 1:
		return {"text": existing, "changed": false, "error": "it declares [%s] more than once" % what}
	if starts.size() == 1:
		var h: int = starts[0]
		start = int((heads[h] as Dictionary)["line"])
		stop = int((heads[h + 1] as Dictionary)["line"]) if h + 1 < heads.size() else lines.size()

	var out: Array[String] = []
	if start == -1:
		out.append_array(lines)
		if not out.is_empty() and out[out.size() - 1].strip_edges() != "":
			out.append(eol)  # blank line before a fresh table
		elif eol != "" and not out.is_empty() and out[out.size() - 1] == "":
			out[out.size() - 1] = eol  # the empty piece after the last CRLF IS that blank line: keep it CRLF
		out.append_array(desired)
	else:
		if _rstrip_blanks(lines.slice(start, stop)) == desired:
			return {"text": existing, "changed": false}
		for k in start:
			out.append(lines[k])
		out.append_array(desired)
		for k in range(stop, lines.size()):
			out.append(lines[k])

	var payload := "\n".join(PackedStringArray(out))
	if not payload.ends_with("\n"):
		payload += "\n"
	return {"text": payload, "changed": true}


## A conservative structural read of a TOML file, for ONE decision: is it safe to rewrite one of
## its tables? It is not a validator (values are not type-checked). It tracks exactly what decides
## where a table begins: comments, basic and literal strings, their multi-line forms, and the
## bracket nesting of multi-line arrays and inline tables. Every line outside those must be blank,
## a comment, a table header or a `key = value` pair.
## Returns {error, headers, pairs}. `headers` lists every table header outside any string or array, in
## file order, as {line (0-based), table (name with its whitespace removed), array (a [[x]] table)}.
## `pairs` lists every `key = value` line the same way as {line (0-based), table (the header it sits
## under, "" before the first), key (the possibly dotted key with its whitespace removed)}: a dotted
## key or an inline table can define a table without any header, and _toml_ours needs to see them.
## `error` is "" for a file that reads clean and otherwise the reason (with a 1-based line number
## where there is one), in which case the caller must not rewrite the file.
## Lenient on purpose: a false refusal only costs the user one hand edit, but it must never refuse
## TOML a real parser accepts, so the bare-key rule is wider than the spec's.
static func _toml_scan(lines: Array[String]) -> Dictionary:
	const KEY := "(?:[^\\s=.\\[\\]\"'#{},]+|\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*')"
	const DOTTED := KEY + "(?:\\s*\\.\\s*" + KEY + ")*"
	var header_re := RegEx.create_from_string("^(?:\\[\\[\\s*(" + DOTTED + ")\\s*\\]\\]|\\[\\s*(" + DOTTED + ")\\s*\\])\\s*(?:#.*)?$")
	var pair_re := RegEx.create_from_string("^\\s*" + DOTTED + "\\s*=")
	var headers: Array = []
	var pairs: Array = []
	var table := ""   # the header the pairs below belong to
	var ml := ""      # inside a multi-line string: the delimiter that ends it
	var depth := 0    # [ and { still open from an earlier line of the same value
	for i in lines.size():
		var line := lines[i]
		if i == 0:
			line = line.trim_prefix(char(0xFEFF))  # a UTF-8 byte-order mark is not part of the first line
		var at := 0   # where scanning of this line's VALUE starts
		if ml == "" and depth == 0:
			var s := line.strip_edges()
			if s == "" or s.begins_with("#"):
				continue
			if s.begins_with("["):
				var hm := header_re.search(s)
				if hm == null:
					return {"error": "line %d is not a valid table header" % (i + 1), "headers": headers, "pairs": pairs}
				var name := hm.get_string(1) if hm.get_string(1) != "" else hm.get_string(2)
				table = name.replace(" ", "").replace("\t", "")
				headers.append({"line": i, "table": table, "array": s.begins_with("[[")})
				continue
			var pm := pair_re.search(line)
			if pm == null:
				return {"error": "line %d is neither a table header nor a key = value pair" % (i + 1), "headers": headers, "pairs": pairs}
			at = pm.get_end()
			pairs.append({"line": i, "table": table, "key": pm.get_string().strip_edges().trim_suffix("=").replace(" ", "").replace("\t", "")})
		var n := line.length()
		var k := at
		while k < n:
			if ml != "":
				if ml == "\"\"\"" and line[k] == "\\":
					k += 2  # an escape, so \" never closes the string
				elif line.substr(k, 3) == ml:
					var run := 3  # up to two more quotes may sit just before the closer, as content
					while k + run < n and line[k + run] == ml[0]:
						run += 1
					ml = ""
					k += run
				else:
					k += 1
				continue
			var c := line[k]
			if c == "#":
				break
			if c == "\"" or c == "'":
				if line.substr(k, 3) == c.repeat(3):
					ml = c.repeat(3)
					k += 3
					continue
				var close := k + 1
				while close < n and line[close] != c:
					close += 2 if (c == "\"" and line[close] == "\\") else 1
				if close >= n:
					return {"error": "line %d has a string that never ends" % (i + 1), "headers": headers, "pairs": pairs}
				k = close + 1
				continue
			if c == "[" or c == "{":
				depth += 1
			elif c == "]" or c == "}":
				depth -= 1
				if depth < 0:
					return {"error": "line %d closes a bracket that was never opened" % (i + 1), "headers": headers, "pairs": pairs}
			k += 1
	if ml != "":
		return {"error": "a multi-line string is never closed", "headers": headers, "pairs": pairs}
	if depth != 0:
		return {"error": "a [ or { is never closed", "headers": headers, "pairs": pairs}
	return {"error": "", "headers": headers, "pairs": pairs}


## Drop trailing all-blank lines so a section that only differs by trailing whitespace reads equal.
static func _rstrip_blanks(arr: Array[String]) -> Array[String]:
	var out: Array[String] = arr.duplicate()
	while not out.is_empty() and out[out.size() - 1].strip_edges() == "":
		out.remove_at(out.size() - 1)
	return out


## Does `path` (a TOML file) already carry our [mcp_servers.<name>] server, in any spelling a real
## parser reads the same way: a table header (bare, quoted, spaced), or a dotted key or inline table
## under [mcp_servers]? A file the scanner cannot read falls back to the two plain header spellings.
static func _toml_has_section(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var lines: Array[String] = []
	for l in FileAccess.get_file_as_string(path).split("\n"):
		lines.append(l)
	var scan := _toml_scan(lines)
	if str(scan["error"]) == "":
		var found := _toml_ours(scan)
		return not (found["headers"] as Array).is_empty() or bool(found["array"]) or bool(found["by_key"])
	for l in lines:
		var s := l.strip_edges()
		if s == "[mcp_servers.%s]" % SERVER_KEY or s == "[mcp_servers.\"%s\"]" % SERVER_KEY:
			return true
	return false


## The parts of a dotted TOML name the way a real parser reads them: split at the dots that sit
## outside quotes, a quoted part unquoted (`"beckett"`, `'beckett'` and `"beckett"` all read
## beckett), a bare part as it is. The whitespace around the dots is already gone (see _toml_scan).
static func _toml_parts(name: String) -> PackedStringArray:
	var parts := PackedStringArray()
	if name.is_empty():
		return parts
	var cur := ""
	var i := 0
	var n := name.length()
	while i < n:
		var c := name[i]
		if c == "\"":
			i += 1
			while i < n and name[i] != "\"":
				if name[i] == "\\" and i + 1 < n:
					var e := name[i + 1]
					i += 2
					match e:
						"b": cur += char(8)
						"t": cur += "\t"
						"n": cur += "\n"
						"f": cur += char(12)
						"r": cur += "\r"
						"u", "U":
							var hex := name.substr(i, 4 if e == "u" else 8)
							i += hex.length()
							var code := hex.hex_to_int() if hex.is_valid_hex_number() else -1
							if code > 0 and code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF):
								cur += char(code)
						_:
							cur += e
				else:
					cur += name[i]
					i += 1
			i += 1  # the closing quote
		elif c == "'":
			var close := name.find("'", i + 1)
			if close == -1:
				close = n
			cur += name.substr(i + 1, close - i - 1)
			i = close + 1
		elif c == ".":
			parts.append(cur)
			cur = ""
			i += 1
		else:
			cur += c
			i += 1
	parts.append(cur)
	return parts


## How a scanned file defines our table, [mcp_servers.<name>]:
##   headers   indexes (into scan.headers) of its plain table headers, in file order;
##   array     true when it is declared as an array of tables, [[mcp_servers.<name>]];
##   key_line  the 1-based line of the first dotted key or inline table that defines it, or the whole
##             of mcp_servers, without a header of its own (`[mcp_servers]` then `beckett.url = ".."`,
##             `beckett = { url = ".." }`, a top-level `mcp_servers.beckett.url = ".."` or
##             `mcp_servers = { .. }`), or -1. A header added beside one of these would declare the
##             table twice;
##   by_key    true when that definition is OUR server's (the others only make mcp_servers a value).
## Names are compared as parts (see _toml_parts), so `mcp_servers . "beckett"` counts. A key that
## sits under our own header is that table's ordinary content and is not a definition of it.
static func _toml_ours(scan: Dictionary) -> Dictionary:
	var out := {"headers": [], "array": false, "key_line": -1, "by_key": false}
	var heads: Array = scan["headers"]
	for h in heads.size():
		var ent: Dictionary = heads[h]
		var t := _toml_parts(str(ent["table"]))
		if t.size() == 2 and t[0] == "mcp_servers" and t[1] == SERVER_KEY:
			if bool(ent["array"]):
				out["array"] = true
			else:
				(out["headers"] as Array).append(h)
	for p in scan["pairs"]:
		var under := _toml_parts(str((p as Dictionary)["table"]))
		if under.size() >= 2 and under[0] == "mcp_servers" and under[1] == SERVER_KEY:
			continue
		var full := under.duplicate()
		full.append_array(_toml_parts(str((p as Dictionary)["key"])))
		var ours := full.size() >= 2 and full[0] == "mcp_servers" and full[1] == SERVER_KEY
		if ours or (full.size() == 1 and full[0] == "mcp_servers"):
			out["key_line"] = int((p as Dictionary)["line"]) + 1
			out["by_key"] = ours
			break
	return out


## Make `dir_name` under `root` if it is not there yet (the project writers need .cursor / .vscode).
static func _mkdir(root: String, dir_name: String) -> void:
	var dir := root.path_join(dir_name)
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


## What a config file's JSON text says, for the writers that rewrite the file around our entry, or
## null when it is not JSON. It exists because the engine's own JSON.parse_string / stringify pair
## damages what it round-trips, and a merge must hand every other server and key back as it found them:
##  - it reads EVERY number as a float, and stringify writes a whole float with a ".0", so a user's
##    `"timeout": 30000` came back `30000.0`, which a client that reads it into an integer (Go, Rust)
##    rejects. Whole numbers are therefore protected as integers across the parse (see _protect_ints);
##  - it refuses a UTF-8 byte-order mark, which Windows editors add, so a hand-edited config read as
##    unparseable and was moved aside for a rewrite from nothing. The mark is dropped before parsing;
##  - parse_string prints an engine error for every failure, and the dock re-reads these files on a
##    2-second tick, so a config with a comment in it filled the Output panel. JSON.new().parse is silent.
## `whole_numbers` false skips the integer protection, for a caller that only LOOKS at the file (the
## dock's detection tick re-reads these every 2 seconds and never writes them back).
static func _json_read(text: String, whole_numbers := true) -> Variant:
	var json := JSON.new()
	var src := text.trim_prefix(char(0xFEFF))
	if json.parse(_protect_ints(src) if whole_numbers else src) != OK:
		return null
	return _restore_ints(json.data) if whole_numbers else json.data


## The text of `data` for a config file: two-space indent, keys in the order the file (and this
## writer) put them in, instead of stringify's default alphabetical re-sort of everything.
static func _json_write(data: Variant) -> String:
	return JSON.stringify(data, "  ", false, true)


## `text` with every bare integer token (outside strings) replaced by a tagged string, so the
## parser cannot turn it into a float. Only whole-number tokens are touched; 1.5, 1e3 and anything
## that is not valid JSON stay exactly as they were, and the parser judges them as before.
static func _protect_ints(text: String) -> String:
	var parts := PackedStringArray()
	var n := text.length()
	var i := 0
	var copied := 0     # text[0:copied] is already in `parts`
	var in_string := false
	while i < n:
		var c := text[i]
		if in_string:
			if c == "\\":
				i += 2
				continue
			if c == "\"":
				in_string = false
		elif c == "\"":
			in_string = true
		elif c == "-" or (c >= "0" and c <= "9"):
			var j := i + 1
			while j < n and "0123456789.eE+-".contains(text[j]):
				j += 1
			var token := text.substr(i, j - i)
			if _is_plain_int(token):
				parts.append(text.substr(copied, i - copied))
				parts.append("\"" + _INT_TAG_ESCAPED + token + "\"")
				copied = j
			i = j
			continue
		i += 1
	parts.append(text.substr(copied))
	return "".join(parts)


## Is `token` JSON's spelling of a whole number: an optional minus and digits, with no leading zero
## (a leading zero is not JSON, so it is left for the parser to refuse)?
static func _is_plain_int(token: String) -> bool:
	var digits := token.trim_prefix("-")
	if digits.is_empty() or (digits.length() > 1 and digits[0] == "0"):
		return false
	for k in digits.length():
		if digits[k] < "0" or digits[k] > "9":
			return false
	return true


## Undo _protect_ints on a parsed value. A whole number that does not fit in 64 bits stays a float, as
## the engine would have read it, instead of overflowing into a wrong integer.
static func _restore_ints(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d:
			d[k] = _restore_ints(d[k])
		return d
	if v is Array:
		var a: Array = v
		for i in a.size():
			a[i] = _restore_ints(a[i])
		return a
	if v is String and (v as String).begins_with(_INT_TAG):
		var token := (v as String).substr(_INT_TAG.length())
		var whole := token.to_int()
		# to_int wraps around on overflow instead of failing, so the digits have to read back the same.
		return whole if str(whole) == token or token == "-0" else token.to_float()
	return v


static func _merge(path: String, root_key: String, ent: Dictionary) -> Dictionary:
	var data: Dictionary = {}
	var existed := FileAccess.file_exists(path)
	var unreadable := ""  # the file's own text, when it exists but is not valid JSON
	if existed:
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = _json_read(text)
		if parsed is Dictionary:
			data = parsed
		elif text.strip_edges() != "":
			# The file exists with content but isn't parseable JSON. Overwriting blind
			# would silently drop whatever it held (possibly other MCP servers), so stash
			# a recoverable backup before we rewrite — never destroy unparseable config.
			unreadable = text
	if not (data.get(root_key) is Dictionary):
		data[root_key] = {}
	# Already correct? Skip the write to avoid churn.
	var cur: Variant = data[root_key].get(SERVER_KEY)
	if cur is Dictionary and JSON.stringify(cur) == JSON.stringify(ent):
		return {"ok": true, "action": "unchanged", "path": path}
	# A write is needed. Refuse a link BEFORE the backup, or a refusal would still leave a stray
	# sidecar beside the link.
	var refusal := link_refusal(path)
	if refusal != "":
		return {"ok": false, "error": refusal, "path": path}
	var backup := _backup_unparseable(path, unreadable) if unreadable != "" else ""
	data[root_key][SERVER_KEY] = ent
	var w := _write_text(path, _json_write(data))
	if not bool(w["ok"]):
		return w
	if Engine.is_editor_hint() and path.begins_with("res://"):
		EditorInterface.get_resource_filesystem().update_file(path)
	var result := {"ok": true, "action": ("merged" if existed else "created"), "path": path}
	if backup != "":
		# Surface the salvage so the panel/log can warn instead of swallowing data loss.
		result["action"] = "rewritten"
		result["warning"] = "previous file was not valid JSON; backed up to " + backup
		result["backup"] = backup
	return result


## Like _merge, but field-merges `fields` INTO the existing server entry instead of replacing
## it whole — so user-managed keys on that entry (Cline's `autoApprove` / `disabled` / `timeout`)
## survive a re-Connect. Also creates the target dir (Cline's settings dir may not exist yet).
## Writes a global path outside res://, so no EditorFilesystem refresh.
static func _merge_into_entry(path: String, root_key: String, fields: Dictionary) -> Dictionary:
	var data: Dictionary = {}
	var existed := FileAccess.file_exists(path)
	var unreadable := ""
	if existed:
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = _json_read(text)
		if parsed is Dictionary:
			data = parsed
		elif text.strip_edges() != "":
			unreadable = text
	if not (data.get(root_key) is Dictionary):
		data[root_key] = {}
	var cur: Variant = data[root_key].get(SERVER_KEY)
	var ent: Dictionary = (cur as Dictionary).duplicate() if cur is Dictionary else {}
	var changed := false
	for k in fields:
		if not ent.has(k) or JSON.stringify(ent[k]) != JSON.stringify(fields[k]):
			ent[k] = fields[k]
			changed = true
	# Already correct (and nothing to salvage)? Skip the write to avoid churn.
	if not changed and unreadable == "":
		return {"ok": true, "action": "unchanged", "path": path}
	var refusal := link_refusal(path)
	if refusal != "":
		return {"ok": false, "error": refusal, "path": path}
	var backup := _backup_unparseable(path, unreadable) if unreadable != "" else ""
	data[root_key][SERVER_KEY] = ent
	var w := _write_text(path, _json_write(data))
	if not bool(w["ok"]):
		return w
	var result := {"ok": true, "action": ("merged" if existed else "created"), "path": path}
	if backup != "":
		result["action"] = "rewritten"
		result["warning"] = "previous file was not valid JSON; backed up to " + backup
		result["backup"] = backup
	return result


## The existing config wasn't valid JSON. Copy it verbatim to a timestamped sidecar so a
## hand-clobbered or corrupted file (e.g. other MCP servers) stays recoverable. Returns the
## backup path, or "" if the copy itself failed (in which case the caller still proceeds).
static func _backup_unparseable(path: String, text: String) -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "-")
	var bak := "%s.invalid-%s.bak" % [path, stamp]
	# The copy takes the mode of the file it copies: that file may hold other servers' keys (0600).
	if not bool(_write_text(bak, text, path)["ok"]):
		return ""
	if Engine.is_editor_hint() and bak.begins_with("res://"):
		EditorInterface.get_resource_filesystem().update_file(bak)
	return bak


## The ONE place a client config reaches disk: refuse a link, then replace the target atomically.
## The new text goes to a sibling temp file and is renamed over the target, so a crash, a full disk
## or a second writer leaves either the old file or the new one, never a truncated one (the old
## in-place write truncated first). A rename gives the file the DEFAULT mode, and a config that
## holds a token or key is often 0600, so the old mode is carried over before any text is written
## (see _carry_mode); and a read-only target stays unwritten, which an in-place write refused by
## itself and a rename would not. Failure comes back as {ok: false, error} in plain words; on every
## failure the target is unchanged, and the new text survives in the temp file only when the target
## no longer exists. `mode_from` is the file whose mode the new one takes when that is not `path`
## itself (a backup copy takes the mode of the file it is a copy of).
static func _write_text(path: String, text: String, mode_from: String = "") -> Dictionary:
	var refusal := link_refusal(path)
	if refusal != "":
		return {"ok": false, "error": refusal, "path": path}
	var existed := FileAccess.file_exists(path)
	if existed and _is_read_only(path):
		return {"ok": false, "error": "%s is read-only, so Beckett did not change it. Clear the read-only flag (or add the beckett entry by hand), then connect again." % path, "path": path}
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp := path + TMP_SUFFIX
	# A temp left by a crashed run is simply replaced. A LINK at that name (planted in a repository,
	# or left dangling) would be written THROUGH by the open below, so whatever sits there goes first.
	if FileAccess.file_exists(tmp) or _is_link(tmp):
		DirAccess.remove_absolute(tmp)
	# WRITE_READ, not WRITE: inside the editor a plain WRITE open is turned into the engine's own safe
	# save (the bytes go to a hidden "name-XXXXXX" file, which only becomes `tmp` when the file is
	# closed), so `tmp` would not exist yet for the mode below to be set on, and the new file would
	# come out at the default mode (0644: the old 0600 of a token-carrying config, lost). The
	# read-write mode is not rewritten that way: `tmp` is the file being written, from the first byte.
	# This function is the safe save here, so nothing is lost by it.
	var f := FileAccess.open(tmp, FileAccess.WRITE_READ)
	if f == null:
		return {"ok": false, "error": "could not create %s (%s); %s was not changed." % [tmp, error_string(FileAccess.get_open_error()), path], "path": path}
	var wider := _carry_mode(mode_from if mode_from != "" else path, tmp)
	if wider != "":
		f.close()
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": wider, "path": path}
	f.store_string(text)
	var wrote := f.get_error() == OK
	f.close()
	if not wrote:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "could not write %s (is the disk full?); %s was not changed." % [tmp, path], "path": path}
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		err = _swap_in(tmp, path)
	if err == OK:
		return {"ok": true, "path": path}
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "could not replace %s (is another program holding it open?); it was not changed." % path, "path": path}
	return {"ok": false, "error": "could not move the new %s into place; its new content is saved as %s." % [path, tmp], "path": path}


## Give `tmp` (just created, still empty) the permission bits of `from` on Unix-likes, before any text
## goes into it; Windows has no mode bits, and a `from` that does not exist is a brand-new file at the
## default mode. A config that holds a token or a key is often 0600. "" when it is done or there is
## nothing to do; otherwise the reason it could not be, in plain words, because a replacement that
## ends up readable by MORE users than the file it replaces would publish what the old one kept
## private. A filesystem with no real modes (FAT) cannot narrow anything, but it cannot widen either:
## the old file read the same way, so that is not a refusal.
static func _carry_mode(from: String, tmp: String) -> String:
	if OS.get_name() == "Windows" or not FileAccess.file_exists(from):
		return ""
	var want: int = FileAccess.get_unix_permissions(from) & 0x1FF
	FileAccess.set_unix_permissions(tmp, want)
	var got: int = FileAccess.get_unix_permissions(tmp) if FileAccess.file_exists(tmp) else 0x1FF
	if not _mode_is_wider(got, want):
		return ""
	return "could not give the new %s the permissions of %s (%o): it would be readable by more users than the file it replaces, so nothing was changed. Fix the permissions of the file, or add the beckett entry by hand, then connect again." % [tmp.trim_suffix(TMP_SUFFIX), from, want]


## Does mode `got` grant any of the nine rwx bits that mode `want` withholds?
static func _mode_is_wider(got: int, want: int) -> bool:
	return ((got & 0x1FF) & ~(want & 0x1FF)) != 0


## The fallback for _write_text when renaming straight over the target fails: move the target
## aside, move the new file in, and put the target back if that second move fails. It exists
## because of how the engine renames over an existing file: DirAccess.rename_absolute replaces it
## on every engine and OS we ran it on (Windows included: 4.4.1, 4.6.2, 4.7), but on Windows by
## DELETING the destination first, so a move that then fails would cost the original. Moving the
## target aside first never leaves a moment where the original exists nowhere. Returns an Error.
static func _swap_in(tmp: String, path: String) -> int:
	var old := path + OLD_SUFFIX
	var had := FileAccess.file_exists(path)
	if had:
		if FileAccess.file_exists(old):
			DirAccess.remove_absolute(old)  # a leftover from an earlier crash; the target is still here
		var aside := DirAccess.rename_absolute(path, old)
		if aside != OK:
			return aside  # held open by another program: the original never moved
	var moved := DirAccess.rename_absolute(tmp, path)
	if moved != OK:
		if had:
			DirAccess.rename_absolute(old, path)
		return moved
	if had:
		DirAccess.remove_absolute(old)
	return OK


## Why `path` must not be written through, in plain words, or "" when it may be. A symbolic link
## can point anywhere (a repository can ship `.mcp.json` as a link to a file in someone's home),
## and a write that follows it lands there, so the file itself is never written through a link.
## The folder holding it is checked too: `~/.codex` as a link is the same redirection one level up,
## and so is a `.cursor` or `.vscode` folder of the project that is a link. For a file inside the
## project, EVERY folder between the project root and the file is looked at. The project root itself
## is not checked, because a project that lives behind a link or a mapped drive is ordinary, and for
## a global file only the folder that holds it is (a dotfile manager that links a whole parent such
## as ~/.config is not refused). DirAccess.is_link covers symlinks, directory junctions and the
## other reparse points, on Windows, macOS and Linux.
static func link_refusal(path: String) -> String:
	var os_path := ProjectSettings.globalize_path(path)
	var linked := linked_part(path)
	if linked.is_empty():
		return ""
	if linked == os_path:
		return "%s is a symbolic link, so Beckett did not write through it (a link can point anywhere). Replace it with a regular file, or add the beckett entry by hand, then connect again." % os_path
	return "%s is a symbolic link or junction, so Beckett did not write inside it (a link can point anywhere). Add the beckett entry to %s by hand, or replace the link with a real folder, then connect again." % [linked, os_path.get_file()]


## The first link a write to (or a read of) `path` would pass through, as an OS path: the file itself,
## else the folder that holds it (for a file inside the project, the outermost such folder below the
## project root); "" when there is none. The rule behind link_refusal, and the one the auth token
## (res://.beckett/token, read, chmod-ed and rewritten by mcp_server.gd) is held to as well.
static func linked_part(path: String) -> String:
	var os_path := ProjectSettings.globalize_path(path)
	if _is_link(os_path):
		return os_path
	if path.begins_with("res://"):
		var cur := "res://"
		for seg in path.trim_prefix("res://").get_base_dir().split("/", false):
			cur = cur.path_join(seg)
			if _is_link(cur):
				return ProjectSettings.globalize_path(cur)
	elif _is_link(os_path.get_base_dir()):
		return os_path.get_base_dir()
	return ""


## Is `path` itself a link? A path that does not exist is not a link. The probe itself lives in
## path_guard.gd (is_link_path), which the read and write confinement uses as well: it reaches
## DirAccess.is_link by name (has_method / call) because that method only exists from Godot 4.3, and
## this script is loaded on every engine the addon supports, 4.2 included, where naming it would be a
## parse error that stops the whole plugin. An engine without it can report no link at all, which is
## what the writers did before links were looked at.
static func _is_link(path: String) -> bool:
	return PathGuardScript.is_link_path(ProjectSettings.globalize_path(path))


## A file the user (or the OS) marked read-only: the Windows/macOS flag, or no owner-write bit.
static func _is_read_only(path: String) -> bool:
	if FileAccess.get_read_only_attribute(path):
		return true
	return OS.get_name() != "Windows" and (FileAccess.get_unix_permissions(path) & FileAccess.UNIX_WRITE_OWNER) == 0
