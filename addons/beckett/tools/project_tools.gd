@tool
extends RefCounted
class_name BeckettProjectTools

## Filesystem + project settings (P0). Generic file IO (any text file, not just scripts),
## content search, and project-setting read/write.

var server

const _TEXT_EXTS := ["gd", "tscn", "tres", "cfg", "json", "md", "txt", "gdshader", "shader", "cs", "import", "godot"]


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
		"description": "Write a text file under res:// (or user://), path-traversal guarded. Refreshes the editor filesystem.",
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
	if Engine.is_editor_hint() and path.begins_with("res://"):
		EditorInterface.get_resource_filesystem().update_file(path)
	return {"text": "wrote %d bytes to %s" % [content.length(), path]}


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
	var v: Variant = _setting_value(args.get("value"))
	ProjectSettings.set_setting(s, v)
	var err := ProjectSettings.save()
	if err != OK:
		return {"error": "saved setting in-memory but project.godot write failed: %s" % error_string(err)}
	return {"text": "set %s = %s" % [s, str(v)]}


## Recover a structured value an MCP client may have JSON-stringified (e.g. a plugin list
## arriving as "[\"res://addons/x/plugin.cfg\"]"), and store an all-string list as a
## PackedStringArray so settings like editor_plugins/enabled serialize correctly (a plain
## String there breaks plugin loading on the next project reload).
static func _setting_value(value: Variant) -> Variant:
	if value is String:
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
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


# (logs_read moved to test_tools.gd — see the note in _register.)
