@tool
extends RefCounted
class_name BeckettClientConfig

## One-click client setup (onboarding moat). Writes/merges MCP client config files in the
## project so an agent connects with zero hand-editing. Merge-not-clobber: never touches
## other servers, and skips writing when the entry is already correct (no VCS churn).
##
## Transport is MCP Streamable HTTP, so any HTTP-capable MCP client connects directly.
## stdio-only clients (e.g. Claude Desktop) bridge via `npx mcp-remote <url>`.

const SERVER_KEY := "beckett"


static func entry(port: int) -> Dictionary:
	return {"type": "http", "url": "http://127.0.0.1:%d/mcp" % port}


## stdio bridge for clients that can't speak HTTP directly (Claude Desktop, etc.).
static func desktop_entry(port: int) -> Dictionary:
	return {"command": "npx", "args": ["mcp-remote", "http://127.0.0.1:%d/mcp" % port]}


static func config_json(port: int) -> String:
	return JSON.stringify({"mcpServers": {SERVER_KEY: entry(port)}}, "  ")


## Snippet for Claude Desktop's claude_desktop_config.json (global; user pastes it).
static func desktop_json(port: int) -> String:
	return JSON.stringify({"mcpServers": {SERVER_KEY: desktop_entry(port)}}, "  ")


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
static func cline_entry(port: int) -> Dictionary:
	return {"url": "http://127.0.0.1:%d/mcp" % port, "type": "streamableHttp"}


## Does `path`'s config already carry our server entry (any port)?
static func _configured(path: String, root_key: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
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
			"configured": _configured("res://.vscode/mcp.json", "servers")},
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
		{"id": "gemini_cli", "name": "Gemini CLI",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".gemini")),
			"configured": _configured(gemini_config_path(), "mcpServers")},
		{"id": "antigravity", "name": "Antigravity",
			"installed": DirAccess.dir_exists_absolute(_home().path_join(".gemini/config")) \
				or DirAccess.dir_exists_absolute(_home().path_join(".gemini/antigravity")),
			"configured": _configured(antigravity_config_path(), "mcpServers")},
	]


# ---------------------------------------------------------------- one-shot connect

## Zero-click path (plugin start): project `.mcp.json` always; Cursor / VS Code only
## when that app exists on this machine (so we never drop a junk config dir into a
## project for an editor the user doesn't have). Claude Desktop is NOT auto-written —
## it's a global file and its entry needs an `npx` bridge (Node.js); see ensure_all.
static func ensure_auto(port: int) -> Array:
	var out: Array = []
	out.append(_tag("Claude Code", ensure_mcp_json(port)))
	if DirAccess.dir_exists_absolute(_home().path_join(".cursor")):
		out.append(_tag("Cursor", ensure_cursor(port)))
	if DirAccess.dir_exists_absolute(_appdata_dir("Code")):
		out.append(_tag("VS Code", ensure_vscode(port)))
	return out


## The panel's one-button connect: everything ensure_auto covers PLUS the global configs
## (Cline's globalStorage, Claude Desktop) when those apps are installed — merge-not-clobber,
## same as the rest. These are outside the project, so they're button-only (never auto).
static func ensure_all(port: int) -> Array:
	var out := ensure_auto(port)
	if DirAccess.dir_exists_absolute(_cline_storage_dir()):
		out.append(_tag("VS Code (Cline)", ensure_cline(port)))
	if DirAccess.dir_exists_absolute(_appdata_dir("Claude")):
		out.append(_tag("Claude Desktop", _merge(desktop_config_path(), "mcpServers", desktop_entry(port))))
	# Home-dir clients (Codex / Windsurf / Gemini CLI / Antigravity): global configs like Cline
	# & Desktop, so button-only (never auto). Each gated on its own dir so we don't seed a config
	# for a client the user doesn't have.
	if DirAccess.dir_exists_absolute(_home().path_join(".codex")):
		out.append(_tag("Codex", ensure_codex(port)))
	if DirAccess.dir_exists_absolute(_home().path_join(".codeium/windsurf")):
		out.append(_tag("Windsurf", ensure_windsurf(port)))
	if DirAccess.dir_exists_absolute(_home().path_join(".gemini")):
		out.append(_tag("Gemini CLI", ensure_gemini(port)))
	if DirAccess.dir_exists_absolute(_home().path_join(".gemini/config")) \
			or DirAccess.dir_exists_absolute(_home().path_join(".gemini/antigravity")):
		out.append(_tag("Antigravity", ensure_antigravity(port)))
	return out


