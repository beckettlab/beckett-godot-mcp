@tool
extends RefCounted
class_name BeckettResources

## MCP Resources (D4) — read-only context the client can pull without spending a tool
## slot or bloating every prompt: the open scene tree, selection, project settings,
## the asset list, and the editor log tail.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server


func list() -> Array:
	return [
		{"uri": "scene://tree", "name": "Open scene tree", "description": "Node tree of the scene open in the editor.", "mimeType": "application/json"},
		{"uri": "scene://selection", "name": "Editor selection", "description": "Nodes currently selected in the editor.", "mimeType": "application/json"},
		{"uri": "project://settings", "name": "Project settings", "description": "Project name, engine version, main scene, autoloads.", "mimeType": "application/json"},
		{"uri": "assets://list", "name": "Project assets", "description": "Files under res:// (excluding .godot).", "mimeType": "application/json"},
		{"uri": "log://output", "name": "Editor log", "description": "Tail of the Godot log file, if file logging is enabled.", "mimeType": "text/plain"},
		{"uri": "audit://recent", "name": "MCP audit log", "description": "Last %d tool calls this session: time, tool, duration, ok/error, brief args." % 200, "mimeType": "application/json"},
		{"uri": "status://connection", "name": "Connection status", "description": "Server running state, the connected MCP client (name/version from its handshake), idle time, live tool count. The model is NOT included — MCP does not report it.", "mimeType": "application/json"},
	]


## Returns {ok:true, mime:String, text:String} or {ok:false, error:String}.
func read(uri: String) -> Dictionary:
	match uri:
		"scene://tree":
			var root := EditorInterface.get_edited_scene_root()
			if root == null:
				return _json({"open": false})
			return _json(_tree(root))
		"scene://selection":
			var sel: Array = []
			for n in EditorInterface.get_selection().get_selected_nodes():
				sel.append({"name": str(n.name), "class": n.get_class(), "path": str(root_rel(n))})
			return _json({"selected": sel})
		"project://settings":
			return _json(_project_settings())
		"assets://list":
			return _json({"files": _list_assets()})
		"log://output":
			return _log_tail()
		"audit://recent":
			var entries: Array = server.audit_log() if server != null else []
			return _json({"count": entries.size(), "calls": entries})
		"status://connection":
			return _json(_connection_status())
		_:
			return {"ok": false, "error": "unknown resource: %s" % uri}


# ---------------------------------------------------------------- builders

func _tree(n: Node) -> Dictionary:
	var d: Dictionary = {"name": str(n.name), "class": n.get_class()}
	var kids: Array = []
	for c in n.get_children():
		kids.append(_tree(c))
	if not kids.is_empty():
		d["children"] = kids
	return d


func _project_settings() -> Dictionary:
	var autoloads: Array = []
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("autoload/"):
			autoloads.append(name.substr(9))
	return {
		"name": ProjectSettings.get_setting("application/config/name", ""),
		"engine": Engine.get_version_info().get("string", ""),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"autoloads": autoloads,
	}


## Connection state for status://connection (same data the dock's Server line shows).
## The model is intentionally absent — MCP carries no model identity; it lives in the client.
func _connection_status() -> Dictionary:
	if server == null:
		return {"running": false, "connected": false}
	var cs: Dictionary = server.client_status() if server.has_method("client_status") else {}
	var idle: int = int(cs.get("idle_ms", -1))
	var tools := 0
	if server.registry != null and server.has_method("get_effort"):
		tools = server.registry.list_specs(server.get_effort()).size()
	var game: bool = server.bridge != null and server.bridge.is_game_connected()
	return {
		"running": server.is_running(),
		"connected": idle >= 0,
		"client": {
			"name": str(cs.get("name", "")),
			"version": str(cs.get("version", "")),
			"user_agent": str(cs.get("ua", "")),
		},
		"idle_ms": idle,
		"tools_advertised": tools,
		"game_runtime_connected": game,
		"note": "MCP does not report the model; it is configured in the client.",
	}


func _list_assets(limit: int = 500) -> Array:
	var out: Array = []
	_walk("res://", out, limit)
	return out


func _walk(path: String, out: Array, limit: int) -> void:
	if out.size() >= limit:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full := path.path_join(entry)
		if dir.current_is_dir():
			if entry != ".godot":
				_walk(full, out, limit)
		else:
			if not entry.ends_with(".import") and not entry.ends_with(".uid"):
				out.append(full)
				if out.size() >= limit:
					break
		entry = dir.get_next()
	dir.list_dir_end()


func _log_tail(lines: int = 100) -> Dictionary:
	var log_path := "user://logs/godot.log"
	if not FileAccess.file_exists(log_path):
		return {"ok": true, "mime": "text/plain", "text": "(no log file — enable Project Settings > Debug > File Logging)"}
	var text := FileAccess.get_file_as_string(log_path)
	var arr := text.split("\n")
	var start := maxi(0, arr.size() - lines)
	var tail: Array = []
	for i in range(start, arr.size()):
		tail.append(arr[i])
	return {"ok": true, "mime": "text/plain", "text": "\n".join(tail)}


# ---------------------------------------------------------------- helpers

func root_rel(n: Node) -> NodePath:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.is_ancestor_of(n):
		return root.get_path_to(n)
	return n.get_path()


func _json(v: Variant) -> Dictionary:
	return {"ok": true, "mime": "application/json", "text": JSON.stringify(v, "  ")}
