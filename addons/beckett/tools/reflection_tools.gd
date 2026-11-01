@tool
extends RefCounted
class_name BeckettReflectionTools

## Reflection-first tool set (D2): discovery (find_classes / describe_class / find_methods)
## + generic execution (describe_object / set_property / call_method) + scene tree.
## These few tools reach any Node / Resource / Object without per-domain wrappers.

const Reflect := preload("res://addons/beckett/core/reflection.gd")
const Internals := preload("res://addons/beckett/core/internals.gd")  # which methods fan out to every node below the target
const CallArgs := preload("res://addons/beckett/core/callargs.gd")
const BuiltinApi := preload("res://addons/beckett/core/builtin_api.gd")
const PersistGuard := preload("res://addons/beckett/core/persist_guard.gd")
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # why a res:// target would not resolve

## What a built-in type result has to tell the agent, since call_method cannot take it.
const BUILTIN_NOTE := "A built-in Variant type (a value, not an Object): call these methods on values in GDScript code. call_method and set_property work on Objects only."

## Cap on names harvested for a "did you mean" — a whole big scene tree, and no more.
const SUGGEST_CANDIDATE_MAX := 2000

var server  # mcp_server node (for get_undo_redo); set by the caller

## Test seam, null in every real run: while it is valid, set_property save=true reads the property back from
## disk_probe.call(file, property) instead of loading the file it wrote, so the unit suite can make the file disagree.
static var disk_probe: Callable = Callable()


