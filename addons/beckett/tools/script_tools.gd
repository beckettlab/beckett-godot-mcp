@tool
extends RefCounted
class_name BeckettScriptTools

## GDScript dev-loop (D3) — Godot's advantage over UE's Live Coding: scripts reload
## instantly, no compile step. Crucially, write_script VALIDATES (parses) before it
## writes by default — closing the #1 AI-on-Godot failure mode (GDScript hallucination)
## at the source instead of letting broken code land on disk.

const Reflect := preload("res://addons/beckett/core/reflection.gd")
const Internals := preload("res://addons/beckett/core/internals.gd")  # attach_script never puts Beckett's own scripts on a node
const ProjectToolsScript := preload("res://addons/beckett/tools/project_tools.gd")
const WarningCheck := preload("res://addons/beckett/core/warning_check.gd")
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")
const PersistGuard := preload("res://addons/beckett/core/persist_guard.gd")  # attach_script inside an instanced scene
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags arrive as text from lenient clients

var server  # mcp_server node


func _register(registry) -> void:
	registry.register({
		"name": "validate_script",
		"description": "Parse/compile GDScript WITHOUT writing it. Pass 'content' (source) or 'path' (res://). Returns whether it compiles, plus the GDScript warnings the editor would show (unused variables, shadowing, integer division...). Use before write_script to catch hallucinated APIs. A class_name from a file written outside the editor is registered first. When validating 'content' destined for an existing file, ALSO pass its 'path' so a real cross-file class_name duplicate is still reported.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"content": {"type": "string"},
			"path": {"type": "string", "description": "res:// path — the file to validate, or (with content) the file the content is destined for"},
			"warnings": {"type": "boolean", "description": "also report GDScript warnings (default true; runs a ~0.3 s headless check)"},
		}},
		"handler": Callable(self, "_validate_script"),
	})
	registry.register({
		"name": "write_script",
		"description": "Write a GDScript (or other text, e.g. .cs) file under res://. GDScript is validated first by default — refuses code that doesn't compile; non-.gd files (C#, config…) are written as-is (use build_csharp to compile-check C#). Set validate=false to force. Reads the file back (disk_verified).",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "res:// path, e.g. res://player.gd"},
			"content": {"type": "string"},
			"validate": {"type": "boolean", "description": "validate before writing (default true)"},
		}, "required": ["path", "content"]},
		"handler": Callable(self, "_write_script"),
	})
	registry.register({
		"name": "read_script",
		"description": "Read a script/text file from res://.",
		"readonly": true,
		# Claude Code spills a result over 50,000 chars to a file, and a script is read whole to be
		# edited: its text IS the answer, not a view of it. 50,000 chars is ~1,300 lines, which a
		# real game's manager script passes; 200,000 (~50k tokens, ~5,000 lines) is far enough that
		# what still spills is a file nobody wants in context whole.
		"max_result_chars": 200000,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"},
		}, "required": ["path"]},
		"handler": Callable(self, "_read_script"),
	})
	registry.register({
		"name": "attach_script",
		"description": "Attach a script (res:// path) to a node in the open scene (undoable).",
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"path": {"type": "string"},
		}, "required": ["target", "path"]},
		"handler": Callable(self, "_attach_script"),
	})
	registry.register({
		"name": "script_patch",
		"description": "Surgically edit an existing res:// file without rewriting it whole. edits = an ordered array; each item is {find, replace[, all]} (find must match EXACTLY once unless all:true), {append: text}, or {prepend: text}. Atomic + safe: nothing is written if any anchor is missing/ambiguous or (for .gd) the result fails to compile. Reads the file back (disk_verified). Prefer this over write_script for small changes.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "res:// path to an existing file"},
			"edits": {"type": "array", "description": "[{find, replace, all?} | {append} | {prepend}] applied in order", "items": {"type": "object"}},
			"validate": {"type": "boolean", "description": "compile-check the result before writing (default true, .gd only)"},
		}, "required": ["path", "edits"]},
		"handler": Callable(self, "_script_patch"),
	})


# ---------------------------------------------------------------- handlers

