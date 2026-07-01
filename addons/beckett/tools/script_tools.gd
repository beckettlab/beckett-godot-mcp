@tool
extends RefCounted
class_name BeckettScriptTools

## GDScript dev-loop (D3) — Godot's advantage over UE's Live Coding: scripts reload
## instantly, no compile step. Crucially, write_script VALIDATES (parses) before it
## writes by default — closing the #1 AI-on-Godot failure mode (GDScript hallucination)
## at the source instead of letting broken code land on disk.

var server  # mcp_server node


func _register(registry) -> void:
	registry.register({
		"name": "validate_script",
		"description": "Parse/compile GDScript WITHOUT writing it. Pass 'content' (source) or 'path' (res://). Returns whether it compiles — use before write_script to catch hallucinated APIs.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"content": {"type": "string"},
			"path": {"type": "string", "description": "res:// path to validate an existing file"},
		}},
		"handler": Callable(self, "_validate_script"),
	})
	registry.register({
		"name": "write_script",
		"description": "Write a GDScript (or other text, e.g. .cs) file under res://. GDScript is validated first by default — refuses code that doesn't compile; non-.gd files (C#, config…) are written as-is (use build_csharp to compile-check C#). Set validate=false to force.",
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
		"description": "Surgically edit an existing res:// file without rewriting it whole. edits = an ordered array; each item is {find, replace[, all]} (find must match EXACTLY once unless all:true), {append: text}, or {prepend: text}. Atomic + safe: nothing is written if any anchor is missing/ambiguous or (for .gd) the result fails to compile. Prefer this over write_script for small changes.",
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
	if args.has("content"):
		content = str(args["content"])
	elif args.has("path"):
		var path := str(args["path"])
		if not FileAccess.file_exists(path):
			return {"error": "No file at: %s" % path}
		content = FileAccess.get_file_as_string(path)
	else:
		return {"error": "Provide 'content' or 'path'."}
	var v := _compile(content)
	if v["valid"]:
		return {"text": "OK — script compiles."}
	return {"error": "Script does not compile: %s" % v["detail"],
		"suggestion": "Fix the reported error; use describe_class/find_methods to confirm the real API."}


func _write_script(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := _guard_path(path)
	if not guard.is_empty():
		return {"error": guard}
	var content := str(args.get("content", ""))
	# The compile-gate is GDScript-only (in-process GDScript.reload). C#/.cs and other text
	# files can't be gated here — C# compiles out-of-process; check it with build_csharp.
	var validate := bool(args.get("validate", true)) and path.ends_with(".gd")
	if validate:
		var v := _compile(content)
		if not v["valid"]:
			return {"error": "Refusing to write: script does not compile (%s)." % v["detail"],
				"suggestion": "Fix the error or pass validate=false to force. Use describe_class/find_methods to confirm the API."}
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "Cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	f.close()
	# Make the editor pick up the new/changed file.
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().update_file(path)
	if path.ends_with(".cs"):
		return {"text": "wrote %d bytes to %s — C# not compile-checked; run build_csharp to verify it compiles" % [content.length(), path]}
	return {"text": "wrote %d bytes to %s" % [content.length(), path]}


func _read_script(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if not FileAccess.file_exists(path):
		return {"error": "No file at: %s" % path}
	return {"text": FileAccess.get_file_as_string(path)}


func _attach_script(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor."}
	var target := str(args.get("target", ""))
	var node := root.get_node_or_null(NodePath(target))
	if node == null:
		node = root.find_child(target, true, false)
	if node == null:
		return {"error": "Could not resolve target: %s" % target}
	var path := str(args.get("path", ""))
	var scr := ResourceLoader.load(path)
	if scr == null or not (scr is Script):
		return {"error": "Not a script: %s" % path}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP attach_script")
	ur.add_do_property(node, "script", scr)
	ur.add_undo_property(node, "script", node.get_script())
	ur.commit_action()
	return {"text": "attached %s to %s" % [path, node.name]}


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
		if occurrences > 1 and not bool(e.get("all", false)):
			return {"error": "edit %d: anchor matches %d times — make it unique or pass all:true. Anchor: \"%s\"" % [i, occurrences, _short(find)]}
		text = text.replace(find, replace)
		applied += 1
	var validate := bool(args.get("validate", true)) and path.ends_with(".gd")
	if validate:
		var v := _compile(text)
		if not v["valid"]:
			return {"error": "Refusing to write: result does not compile (%s)." % v["detail"],
				"suggestion": "Adjust the edits, or pass validate=false to force."}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "Cannot open for write: %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(text)
	f.close()
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().update_file(path)
	return {"text": "patched %s — %d edit(s), now %d bytes" % [path, applied, text.length()]}


# ---------------------------------------------------------------- helpers

## Compile GDScript source in-memory. Returns {valid:bool, detail:String}.
func _compile(content: String) -> Dictionary:
	var gd := GDScript.new()
	gd.source_code = content
	var err := gd.reload(false)
	if err == OK:
		return {"valid": true, "detail": ""}
	return {"valid": false, "detail": "%s — see the Godot Output panel (or get_log) for the line." % error_string(err)}


## Project-scope + traversal guard for writes.
func _guard_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "path must be project-scoped (start with res://)"
	if path.contains(".."):
		return "path must not contain '..'"
	return ""


## One-line, length-capped anchor for error messages.
func _short(s: String) -> String:
	var one := s.replace("\n", "\\n").replace("\t", "\\t")
	return one if one.length() <= 60 else one.substr(0, 57) + "..."
