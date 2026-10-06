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
const CallArgsScript := preload("res://addons/beckett/core/callargs.gd")  # strict typed-setting coercion
const PathGuardScript := preload("res://addons/beckett/core/path_guard.gd")  # the one rule for caller-supplied write paths
const DotnetCheckScript := preload("res://addons/beckett/core/dotnet_check.gd")  # .NET SDK vs this engine/project, for doctor
const EngineIssuesScript := preload("res://addons/beckett/core/engine_issues.gd")  # known Godot bugs for the running version
const RunToolsScript := preload("res://addons/beckett/tools/run_tools.gd")  # policy_now: will an agent-started run pause at a script error
const VersionScript := preload("res://addons/beckett/core/version.gd")  # beckett_version: the one reader of plugin.cfg

## Constructors a NEW setting may be written with (see _typed_literal).
const _LITERAL_TYPES := ["Color", "Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i",
	"Rect2", "Rect2i", "Quaternion", "Plane", "AABB", "Basis", "Transform2D", "Transform3D"]

## Opt-in: reload a scene the editor has open after we overwrite its file on disk.
## Default FALSE on purpose. Scripts have an editor setting for this and it defaults on,
## but Godot has NO equivalent for scenes, and it also exposes no way to ask whether an
## open scene holds unsaved human edits — so an automatic reload can silently discard
## someone's work. That is the same class of quiet data loss this release spent its time
## removing, so the safe default wins and the project opts in deliberately.
const AUTO_RELOAD_SCENES := "beckett/auto_reload_scenes"


## Tell the editor a file changed underneath it, and return an honest note about anything
## the change is still WAITING on. Shared by every core write path (write_file,
## apply_template, write_script, script_patch, rescan_filesystem) so the behaviour cannot
## drift between them.
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
	var efs := EditorInterface.get_resource_filesystem()
	# update_file is a silent no-op in both cases below (checked on 4.4.1, 4.6.2 and 4.7), so
	# say what will actually pick the file up instead of implying it already happened.
	if efs.is_scanning():
		return " (the editor is mid-scan and ignores single-file updates until it finishes; call rescan_filesystem afterwards if this file does not show up)"
	if not editor_knows_dir(path.get_base_dir()):
		start_full_scan()
		return (" (%s/ is a folder the editor had not seen, and it only learns new folders by scanning:" % path.get_base_dir()
			+ " a background scan has started. A class_name in this file registers when it finishes; rescan_filesystem reports when that is.)")
	efs.update_file(path)
	return ""


## Test seam, null in every real run: while it is valid, verify_write takes the md5 it finds from
## `read_back_probe.call(path)` ("" = no file) instead of reading the disk. Nothing short of a second
## process can change a file between a write and its read-back, so the unit suite uses this to make
## the read-back come out wrong THROUGH the real writers (write_file, write_script, script_patch,
## apply_template) and require each of them to return the error instead of reporting a clean write.
static var read_back_probe: Callable = Callable()


## Read a file back right after writing it and compare it with what was meant to land (md5 of the
## bytes). A write reports success the moment the bytes are handed to the OS, so a second writer on
## the same path (an external editor, a formatter, a file watcher) or an editor buffer saved over it
## in that instant is invisible to it. {} = verified; otherwise a ready-to-return tool error naming
## both md5s and the likely cause. ONE synchronous read: a handler cannot wait and look again, so a
## writer that lands LATER is covered by editor_buffer_note() instead of a second check.
static func verify_write(path: String, content: String) -> Dictionary:
	var expected := content.md5_text()
	var actual := ""
	if read_back_probe.is_valid():
		actual = str(read_back_probe.call(path))
	elif FileAccess.file_exists(path):
		actual = FileAccess.get_md5(path)
	if actual == expected:
		return {}
	return {
		"error": "%s was written, but reading it back does not match: expected md5 %s, found %s. Something else changed the file between the write and the read (another tool or editor writing the same path, a formatter or file watcher), or an editor buffer saved over it.%s" % [
			path, expected, ("md5 " + actual) if not actual.is_empty() else "no file", editor_buffer_note(path)],
		"suggestion": "Read the file to see what is on disk, close it or save it in the editor, then write it again.",
	}


## One line when `path` is open in the Script Editor, "" otherwise (and outside the editor): an
## unsaved buffer there can overwrite what was just written on its next save, and no read-back can
## see a save that has not happened yet.
static func editor_buffer_note(path: String) -> String:
	if not Engine.is_editor_hint() or not path.begins_with("res://"):
		return ""
	for s in EditorInterface.get_script_editor().get_open_scripts():
		if s.resource_path == path:
			return " NOTE: %s is open in the Script Editor; an unsaved editor buffer can overwrite this file on its next save." % path
	return ""


## The success reply for a write that read back clean: the text, the editor-buffer line when it
## applies, and disk_verified for parsers.
static func verified_reply(path: String, text: String) -> Dictionary:
	return {"text": text + editor_buffer_note(path), "json": {"disk_verified": true}}


## The scan for work update_file cannot do (new folders, never-imported assets). A FULL scan,
## not scan_sources(): the changes scan decides a folder changed by comparing modification
## times in whole seconds, so a folder or file created in the same second as the previous
## scan is missed, and missed again by every later changes scan (reproduced 2026-09-30 on
## 4.6.2: an agent writing files between two calls hits that second routinely).
static func start_full_scan() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if not efs.is_scanning():
		efs.scan()