static func _tag(client_name: String, r: Dictionary) -> Dictionary:
	r["name"] = client_name
	return r


# Claude Code: res://.mcp.json   (key "mcpServers")
static func ensure_mcp_json(port: int) -> Dictionary:
	return _merge("res://.mcp.json", "mcpServers", entry(port))


# Cursor / Windsurf: res://.cursor/mcp.json   (key "mcpServers")
static func ensure_cursor(port: int) -> Dictionary:
	_mkdir(".cursor")
	return _merge("res://.cursor/mcp.json", "mcpServers", entry(port))


# VS Code (Copilot / VS Code-native): res://.vscode/mcp.json   (key "servers", not "mcpServers")
static func ensure_vscode(port: int) -> Dictionary:
	_mkdir(".vscode")
	return _merge("res://.vscode/mcp.json", "servers", entry(port))


# Cline: its global cline_mcp_settings.json (key "mcpServers"). Field-merge so the user's
# autoApprove/disabled/timeout on our entry survive a re-Connect — see _merge_into_entry.
static func ensure_cline(port: int) -> Dictionary:
	return _merge_into_entry(cline_settings_path(), "mcpServers", cline_entry(port))


# ---------------------------------------------------------------- home-dir clients
# Codex / Windsurf / Gemini CLI / Antigravity all keep a GLOBAL config under the user's home
# (not the project), so — like Cline / Claude Desktop — they're button-only via ensure_all,
# never auto-written on plugin start. Paths + URL-field names below are each client's own
# schema (not interchangeable): Windsurf/Antigravity use `serverUrl`, Gemini CLI uses `httpUrl`,
# Codex is TOML with a `url`. The three JSON ones reuse _merge_into_entry (creates the dir,
# field-merges, preserves user-set keys, backs up unparseable files).

static func windsurf_config_path() -> String:
	return _home().path_join(".codeium/windsurf/mcp_config.json")


static func gemini_config_path() -> String:
	return _home().path_join(".gemini/settings.json")


static func antigravity_config_path() -> String:
	return _home().path_join(".gemini/config/mcp_config.json")


static func codex_config_path() -> String:
	return _home().path_join(".codex/config.toml")


# Windsurf speaks Streamable HTTP through a `serverUrl` field (not `url`).
static func ensure_windsurf(port: int) -> Dictionary:
	return _merge_into_entry(windsurf_config_path(), "mcpServers", {"serverUrl": "http://127.0.0.1:%d/mcp" % port})


# Gemini CLI keys a streamable-HTTP server under `httpUrl`.
static func ensure_gemini(port: int) -> Dictionary:
	return _merge_into_entry(gemini_config_path(), "mcpServers", {"httpUrl": "http://127.0.0.1:%d/mcp" % port})


# Antigravity (Google's agentic IDE) shares Gemini's tree but under config/, and uses `serverUrl`
# like Windsurf. We leave `disabled` unset — absent == enabled — so re-Connect never stomps a
# user who toggled the server off in the UI.
static func ensure_antigravity(port: int) -> Dictionary:
	return _merge_into_entry(antigravity_config_path(), "mcpServers", {"serverUrl": "http://127.0.0.1:%d/mcp" % port})


## Codex is TOML, not JSON, so it needs its own minimal upsert: rewrite (or append) exactly our
## [mcp_servers.beckett] table and touch nothing else — Codex users routinely keep model/approval
## settings and other MCP servers in this file. We only ever replace our own section, never
## blind-overwrite, and skip the write when it is already correct (no churn), mirroring _merge.
static func ensure_codex(port: int) -> Dictionary:
	var path := codex_config_path()
	var existed := FileAccess.file_exists(path)
	var existing := FileAccess.get_file_as_string(path) if existed else ""
	var res := _codex_upsert(existing, port)
	if not bool(res["changed"]):
		return {"ok": true, "action": "unchanged", "path": path}
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": error_string(FileAccess.get_open_error()), "path": path}
	f.store_string(String(res["text"]))
	f.close()
	return {"ok": true, "action": ("merged" if existed else "created"), "path": path}


