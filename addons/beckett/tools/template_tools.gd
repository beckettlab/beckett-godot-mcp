@tool
extends RefCounted
class_name BeckettTemplateTools

## Templates (B-tpl) — instantiate a whole bundled (or project-supplied) starter into res://
## in one call: scene(s) + scripts + resources, optionally setting the main scene. This moves
## the most error-prone part of authoring — assembling many nodes/resources by hand — out of
## model prose and into deterministic code, which is exactly where a smaller model needs it.
##
## A template is a folder of plain project files plus an optional `template.json`:
##   { "description": "...", "main_scene": "res://main.tscn", "open": true }
## Bundled templates ship under addons/beckett/templates/; a project can add or override its
## own under res://.beckett/templates/ (same bundled+project pattern as skills).

var server

const BUNDLED_DIR := "res://addons/beckett/templates"
const PROJECT_DIR := "res://.beckett/templates"


func _register(registry) -> void:
	registry.register({
		"name": "apply_template",
		"description": "Instantiate a bundled (or project) template into res:// in one call — copies its files and, if the template declares a main_scene, sets and opens it. Generic: a template can be a game starter, a UI screen, a settings menu, a test harness. Project templates under res://.beckett/templates/ override bundled ones. Call with no 'template' to list what's available.",
		"input_schema": {"type": "object", "properties": {
			"template": {"type": "string", "description": "template name, e.g. platformer-2d"},
			"force": {"type": "boolean", "description": "overwrite existing res:// files (default false)"},
		}},
		"handler": Callable(self, "_apply_template"),
	})


func _apply_template(args: Dictionary) -> Dictionary:
	var tpl := str(args.get("template", ""))
	if tpl.is_empty():
		return {"json": {"error": "apply_template requires 'template'.", "available": _list_templates()}}
	var src := _template_dir(tpl)
	if src.is_empty():
		return {"error": "No template '%s'." % tpl, "json": {"available": _list_templates()}}

	var dir := DirAccess.open(src)
	# Copy source files only — skip editor sidecars and the manifest itself.
	var files: Array = []
	for f in dir.get_files():
		var fn := str(f)
		if fn.ends_with(".uid") or fn.ends_with(".import") or fn == "template.json":
			continue
		files.append(fn)
	if files.is_empty():
		return {"error": "Template '%s' has no files." % tpl}
	var force := bool(args.get("force", false))

	if not force:
		var clash: Array = []
		for f in files:
			if FileAccess.file_exists("res://" + str(f)):
				clash.append("res://" + str(f))
		if not clash.is_empty():
			return {"error": "Refusing to overwrite existing files (pass force=true to replace).",
				"json": {"would_overwrite": clash}}

	# Scripts/resources before scenes so a scene's ext_resource refs resolve on open.
	var ordered: Array = []
	for f in files:
		if not str(f).ends_with(".tscn"):
			ordered.append(f)
	for f in files:
		if str(f).ends_with(".tscn"):
			ordered.append(f)

	var wrote: Array = []
	for f in ordered:
		var fname := str(f)
		var to := "res://" + fname
		var text := FileAccess.get_file_as_string(src.path_join(fname))
		var out := FileAccess.open(to, FileAccess.WRITE)
		if out == null:
			return {"error": "Cannot write %s (%s)" % [to, error_string(FileAccess.get_open_error())],
				"json": {"wrote": wrote}}
		out.store_string(text)
		out.close()
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().update_file(to)
		wrote.append(to)

	# The template — not apply_template — decides whether it owns the main scene.
	var manifest := _manifest(src)
	var main_scene := str(manifest.get("main_scene", ""))
	if not main_scene.is_empty() and FileAccess.file_exists(main_scene):
		ProjectSettings.set_setting("application/run/main_scene", main_scene)
		ProjectSettings.save()
		if Engine.is_editor_hint() and bool(manifest.get("open", true)):
			EditorInterface.open_scene_from_path(main_scene)
	else:
		main_scene = ""

	return {"json": {
		"template": tpl,
		"description": str(manifest.get("description", "")),
		"wrote": wrote,
		"main_scene": main_scene,
		"next": "Customize the copied files to your needs. Confirm structure with assert_scene before relying on it.",
	}}


func _template_dir(name: String) -> String:
	var proj := PROJECT_DIR.path_join(name)
	if DirAccess.dir_exists_absolute(proj):
		return proj
	var bundled := BUNDLED_DIR.path_join(name)
	if DirAccess.dir_exists_absolute(bundled):
		return bundled
	return ""


func _manifest(src: String) -> Dictionary:
	var p := src.path_join("template.json")
	if not FileAccess.file_exists(p):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed if parsed is Dictionary else {}


func _list_templates() -> Array:
	var seen: Dictionary = {}
	for root in [PROJECT_DIR, BUNDLED_DIR]:
		var dir := DirAccess.open(root)
		if dir == null:
			continue
		dir.list_dir_begin()
		var e := dir.get_next()
		while e != "":
			if dir.current_is_dir() and not e.begins_with("."):
				if not seen.has(e):
					seen[e] = {"name": e, "source": "project" if root == PROJECT_DIR else "bundled"}
			e = dir.get_next()
		dir.list_dir_end()
	var out: Array = seen.values()
	out.sort_custom(func(a, b): return str(a.name) < str(b.name))
	return out
