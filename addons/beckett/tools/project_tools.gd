@tool
extends RefCounted
class_name BeckettProjectTools

## Filesystem + project settings (P0). Generic file IO (any text file, not just scripts),
## content search, and project-setting read/write.

var server

const _TEXT_EXTS := ["gd", "tscn", "tres", "cfg", "json", "md", "txt", "gdshader", "shader", "cs", "import", "godot"]
const MCPClientConfigScript := preload("res://addons/beckett/core/client_config.gd")
const InputCodecScript := preload("res://addons/beckett/runtime/input_codec.gd")  # device-id probe for doctor
const MCPEffortScript := preload("res://addons/beckett/core/effort.gd")            # tier names for doctor's context block
const RuntimeBridgeScript := preload("res://addons/beckett/core/runtime_bridge.gd")  # static game-view probe for doctor

## Opt-in: reload a scene the editor has open after we overwrite its file on disk.
## Default FALSE on purpose. Scripts have an editor setting for this and it defaults on,
## but Godot has NO equivalent for scenes, and it also exposes no way to ask whether an
## open scene holds unsaved human edits — so an automatic reload can silently discard
## someone's work. That is the same class of quiet data loss this release spent its time
## removing, so the safe default wins and the project opts in deliberately.
const AUTO_RELOAD_SCENES := "beckett/auto_reload_scenes"


## Tell the editor a file changed underneath it, and return an honest note about anything
## the change is still WAITING on. Shared by every core write path (write_file,
## apply_template) so the behaviour cannot drift between them.
static func sync_written_file(path: String) -> String:
	if not Engine.is_editor_hint() or not path.begins_with("res://"):
		return ""
	var is_scene := path.ends_with(".tscn") or path.ends_with(".scn")
	if is_scene and EditorInterface.get_open_scenes().has(path):
		# DO NOT call update_file here. Telling EditorFileSystem that a CURRENTLY OPEN scene
		# changed drags the editor into its external-change handling from inside our
		# synchronous handler, and the editor never comes back: the tool call never answers
		# and the whole MCP server is wedged until the editor is killed. Reproduced on
		# 4.6.2 (headless) and confirmed pre-existing — it is not the reload feature below,
		# it is the plain update_file that every write already did.
		if bool(ProjectSettings.get_setting(AUTO_RELOAD_SCENES, false)):
			# Deferred so the reload runs on a later frame, AFTER this response is sent.
			EditorInterface.call_deferred("reload_scene_from_path", path)
			return " (that scene is open in the editor; queued a reload of it)"
		return (" NOTE: that scene is OPEN in the editor, so the editor still holds the OLD"
			+ " version and saving from the editor would overwrite what was just written."
			+ " Reopen it, or set beckett/auto_reload_scenes=true to reload it automatically"
			+ " (off by default: Godot cannot report whether an open scene has unsaved edits,"
			+ " so reloading may discard them). Better still, edit scenes with the scene tools"
			+ " (create_node / set_property / save_scene) instead of writing .tscn text.")
	EditorInterface.get_resource_filesystem().update_file(path)
	return ""