func _validate_script(args: Dictionary) -> Dictionary:
	var content: String
	var vpath := ""
	var guard: Dictionary = {}  # the read check, only when the file is read from `path` (content is checked as given)
	if args.has("content"):
		content = str(args["content"])
		vpath = str(args.get("path", ""))  # optional: lets the class_name mask know the target
	elif args.has("path"):
		vpath = str(args["path"])
		guard = PathGuard.check_read(vpath)
		if guard.has("error"):
			return guard
		if not FileAccess.file_exists(vpath):
			return {"error": "No file at: %s" % vpath}
		content = FileAccess.get_file_as_string(vpath)
	else:
		return {"error": "Provide 'content' or 'path'."}
	var v := _compile(content, vpath)
	var synced := _synced_note(v)
	if not v["valid"]:
		return _heal_echo(v, {"error": "Script does not compile: %s%s" % [v["detail"], synced],
			"suggestion": "Fix the reported error; use describe_class/find_methods to confirm the real API."})
	if not CallArgs.flag(args, "warnings", true):
		return PathGuard.noted(_heal_echo(v, {"text": "OK: script compiles (warnings not checked).%s" % synced}), guard)
	# The source that compiled (class_name mask included), checked as the file it is meant
	# for. Line numbers survive the mask, so they match what the caller sent.
	var w := WarningCheck.collect(str(v["source"]), vpath)
	if not bool(w.get("ok", false)):
		return PathGuard.noted(_heal_echo(v, {"text": "OK: script compiles. Warnings could not be checked: %s.%s" % [str(w.get("reason", "")), synced]}), guard)
	var warns: Array = w["warnings"]
	var lines: Array = []
	for x in warns:
		lines.append("line %d %s: %s" % [int(x["line"]), str(x["code"]), str(x["message"])])
	var text := "OK: script compiles, no warnings." if warns.is_empty() \
		else "OK: script compiles, with %d warning(s):\n%s" % [warns.size(), "\n".join(lines)]
	var errs: Array = w["errors"]
	if not errs.is_empty():
		var elines: Array = []
		for e in errs:
			elines.append(("line %d: %s" % [int(e["line"]), str(e["message"])]) if int(e["line"]) > 0 else str(e["message"]))
		text += "\nLoading it in a game run raised an error the editor compile cannot see: " + "; ".join(elines)
	return PathGuard.noted(_heal_echo(v, {"text": text + _warning_scope_note(vpath) + synced}), guard)


