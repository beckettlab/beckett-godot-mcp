@tool
extends RefCounted
class_name BeckettSignalTools

## Signal wiring: editor-persisted (CONNECT_PERSIST so it saves into the .tscn) and undoable.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server


func _register(registry) -> void:
	registry.register({
		"name": "connect_signal",
		"description": "Connect a node's signal to a method on another node, persisted into the scene (undoable). from/to = node path/name in the open scene.",
		"input_schema": {"type": "object", "properties": {
			"from": {"type": "string"}, "signal": {"type": "string"},
			"to": {"type": "string"}, "method": {"type": "string"},
		}, "required": ["from", "signal", "to", "method"]},
		"handler": Callable(self, "_connect_signal"),
	})
	registry.register({
		"name": "disconnect_signal",
		"description": "Disconnect a previously connected signal (undoable).",
		"input_schema": {"type": "object", "properties": {
			"from": {"type": "string"}, "signal": {"type": "string"},
			"to": {"type": "string"}, "method": {"type": "string"},
		}, "required": ["from", "signal", "to", "method"]},
		"handler": Callable(self, "_disconnect_signal"),
	})
	registry.register({
		"name": "list_signals",
		"description": "List a node's signals and their current connections (target node + method).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"},
		}, "required": ["target"]},
		"handler": Callable(self, "_list_signals"),
	})


func _connect_signal(args: Dictionary) -> Dictionary:
	var from := Reflect.resolve(str(args.get("from", ""))) as Node
	var to := Reflect.resolve(str(args.get("to", ""))) as Node
	# Miss answers say why when the node is one of Beckett's own (a signal wired to its send_command would run
	# whatever the signal carries) or outside the open scene.
	if from == null:
		return {"error": Reflect.miss(str(args.get("from", "")), "'from' node")}
	if to == null:
		return {"error": Reflect.miss(str(args.get("to", "")), "'to' node")}
	var sig := str(args.get("signal", ""))
	var method := str(args.get("method", ""))
	if not from.has_signal(sig):
		return {"error": "%s has no signal '%s'" % [from.get_class(), sig],
			"suggestion": "Call list_signals target=%s." % str(args.get("from", ""))}
	var cb := Callable(to, method)
	if from.is_connected(sig, cb):
		return {"text": "already connected"}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP connect_signal")
	ur.add_do_method(from, "connect", sig, cb, Object.CONNECT_PERSIST)
	ur.add_undo_method(from, "disconnect", sig, cb)
	ur.commit_action()
	var warn := "" if to.has_method(method) else "  (note: %s has no method '%s' yet — add it with write_script/attach_script)" % [to.name, method]
	return {"text": "connected %s.%s -> %s.%s%s" % [from.name, sig, to.name, method, warn]}


func _disconnect_signal(args: Dictionary) -> Dictionary:
	var from := Reflect.resolve(str(args.get("from", ""))) as Node
	var to := Reflect.resolve(str(args.get("to", ""))) as Node
	if from == null or to == null:
		for spec in [str(args.get("from", "")), str(args.get("to", ""))]:
			var off := Reflect.refusal_for(spec)
			if not off.is_empty():
				return {"error": off}
		return {"error": "Could not resolve from/to node."}
	var sig := str(args.get("signal", ""))
	var cb := Callable(to, str(args.get("method", "")))
	if not from.is_connected(sig, cb):
		return {"error": "Not connected."}
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP disconnect_signal")
	ur.add_do_method(from, "disconnect", sig, cb)
	ur.add_undo_method(from, "connect", sig, cb, Object.CONNECT_PERSIST)
	ur.commit_action()
	return {"text": "disconnected %s.%s -> %s.%s" % [from.name, sig, to.name, str(args.get("method", ""))]}


func _list_signals(args: Dictionary) -> Dictionary:
	var node := Reflect.resolve(str(args.get("target", ""))) as Node
	if node == null:
		return {"error": Reflect.miss(str(args.get("target", "")))}
	var out: Array = []
	for s in node.get_signal_list():
		var name: String = str(s.get("name", ""))
		var conns: Array = []
		for c in node.get_signal_connection_list(name):
			var cb: Callable = c.get("callable")
			var obj := cb.get_object()
			conns.append({
				"to": str(obj.name) if obj is Node else str(obj),
				"method": str(cb.get_method()),
			})
		out.append({"signal": name, "connections": conns})
	return {"json": {"target": str(args.get("target", "")), "signals": out}}