func _register(registry) -> void:
	registry.register({
		"name": "read_file",
		"description": "Read a text file by res:// (or user://) path.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		"handler": Callable(self, "_read_file"),
	})
	registry.register({
		"name": "write_file",
		"description": "Write a text file under res:// (or user://), path-traversal guarded. Refreshes the editor filesystem. If the file is a .tscn the editor currently has OPEN, the result says so: Godot prompts the human to reload it and until they do the editor still holds the old version (scripts have no such problem, the editor auto-reloads them). Set beckett/auto_reload_scenes=true to reload open scenes automatically. Prefer the scene tools (create_node / set_property / save_scene) over writing .tscn text at all - editor-side edits never go stale.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "content": {"type": "string"},
		}, "required": ["path", "content"]},
		"handler": Callable(self, "_write_file"),
	})
	registry.register({
		"name": "list_dir",
		"description": "List entries (dirs + files) of a res:// directory.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {"path": {"type": "string"}}},
		"handler": Callable(self, "_list_dir"),
	})
	registry.register({
		"name": "search_files",
		"description": "Search file contents under res:// for a substring (or regex with regex=true). Returns file:line matches.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string"}, "ext": {"type": "string", "description": "restrict to one extension, e.g. gd"},
			"regex": {"type": "boolean"}, "max": {"type": "integer"},
		}, "required": ["query"]},
		"handler": Callable(self, "_search_files"),
	})
	registry.register({
		"name": "get_project_setting",
		"description": "Read a ProjectSettings value by its property path (e.g. application/run/main_scene). Pass it as 'setting' ('name' is also accepted).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"setting": {"type": "string"}, "name": {"type": "string"},
		}},
		"handler": Callable(self, "_get_setting"),
	})
	registry.register({
		"name": "set_project_setting",
		"description": "Set a ProjectSettings value and persist project.godot. The property path goes in 'setting' ('name' is also accepted); e.g. set application/run/main_scene to res://main.tscn.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"setting": {"type": "string"}, "name": {"type": "string"}, "value": {},
		}, "required": ["value"]},
		"handler": Callable(self, "_set_setting"),
	})
	registry.register({
		"name": "doctor",
		"description": "Beckett self-diagnosis — one call answers 'why can't the agent see or do X?'. Reports: edition (Lite/Full), the effort dial vs its ceiling AND where the cap comes from (a beckett/effort= line committed in project.godot silently trims every clone's tool list), advertised-vs-ceiling tool counts, dock-disabled tools, server/port/auth state, per-client config freshness (does each written config still carry the CURRENT endpoint URL?), runtime-bridge liveness, what this tool surface costs your context (exact tools/list bytes and approximate tokens for every effort tier, measured on THIS install, so you can price a tier before dialing to it), whether the game plays EMBEDDED in the editor's Game workspace or in its own window (embedded means the Suspend button freezes every runtime call and window-mode asserts can never pass), and whether the editor auto-reloads externally-changed scripts (off = every script this server writes waits behind a modal the human must click). Run this FIRST when tools seem missing, counts look wrong, or calls fail unexpectedly.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_doctor"),
	})
	# NOTE: logs_read (L3) lives in test_tools.gd — premium modules keep ALL their
	# code out of the Lite build; nothing tier-3+ may be implemented in this file.