func _register(registry) -> void:
	registry.register({
		"name": "get_godot_version",
		"description": "Return the running Godot engine version info.",
		"readonly": true,
		"always_load": true,  # bootstrap set (tool_registry.gd): ~220 bytes, and the first thing to know before writing engine API calls
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_get_godot_version"),
	})
	registry.register({
		"name": "find_classes",
		"description": "Search classes by name substring — engine classes, built-in Variant types (Vector3, Transform3D, Color...) AND your project's own types (GDScript class_name + C# [GlobalClass]). Optional 'base' restricts to subclasses (e.g. base=Node2D). The discovery entry point — pair with describe_class.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string", "description": "case-insensitive name substring"},
			"base": {"type": "string", "description": "only subclasses of this class"},
			"max": {"type": "integer", "description": "max results (default 50)"},
		}},
		"handler": Callable(self, "_find_classes"),
	})
	registry.register({
		"name": "describe_class",
		"description": "List a class's properties and methods (with signatures) so you know exactly what to set_property / call_method. The discovery key for full domain coverage. Also covers built-in Variant types (Vector3, Transform3D, Basis, Color, String...) and your class_name types.",
		"readonly": true,
		# Claude Code spills a result over 50,000 chars to a file, and a signature list cut to a
		# preview is useless. Measured on 4.6.2 with inherited=true: 17 of 1,040 engine classes
		# cross that line, the largest (CodeEdit) at 81 KB. 100,000 clears all of them.
		"max_result_chars": 100000,
		"input_schema": {"type": "object", "properties": {
			"class": {"type": "string"},
			"inherited": {"type": "boolean", "description": "include inherited members (default false)"},
		}, "required": ["class"]},
		"handler": Callable(self, "_describe_class"),
	})
	registry.register({
		"name": "find_methods",
		"description": "Search methods by name substring, optionally restricted to a class (incl. inherited). Covers engine classes, built-in Variant types (Vector3, Transform3D, Color...) and your class_name types. Object methods are invokable via call_method; kind=builtin results are called on values in GDScript. An unknown class is an error, never a silent search of everything.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string"},
			"class": {"type": "string"},
			"max": {"type": "integer"},
		}, "required": ["query"]},
		"handler": Callable(self, "_find_methods"),
	})
	registry.register({
		"name": "describe_object",
		"description": "Dump a live object's properties as JSON. target = a res:// path, a node name/path in the OPEN scene, or a class name (falls back to describe_class). While a game is running it also resolves live nodes (/root/Main/Player), the same paths runtime_get_property takes; the answer says which scope it came from, since the edited scene and the running game share one path syntax but are different worlds.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
		}, "required": ["target"]},
		"handler": Callable(self, "_describe_object"),
	})
	registry.register({
		"name": "set_property",
		"description": "Set a property on a resolved object (undoable). value is converted to the type the property declares: vectors take [x,y,z], \"x y z\" or \"(x, y, z)\", colors \"#rrggbb\", a name or [r,g,b,a], an enum its number, an object property a res:// path (loaded) or null. A value that does not fit is an ERROR and nothing is written. Every spelling: help(tool=\"set_property\").",
		"help": "value is converted to the type the property DECLARES, the rule the Full edition's runtime_set_property keeps in the running game. A value that cannot be that type is an ERROR naming the type and how to spell one, and nothing is written: Godot's own set() would store the type's default instead (a zero vector, black, 0) and say nothing.\n\n  Vector3: [0, 6, 11] (how a read of the running game returns one, so a value read can be written back), \"0 6 11\", \"0, 6, 11\", \"(0, 6, 11)\" (how str() prints one), \"Vector3(0, 6, 11)\" or {\"x\": 0, \"y\": 6, \"z\": 11}. The wrong number of parts (\"1 2\") is refused, never padded with zeros.\n  Color: \"#ff8800\", a name like \"gold\" or \"Color.GOLD\", [r, g, b] or [r, g, b, a] in 0..1, \"Color(1, 0.5, 0)\", \"(1, 0.5, 0, 1)\" or {\"r\": 1, \"g\": 0.5, \"b\": 0}\n  int, float, bool: JSON numbers and true/false (\"5\", \"0.5\" and \"true\" read too). An int refuses 2.5, a bool refuses \"maybe\".\n  enum (process_mode, a script's @export_enum): its number. A name such as \"Always\" is refused, and the error lists every number with its name.\n  NodePath: the path as text, such as \"../Player\" (NodePath(\"../Player\"), the form describe_object prints, reads too); null clears it.\n  object (a Texture2D, a Material...): a res:// or uid:// path, loaded under the read rule and checked against the class the property takes; null empties it. set_resource class=<Class> makes a new inline one.\n  node (an @export var follow: Node3D): the node's path from this node (\"../Player\"), from the scene root, or its name; checked against the class it takes, and null empties it.\n\nThe reply quotes the value READ BACK after the write. A write that did not stick (a read-only property, a setter that ignores it) is an error, and one the property changed on the way in (a clamp) carries a NOTE.\n\nsave=true, for a resource saved as its own file (a .tres, .res or .gdshader, named as target=res://... or reached through a node such as Water/material_override): the editor holds one copy of it in memory, and a write changes that copy. Without save the reply ends with a NOTE that the file on disk keeps the old value. The editor writes edited resource files when it saves a scene, and only while a saved scene is open: save_scene, and the save before each play while the editor setting run/auto_save/save_before_running is on (its default); Ctrl+S writes them either way. Until then a game started outside the editor, or a tool that reads the file, gets the old value. save=true writes the file now, the way the editor saves a resource, and reads the property back from the file. It writes the whole resource as the editor holds it, so earlier unsaved changes go along (with several writes to one resource, pass save=true on the last), and so does an older copy of a file that changed outside the editor since (your own file tools, git): the reply names the other values it wrote that differed from the file, one inside a sub-resource of the file by its path (sky:radiance_size). rescan_filesystem paths=[<file>] first takes such a change in, but a rescan or a write_file of that file replaces the editor's copy, unsaved edits included. After set_resource class=<Class> or call_method edits on such a resource, set_property save=true on any stored property at its current value writes the whole file. call_method makes no undo entry, so its edits last only while something holds the resource: assign it to a node first (set_resource). A part of another .tres (Water:material_override:next_pass, WorldEnvironment:environment:sky) writes that .tres. Refused before anything changes: an imported asset (Godot rebuilds it from its source on import: change its import options, or override the value on the node), a scene file or a part of a scene that is not open (open_scene it, then save_scene), a script (write_script, script_patch), a property files do not store, a read-only file, Beckett's own files, and a path outside res:// and user://. On a node, or a resource stored inside the open scene, the value is written and a NOTE says save_scene writes it. Undo reverts the editor's copy, not the file; the next scene save then writes the reverted value.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"property": {"type": "string"},
			"value": {"description": "any JSON value"},
			"save": {"type": "boolean", "description": "also write the resource's own .tres/.res file now"},
		}, "required": ["target", "property", "value"]},
		"handler": Callable(self, "_set_property"),
	})
	registry.register({
		"name": "call_method",
		"description": "Invoke a method on a resolved object. args = a positional array, coerced to the declared param types: vectors accept [x,y,z] / {\"x\":..} / \"x y z\", colors hex or [r,g,b,a], object params a node name/path or res:// path. set / set_deferred / set_indexed hold the value to the property's type, as set_property does. Wrong types or counts return an ERROR (never a silent no-op). Returns the result as JSON.",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
			"method": {"type": "string"},
			"args": {"type": "array"},
		}, "required": ["target", "method"]},
		"handler": Callable(self, "_call_method"),
	})
	registry.register({
		"name": "get_scene_tree",
		"description": "Return the node tree of the scene currently open in the editor (name/class/script, nested).",
		"readonly": true,
		"always_load": true,  # bootstrap set (tool_registry.gd): ~260 bytes, and the first call of almost every session
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_get_scene_tree"),
	})


# ---------------------------------------------------------------- handlers

func _get_godot_version(_args: Dictionary) -> Dictionary:
	return {"json": Engine.get_version_info()}