## Does the editor's filesystem tree have this res:// folder yet? A folder created OUTSIDE the
## editor (by an agent's own file tools, or by write_script making a path) stays unknown to it
## until a scan, and update_file on any file inside an unknown folder does nothing at all.
## Asked only while the editor is not scanning: get_filesystem_path answers null mid-scan.
static func editor_knows_dir(dir: String) -> bool:
	return EditorInterface.get_resource_filesystem().get_filesystem_path(dir) != null


## `class_name X` as the engine reads it: at the top level, optionally after annotations.
## Same shape script_tools.gd masks for validation.
const _CLASS_NAME_RE := "(?m)^(?:@[A-Za-z_]+[ \\t]+)*class_name[ \\t]+([A-Za-z_][A-Za-z0-9_]*)"

## Walk cap, same order of magnitude as search_files: a project that big still finishes
## in a blink, and one bigger than that should not stall the editor on a single call.
const _SCRIPT_WALK_MAX := 5000


## The class_name a script's source declares, or "".
static func declared_class_name(src: String) -> String:
	var re := RegEx.new()
	re.compile(_CLASS_NAME_RE)
	var m := re.search(src)
	return m.get_string(1) if m != null else ""


## What an outside write leaves the editor not knowing, given each script's declared
## class_name and the editor's registration map ({class: path}). Pure, so the unit suite can
## pin it: a declared name nobody registered, and a name still registered to a file that is
## gone (the script moved on disk). A name registered to ANOTHER existing file is a real
## duplicate, which the engine rejects on its own; that is not ours to paper over.
static func missing_registrations(declared: Dictionary, registered: Dictionary) -> Array:
	var out: Array = []
	for path in declared:
		var cname := str(declared[path])
		if cname.is_empty():
			continue
		if not registered.has(cname):
			out.append({"class": cname, "path": str(path)})
		elif str(registered[cname]) != str(path) and not FileAccess.file_exists(str(registered[cname])):
			out.append({"class": cname, "path": str(path), "moved_from": str(registered[cname])})
	return out


## Scripts written or changed OUTSIDE the editor that it has not caught up with. The editor
## notices outside changes when its window regains focus, which a driven editor rarely gets,
## so until something calls update_file a new class_name stays unknown ("Could not find
## type") and an edited script keeps running its old loaded copy.
static func unsynced_scripts() -> Dictionary:
	var registered := {}
	for gc in ProjectSettings.get_global_class_list():
		registered[str(gc.get("class", ""))] = str(gc.get("path", ""))
	var found := {"declared": {}, "stale": [], "unimported": [], "skipped": []}
	_walk_project("res://", found, [0], {})
	return {"classes": missing_registrations(found["declared"], registered), "stale": found["stale"], "unimported": found["unimported"], "skipped": found["skipped"]}


## Asset types an importer handles. One of these with no .import file beside it was never
## imported: only a scan does that, and until then nothing can load it.
const _IMPORT_EXTS := ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "hdr", "exr", "ktx", "dds",
	"wav", "ogg", "mp3", "glb", "gltf", "fbx", "blend", "obj", "dae", "ttf", "otf", "woff", "woff2", "fnt", "font"]


## `found["skipped"]` collects what the walk left out because it is a link leading outside the project
## (see PathGuard.walk_skip): the editor does not index what is not in the project, and this walk reads
## every script it meets, so it must not read one through a link either.
static func _walk_project(dir_path: String, found: Dictionary, seen: Array, memo: Dictionary) -> void:
	if seen[0] >= _SCRIPT_WALK_MAX:
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		# Dot-folders (.godot, .git, .beckett) and .gdignore'd folders are invisible to the
		# editor too, so nothing in them can be missing from it.
		if not e.begins_with("."):
			var full := dir_path.path_join(e)
			if dir.current_is_dir():
				if not FileAccess.file_exists(full.path_join(".gdignore")):
					if PathGuardScript.walk_skip(full, memo):
						found["skipped"].append(full)
					else:
						_walk_project(full, found, seen, memo)
			elif e.get_extension() == "gd":
				if PathGuardScript.walk_skip(full, memo):
					found["skipped"].append(full)
					e = dir.get_next()
					continue
				seen[0] += 1
				var text := FileAccess.get_file_as_string(full)
				found["declared"][full] = declared_class_name(text)
				if ResourceLoader.has_cached(full):
					var loaded: Variant = load(full)
					if loaded is Script and str((loaded as Script).source_code).replace("\r\n", "\n") != text.replace("\r\n", "\n"):
						found["stale"].append(full)
			elif e.get_extension().to_lower() in _IMPORT_EXTS and not FileAccess.file_exists(full + ".import"):
				found["unimported"].append(full)
			if seen[0] >= _SCRIPT_WALK_MAX:
				break
		e = dir.get_next()
	dir.list_dir_end()