func _read_file(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if not FileAccess.file_exists(path):
		return {"error": "No file at: %s" % path}
	return {"text": FileAccess.get_file_as_string(path)}


func _write_file(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return {"error": "path must be res:// or user://"}
	if path.contains(".."):
		return {"error": "path must not contain '..'"}
	var content := str(args.get("content", ""))
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	f.close()
	return {"text": "wrote %d bytes to %s%s" % [content.length(), path, sync_written_file(path)]}


func _list_dir(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", "res://"))
	var dir := DirAccess.open(path)
	if dir == null:
		return {"error": "cannot open dir: %s" % path}
	var dirs: Array = []
	var files: Array = []
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if e != "." and e != "..":
			if dir.current_is_dir():
				dirs.append(e)
			else:
				files.append(e)
		e = dir.get_next()
	dir.list_dir_end()
	dirs.sort()
	files.sort()
	return {"json": {"path": path, "dirs": dirs, "files": files}}


func _search_files(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", ""))
	if query.is_empty():
		return {"error": "query is required"}
	var ext := str(args.get("ext", ""))
	var use_regex := bool(args.get("regex", false))
	var maxn := int(args.get("max", 50))
	var re: RegEx = null
	if use_regex:
		re = RegEx.new()
		if re.compile(query) != OK:
			return {"error": "invalid regex: %s" % query}
	var hits: Array = []
	var scanned := [0]
	_search_walk("res://", query, ext, re, hits, maxn, scanned)
	return {"json": {"count": hits.size(), "scanned_files": scanned[0], "matches": hits}}


func _search_walk(path: String, query: String, ext: String, re: RegEx, hits: Array, maxn: int, scanned: Array) -> void:
	if hits.size() >= maxn or scanned[0] >= 3000:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if e == "." or e == ".." :
			e = dir.get_next()
			continue
		var full := path.path_join(e)
		if dir.current_is_dir():
			if e != ".godot":
				_search_walk(full, query, ext, re, hits, maxn, scanned)
		else:
			var fext := e.get_extension()
			var ok_ext := (ext == "" and _TEXT_EXTS.has(fext)) or (ext != "" and fext == ext)
			if ok_ext:
				scanned[0] += 1
				var text := FileAccess.get_file_as_string(full)
				var lines := text.split("\n")
				for i in lines.size():
					var line: String = lines[i]
					var matched := false
					if re != null:
						matched = re.search(line) != null
					else:
						matched = line.contains(query)
					if matched:
						hits.append({"file": full, "line": i + 1, "text": line.strip_edges()})
						if hits.size() >= maxn:
							break
		if hits.size() >= maxn or scanned[0] >= 3000:
			break
		e = dir.get_next()
	dir.list_dir_end()


func _get_setting(args: Dictionary) -> Dictionary:
	# Accept 'name' as an alias for 'setting' — small models routinely guess 'name'.
	var s := str(args.get("setting", args.get("name", "")))
	if s.is_empty():
		return {"error": "get_project_setting requires 'setting' (the property path, e.g. application/run/main_scene)."}
	if not ProjectSettings.has_setting(s):
		return {"error": "no such setting: %s" % s}
	return {"json": {"setting": s, "value": ProjectSettings.get_setting(s)}}


func _set_setting(args: Dictionary) -> Dictionary:
	# Accept 'name' as an alias for 'setting'. Never silently no-op on a missing key:
	# an empty setting used to "succeed" (ProjectSettings.set_setting("", v) is a no-op
	# that returns OK), which let callers believe a write landed when it had not.
	var s := str(args.get("setting", args.get("name", "")))
	if s.is_empty():
		return {"error": "set_project_setting requires 'setting' (the property path, e.g. application/run/main_scene). Got neither 'setting' nor 'name'."}
	if not args.has("value"):
		return {"error": "set_project_setting requires 'value'."}
	var existing: Variant = ProjectSettings.get_setting(s) if ProjectSettings.has_setting(s) else null
	var v: Variant = _setting_value(args.get("value"), existing)
	ProjectSettings.set_setting(s, v)
	var err := ProjectSettings.save()
	if err != OK:
		return {"error": "saved setting in-memory but project.godot write failed: %s" % error_string(err)}
	# Name the stored TYPE. A JSON "2" written to msaa_3d lands in project.godot as the
	# string "2", which the engine cannot read as an enum — it just silently does nothing.
	# Showing the type makes that visible on the first call instead of after a screenshot.
	var out := {"text": "set %s = %s (%s)" % [s, str(v), type_string(typeof(v))]}
	if existing == null and v is String and (str(v).is_valid_float() or str(v).to_lower() in ["true", "false"]):
		out["warning"] = "stored as String. This setting did not exist before, so there was no type to mirror — if it expects a number or bool, pass a JSON number (0.35) or boolean (true), not a quoted string."
	return out


## Recover a structured value an MCP client may have JSON-stringified (e.g. a plugin list
## arriving as "[\"res://addons/x/plugin.cfg\"]"), and store an all-string list as a
## PackedStringArray so settings like editor_plugins/enabled serialize correctly (a plain
## String there breaks plugin loading on the next project reload).
## Also mirrors the type of a setting that ALREADY exists: an MCP client that sends every
## value as a string turned rendering/.../msaa_3d into "2", which Godot reads as neither the
## enum nor an int, so the setting silently had no effect. Mirroring only against a known
## existing type keeps application/config/name = "2048" a String, where guessing would not.
static func _setting_value(value: Variant, existing: Variant = null) -> Variant:
	if value is String:
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
		elif existing != null:
			match typeof(existing):
				TYPE_INT:
					if raw.is_valid_int():
						return int(raw)
				TYPE_FLOAT:
					if raw.is_valid_float():
						return float(raw)
				TYPE_BOOL:
					if raw.to_lower() in ["true", "false", "0", "1"]:
						return raw.to_lower() in ["true", "1"]
	# JSON has ONE number type, so every integer arrives as a float and an int setting
	# (msaa_3d, an enum, a count) would be persisted as "0.0". Mirror numbers the same way
	# strings are mirrored — only against a known existing type, and never lossily.
	elif existing != null and (value is float or value is int or value is bool):
		match typeof(existing):
			TYPE_INT:
				if value is bool:
					return 1 if value else 0
				if value is int or is_equal_approx(float(value), roundf(float(value))):
					return int(value)
			TYPE_FLOAT:
				if not (value is bool):
					return float(value)
			TYPE_BOOL:
				return bool(value)
	if value is Array and not (value as Array).is_empty():
		var all_str := true
		for e in value:
			if not (e is String):
				all_str = false
				break
		if all_str:
			var psa := PackedStringArray()
			for e in value:
				psa.append(str(e))
			return psa
	return value


## The editor setting that decides whether an agent's script writes are silent or modal.
## Verified present and defaulting to TRUE on 4.6.2; guarded with has_setting anyway so an
## older or renamed build degrades to "not present" instead of a wrong warning.
const _AUTO_RELOAD_SETTING := "text_editor/behavior/files/auto_reload_scripts_on_external_change"


## Which gates are actually standing right now (v1.12 W3.4). Auth is the one users turn
## off, and turning it off does NOT remove the other two — saying so precisely is the point:
## someone who sets BECKETT_AUTH=0 should be able to see exactly what they gave up and what
## still protects them, instead of guessing from a single "auth: off" line.
func _security_state(auth_on: bool) -> Dictionary:
	var ids: Dictionary = InputCodecScript.device_ids()
	return {
		"token_auth": "on" if auth_on else "off (any LOCAL process can call this server)",
		"origin_check": "on (a cross-origin browser request gets 403; an Origin-less client is allowed, which is why the Host check exists)",
		"host_check": "on (only a loopback Host on this port is served; closes DNS rebinding, and holds even with BECKETT_AUTH=0)",
		"runtime_bridge": ("handshake token on" if server.bridge != null and not str(server.bridge.expected_token).is_empty()
			else "handshake off (BECKETT_AUTH=0); the bridge still binds loopback only, and speaks no HTTP, so a browser cannot reach it"),
		"protocol": "MCP %s" % _protocol_version(),
		"injected_input_device_ids": ("stamped (keyboard=%d mouse=%d)" % [int(ids.get("keyboard", -1)), int(ids.get("mouse", -1))]
			if int(ids.get("keyboard", -1)) >= 0 else "not available on this Godot (4.7+ only); injected events carry device 0"),
	}


func _protocol_version() -> String:
	var s = server
	return str(s.PROTOCOL_VERSION) if s != null else "?"


## v1.9 (B6): the support checklist as one call — born from the 1.7.0 postmortem, where a
## committed beckett/effort=3 in the public repo's project.godot silently capped every
## git-clone user at 42 tools for a month and nothing in the product could say why.
## Reports state + a compiled warnings list; ok=true means nothing needs attention.
## The token VALUE is deliberately never echoed (this output lands in agent transcripts).
func _doctor(_args: Dictionary) -> Dictionary:
	var warnings: Array = []
	var effort: int = server.get_effort()
	var ceiling: int = server.max_effort()

	var effort_source := "default (no beckett/effort persisted)"
	if ProjectSettings.has_setting("beckett/effort"):
		effort_source = "project.godot beckett/effort=%d — if that line is committed, every clone inherits it" % int(ProjectSettings.get_setting("beckett/effort", effort))
	if effort < ceiling:
		warnings.append("effort dial at L%d < ceiling L%d: tools/list is trimmed to the lower tier (%s). Raise it on the Beckett dock." % [effort, ceiling, effort_source])

	var advertised: int = (server.effective_specs(effort) as Array).size()
	var at_ceiling: int = (server.effective_specs(ceiling) as Array).size()
	var disabled: PackedStringArray = server.disabled_tools()
	if disabled.size() > 0:
		warnings.append("%d tool(s) switched off on the dock: %s" % [disabled.size(), ", ".join(disabled)])

	var running: bool = server.is_running()
	if not running:
		warnings.append("server is NOT running — Start Server on the Beckett dock (or beckett/autostart=true)")
	var auth_on: bool = server.auth_enabled()
	if not auth_on:
		warnings.append("token auth is OFF — any local process can call this server; enable it on the Beckett dock (auth row → Enable). The Origin and Host gates still hold, so a WEB PAGE cannot reach it, but a local process can.")
	if OS.get_environment("BECKETT_PORT") != "":
		warnings.append("BECKETT_PORT env override active (=%s) — configs written for the project-setting port will not match this session" % OS.get_environment("BECKETT_PORT"))
	if server.is_readonly():
		warnings.append("BECKETT_READONLY is on — every mutating tool is blocked this session")

	var base_port: int = MCPClientConfigScript.configured_port()
	var port: int = server.http.port if running and server.http != null else base_port
	if running and port != base_port:
		warnings.append("configured port %d was busy — serving on %d (B5 walk; client configs were regenerated for the live port, but anything hand-pointed at %d will not reach this editor)" % [base_port, port, base_port])
	var clients: Array = MCPClientConfigScript.staleness(port, server.auth_token())
	for c in clients:
		if not bool(c.get("current", true)):
			warnings.append("%s config (%s) does not carry the current endpoint URL — reconnect from the dock (Set up clients)" % [str(c.get("client", "?")), str(c.get("path", ""))])

	var ver := ""
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/beckett/plugin.cfg") == OK:
		ver = str(cfg.get_value("plugin", "version", ""))

	# v1.11 error echo state: on / unavailable (<4.5 Logger API) / off (env or stopped).
	var echo_state := "off (server not started)"
	if OS.get_environment("BECKETT_ERROR_ECHO") == "0":
		echo_state = "off (BECKETT_ERROR_ECHO=0)"
	elif server.error_echo != null:
		echo_state = "on" if server.error_echo.capture_active() else "unavailable (needs Godot 4.5+)"

	# Every script an agent writes lands on disk from OUTSIDE the editor, so this one editor
	# setting decides whether the human gets a modal per edit or never sees one. It defaults
	# to ON, so when it is off it is off because someone turned it off long ago - and nothing
	# in the product could say so, which is exactly the 42-tool trap's shape. Report, never
	# flip: it is the user's editor-wide preference, not ours to change.
	var script_reload := "unknown (EditorSettings unavailable)"
	var es := EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if es != null:
		if es.has_setting(_AUTO_RELOAD_SETTING):
			var on := bool(es.get_setting(_AUTO_RELOAD_SETTING))
			script_reload = "on" if on else "off"
			if not on:
				warnings.append("Editor Settings > Text Editor > Behavior > Files > 'Auto Reload Scripts On External Change' is OFF: every script this server writes pops a reload prompt the human must click, and edits do not take effect until they do. Godot changed this default between versions (4.4 ships it OFF, 4.6 ships it ON), so on an older editor it is off without anyone having chosen that. Turn it on unless you want the prompt.")
		else:
			script_reload = "not present on this Godot build"
	# Scenes have no editor setting at all, so state OUR opt-in instead. Not a warning:
	# off is the recommended default, and warning on the recommended state is just noise.
	var scene_reload := "off (Godot prompts the human; set beckett/auto_reload_scenes=true to reload automatically)"
	if bool(ProjectSettings.get_setting(AUTO_RELOAD_SCENES, false)):
		scene_reload = "on (beckett/auto_reload_scenes=true: open scenes reload without asking)"

	# v1.13 S10: what this tool surface costs the model, measured on THIS install instead of
	# quoted from a release note. `bytes` is the exact wire figure — tools/list ships
	# JSON.stringify over the compact spec array — so per_tier[N].bytes can be checked against
	# a live tools/list at that tier byte for byte. Never String.length(): it counts code
	# points and under-reports the ~100 non-ASCII characters in the payload by ~200 bytes.
	# Costs up to 6 stringify passes over the whole surface (~200 KB of transient string work),
	# which is fine for a rare human-triggered call and must not go anywhere near a hot path.
	# No warning is appended: paying context for tools you asked for is not a fault.
	var per_tier: Array = []
	var context_bytes := 0
	for lvl in range(1, ceiling + 1):
		var lvl_specs: Array = server.effective_specs(lvl)
		var lvl_bytes: int = JSON.stringify(lvl_specs).to_utf8_buffer().size()
		if lvl == effort:
			context_bytes = lvl_bytes
		per_tier.append({
			"level": lvl,
			"name": str((MCPEffortScript.LEVELS.get(lvl, {}) as Dictionary).get("name", "L%d" % lvl)),
			"tools": lvl_specs.size(),
			"bytes": lvl_bytes,
			"approx_tokens": int(lvl_bytes / 4.0),
		})

	return {"json": {
		"ok": warnings.is_empty(),
		"edition": "Lite" if server.is_lite() else "Full",
		"beckett_version": ver,
		"godot_version": String(Engine.get_version_info().get("string", "")),
		"effort": {"level": effort, "ceiling": ceiling, "source": effort_source},
		"tools": {"advertised_now": advertised, "at_ceiling": at_ceiling, "disabled": Array(disabled)},
		"context": {
			"advertised_tools": advertised,
			"bytes": context_bytes,
			"approx_tokens": int(context_bytes / 4.0),
			"ratio_note": "~4 bytes/token, approximate: the byte figures are exact wire bytes, the token figures are bytes/4",
			"per_tier": per_tier,
		},
		"server": {"running": running, "port": port, "auth": ("token on" if auth_on else "off"), "error_echo": echo_state},
		"security": _security_state(auth_on),
		"editor": {"script_auto_reload_on_external_change": script_reload, "scene_auto_reload": scene_reload},
		"game_bridge": {
			"connected": server.bridge != null and server.bridge.is_game_connected(),
			"auth": ("handshake on" if server.bridge != null and not str(server.bridge.expected_token).is_empty() else "off"),
			"port": server.bridge.port if server.bridge != null else 0,
		},
		# v1.13 S11: does the game play inside the editor's Game workspace or in its own OS
		# window? Embedded has been the default since 4.4, so this is the common case, and it
		# is what decides whether a window-mode assert can ever pass (see the note field).
		# Not a warning either: embedded is the ENGINE's recommended default, and warning on
		# the recommended state would make every doctor report not-ok forever.
		"game_view": RuntimeBridgeScript.game_view_state(),
		"clients": clients,
		"warnings": warnings,
	}}


# (logs_read moved to test_tools.gd — see the note in _register.)
