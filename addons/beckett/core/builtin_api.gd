@tool
extends RefCounted

## Methods, properties and constants of the built-in Variant types: Vector3, Transform3D,
## Basis, Color, String, Array, Dictionary and the rest. ClassDB only knows Object classes, so
## describe_class and find_methods were blind to exactly the math types an agent reaches for
## most (field report 2026-09-29: find_methods class=Transform3D found nothing, and quietly
## searched every OTHER class instead).
##
## GDScript has no way to list a Variant type's methods, but the engine can print them:
## `--dump-extension-api` writes extension_api.json, and its builtin_classes section is the
## same table the GDScript analyzer checks against. So: one child run of THIS editor binary
## (about 1 s, once per engine build), kept compact under .godot/beckett/, after which every
## call is a small file read that always matches the running engine version.

const Subprocess := preload("res://addons/beckett/core/subprocess.gd")

const WORK_DIR := "res://.godot/beckett"
const TIMEOUT_MS := 30000

static var _table: Dictionary = {}
static var _failure := ""


## Every built-in Variant type name. Nil is not a type anyone asks about, and Object is a
## ClassDB class that describe_class already covers.
static func type_names() -> PackedStringArray:
	var out := PackedStringArray()
	for t in range(1, TYPE_MAX):
		if t != TYPE_OBJECT:
			out.append(type_string(t))
	return out


static func is_builtin(name: String) -> bool:
	return not name.is_empty() and type_names().has(name)


## {type: {methods: [{name, signature}], members: [{name, type}], constants: [name]}}, or {}
## when the dump could not be produced (last_error() says why). A failure is remembered for
## the session: the dump is a blocking child run, and retrying it on every call would stall
## the editor each time for the same answer.
static func table() -> Dictionary:
	if not _table.is_empty():
		return _table
	if not _failure.is_empty():
		return {}
	var cache := _cache_path()
	if FileAccess.file_exists(cache):
		var cached: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache))
		if cached is Dictionary and not (cached as Dictionary).is_empty():
			_table = cached
			return _table
	var dumped := _dump()
	if dumped.has("error"):
		_failure = str(dumped["error"])
		return {}
	_table = dumped["table"]
	var f := FileAccess.open(cache, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_table))
		f.close()
	return _table


static func last_error() -> String:
	return _failure


## One cache file per engine BUILD: a patch release or a custom build can add methods.
static func _cache_path() -> String:
	var v := Engine.get_version_info()
	var key := ("%s_%s" % [str(v.get("hex", 0)), str(v.get("hash", "")).left(12)]).validate_filename()
	return ProjectSettings.globalize_path(WORK_DIR).path_join("builtin_api_%s.json" % key)


static func _dump() -> Dictionary:
	var dir := ProjectSettings.globalize_path(WORK_DIR).path_join("api_dump")
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	# --path must name a project. A bare one of our own, so the dump boots nothing of the
	# user's (no autoloads, no extensions), and --path also makes it the working directory,
	# which is where the dump is written.
	var proj := dir.path_join("project.godot")
	if not FileAccess.file_exists(proj):
		var pf := FileAccess.open(proj, FileAccess.WRITE)
		if pf == null:
			return {"error": "cannot write %s (%s)" % [proj, error_string(FileAccess.get_open_error())]}
		pf.store_string("config_version=5\n")
		pf.close()
	var out_file := dir.path_join("extension_api.json")
	if FileAccess.file_exists(out_file):
		DirAccess.remove_absolute(out_file)
	# Quiet: the engine prints "Dumping Extension API" even under --quiet, and on Linux and macOS a plain
	# create_process child would print it into this process's own stdout.
	var pid := Subprocess.spawn_quiet(OS.get_executable_path(),
		PackedStringArray(["--headless", "--quiet", "--no-header", "--path", dir, "--dump-extension-api"]))
	if pid <= 0:
		return {"error": "could not start %s" % OS.get_executable_path()}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(20)
	if OS.is_process_running(pid):
		OS.kill(pid)
		return {"error": "the engine API dump did not finish within %d s" % (TIMEOUT_MS / 1000.0)}
	if not FileAccess.file_exists(out_file):
		return {"error": "the engine API dump wrote no extension_api.json"}
	var api: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_file))
	DirAccess.remove_absolute(out_file)
	if not (api is Dictionary):
		return {"error": "the engine API dump was not valid JSON"}
	return {"table": compact((api as Dictionary).get("builtin_classes", []))}


## extension_api.json builtin_classes -> the compact table. Pure, so the unit suite pins it.
## Constants are names only: Color alone has ~150 named colors, and the value of Vector3.UP
## is not what anyone is looking up.
static func compact(builtin_classes: Array) -> Dictionary:
	var out := {}
	for bc in builtin_classes:
		if not (bc is Dictionary):
			continue
		var methods: Array = []
		for m in (bc as Dictionary).get("methods", []):
			methods.append({"name": str(m.get("name", "")), "signature": signature(m)})
		var members: Array = []
		for mm in (bc as Dictionary).get("members", []):
			members.append({"name": str(mm.get("name", "")), "type": str(mm.get("type", ""))})
		var constants: Array = []
		for c in (bc as Dictionary).get("constants", []):
			constants.append(str(c.get("name", "")))
		out[str(bc.get("name", ""))] = {"methods": methods, "members": members, "constants": constants}
	return out


## "Transform3D looking_at(Vector3 target, Vector3 up = Vector3(0, 1, 0), ...)", the same
## "Ret name(Type arg)" shape reflection.gd prints for ClassDB methods.
static func signature(m: Dictionary) -> String:
	var parts: Array = []
	for a in m.get("arguments", []):
		var s := "%s %s" % [str(a.get("type", "Variant")), str(a.get("name", "arg"))]
		if (a as Dictionary).has("default_value"):
			s += " = " + str(a["default_value"])
		parts.append(s)
	if bool(m.get("is_vararg", false)):
		parts.append("...")
	var prefix := "static " if bool(m.get("is_static", false)) else ""
	return "%s%s %s(%s)" % [prefix, str(m.get("return_type", "void")), str(m.get("name", "?")), ", ".join(parts)]