func _find_classes(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", "")).to_lower()
	var base := str(args.get("base", ""))
	var maxn := int(args.get("max", 50))
	var src: PackedStringArray
	if not base.is_empty() and ClassDB.class_exists(base):
		src = ClassDB.get_inheriters_from_class(base)
	else:
		src = ClassDB.get_class_list()
	var out: Array = []
	# Built-in Variant types first: there are only ~38, they are the math and container types
	# code touches constantly, and ClassDB (below) never lists them. They have no base class,
	# so a 'base' filter excludes them.
	if base.is_empty():
		for bn in BuiltinApi.type_names():
			if query.is_empty() or bn.to_lower().contains(query):
				out.append({"name": bn, "parent": "", "kind": "builtin"})
				if out.size() >= maxn:
					break
	for c in src:
		if out.size() >= maxn:
			break
		if query.is_empty() or String(c).to_lower().contains(query):
			out.append({"name": String(c), "parent": String(ClassDB.get_parent_class(c))})
			if out.size() >= maxn:
				break
	# Also surface user-defined global classes (GDScript class_name + C# [GlobalClass]) —
	# ClassDB never lists these. Tagged with language + script path so the agent knows they
	# are project types (drive them the same way: create_node / set_property / call_method).
	if out.size() < maxn:
		for e in _global_classes():
			var nm := String(e.get("class", ""))
			if nm.is_empty():
				continue
			if not query.is_empty() and not nm.to_lower().contains(query):
				continue
			if not base.is_empty() and String(e.get("base", "")) != base:
				continue
			out.append({
				"name": nm,
				"parent": String(e.get("base", "")),
				"kind": "script",
				"language": String(e.get("language", "")),
				"script": String(e.get("path", "")),
			})
			if out.size() >= maxn:
				break
	return {"json": {"count": out.size(), "truncated": out.size() >= maxn, "classes": out}}


func _describe_class(args: Dictionary) -> Dictionary:
	var cls := str(args.get("class", ""))
	if not ClassDB.class_exists(cls):
		if BuiltinApi.is_builtin(cls):
			return _describe_builtin(cls)
		var gentry := _global_class_entry(cls)
		if not gentry.is_empty():
			return _describe_global_class(cls, gentry)
		return {"error": "No such class: %s" % cls, "suggestion": _did_you_mean(cls)}
	var no_inh := not CallArgs.flag(args, "inherited")
	var props: Array = []
	for p in ClassDB.class_get_property_list(cls, no_inh):
		var usage := int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		props.append({"name": String(p.get("name", "")), "type": Reflect._type_name(p)})
	var methods: Array = []
	for m in ClassDB.class_get_method_list(cls, no_inh):
		methods.append({"name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
	return {"json": {
		"class": cls,
		"parent": String(ClassDB.get_parent_class(cls)),
		"properties": props,
		"methods": methods,
	}}


func _find_methods(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", "")).to_lower()
	var cls := str(args.get("class", ""))
	var maxn := int(args.get("max", 50))
	var out: Array = []
	var result := {}
	if not cls.is_empty():
		# A named class must be one we can actually search. Until 2026-09 an unknown name fell
		# through to the search-everything branch below, so class=Transform3D answered with
		# other classes' methods and no error at all.
		if ClassDB.class_exists(cls):
			for m in ClassDB.class_get_method_list(cls, false):
				if _method_matches(m, query):
					out.append({"class": cls, "name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
					if out.size() >= maxn:
						break
		elif BuiltinApi.is_builtin(cls):
			var t := BuiltinApi.table()
			if t.is_empty():
				return _builtin_unavailable(cls)
			for m in (t.get(cls, {}) as Dictionary).get("methods", []):
				if _method_matches(m, query):
					out.append({"class": cls, "name": str(m["name"]), "signature": str(m["signature"]), "kind": "builtin"})
					if out.size() >= maxn:
						break
			result["note"] = BUILTIN_NOTE
		else:
			var entry := _global_class_entry(cls)
			if entry.is_empty():
				return {"error": "No such class: %s" % cls, "suggestion": _did_you_mean(cls)}
			_script_methods(cls, entry, query, maxn, out)
	else:
		for c in ClassDB.get_class_list():
			for m in ClassDB.class_get_method_list(c, true):
				if _method_matches(m, query):
					out.append({"class": String(c), "name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
					if out.size() >= maxn:
						break
			if out.size() >= maxn:
				break
		if out.size() < maxn:
			var t := BuiltinApi.table()
			if t.is_empty():
				result["note"] = "Built-in Variant types (Vector3, Transform3D, ...) were not searched: %s" % BuiltinApi.last_error()
			else:
				for bn in t:
					for m in (t[bn] as Dictionary).get("methods", []):
						if _method_matches(m, query):
							out.append({"class": str(bn), "name": str(m["name"]), "signature": str(m["signature"]), "kind": "builtin"})
							if out.size() >= maxn:
								break
					if out.size() >= maxn:
						break
	result["count"] = out.size()
	result["truncated"] = out.size() >= maxn
	result["methods"] = out
	return {"json": result}


func _method_matches(m: Dictionary, query: String) -> bool:
	return query.is_empty() or String(m.get("name", "")).to_lower().contains(query)


## A class_name type's own script methods (inherited script methods included), then the
## engine class it ultimately extends.
func _script_methods(cls: String, entry: Dictionary, query: String, maxn: int, out: Array) -> void:
	var path := String(entry.get("path", ""))
	var scr: Variant = load(path) if not path.is_empty() else null
	if not (scr is Script):
		return
	for m in (scr as Script).get_script_method_list():
		if _method_matches(m, query):
			out.append({"class": cls, "name": String(m.get("name", "")), "signature": Reflect.method_signature(m), "kind": "script"})
			if out.size() >= maxn:
				return
	var native := String((scr as Script).get_instance_base_type())
	if ClassDB.class_exists(native):
		for m in ClassDB.class_get_method_list(native, false):
			if _method_matches(m, query):
				out.append({"class": native, "name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
				if out.size() >= maxn:
					return


func _describe_builtin(cls: String) -> Dictionary:
	var t := BuiltinApi.table()
	if t.is_empty():
		return _builtin_unavailable(cls)
	var info: Dictionary = t.get(cls, {})
	return {"json": {
		"class": cls,
		"kind": "builtin",
		"note": BUILTIN_NOTE,
		"properties": info.get("members", []),
		"methods": info.get("methods", []),
		"constants": info.get("constants", []),
	}}


func _builtin_unavailable(cls: String) -> Dictionary:
	return {"error": "%s is a built-in Variant type. Its method list comes from the engine's own API dump, which could not be produced here: %s" % [cls, BuiltinApi.last_error()],
		"suggestion": "Check the Godot docs for %s, or validate_script a snippet that calls the method you expect." % cls}


func _describe_object(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var guard := _target_guard(target)
	if guard.has("error"):
		return guard
	var obj := Reflect.resolve(target)
	if obj == null:
		# One of Beckett's own objects, or the editor around the open scene: say so, and do not ask the game
		# about a path that names a node of the editor (the game has no such node, and "not found" would hide why).
		var off := Reflect.refusal_for(target)
		if not off.is_empty():
			return {"error": off}
		# The editor and the running game are two different scopes that share one path
		# syntax, and nothing said so: runtime_get_property happily takes /root/Main/Player
		# while describe_object on the same string said "could not resolve" and sent the
		# agent off to get_remote_tree to guess. If the game is up, just ask it.
		# Not with a ':' path: the game's resolver drops what follows the ':' as get_node_or_null does, and would
		# answer with the node's own properties.
		var subpath := target.contains(":") and not target.begins_with("res://") and not target.begins_with("uid://")
		if not subpath and server.bridge.is_game_connected():
			var r: Dictionary = server.bridge.send_command({"cmd": "describe", "path": target})
			if bool(r.get("ok", false)):
				return {"json": {
					"target": target,
					"scope": "runtime (the running game — not the edited scene)",
					"class": r.get("class", ""),
					"resolved": r.get("resolved", target),
					"properties": r.get("properties", {}),
				}}
		if ClassDB.class_exists(target) or BuiltinApi.is_builtin(target) or not _global_class_entry(target).is_empty():
			return _describe_class({"class": target, "inherited": args.get("inherited", false)})
		var how := "Use a res:// path, a node name/path in the OPEN scene, a class name, or (while the game is running) a live node path such as /root/Main/Player."
		if subpath:
			var note := Reflect.subpath_note(target)
			if not note.is_empty():
				return {"error": "Could not resolve target: %s%s" % [target, note]}
			how += " A ':' path is read in the open scene only; for the running game put it in the property instead: runtime_get_property path=/root/Main/Ground property=material_override:shader_parameter/tint."
		# This miss path is reached for RUNTIME targets too (the branch above), so the
		# suggestion has to come from the tree the agent is actually driving — naming the
		# edited scene's nodes mid-playtest points at the wrong world entirely.
		var near := _did_you_mean_target(target, true)
		return {
			"error": "Could not resolve target: %s" % target,
			"suggestion": ("%s %s" % [near, how]) if not near.is_empty() else how,
		}
	return PathGuard.noted({"json": {
		"target": target,
		"class": obj.get_class(),
		"properties": Reflect.properties_of(obj),
	}}, guard)


func _set_property(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var prop := str(args.get("property", ""))
	if not args.has("value"):
		return {"error": "value is required"}
	var obj := Reflect.resolve(target)
	if obj == null:
		return _unresolved(target)
	if not Reflect.has_property(obj, prop):
		return {"error": "%s has no property '%s'" % [obj.get_class(), prop],
			"suggestion": "Call describe_object target=%s (or describe_class) to see valid properties." % target}
	# A value that cannot be stored is refused here: Object.set() would store the type's default instead (text in a
	# texture empties it) and this said it was set.
	var fit := Reflect.value_for_property(obj, prop, args["value"])
	if fit.has("error"):
		return fit
	# Where the written resource lives on disk, asked before the write (a write to resource_path moves it). A write
	# changes the copy the editor has loaded; a file of its own keeps the old value until a save (persist_guard.gd).
	var res := obj as Resource
	var open_file := Reflect.open_scene_file()
	var home: Dictionary = PersistGuard.resource_home(res, open_file) if res != null else {}
	var want_save := CallArgs.flag(args, "save")
	var plan: Dictionary = {}
	if want_save and res != null:
		# Every refusal comes before the write, so "Nothing was written." is true and a retry is safe.
		var refused := PersistGuard.save_refusal(home)
		if not refused.is_empty():
			return refused
		if PersistGuard.saves_file(home):
			plan = _save_plan(res, prop, home)
			if plan.has("error"):
				return plan
	var coerced: Variant = fit["value"]
	var before: Variant = obj.get(prop)
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	if ur != null:
		ur.create_action("MCP set_property %s.%s" % [target, prop])
		ur.add_do_property(obj, prop, coerced)
		ur.add_undo_property(obj, prop, before)
		ur.commit_action()
	else:
		obj.set(prop, coerced)
	var back := Reflect.readback(obj, prop, before, coerced)
	if back.has("error"):
		return back
	var text := "set %s.%s = %s" % [target, prop, Reflect.shown(back["value"])]
	if not plan.is_empty():
		var saved := _save_to_disk(plan, res, prop, target, back["value"])
		if saved.has("error"):
			return saved
		text += str(saved["text"])
	if back.has("note"):
		text += ". NOTE: %s" % back["note"]
	# Reflect.scene_root() is the edited scene's root in the editor, and the unit suite's stand-in scene there. A resource
	# or a sub-resource has no place in the scene tree to judge.
	var verdict: Dictionary = PersistGuard.verdict(Reflect.scene_root(), obj as Node, PersistGuard.SET) if obj is Node else {}
	if want_save and plan.is_empty():
		# Nothing of its own to write. On a node the NOT SAVED verdict, when there is one, already says what a save keeps.
		if bool(verdict.get("persisted", true)):
			text += ". " + PersistGuard.save_noop_note(target, open_file)
	elif not want_save and res != null and Reflect.is_stored(res, prop):
		var note := PersistGuard.file_note(home, true)
		if not note.is_empty():
			text += ". " + note
	var reply := {"text": text}
	if obj is Node:
		reply = PersistGuard.attach(reply, verdict)
	return PathGuard.noted(reply, fit)  # a value loaded from outside the project says so


## What save=true writes, checked before anything changes: {holder, file, drift}, or an error that ends "Nothing was
## written.". holder is the resource itself, or for a part of another file ('file::id') the copy of that file the cache
## holds, the way the editor's own scene save maps a part to its file. drift lists what else the save writes over the
## file (_file_drift).
func _save_plan(res: Resource, prop: String, home: Dictionary) -> Dictionary:
	var file := str(home.get("file", ""))
	var fs := PathGuard._plain(file)  # the file's name as the reply shows it: no control character, no line break
	var perr: String = PathGuard.write_path_error(file)  # no "..", no control characters, no link that leaves the project
	if not perr.is_empty():
		return {"error": "save=true: %s: %s. Nothing was written." % [fs, perr]}
	if Internals.is_beckett_path(file):
		return {"error": "save=true: %s is one of Beckett's own files, and %s. Nothing was written." % [fs, Internals.OFF_LIMITS]}
	if not Reflect.is_stored(res, prop):
		return {"error": "save=true: %s.%s is not stored in resource files, so no save keeps it. Nothing was written." % [res.get_class(), prop],
			"suggestion": "Set it without save=true: it holds for this editor session only."}
	var holder: Resource = res
	if str(home.get("kind", "")) == PersistGuard.HOME_INSIDE:
		if not ResourceLoader.has_cached(file):
			return {"error": "save=true: %s, which stores this, is not loaded in the editor any more, so there is no copy of it to save. Nothing was written." % fs,
				"suggestion": "Reach it again through the node or resource that holds it, then call again."}
		holder = ResourceLoader.load(file)
	elif ResourceLoader.has_cached(file) and ResourceLoader.load(file) != res:
		return {"error": "save=true: the editor holds another copy of %s, so saving this one would leave that copy stale. Nothing was written." % fs}
	if holder == null or not ResourceSaver.get_recognized_extensions(holder).has(file.get_extension().to_lower()):
		return {"error": "save=true: Godot has no saver that writes a %s to .%s. Nothing was written." % [holder.get_class() if holder != null else res.get_class(), PathGuard._plain(file.get_extension())]}
	if FileAccess.file_exists(file):
		# READ_WRITE neither truncates the file nor goes through the safe-save temp file, so the probe changes nothing.
		var probe := FileAccess.open(file, FileAccess.READ_WRITE)
		if probe == null:
			return {"error": "save=true: %s cannot be opened for writing (%s): it may be read-only or open in another program. Nothing was written." % [fs, error_string(FileAccess.get_open_error())]}
		probe.close()
	return {"holder": holder, "file": file, "drift": _file_drift(file, holder, res, prop)}


## The stored values, besides the one being written, in which the editor's copy differs from the file, the parts of the
## file ('file::id') compared by what they store and named by their path in it ("sky:radiance_size"). The save writes the
## whole copy, so it writes those too: right for earlier unsaved edits, and a revert of a file changed outside the editor
## since it was loaded (a headless editor never looks again), so the reply names them. For a part, prop is left out on
## that part wherever the file holds it.
func _file_drift(file: String, holder: Resource, res: Resource, prop: String) -> Array:
	if not FileAccess.file_exists(file):
		return []
	var fresh := ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh == null:
		return []
	return Reflect.stored_differences(holder, fresh, prop, res)


## Save the planned file the way the editor's scene save writes an edited resource, then read `prop` back from the file:
## {"text": the reply's clause}, or an error. The value is already set in the editor by then, so an error says so. No
## update_file, sync_written_file or refresh_loaded_copy here: ResourceSaver's own callback (EditorNode::_resource_saved)
## records the new modification time, so nothing reloads, and a refresh would swap every part of the file for a new object.
func _save_to_disk(plan: Dictionary, res: Resource, prop: String, target: String, value: Variant) -> Dictionary:
	var file := str(plan["file"])
	var fs := PathGuard._plain(file)  # the file's name as the reply shows it: no control character, no line break
	var shown := Reflect.shown(value)
	var err := ResourceSaver.save(plan["holder"], file, _save_flags())
	if err != OK:
		return {"error": "set %s.%s = %s in the editor, but saving %s failed (%s): the file still holds the old value." % [target, prop, shown, fs, error_string(err)],
			"suggestion": "Make %s writable, then call again with save=true (the value is already set)." % fs}
	var disk := _disk_value(file, res, prop)
	if disk.has("error"):
		return {"error": "set %s.%s = %s and saved %s, but %s." % [target, prop, shown, fs, str(disk["error"])]}
	if not Reflect.same_stored(disk["value"], value):
		return {"error": "set %s.%s = %s and saved %s, but the file reads it back as %s: a game loading it gets that." % [target, prop, shown, fs, Reflect.shown(disk["value"])],
			"suggestion": "describe_object target=%s shows the editor's copy and read_file path=%s the file. If %s was reloaded since this was reached, reach it again through what holds it." % [target, fs, fs]}
	var text := ", saved and read back from the file"
	if str(plan["holder"].resource_path) != str(res.resource_path):
		text = ", saved to %s, which stores it, and read back from the file" % fs
	elif target != file:
		text = ", saved to %s and read back from the file" % fs
	var drift: Array = plan["drift"]
	if not drift.is_empty():
		var names := PackedStringArray()
		for d in drift.slice(0, 6):
			names.append(PathGuard._plain(str(d)))  # property names the file chose, shown like its name
		var named := ", ".join(names)
		if drift.size() > 6:
			named += " and %d more" % (drift.size() - 6)
		text += ", and also wrote %s, which differed from the file (an older editor copy, or earlier unsaved edits)" % named
	return {"text": text}


## The value of `prop` in the file just saved, from a fresh load that shares nothing with the editor's copy but the
## files it depends on: what a game loading it gets. The part is found by its path read AFTER the save, which gives a
## part that had none its 'file::id'. has_property first: a ShaderMaterial answers a uniform only after listing it.
func _disk_value(file: String, res: Resource, prop: String) -> Dictionary:
	if disk_probe.is_valid():
		return {"value": disk_probe.call(file, prop)}
	var fresh := ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh == null:
		return {"error": "the saved file does not load (the editor's output has the error), so a game cannot load it either"}
	var at: Resource = fresh if res.resource_path == file else Reflect.embedded_by_path(fresh, res.resource_path)
	if at == null:
		return {"error": "%s is not in the saved file" % PathGuard._plain(res.resource_path)}
	if not Reflect.has_property(at, prop):
		return {"error": "the %s loaded from it has no property '%s'" % [at.get_class(), prop]}
	return {"value": at.get(prop)}


## The flags the editor's scene save writes an edited resource with (EditorNode::_save_external_resources): parts of the
## file get 'file::id' paths, and a binary file is compressed while the editor setting says so (its default).
func _save_flags() -> int:
	var flags: int = ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		var key := "filesystem/on_save/compress_binary_resources"
		if es != null and es.has_setting(key) and CallArgs.to_bool(es.get_setting(key)):
			flags |= ResourceSaver.FLAG_COMPRESS
	return flags


func _call_method(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var method := str(args.get("method", ""))
	var obj := Reflect.resolve(target)
	if obj == null:
		return _unresolved(target)
	var call_args: Array = []
	var incoming: Variant = args.get("args", [])
	if incoming is Array:
		call_args = incoming
	# A method that runs something on every node below its target (propagate_call), or runs another method by
	# name (call, callv, call_deferred, so call("propagate_call", ...) too), reaches Beckett's own objects from any
	# node that has them below it, and the target itself being fine does not make that call fine.
	var off := Internals.dispatch_refusal(obj, method, call_args)
	if not off.is_empty():
		return {"error": off}
	if not obj.has_method(method):
		return {"error": "%s has no method '%s'" % [obj.get_class(), method],
			"suggestion": "Call find_methods query=%s class=%s to discover callable methods." % [method, obj.get_class()]}
	# Coerce BEFORE callv: a mis-typed callv does NOT execute the method (the engine
	# prints to the editor console and returns null), which this handler used to wrap
	# as success - the silent-argument trap. Coercion failures now fail the call.
	var prep: Dictionary = CallArgs.prepare(obj, method, call_args, self)
	if not bool(prep.get("ok", false)):
		return {"error": "call_method %s.%s: %s" % [obj.get_class(), method, str(prep.get("error", "argument mismatch"))],
			"suggestion": "describe_class class=%s shows the declared signature; vectors accept [x,y,z]." % obj.get_class()}
	var prepared: Array = (prep["args"] as Array).duplicate()
	# set, set_deferred and set_indexed take the value as a Variant, so CallArgs hands it over as sent, and a property
	# given a value of another type stores that type's DEFAULT: set("position", "0 6 11") zeroed the node, with no undo,
	# and the call answered null as it always does. A value for a property that resolves is held to its type here, the
	# way set_property holds it (and the running game's runtime_call).
	var loaded: Dictionary = {}
	if method in ["set", "set_deferred", "set_indexed"] and prepared.size() == 2:
		var fit := Reflect.value_for_path(obj, str(prepared[0]), prepared[1])
		if fit.has("error"):
			var refused := {"error": "call_method %s.%s: arg 1 (value): %s" % [obj.get_class(), method, str(fit["error"])]}
			if fit.has("suggestion"):
				refused["suggestion"] = fit["suggestion"]
			return refused
		if fit.has("value"):
			prepared[1] = fit["value"]
			loaded = fit
	var ret: Variant = obj.callv(method, prepared)
	var payload := {"result": Reflect.to_json_safe(ret)}
	var warn := _stale_script_warning(obj)
	if not warn.is_empty():
		payload["warning"] = warn
	return PathGuard.noted({"json": payload}, loaded)  # a resource loaded from outside the project says so


func _resolve_object_arg(spec: String) -> Object:
	return Reflect.resolve(spec)


## Why an object argument that did not resolve was refused (CallArgs.prepare asks): handing one of Beckett's
## objects to add_child, reparent, connect or the like is a way to them as good as naming one as the target.
func _object_arg_refusal(spec: String) -> String:
	return Reflect.refusal_for(spec)


## call_method executes the LOADED script. A .gd changed outside write_script/
## script_patch (the agent's own file tools, an external editor) stays stale in a
## driven editor - reload-on-focus never fires headless - so results quietly stop
## matching the file. Detect the drift and say so in the response. A write through
## Beckett does not always fix it, so the warning says to read that reply: a headless
## Godot 4.5+ editor never reloads a written script itself, and Beckett reloads it only
## while its variables and method signatures stay the same (project_tools.gd,
## skipped_reload_note). It used to say the writes reload, which was false there.
func _stale_script_warning(obj: Object) -> String:
	var scr: Variant = obj.get_script()
	if scr == null or not (scr is GDScript):
		return ""
	var path: String = (scr as GDScript).resource_path
	if not path.begins_with("res://") or not FileAccess.file_exists(path):
		return ""
	var disk := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	var loaded := str((scr as GDScript).source_code).replace("\r\n", "\n")
	if disk.is_empty() or loaded.is_empty() or disk == loaded:
		return ""
	var msg := ("script %s differs on disk from the loaded version: this call ran the LOADED code. Write it through write_script or script_patch" % path
		+ " (after an outside edit, rescan_filesystem with paths=[\"%s\"] does the same), read what the reply says about reloading it, then call again." % path)
	var v := Engine.get_version_info()
	if DisplayServer.get_name() == "headless" and (int(v.get("major", 4)) > 4 or int(v.get("minor", 0)) >= 5):
		msg += (" In a headless Godot 4.5+ editor Beckett can reload a written script only while its variables and method signatures stay the same;"
			+ " after any other change the editor runs the old code until it restarts (a played game loads the file).")
	return msg


func _get_scene_tree(_args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"text": "No scene is currently open in the editor."}
	return {"json": _node_tree(root)}


# ---------------------------------------------------------------- helpers

func _node_tree(n: Node) -> Dictionary:
	var d: Dictionary = {"name": String(n.name), "class": n.get_class()}
	var scr := n.get_script()
	if scr != null and scr is Script:
		d["script"] = (scr as Script).resource_path
	var kids: Array = []
	for c in n.get_children():
		kids.append(_node_tree(c))
	if not kids.is_empty():
		d["children"] = kids
	return d


func _did_you_mean(cls: String) -> String:
	var q := cls.to_lower()
	var hits: Array = []
	for bn in BuiltinApi.type_names():
		if hits.size() >= 5:
			break
		if bn.to_lower().contains(q):
			hits.append(bn)
	for c in ClassDB.get_class_list():
		if hits.size() >= 5:
			break
		if String(c).to_lower().contains(q):
			hits.append(String(c))
			if hits.size() >= 5:
				break
	for e in _global_classes():  # include the project's own types in suggestions
		if hits.size() >= 5:
			break
		var nm := String(e.get("class", ""))
		if not nm.is_empty() and nm.to_lower().contains(q) and not hits.has(nm):
			hits.append(nm)
	# Substring only finds names that CONTAIN the query, so a typo ("Sprit2D") has zero hits
	# and used to fall through to the generic advice. Edit distance catches exactly that.
	# Order matters: substring first, so a prefix query like "Light" still lists the family.
	if hits.is_empty():
		hits = Reflect.nearest(cls, _class_name_pool(), 5)
	if hits.is_empty():
		return "Use find_classes to search for the right class name."
	return "Did you mean: %s" % ", ".join(hits)


## Every class name a describe_class query could legitimately have meant: engine classes
## plus the project's own global types. Built only on a miss.
func _class_name_pool() -> Array:
	var pool: Array = Array(BuiltinApi.type_names())
	for c in ClassDB.get_class_list():
		pool.append(String(c))
	for e in _global_classes():
		var nm := String(e.get("class", ""))
		if not nm.is_empty():
			pool.append(nm)
	return pool


## "Did you mean ...?" for a target that did not resolve, or "" when nothing is close.
## The candidate SCOPE is the CALLER's scope, never "whatever is reachable": describe_object
## also answers for the running game, so its misses match against the live tree, while
## set_property / call_method only ever touch the edited scene and would send the agent after
## a node they cannot address if they borrowed the game's names.
func _did_you_mean_target(target: String, from_runtime: bool) -> String:
	# A res:// / uid:// miss is a load failure, not a mistyped node name — say nothing.
	if target.begins_with("res://") or target.begins_with("uid://"):
		return ""
	var leaf := target.get_slice(":", 0).get_file()  # "/root/Main/Playr" -> "Playr", "Grond:mesh" -> "Grond"; a bare name is unchanged
	if leaf.is_empty():
		return ""
	var runtime: bool = from_runtime and server != null and server.bridge != null and server.bridge.is_game_connected()
	var by_leaf: Dictionary = {}  # leaf name -> the exact string to pass back
	if runtime:
		var r: Dictionary = server.bridge.send_command({"cmd": "find", "recursive": true, "max": SUGGEST_CANDIDATE_MAX})
		for e in r.get("nodes", []):  # absent on a failed find, which just means no suggestion
			var p := str((e as Dictionary).get("path", ""))
			if not p.is_empty():
				by_leaf[p.get_file()] = p
	else:
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return ""
		by_leaf[String(root.name)] = String(root.name)
		_collect_node_names(root, by_leaf)
	var hits: Array = Reflect.nearest(leaf, by_leaf.keys(), 3)
	if hits.is_empty():
		return ""
	var names: Array = []
	for h in hits:
		names.append(str(by_leaf[h]))
	var scope := "live nodes in the RUNNING game" if runtime else "nodes in the OPEN scene"
	return "Did you mean %s? (%s)" % [", ".join(names), scope]


## Every node name under the edited scene root, keyed by itself: Reflect.resolve finds a node
## by bare name anywhere in the tree, so the name IS the string to hand back.
func _collect_node_names(n: Node, into: Dictionary) -> void:
	for c in n.get_children():
		if into.size() >= SUGGEST_CANDIDATE_MAX:
			return
		into[String(c.name)] = String(c.name)
		_collect_node_names(c, into)


## The read rule's verdict on `target` when it is a res:// or uid:// resource path, else {}. Reflect.resolve
## returns null for a path the rule refuses, and "could not resolve" would hide why: callers return the
## verdict's error as it is, and add its note (outside reads switched on) to what they answer.
func _target_guard(target: String) -> Dictionary:
	if not (target.begins_with("res://") or target.begins_with("uid://")):
		return {}
	return PathGuard.check_read(target)


## The shared "target did not resolve" error for the EDITOR-scoped tools, carrying a nearby
## name when there is one.
func _unresolved(target: String) -> Dictionary:
	var guard := _target_guard(target)
	if guard.has("error"):
		return guard
	var off := Reflect.refusal_for(target)  # one of Beckett's own objects, or a node outside the open scene
	if not off.is_empty():
		return {"error": off}
	# A ':' path whose node was found missed on a property: say which one, not "did you mean" that same node.
	var note := Reflect.subpath_note(target)
	var out := {"error": "Could not resolve target: %s%s" % [target, note]}
	var near := _did_you_mean_target(target, false) if note.is_empty() else ""
	if not near.is_empty():
		out["suggestion"] = near
	return out


## User-defined global classes (GDScript class_name + C# [GlobalClass]) — the surface
## ClassDB does not track. Fresh each call so it reflects scripts added mid-session.
func _global_classes() -> Array:
	if ProjectSettings.has_method("get_global_class_list"):
		return ProjectSettings.get_global_class_list()
	return []


func _global_class_entry(name: String) -> Dictionary:
	if name.is_empty():
		return {}
	for e in _global_classes():
		if String(e.get("class", "")) == name:
			return e
	return {}


## Describe a user global class from its Script resource. get_script_method_list /
## get_script_property_list work for BOTH GDScript and CSharpScript — but C# type info
## is only populated after a successful build, so an empty result folds in the base class.
func _describe_global_class(cls: String, entry: Dictionary) -> Dictionary:
	var base := String(entry.get("base", ""))
	var lang := String(entry.get("language", ""))
	var path := String(entry.get("path", ""))
	var scr: Variant = load(path) if not path.is_empty() else null
	var props: Array = []
	var methods: Array = []
	if scr != null and scr is Script:
		for p in (scr as Script).get_script_property_list():
			var usage := int(p.get("usage", 0))
			if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_CATEGORY) != 0:
				continue
			props.append({"name": String(p.get("name", "")), "type": Reflect._type_name(p)})
		for m in (scr as Script).get_script_method_list():
			methods.append({"name": String(m.get("name", "")), "signature": Reflect.method_signature(m)})
	var result := {
		"class": cls,
		"parent": base,
		"language": lang,
		"script": path,
		"properties": props,
		"methods": methods,
	}
	if props.is_empty() and methods.is_empty():
		var why := " — C# type info needs a successful build (run build_csharp)" if lang == "C#" else ""
		result["note"] = "No script members resolved%s. Showing the base class '%s' instead." % [why, base]
		if ClassDB.class_exists(base):
			var bd := _describe_class({"class": base})
			if bd.has("json"):
				result["base_class"] = bd["json"]
	return {"json": result}