## Hand the editor every script unsynced_scripts() found, then report what it now knows.
## update_file is what registers a class_name, and it answers synchronously, which is the
## point: the caller's very next compile sees the class. Two cases it cannot cover are reported
## instead of claimed: the editor is mid-scan (update_file is a no-op then), and a script in a
## folder the editor has never seen ("pending": only a scan registers those). start_scan lets
## rescan_filesystem start that scan; validate_script, a read-only tool, leaves it to the agent.
static func sync_unsynced_scripts(start_scan: bool = false) -> Dictionary:
	var found := unsynced_scripts()
	var classes: Array = found["classes"]
	var stale: Array = found["stale"]
	var out := {"registered": [], "unregistered": [], "pending": [], "reloaded": [], "scanning": false,
		"unimported": found["unimported"], "skipped": found["skipped"]}
	if not Engine.is_editor_hint() or (classes.is_empty() and stale.is_empty()):
		out["unregistered"] = classes
		if start_scan and Engine.is_editor_hint() and not (found["unimported"] as Array).is_empty():
			start_full_scan()
			out["scanning"] = EditorInterface.get_resource_filesystem().is_scanning()
		return out
	var efs := EditorInterface.get_resource_filesystem()
	if efs.is_scanning():
		out["scanning"] = true
		out["unregistered"] = classes
		return out
	var syncable: Array = []
	for c in classes:
		if editor_knows_dir(str(c["path"]).get_base_dir()):
			syncable.append(c)
		else:
			out["pending"].append(c)
	for c in syncable:
		if (c as Dictionary).has("moved_from"):
			efs.update_file(str(c["moved_from"]))
		efs.update_file(str(c["path"]))
	for p in stale:
		if editor_knows_dir(str(p).get_base_dir()):
			efs.update_file(str(p))
			out["reloaded"].append(p)
	var now := {}
	for gc in ProjectSettings.get_global_class_list():
		now[str(gc.get("class", ""))] = str(gc.get("path", ""))
	for c in syncable:
		if str(now.get(str(c["class"]), "")) == str(c["path"]):
			out["registered"].append(c)
		else:
			out["unregistered"].append(c)
	if start_scan and not ((out["pending"] as Array).is_empty() and (out["unimported"] as Array).is_empty()):
		start_full_scan()
		out["scanning"] = efs.is_scanning()
	return out


func _register(registry) -> void:
	registry.register({
		"name": "read_file",
		"description": "Read a text file by res:// (or user://) path.",
		"help": "path = res://..., user://..., or an absolute path that lies inside the project folder or the project's user:// folder.\n\nReads are CONFINED to those two folders. Any other path is refused with an error that names it: a folder elsewhere on the machine, a relative path (it could mean any folder), a path with '..', or a path that goes through a symbolic link or junction that leads out of the project (a cloned repository can ship one). read_script, list_dir, validate_script, logs_read, wait_until file_exists:, load_skill, apply_template, test_run, build_csharp, and every tool that opens a scene, script or resource by path follow the same rule. search_files, rescan_filesystem, list_skills and the project-analysis tools do not follow a link that leads out of the project; they list what they left out in skipped_links. logs_read with no path reads the log that debug/file_logging/log_path names, under the same rule.\n\nTo read outside the project on purpose, the person who owns the project sets the project setting beckett/allow_outside_reads=true (under [beckett] in project.godot; set_project_setting refuses to turn it on, so an agent cannot lift the confinement itself), or starts the editor with BECKETT_ALLOW_OUTSIDE_READS=1 (the environment wins, and BECKETT_ALLOW_OUTSIDE_READS=0 forces the confinement back on over a project setting that a repository committed). Each reply to such a read says so (outside_read), and doctor warns while it is on.\n\nWrites are never affected: write_file, write_script, script_patch, create_resource, save_scene, apply_template, asset_lib_install and the playtest and compare_screenshots baselines stay under res:// or user://, and refuse a path that goes through a link leaving the project, whatever this setting says.",
		"readonly": true,
		"max_result_chars": 200000,  # same reasoning as read_script: the text is the answer; see script_tools.gd
		"input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		"handler": Callable(self, "_read_file"),
	})
	registry.register({
		"name": "write_file",
		"description": "Write a text file under res:// (or user://), path-traversal guarded. Reads it back (disk_verified). Refreshes the editor filesystem. If the file is a .tscn the editor currently has OPEN, the result says so: Godot prompts the human to reload it and until they do the editor still holds the old version (scripts have no such problem, the editor auto-reloads them). Set beckett/auto_reload_scenes=true to reload open scenes automatically. Prefer the scene tools (create_node / set_property / save_scene) over writing .tscn text at all - editor-side edits never go stale.",
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
		"description": "Set a ProjectSettings value and persist project.godot. The property path goes in 'setting' ('name' is also accepted); e.g. set application/run/main_scene to res://main.tscn. A setting that already holds a typed value keeps its type: colors take \"#rrggbb\" or [r,g,b,a], vectors [x,y]. A value that cannot convert is refused, not stored.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"setting": {"type": "string"}, "name": {"type": "string"}, "value": {},
		}, "required": ["value"]},
		"handler": Callable(self, "_set_setting"),
	})
	registry.register({
		"name": "rescan_filesystem",
		"description": "Make the editor see files written OUTSIDE it (your own file tools, git, a generator). Scripts sync at once, so a new class_name resolves right away for validate_script / write_script; new assets import in a background scan (the result says while it is still scanning). Pass 'paths' to sync just those files. write_file, write_script and script_patch already do this for what they write.",
		"idempotent": true,
		"input_schema": {"type": "object", "properties": {
			"paths": {"type": "array", "items": {"type": "string"}, "description": "res:// files to sync now. Default: every script with an unregistered class_name or a stale loaded copy"},
		}},
		"handler": Callable(self, "_rescan_filesystem"),
	})
	registry.register({
		"name": "doctor",
		"description": "Beckett self-diagnosis — one call answers 'why can't the agent see or do X?'. Reports: edition (Lite/Full), the effort dial vs its ceiling AND where the cap comes from (a beckett/effort= line committed in project.godot silently trims every clone's tool list), advertised-vs-ceiling tool counts, dock-disabled tools, server/port/auth state, per-client config freshness (does each written config still carry the CURRENT endpoint URL, and does a Claude Desktop bridge pin an exact mcp-remote version?), runtime-bridge liveness, what this tool surface costs your context (exact tools/list bytes and approximate tokens for every effort tier, measured on THIS install, so you can price a tier before dialing to it; plus what Claude Code's tool search holds upfront, the always_load tools), whether the game plays EMBEDDED in the editor's Game workspace or in its own window (embedded means the Suspend button freezes every runtime call and window-mode asserts can never pass), and whether the editor auto-reloads externally-changed scripts (off = every script this server writes waits behind a modal the human must click), for C# projects whether an installed .NET SDK satisfies this engine (4.8 needs SDK 10), and the known Godot bugs for this exact version (known_issues, never part of ok). Run this FIRST when tools seem missing, counts look wrong, or calls fail unexpectedly.",
		"readonly": true,
		# One success path, so every key here is genuinely always present. `ok` is
		# literally warnings.is_empty(), which is why it can be required.
		# No prose inside the schema: a JSON Schema is read by a parser, the key names are
		# self-describing, and every description here would ship on EVERY tools/list at
		# EVERY tier — doctor is L1. The first cut of this block cost 1.4 KB at tier 1,
		# which is the exact cost the rest of this release was spent removing.
		"output_schema": {"type": "object", "properties": {
			"ok": {"type": "boolean"}, "edition": {"type": "string"},
			"beckett_version": {"type": "string"}, "godot_version": {"type": "string"},
			"effort": {"type": "object"}, "tools": {"type": "object"},
			"context": {"type": "object"}, "server": {"type": "object"},
			"security": {"type": "object"}, "editor": {"type": "object"},
			"game_bridge": {"type": "object"}, "game_view": {"type": "object"},
			"clients": {"type": "array"}, "warnings": {"type": "array"},
			"dotnet": {"type": "object"}, "known_issues": {"type": "array"},
		}, "required": ["ok", "edition", "beckett_version", "godot_version", "effort", "tools", "context", "server"]},
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_doctor"),
	})
	# NOTE: logs_read (L3) lives in test_tools.gd — premium modules keep ALL their
	# code out of the Lite build; nothing tier-3+ may be implemented in this file.