## Pure text transform behind ensure_codex (no file IO) — so the section-replace is unit-testable
## and provably never disturbs other tables. Rewrites exactly our [mcp_servers.<name>] table (from
## its header to the next TOML header or EOF); everything else is copied verbatim. Returns
## {text, changed}; changed=false when our table is already present exactly (skip the write).
static func _codex_upsert(existing: String, port: int) -> Dictionary:
	var header := "[mcp_servers.%s]" % SERVER_KEY
	var desired: Array[String] = [header, "url = \"http://127.0.0.1:%d/mcp\"" % port, "enabled = true"]

	var lines: Array[String] = []
	if existing != "":
		for l in existing.split("\n"):
			lines.append(l)

	# Locate our table: header line → up to the next TOML header (a line starting with "[") or EOF.
	var start := -1
	for i in lines.size():
		var s := lines[i].strip_edges()
		if s == header or s == "[mcp_servers.\"%s\"]" % SERVER_KEY:
			start = i
			break

	var out: Array[String] = []
	if start == -1:
		out.append_array(lines)
		if not out.is_empty() and out[out.size() - 1].strip_edges() != "":
			out.append("")  # blank line before a fresh table
		out.append_array(desired)
	else:
		var stop := lines.size()
		for j in range(start + 1, lines.size()):
			if lines[j].strip_edges().begins_with("["):
				stop = j
				break
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


## Drop trailing all-blank lines so a section that only differs by trailing whitespace reads equal.
static func _rstrip_blanks(arr: Array[String]) -> Array[String]:
	var out: Array[String] = arr.duplicate()
	while not out.is_empty() and out[out.size() - 1].strip_edges() == "":
		out.remove_at(out.size() - 1)
	return out


## Does `path` (a TOML file) already declare our [mcp_servers.<name>] table (quoted or bare)?
static func _toml_has_section(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	for l in FileAccess.get_file_as_string(path).split("\n"):
		var s := l.strip_edges()
		if s == "[mcp_servers.%s]" % SERVER_KEY or s == "[mcp_servers.\"%s\"]" % SERVER_KEY:
			return true
	return false


static func _mkdir(dir_name: String) -> void:
	var d := DirAccess.open("res://")
	if d != null and not d.dir_exists(dir_name):
		d.make_dir(dir_name)


static func _merge(path: String, root_key: String, ent: Dictionary) -> Dictionary:
	var data: Dictionary = {}
	var existed := FileAccess.file_exists(path)
	var backup := ""
	if existed:
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			data = parsed
		elif text.strip_edges() != "":
			# The file exists with content but isn't parseable JSON. Overwriting blind
			# would silently drop whatever it held (possibly other MCP servers), so stash
			# a recoverable backup before we rewrite — never destroy unparseable config.
			backup = _backup_unparseable(path, text)
	if not (data.get(root_key) is Dictionary):
		data[root_key] = {}
	# Already correct? Skip the write to avoid churn.
	var cur: Variant = data[root_key].get(SERVER_KEY)
	if cur is Dictionary and JSON.stringify(cur) == JSON.stringify(ent):
		return {"ok": true, "action": "unchanged", "path": path}
	data[root_key][SERVER_KEY] = ent
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": error_string(FileAccess.get_open_error()), "path": path}
	f.store_string(JSON.stringify(data, "  "))
	f.close()
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
	var backup := ""
	if existed:
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			data = parsed
		elif text.strip_edges() != "":
			backup = _backup_unparseable(path, text)
	else:
		var dir := path.get_base_dir()
		if dir != "" and not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
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
	if not changed and backup == "":
		return {"ok": true, "action": "unchanged", "path": path}
	data[root_key][SERVER_KEY] = ent
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": error_string(FileAccess.get_open_error()), "path": path}
	f.store_string(JSON.stringify(data, "  "))
	f.close()
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
	var f := FileAccess.open(bak, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(text)
	f.close()
	if Engine.is_editor_hint() and bak.begins_with("res://"):
		EditorInterface.get_resource_filesystem().update_file(bak)
	return bak
