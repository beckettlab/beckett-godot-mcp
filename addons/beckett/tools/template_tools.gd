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
##
## The bundled folder sits behind a .gdignore. Template scenes point at res:// paths that only
## exist after the copy, so the editor must not scan them: an export that kept the addon used
## to load them and log "File not found" for every script. DirAccess/FileAccess ignore it.

var server

const CallArgs := preload("res://addons/beckett/core/callargs.gd")
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the read rule for a template folder, the write rule for what it is copied to
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
	# A template is a folder NAME. A separator, a colon or ".." in it would point at any folder on the
	# machine and copy its files into the project, where read_file would hand them back.
	var src := "" if (tpl.contains("/") or tpl.contains("\\") or tpl.contains(":") or tpl.contains("..")) else _template_dir(tpl)
	if src.is_empty():
		return {"error": "No template '%s'." % tpl, "json": {"available": _list_templates()}}
	# A project template folder can be a link out of the project; the bundled ones are Beckett's own files
	# (and the addon itself may be linked in from a dev checkout), so only the project's are held to it.
	var guard: Dictionary = PathGuard.check_read(src) if src.begins_with(PROJECT_DIR) else {}
	if guard.has("error"):
		return guard

	var dir := DirAccess.open(src)
	var files: Array = []
	for f in dir.get_files():
		if _copyable(str(f)):
			files.append(str(f))
	if files.is_empty():
		return {"error": "Template '%s' has no files." % tpl}
	if src.begins_with(PROJECT_DIR):
		# Every file is opened and copied into the project, where read_file hands it back, so a file of a
		# project template that is a link leading outside is refused too (the folder being fine is not enough).
		var read_memo := {}
		for f in files:
			var fg: Dictionary = PathGuard.check_read(src.path_join(str(f)), read_memo)
			if fg.has("error"):
				return fg
			if fg.has("note"):
				guard = fg
	var force := CallArgs.flag(args, "force")
	# Every file lands under res://, so each target is checked before the first one is written: a link in
	# the project that leaves it (res://scripts as a junction, say) must not take a template's files out.
	var memo := {}
	for f in files:
		var perr: String = PathGuard.write_path_error("res://" + str(f), memo)
		if not perr.is_empty():
			return {"error": "res://%s: %s. Nothing was written." % [str(f), perr]}

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
	var editor_notes: Array = []  # scenes the editor is holding open over what we just wrote
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
		var bad := BeckettProjectTools.verify_write(to, text)
		if not bad.is_empty():
			bad["json"] = {"wrote": wrote}
			return bad
		var note := BeckettProjectTools.sync_written_file(to)
		if not note.is_empty():
			editor_notes.append(to + ":" + note)
		wrote.append(to)

	# The template — not apply_template — decides whether it owns the main scene.
	var manifest := _manifest(src)
	var main_scene := str(manifest.get("main_scene", ""))
	var main_skipped := ""
	if not main_scene.is_empty() and src.begins_with(PROJECT_DIR):
		# The manifest is a file the project supplies: the scene it names is opened by the editor, so it is
		# read under the same rule (a bundled template names a res:// scene of its own).
		var mg: Dictionary = PathGuard.check_read(main_scene)
		if mg.has("error"):
			main_skipped = str(mg["error"])
			main_scene = ""
	if not main_scene.is_empty() and FileAccess.file_exists(main_scene):
		ProjectSettings.set_setting("application/run/main_scene", main_scene)
		ProjectSettings.save()
		if Engine.is_editor_hint() and bool(manifest.get("open", true)):
			EditorInterface.open_scene_from_path(main_scene)
	else:
		main_scene = ""

	var out := {
		"template": tpl,
		"description": str(manifest.get("description", "")),
		"wrote": wrote,
		"disk_verified": true,
		"main_scene": main_scene,
		"next": "Customize the copied files to your needs. Confirm the structure with get_scene_tree before relying on it.",
	}
	if not editor_notes.is_empty():
		out["editor_notes"] = editor_notes
	if not main_skipped.is_empty():
		out["main_scene_skipped"] = main_skipped
	return PathGuard.noted({"json": out}, guard)


## Source files only: editor sidecars and the manifest stay behind, and so does every dotfile.
## A .gdignore copied to res:// would hide the user's whole project from the editor.
static func _copyable(file_name: String) -> bool:
	return not (file_name.begins_with(".") or file_name.ends_with(".uid")
		or file_name.ends_with(".import") or file_name == "template.json")


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