func _read_file(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard: Dictionary = PathGuardScript.check_read(path)  # inside the project / user:// only, unless the owner opted out
	if guard.has("error"):
		return guard
	if not FileAccess.file_exists(path):
		return {"error": "No file at: %s" % path}
	return PathGuardScript.noted({"text": FileAccess.get_file_as_string(path)}, guard)


func _write_file(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var perr: String = PathGuardScript.write_path_error(path)
	if not perr.is_empty():
		return {"error": perr}
	var content := str(args.get("content", ""))
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	f.close()
	var bad := verify_write(path, content)
	if not bad.is_empty():
		return bad
	return verified_reply(path, "wrote %d bytes to %s%s" % [content.length(), path, sync_written_file(path)])


## Extensions update_file fully covers. Anything else may need an importer (textures, audio,
## models, fonts), and importing is what the background scan does.
const _NO_IMPORT_EXTS := ["gd", "cs", "tscn", "scn", "tres", "res", "gdshader", "gdshaderinc",
	"json", "cfg", "txt", "md", "godot", "uid", "import", "gdextension"]


func _rescan_filesystem(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"error": "rescan_filesystem needs a running editor."}
	var efs := EditorInterface.get_resource_filesystem()
	# update_file is a silent no-op while a scan runs, so there is nothing to force yet; and
	# when that scan ends the editor has seen every file on disk anyway.
	if efs.is_scanning():
		return {"json": {"scanning": true, "progress": snappedf(efs.get_scanning_progress(), 0.01),
			"summary": "The editor is still scanning. When it finishes it has seen every file on disk, new folders included; call rescan_filesystem again in a moment."}}
	var out := {}
	var pending: Array = []
	var unimported: Array = []
	var needs_scan := false
	var raw: Variant = args.get("paths", [])
	if raw is Array and not (raw as Array).is_empty():
		var synced: Array = []
		var removed: Array = []
		var notes: Array = []
		var scripts: Dictionary = {}
		var memo := {}
		for p in raw:
			var path := str(p)
			if not path.begins_with("res://") or path.contains(".."):
				return {"error": "paths must be res:// paths without '..' (got '%s'). Nothing was synced." % path}
			# The sync reads each .gd to learn its class_name, so a path through a link that leaves the
			# project is refused like any other read.
			var guard: Dictionary = PathGuardScript.check_read(path, memo)
			if guard.has("error"):
				return {"error": "%s Nothing was synced." % str(guard["error"])}
		for p in raw:
			var path := str(p)
			# A file in a folder the editor has never seen cannot be synced one by one, only
			# scanned: collect it as pending and let the one scan below pick it up.
			var known := editor_knows_dir(path.get_base_dir())
			var cname := ""
			if not FileAccess.file_exists(path):
				removed.append(path)
			elif path.get_extension() == "gd":
				cname = declared_class_name(FileAccess.get_file_as_string(path))
			if not known or not (path.get_extension() in _NO_IMPORT_EXTS):
				needs_scan = true
			if not known:
				if not cname.is_empty():
					pending.append({"class": cname, "path": path})
				continue
			if not cname.is_empty():
				scripts[path] = cname
			var note := sync_written_file(path)
			if not note.is_empty():
				notes.append(path + ":" + note)
			synced.append(path)
		var now := {}
		for gc in ProjectSettings.get_global_class_list():
			now[str(gc.get("class", ""))] = str(gc.get("path", ""))
		var registered: Array = []
		var unregistered: Array = []
		for sp in scripts:
			var sname := str(scripts[sp])
			if str(now.get(sname, "")) == str(sp):
				registered.append({"class": sname, "path": sp})
			else:
				unregistered.append({"class": sname, "path": sp, "registered_to": str(now.get(sname, ""))})
		out = {"synced": synced, "registered": registered}
		if not removed.is_empty():
			out["removed"] = removed
		if not unregistered.is_empty():
			out["unregistered"] = unregistered
		if not notes.is_empty():
			out["notes"] = notes
	else:
		# Scripts sync on the spot. A scan starts only for work nothing else can do (scripts in
		# new folders, assets never imported), so a project with nothing left settles at
		# scanning=false instead of every call starting the next scan.
		var r := sync_unsynced_scripts(true)
		out = {"registered": r["registered"], "reloaded": r["reloaded"]}
		if not (r["unregistered"] as Array).is_empty():
			out["unregistered"] = r["unregistered"]
		pending = r["pending"]
		unimported = r["unimported"]
		if not unimported.is_empty():
			out["unimported"] = unimported.slice(0, 20)
		out.merge(PathGuardScript.skipped_note(r["skipped"]))  # scripts behind a link that leaves the project were not read
		needs_scan = not (pending.is_empty() and unimported.is_empty())
	# The no-args branch above already started its scan (sync_unsynced_scripts(true)).
	if needs_scan and raw is Array and not (raw as Array).is_empty():
		start_full_scan()
	if not pending.is_empty():
		out["pending"] = pending
	out["scan"] = "started" if needs_scan else "not needed"
	out["scanning"] = efs.is_scanning()
	var parts: Array = []
	if not (out.get("registered", []) as Array).is_empty():
		var names: Array = []
		for c in out["registered"]:
			names.append(str(c["class"]))
		parts.append("registered class_name %s" % ", ".join(names))
	if out.has("synced"):
		parts.append("synced %d file(s)" % (out["synced"] as Array).size())
	if not (out.get("reloaded", []) as Array).is_empty():
		parts.append("%d script(s) changed on disk were handed back to the editor" % (out["reloaded"] as Array).size())
	if out.has("unregistered"):
		parts.append("%d class_name(s) still NOT registered (see unregistered: another file may already own the name)" % (out["unregistered"] as Array).size())
	if not pending.is_empty():
		parts.append("%d class_name(s) sit in folders the editor had not seen and register once the background scan has run (call rescan_filesystem again in a moment: they are done when 'pending' is gone)" % pending.size())
	if not unimported.is_empty():
		parts.append("%d asset(s) were never imported and import in the background scan (load them once rescan_filesystem reports scanning=false)" % unimported.size())
	elif needs_scan and pending.is_empty():
		parts.append("background scan started for new or changed assets" + (" (still scanning)" if out["scanning"] else ""))
	out["summary"] = ("; ".join(parts) if not parts.is_empty() else "nothing was out of sync") + "."
	return {"json": out}


func _list_dir(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", "res://"))
	var guard: Dictionary = PathGuardScript.check_read(path)
	if guard.has("error"):
		return guard
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
	return PathGuardScript.noted({"json": {"path": path, "dirs": dirs, "files": files}}, guard)


func _search_files(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", ""))
	if query.is_empty():
		return {"error": "query is required"}
	var ext := str(args.get("ext", ""))
	var use_regex := CallArgsScript.flag(args, "regex")
	var maxn := int(args.get("max", 50))
	var re: RegEx = null
	if use_regex:
		re = RegEx.new()
		if re.compile(query) != OK:
			return {"error": "invalid regex: %s" % query}
	var hits: Array = []
	var scanned := [0]
	var skipped: Array = []  # links that lead out of the project: not followed (see PathGuard.walk_skip)
	var out := {"count": 0, "scanned_files": 0, "matches": hits}
	_search_walk("res://", query, ext, re, hits, maxn, scanned, skipped, {})
	out["count"] = hits.size()
	out["scanned_files"] = scanned[0]
	out.merge(PathGuardScript.skipped_note(skipped))
	return {"json": out}


func _search_walk(path: String, query: String, ext: String, re: RegEx, hits: Array, maxn: int, scanned: Array, skipped: Array, memo: Dictionary) -> void:
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
				if PathGuardScript.walk_skip(full, memo):
					skipped.append(full)
				else:
					_search_walk(full, query, ext, re, hits, maxn, scanned, skipped, memo)
		else:
			var fext := e.get_extension()
			var ok_ext := (ext == "" and _TEXT_EXTS.has(fext)) or (ext != "" and fext == ext)
			# Only a file that is about to be opened is looked at for a link: the probe is free for a plain
			# file, but a cloud-synced placeholder can be downloaded by being asked where it points.
			if ok_ext and PathGuardScript.walk_skip(full, memo):
				skipped.append(full)
			elif ok_ext:
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
	var owner_only: String = PathGuardScript.setting_write_error(s, args["value"])  # the read-confinement switch is the owner's
	if not owner_only.is_empty():
		return {"error": owner_only}
	var existing: Variant = ProjectSettings.get_setting(s) if ProjectSettings.has_setting(s) else null
	var v: Variant = _setting_value(args.get("value"), existing)
	# Refuse rather than store a value of the wrong type in a typed slot: the engine does not
	# read a String as a Color, so the old behaviour "succeeded" and the setting did nothing.
	var mismatch := _setting_type_error(v, existing)
	if not mismatch.is_empty():
		return {"error": "%s holds a value of type %s, and this value cannot become one: %s. Nothing was written." % [s, type_string(typeof(existing)), mismatch],
			"suggestion": "get_project_setting setting=%s shows the current value and its type." % s}
	ProjectSettings.set_setting(s, v)
	var err := ProjectSettings.save()
	if err != OK:
		return {"error": "saved setting in-memory but project.godot write failed: %s" % error_string(err)}
	# Name the stored TYPE. A JSON "2" written to msaa_3d lands in project.godot as the
	# string "2", which the engine cannot read as an enum — it just silently does nothing.
	# Showing the type makes that visible on the first call instead of after a screenshot.
	var text := "set %s = %s (%s)" % [s, str(v), type_string(typeof(v))]
	var warning := _setting_warning(v, existing)
	# In the text, not a sibling "warning" key: _tool_result renders text/json/error only, so
	# the v1.12 warning that lived in its own key never reached the agent.
	if not warning.is_empty():
		text += "\nWarning: " + warning
	return {"text": text}


## Setting types JSON has no literal for (Color, the vectors, Rect2, PackedStringArray, ...).
## A value for a setting that already holds one must BECOME one: a String left in a Color
## slot is not a color the engine can read, so the setting silently does nothing (field report
## 2026-09-29: default_clear_color = "#1b3552" was stored as a String). The loose types below
## keep their v1.12 mirroring rules in _setting_value; every other type goes through the
## strict call-argument coercion, which either produces the type or says why it cannot.
static func _strict_setting_type(t: int) -> bool:
	return not (t in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT])


## Why v cannot go into a setting that currently holds `existing`, or "" when it can.
static func _setting_type_error(v: Variant, existing: Variant) -> String:
	if existing == null or not _strict_setting_type(typeof(existing)) or typeof(v) == typeof(existing):
		return ""
	var r: Dictionary = CallArgsScript.coerce(v, typeof(existing))
	return str(r.get("error", "expected %s" % type_string(typeof(existing))))


## The honest footnote for a write that went through but may not do what the caller meant.
static func _setting_warning(v: Variant, existing: Variant) -> String:
	if existing == null and v is String:
		if str(v).is_valid_float() or str(v).to_lower() in ["true", "false"]:
			return "stored as String. This setting did not exist before, so there was no type to mirror. If it expects a number or bool, pass a JSON number (0.35) or boolean (true), not a quoted string."
		if str(v).begins_with("#") and Color.html_is_valid(str(v)):
			return "stored as String. This setting did not exist before, so there was no type to mirror. To store a Color, pass a Godot literal such as \"Color(0.1, 0.2, 0.3, 1)\"."
	elif existing != null and typeof(v) != typeof(existing):
		return "stored as %s, but this setting held type %s. The engine may ignore a value of the wrong type." % [type_string(typeof(v)), type_string(typeof(existing))]
	return ""


## A Godot literal for a typed value ("Color(1, 0.5, 0, 1)", "Vector2i(640, 360)"), or null.
## Only an explicit constructor counts: a brand-new setting has no type to mirror, and a bare
## "#ff8800" or "2" stays the String it was sent as.
static func _typed_literal(raw: String) -> Variant:
	var t := raw.strip_edges()
	var open := t.find("(")
	if open <= 0 or not t.ends_with(")"):
		return null
	if not (t.substr(0, open) in _LITERAL_TYPES):
		return null
	var parsed: Variant = str_to_var(t)
	if parsed == null or parsed is String:
		return null
	return parsed


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
		elif existing == null:
			var lit: Variant = _typed_literal(raw)
			if lit != null:
				return lit
		else:
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
	# Everything JSON cannot spell (Color, vectors, PackedStringArray, ...): convert to the
	# existing type or hand the value back unchanged for _set_setting to refuse.
	if existing != null and _strict_setting_type(typeof(existing)) and typeof(value) != typeof(existing):
		var r: Dictionary = CallArgsScript.coerce(value, typeof(existing))
		return r["value"] if bool(r.get("ok", false)) else value
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

## Said in doctor's effort block and on the dock after a dial change (panel.gd keeps the same
## sentence). Claude Code inside the Claude desktop app does not rebuild its deferred tool pool
## on notifications/tools/list_changed (anthropics/claude-code#88483, open), and the signal
## is the only way a live dial change reaches any client, so there the change shows on a new
## session or after an app restart. It is not a fault, so it is a note and never a warning.
const EFFORT_DESKTOP_NOTE := "Claude Code in the Claude desktop app does not rebuild its tool list when this dial moves (anthropics/claude-code#88483): start a new session or restart the app to see a change."


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
		"file_reads": _file_reads_state(),
		"runtime_bridge": ("handshake token on" if server.bridge != null and not str(server.bridge.expected_token).is_empty()
			else "handshake off (BECKETT_AUTH=0); the bridge still binds loopback only, and speaks no HTTP, so a browser cannot reach it"),
		"protocol": "MCP %s" % _protocol_version(),
		"injected_input_device_ids": ("stamped (keyboard=%d mouse=%d)" % [int(ids.get("keyboard", -1)), int(ids.get("mouse", -1))]
			if int(ids.get("keyboard", -1)) >= 0 else "not available on this Godot (4.7+ only); injected events carry device 0"),
	}


## Where the file tools may read (v1.16): inside the project and user://, unless the owner opted out.
## Writes never consult the opt-out, so the line says what stays true either way.
func _file_reads_state() -> String:
	var src: String = PathGuardScript.outside_reads_source()
	if src.is_empty():
		return "confined to the project folder and user:// (read_file, read_script, list_dir and the other readers refuse any other path, and a link that leads out of the project; opt out with %s or %s=1)" % [PathGuardScript.SETTING_OUTSIDE_READS, PathGuardScript.ENV_OUTSIDE_READS]
	return "OUTSIDE READS ON via %s: the read tools open any path this editor process can read. Writes stay confined to res:// and user:// regardless" % src


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
	var outside_src: String = PathGuardScript.outside_reads_source()
	if not outside_src.is_empty():
		warnings.append("outside reads are ON (%s): read_file, read_script, list_dir and the other read tools open any file this editor process can read, not only the project. Switch it off unless you need it." % outside_src)

	var base_port: int = MCPClientConfigScript.configured_port()
	var port: int = server.http.port if running and server.http != null else base_port
	if running and port != base_port:
		warnings.append("configured port %d was busy — serving on %d (B5 walk; client configs were regenerated for the live port, but anything hand-pointed at %d will not reach this editor)" % [base_port, port, base_port])
	var clients: Array = MCPClientConfigScript.staleness(port, server.auth_token())
	warnings.append_array(_client_warnings(clients))

	var ver: String = VersionScript.current()

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
	var effort_specs: Array = []
	for lvl in range(1, ceiling + 1):
		var lvl_specs: Array = server.effective_specs(lvl)
		var lvl_bytes: int = JSON.stringify(lvl_specs).to_utf8_buffer().size()
		if lvl == effort:
			context_bytes = lvl_bytes
			effort_specs = lvl_specs
		per_tier.append({
			"level": lvl,
			"name": str((MCPEffortScript.LEVELS.get(lvl, {}) as Dictionary).get("name", "L%d" % lvl)),
			"tools": lvl_specs.size(),
			"bytes": lvl_bytes,
			"approx_tokens": int(lvl_bytes / 4.0),
		})

	# v1.16: C# only. Does an installed .NET SDK satisfy this engine and project? A failure IS a
	# warning (the project cannot build), so this runs before `ok` is read off the warnings.
	var dotnet := _dotnet_report(warnings)
	# v1.16: Godot's own bugs for the running version. A separate list on purpose, never
	# warnings: they are not Beckett state, and on most engines at least one applies, so a
	# warning would make `ok` false for nearly everyone and stop meaning anything.
	var known_issues: Array = EngineIssuesScript.for_version(Engine.get_version_info())

	var report := {
		"ok": warnings.is_empty(),
		"edition": "Lite" if server.is_lite() else "Full",
		"beckett_version": ver,
		"godot_version": String(Engine.get_version_info().get("string", "")),
		"effort": {"level": effort, "ceiling": ceiling, "source": effort_source, "note": EFFORT_DESKTOP_NOTE},
		"tools": {"advertised_now": advertised, "at_ceiling": at_ceiling, "disabled": Array(disabled)},
		"context": {
			"advertised_tools": advertised,
			"bytes": context_bytes,
			"approx_tokens": int(context_bytes / 4.0),
			"ratio_note": "~4 bytes/token, approximate: the byte figures are exact wire bytes, the token figures are bytes/4",
			"per_tier": per_tier,
			"tool_search": _tool_search_report(effort_specs, server.supports_tool_meta()),
		},
		"server": {"running": running, "port": port, "auth": ("token on" if auth_on else "off"), "error_echo": echo_state},
		"security": _security_state(auth_on),
		"editor": {"script_auto_reload_on_external_change": script_reload, "scene_auto_reload": scene_reload},
		"game_bridge": {
			"connected": server.bridge != null and server.bridge.is_game_connected(),
			"auth": ("handshake on" if server.bridge != null and not str(server.bridge.expected_token).is_empty() else "off"),
			"port": server.bridge.port if server.bridge != null else 0,
			# the played game is parked in the editor's debugger (a script error or a breakpoint): connected, and silent
			"debugger_break": server.bridge != null and not server.bridge.debugger_break().is_empty(),
		},
		# Will a game the AGENT starts pause at a script error? On 4.5+ play_scene launches with --ignore-error-breaks
		# unless the project or the environment opted out; before 4.5 there is no such flag. Not a warning either way.
		"error_breaks": _error_breaks_report(),
		# v1.13 S11: does the game play inside the editor's Game workspace or in its own OS
		# window? Embedded has been the default since 4.4, so this is the common case, and it
		# is what decides whether a window-mode assert can ever pass (see the note field).
		# Not a warning either: embedded is the ENGINE's recommended default, and warning on
		# the recommended state would make every doctor report not-ok forever.
		"game_view": RuntimeBridgeScript.game_view_state(),
		"clients": clients,
		"warnings": warnings,
	}
	if not dotnet.is_empty():
		report["dotnet"] = dotnet
	if not known_issues.is_empty():
		report["known_issues"] = known_issues
	return {"json": report}


## doctor's error_breaks block: whether a game the agent starts skips the debugger's pause at a script error, and
## why or why not, in the words a person can act on (RunTools.policy_now decides; play_scene obeys the same call).
func _error_breaks_report() -> Dictionary:
	var p: Dictionary = RunToolsScript.policy_now()
	var on := bool(p.get("on", false))
	var out := {"agent_runs_skip_pause": on}
	if on:
		out["source"] = str(p.get("source", ""))
		out["note"] = "play_scene launches with %s: a script error is logged (game_logs) and the game keeps running. Opt out with the project setting %s=false or %s=0." % [
			RunToolsScript.IGNORE_BREAKS_FLAG, RunToolsScript.IGNORE_BREAKS_SETTING, RunToolsScript.IGNORE_BREAKS_ENV]
	else:
		out["why"] = str(p.get("why", ""))
		out["note"] = "a script error in a game the editor launches pauses it in the debugger; runtime tools then answer at once that it is paused (get_play_state shows debugger_break)."
	return out


## What Claude Code's tool search holds from the first turn (v1.16). It defers every MCP tool
## schema by default, so the figure that matters THERE is not a tier's full bytes but the tools
## that opted out of deferral with `anthropic/alwaysLoad`, which the server sends only to a
## peer on MCP 2025-06-18 or newer. Read off the specs this install really ships, so the bytes
## are the wire bytes, `_meta` included; each deferred tool still costs its name, which this
## does not price. `specs` is the advertised surface at the current dial; `meta_sent` is
## whether the connected client gets `_meta` at all.
func _tool_search_report(specs: Array, meta_sent: bool) -> Dictionary:
	var upfront: Array = []
	var names: Array = []
	for s in specs:
		var hints: Variant = (s as Dictionary).get("_meta")
		if hints is Dictionary and bool((hints as Dictionary).get("anthropic/alwaysLoad", false)):
			upfront.append(s)
			names.append(str((s as Dictionary).get("name", "")))
	var bytes := JSON.stringify(upfront).to_utf8_buffer().size() if not upfront.is_empty() else 0
	return {
		"always_load": names,
		"tools": names.size(),
		"bytes": bytes,
		"approx_tokens": int(bytes / 4.0),
		"deferred_tools": specs.size() - names.size(),
		"note": ("Claude Code defers every other tool schema behind tool search: these always_load tools are all it holds at session start, plus the name of each deferred tool. A client without tool search loads the whole tier (per_tier)."
			if meta_sent else "The connected client negotiated an MCP revision older than 2025-06-18, which has no Tool._meta, so no always_load hint is sent and the whole tier loads (per_tier)."),
	}


## doctor's per-client warnings, from staleness() rows: a config that does not carry the current
## endpoint URL, and a Claude Desktop bridge that runs mcp-remote without an exact version.
func _client_warnings(clients: Array) -> Array:
	var out: Array = []
	for c in clients:
		var who := str(c.get("client", "?"))
		if not bool(c.get("current", true)):
			out.append("%s config (%s) does not carry the current endpoint URL: press Connect Detected Clients on the Beckett dock to rewrite it" % [who, str(c.get("path", ""))])
		if c.has("unpinned"):
			out.append("%s runs an unpinned mcp-remote (\"%s\"): npx fetches whatever npm serves under that name on every launch, with the endpoint URL (token included when auth is on) in its arguments. Press Connect Detected Clients on the Beckett dock again: it pins that argument to mcp-remote@%s and makes the URL current, and leaves the rest of the entry (command, other arguments, env) as it is." % [who, str(c["unpinned"]), MCPClientConfigScript.MCP_REMOTE_VERSION])
	return out


## The C# block of doctor, {} when this is not a C# situation (see DotnetCheck.applies): the
## SDKs found, what the project and engine need, and whether the first satisfies the second.
## Every problem also lands in `warnings`, in the same plain words build_csharp returns.
func _dotnet_report(warnings: Array) -> Dictionary:
	if not DotnetCheckScript.applies():
		return {}
	var insp: Dictionary = DotnetCheckScript.inspect("", Engine.get_version_info())
	var verdict: Dictionary = insp["check"]
	var versions: Array = []
	for s in insp["sdks"]:
		versions.append(str((s as Dictionary).get("version", "")))
	var proj: Dictionary = insp["proj"]
	var out := {
		"sdks": versions,
		"needs_sdk": int(verdict["need"]),
		"satisfied": bool(verdict["ok"]),
	}
	if not proj.is_empty():
		out["csproj"] = str(proj.get("file", ""))
		out["godot_sdk"] = str(proj.get("godot_sdk", ""))
		out["targets"] = proj.get("targets", [])
	for p in verdict["problems"]:
		warnings.append("C#: %s %s" % [str((p as Dictionary).get("message", "")), str((p as Dictionary).get("suggestion", ""))])
	return out


# (logs_read moved to test_tools.gd — see the note in _register.)
