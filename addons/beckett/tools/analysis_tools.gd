@tool
extends RefCounted
class_name BeckettAnalysisTools

## Project statistics (L1, core) — a pure, headless-safe static scan over the project
## filesystem. The heavier L4 analyses (find_unused_resources, detect_circular_dependencies)
## live in analysis_pro_tools.gd so the Lite build ships zero tier-3+ code.

var server

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the walk does not follow a link out of the project

const _SKIP_DIRS := [".godot", ".git", ".import"]
const _MAX_FILES := 6000


func _register(registry) -> void:
	registry.register({
		"name": "get_project_statistics",
		"description": "Project overview: file/script/scene/resource counts, total GDScript lines, autoloads, main scene, input-action count, Godot version. Read-only static scan.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_statistics"),
	})


# ---------------------------------------------------------------- statistics

func _statistics(_args: Dictionary) -> Dictionary:
	var skipped: Array = []  # links that lead out of the project: not followed (see PathGuard.walk_skip)
	var files := _all_files([], skipped)
	var by_ext: Dictionary = {}
	var gd_lines := 0
	var scripts := 0
	var scenes := 0
	var resources := 0
	for f in files:
		var ext: String = f.get_extension().to_lower()
		by_ext[ext] = int(by_ext.get(ext, 0)) + 1
		match ext:
			"gd":
				scripts += 1
				gd_lines += FileAccess.get_file_as_string(f).split("\n").size()
			"tscn":
				scenes += 1
			"tres", "res":
				resources += 1
	var autoloads: Array = []
	var input_actions := 0
	for p in ProjectSettings.get_property_list():
		var n: String = str(p.get("name", ""))
		if n.begins_with("autoload/"):
			autoloads.append(n.substr(9))
		elif n.begins_with("input/"):
			input_actions += 1
	var stats := {
		"godot_version": Engine.get_version_info().get("string", ""),
		"total_files": files.size(),
		"scripts": scripts,
		"gdscript_lines": gd_lines,
		"scenes": scenes,
		"resources": resources,
		"by_extension": by_ext,
		"autoloads": autoloads,
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"input_actions": input_actions,
		"capped": files.size() >= _MAX_FILES,
	}
	stats.merge(PathGuard.skipped_note(skipped))
	return {"json": stats}


# ---------------------------------------------------------------- file walk

## `skipped` collects what the walk left out because it is a link that leads outside the project. Only
## the .gd files are opened here (for their line count), so only they are checked as files; a folder
## is checked either way, because that is where a whole outside tree would come in.
func _all_files(exts: Array, skipped: Array = []) -> Array:
	var out: Array = []
	_walk("res://", exts, out, skipped, {})
	return out


func _walk(path: String, exts: Array, out: Array, skipped: Array, memo: Dictionary) -> void:
	if out.size() >= _MAX_FILES:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if e == "." or e == "..":
			e = dir.get_next()
			continue
		var full := path.path_join(e)
		if dir.current_is_dir():
			if not _SKIP_DIRS.has(e):
				if PathGuard.walk_skip(full, memo):
					skipped.append(full)
				else:
					_walk(full, exts, out, skipped, memo)
		elif exts.is_empty() or exts.has(e.get_extension().to_lower()):
			if e.get_extension().to_lower() == "gd" and PathGuard.walk_skip(full, memo):
				skipped.append(full)
			else:
				out.append(full)
		if out.size() >= _MAX_FILES:
			break
		e = dir.get_next()
	dir.list_dir_end()