func _write_script(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := _guard_path(path)
	if not guard.is_empty():
		return {"error": guard}
	var content := str(args.get("content", ""))
	# The compile-gate is GDScript-only (in-process GDScript.reload). C#/.cs and other text
	# files can't be gated here — C# compiles out-of-process; check it with build_csharp.
	var validate := CallArgs.flag(args, "validate", true) and path.ends_with(".gd")
	var synced := ""
	var v: Dictionary = {}
	if validate:
		v = _compile(content, path)
		synced = _synced_note(v)
		if not v["valid"]:
			return _heal_echo(v, {"error": "Refusing to write: script does not compile (%s).%s" % [v["detail"], synced],
				"suggestion": "Fix the error or pass validate=false to force. Use describe_class/find_methods to confirm the API."})
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "Cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	f.close()
	# Read it back before trusting it: the write succeeds the moment the bytes reach the OS.
	var bad := ProjectToolsScript.verify_write(path, content)
	if not bad.is_empty():
		return bad
	# Make the editor pick up the new/changed file. The shared path, so a script written into a
	# folder the editor has not seen yet (which update_file silently ignores) says so.
	var fs_note := ProjectToolsScript.sync_written_file(path)
	if path.ends_with(".cs"):
		return ProjectToolsScript.verified_reply(path, "wrote %d bytes to %s — C# not compile-checked; run build_csharp to verify it compiles%s" % [content.length(), path, fs_note])
	return _heal_echo(v, ProjectToolsScript.verified_reply(path, "wrote %d bytes to %s%s%s" % [content.length(), path, fs_note, synced]))


func _read_script(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := PathGuard.check_read(path)  # inside the project / user:// only, unless the owner opted out
	if guard.has("error"):
		return guard
	if not FileAccess.file_exists(path):
		return {"error": "No file at: %s" % path}
	return PathGuard.noted({"text": FileAccess.get_file_as_string(path)}, guard)


func _attach_script(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor."}
	var target := str(args.get("target", ""))
	# Shared resolver (v1.10.2): accepts ".", "/root", the scene root's OWN name, and
	# descendant names/paths. The hand-rolled lookup that lived here was the one
	# resolver copy missing the root-name alias, so attach_script target=<root name>
	# failed while create_node parent=<root name> worked.
	var node := Reflect.resolve(target) as Node
	if node == null:
		return {"error": Reflect.miss(target)}
	var path := str(args.get("path", ""))
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	if Internals.is_beckett_path(path):
		return {"error": Internals.file_text(path)}
	var scr := ResourceLoader.load(path)
	if scr == null or not (scr is Script):
		return {"error": "Not a script: %s" % path}
	if Internals.is_beckett_path((scr as Script).resource_path):
		return {"error": Internals.file_text(path)}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP attach_script")
	ur.add_do_property(node, "script", scr)
	ur.add_undo_property(node, "script", node.get_script())
	ur.commit_action()
	return PathGuard.noted(PersistGuard.attach({"text": "attached %s to %s" % [path, node.name]}, PersistGuard.verdict(root, node, PersistGuard.SET)), guard)


func _script_patch(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := _guard_path(path)
	if not guard.is_empty():
		return {"error": guard}
	if not FileAccess.file_exists(path):
		return {"error": "No file at: %s" % path, "suggestion": "Use write_script to create it."}
	var edits: Variant = args.get("edits", [])
	if not (edits is Array) or (edits as Array).is_empty():
		return {"error": "edits must be a non-empty array."}
	var text := FileAccess.get_file_as_string(path)
	var applied := 0
	for i in range((edits as Array).size()):
		var e: Variant = edits[i]
		if not (e is Dictionary):
			return {"error": "edit %d must be an object." % i}
		if e.has("append"):
			var tail := str(e["append"])
			if not text.is_empty() and not text.ends_with("\n"):
				text += "\n"
			text += tail
			applied += 1
			continue
		if e.has("prepend"):
			text = str(e["prepend"]) + text
			applied += 1
			continue
		if not e.has("find"):
			return {"error": "edit %d needs 'find' (+ 'replace'), or 'append'/'prepend'." % i}
		var find := str(e["find"])
		if find.is_empty():
			return {"error": "edit %d: 'find' must be non-empty." % i}
		var replace := str(e.get("replace", ""))
		var occurrences := text.count(find)
		if occurrences == 0:
			return {"error": "edit %d: anchor not found: \"%s\"" % [i, _short(find)],
				"suggestion": "read_script to copy the exact text, including indentation."}
		if occurrences > 1 and not CallArgs.flag(e, "all"):
			return {"error": "edit %d: anchor matches %d times — make it unique or pass all:true. Anchor: \"%s\"" % [i, occurrences, _short(find)]}
		text = text.replace(find, replace)
		applied += 1
	var validate := CallArgs.flag(args, "validate", true) and path.ends_with(".gd")
	var synced := ""
	var v: Dictionary = {}
	if validate:
		v = _compile(text, path)
		synced = _synced_note(v)
		if not v["valid"]:
			return _heal_echo(v, {"error": "Refusing to write: result does not compile (%s).%s" % [v["detail"], synced],
				"suggestion": "Adjust the edits, or pass validate=false to force."})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "Cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(text)
	f.close()
	var bad := ProjectToolsScript.verify_write(path, text)
	if not bad.is_empty():
		return bad
	var fs_note := ProjectToolsScript.sync_written_file(path)
	return _heal_echo(v, ProjectToolsScript.verified_reply(path, "patched %s — %d edit(s), now %d bytes%s%s" % [path, applied, text.length(), fs_note, synced]))


# ---------------------------------------------------------------- helpers

## Compile GDScript source in-memory. Returns {valid:bool, detail:String, source:String}, plus
## {synced} when it had to bring the editor up to date first.
func _compile(content: String, target_path: String = "") -> Dictionary:
	var v := _compile_once(content, target_path)
	if bool(v["valid"]) or not Engine.is_editor_hint():
		return v
	# The script may use a class_name from a file written OUTSIDE the editor, which the editor
	# has not registered yet ("Could not find type"), or call into a script whose loaded copy
	# is older than its file. Hand those to the editor and try once more. Reported either way,
	# since it changed what the editor knows (field report 2026-09-29).
	var s: Dictionary = ProjectToolsScript.sync_unsynced_scripts()
	if bool(s["scanning"]):
		v["detail"] += " (the editor is mid-scan, so a file written outside it may not be registered yet; call rescan_filesystem until scanning is false, then retry)"
		return v
	if (s["registered"] as Array).is_empty() and (s["reloaded"] as Array).is_empty():
		if not (s["pending"] as Array).is_empty():
			v["synced"] = s
		return v
	# The first attempt's parse error is history once the retry runs; see _heal_echo.
	var echo_from := -1
	if server != null and server.error_echo != null:
		echo_from = server.error_echo.mark()
	var again := _compile_once(content, target_path)
	again["synced"] = s
	if echo_from >= 0:
		again["echo_from"] = echo_from
	return again


## After a healed compile, error echo would still carry the FIRST attempt's "Parse Error:
## Identifier not declared" next to an OK result, and an agent reads that as the outcome.
## Echo only what was raised from the retry on (the server keeps a handler's own
## engine_errors instead of computing its own).
func _heal_echo(v: Dictionary, result: Dictionary) -> Dictionary:
	if v.has("echo_from") and server != null and server.error_echo != null:
		result["engine_errors"] = server.error_echo.echo_since(int(v["echo_from"]))
	return result


## " Registered ... first" for a result that needed _compile's sync, else "".
func _synced_note(v: Dictionary) -> String:
	if not v.has("synced"):
		return ""
	var s: Dictionary = v["synced"]
	var bits: Array = []
	for c in s.get("registered", []):
		bits.append("registered class_name %s (%s)" % [str(c["class"]), str(c["path"])])
	var reloaded: Array = s.get("reloaded", [])
	if not reloaded.is_empty():
		bits.append("handed %d script(s) that changed on disk back to the editor" % reloaded.size())
	var note := ""
	if not bits.is_empty():
		note = "\nFirst %s: written outside the editor, they were not known to it yet." % ", ".join(bits)
	var pending: Array = s.get("pending", [])
	if not pending.is_empty():
		var names: Array = []
		for c in pending:
			names.append("%s (%s)" % [str(c["class"]), str(c["path"])])
		note += ("\nclass_name %s sits in a folder the editor has not seen yet, which only a scan can register:" % ", ".join(names)
			+ " call rescan_filesystem (again after a moment, until 'pending' is gone), then validate again.")
	return note


## Say so when silence comes from the project's settings rather than from clean code.
func _warning_scope_note(path: String) -> String:
	if not bool(ProjectSettings.get_setting("debug/gdscript/warnings/enable", true)):
		return "\n(GDScript warnings are turned off in this project: debug/gdscript/warnings/enable.)"
	if path.begins_with("res://addons/") and bool(ProjectSettings.get_setting("debug/gdscript/warnings/exclude_addons", true)):
		return "\n(res://addons/ is excluded from warnings by debug/gdscript/warnings/exclude_addons.)"
	return ""


func _compile_once(content: String, target_path: String) -> Dictionary:
	# v1.9 B4 root-fix: a detached GDScript.reload() false-errors on ANY script whose
	# class_name is already registered ("hides a global script class") — which is every
	# re-validate of an existing named script. Mask the declaration (line numbers preserved)
	# when the registration is legitimate; keep the honest failure when it's a real
	# cross-file duplicate. See _mask_registered_class_name.
	var masked := _mask_registered_class_name(content, target_path)
	if masked.has("conflict"):
		return {"valid": false, "detail": str(masked["conflict"]), "source": content}
	var gd := GDScript.new()
	gd.source_code = str(masked["content"])
	var err := gd.reload(false)
	if err == OK:
		return {"valid": true, "detail": "", "source": str(masked["content"])}
	return {"valid": false, "detail": "%s — see the Godot Output panel (or get_log) for the line." % error_string(err), "source": str(masked["content"])}


## Neutralize a `class_name X` declaration ONLY when X is already registered in the global
## class list — the case that used to false-error every validate of an existing named script.
## The masking is a RENAME-IN-PLACE of just the name token (X -> __BeckettValidate, a name
## nothing registers): line numbers, any inline `extends`, and annotation attachment (`@tool`,
## `@icon`, the 4.5+ same-line `@abstract class_name X` form — verified empirically on 4.6.2)
## are all preserved. Self-references to X inside the body still resolve — X IS registered,
## which is exactly why the mask is needed; the temp name itself is never referenced. If X is
## registered by a DIFFERENT file than target_path, that's a real project error the engine
## would also reject on save: return it as {conflict} instead of masking it away.
func _mask_registered_class_name(content: String, target_path: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("(?m)^(?:@[A-Za-z_]+[ \\t]+)*class_name[ \\t]+([A-Za-z_][A-Za-z0-9_]*)")
	var m := re.search(content)
	if m == null:
		return {"content": content}
	var cname := m.get_string(1)
	var registered_path := ""
	for gc in ProjectSettings.get_global_class_list():
		if str(gc.get("class", "")) == cname:
			registered_path = str(gc.get("path", ""))
			break
	if registered_path.is_empty():
		return {"content": content}  # unregistered name: nothing to mask, self-refs need the line
	if not target_path.is_empty() and registered_path != target_path:
		return {"conflict": "class_name %s is already registered by %s — two scripts cannot share one class_name. Pick another name (or update that file instead)." % [cname, registered_path]}
	var out := content.substr(0, m.get_start(1)) + "__BeckettValidate" + content.substr(m.get_end(1))
	return {"content": out}


## Project-scope + traversal guard for writes. Scripts live in the project, so this is
## res:// only; the traversal and control-character rules are the shared PathGuard ones.
func _guard_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "path must be project-scoped (start with res://)"
	return PathGuard.write_path_error(path)


## One-line, length-capped anchor for error messages.
func _short(s: String) -> String:
	var one := s.replace("\n", "\\n").replace("\t", "\\t")
	return one if one.length() <= 60 else one.substr(0, 57) + "..."
