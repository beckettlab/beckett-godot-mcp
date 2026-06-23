@tool
extends RefCounted
class_name BeckettBatchTools

## Atomic-ish multi-call (D6 amplifier). Runs a list of tool calls in one request, in order,
## failing fast. For mutations on the open scene it snapshots the scene's undo version up front
## and, on failure, undoes exactly the actions this batch committed — a true rollback for the
## EditorUndoRedoManager-backed tools (create_node, set_property, attach_script, ...). File and
## resource writes (write_script, create_resource, save_scene) do not go on that history and are
## NOT rolled back; the result says so. Sub-calls are re-gated, so read-only / allowlist /
## confirm-destructive rules still apply per step.

var server  # mcp_server node (owns .registry and ._gate)


func _register(registry) -> void:
	registry.register({
		"name": "batch_execute",
		"description": "Run several tool calls in one request, in order. steps = [{tool, args}]. "
			+ "Stops at the first failure (stop_on_error, default true). When a step fails, scene edits made by the batch are rolled back via the editor undo history (rollback, default true) — file/resource writes are not. "
			+ "Use to collapse multi-step authoring (create node → set props → attach script) into one atomic call.",
		"input_schema": {"type": "object", "properties": {
			"steps": {"type": "array", "description": "ordered [{tool: name, args: {...}}]", "items": {"type": "object"}},
			"stop_on_error": {"type": "boolean", "description": "halt on first failure (default true)"},
			"rollback": {"type": "boolean", "description": "undo scene edits on failure (default true)"},
		}, "required": ["steps"]},
		"handler": Callable(self, "_batch_execute"),
	})


func _batch_execute(args: Dictionary) -> Dictionary:
	var steps: Variant = args.get("steps", [])
	if not (steps is Array) or (steps as Array).is_empty():
		return {"error": "steps must be a non-empty array of {tool, args}."}
	var stop := bool(args.get("stop_on_error", true))
	var want_rollback := bool(args.get("rollback", true))
	var registry = server.registry

	var uredo := _scene_undo()
	var v0 := uredo.get_version() if uredo != null else 0

	var results: Array = []
	var failed_at := -1
	for i in range((steps as Array).size()):
		var step: Variant = steps[i]
		if not (step is Dictionary):
			results.append({"step": i, "ok": false, "error": "step must be an object {tool, args}"})
			failed_at = i
			if stop:
				break
			continue
		var tname := str(step.get("tool", step.get("name", "")))
		var sargs: Variant = step.get("args", step.get("arguments", {}))
		if not (sargs is Dictionary):
			sargs = {}
		if tname.is_empty() or not registry.has(tname):
			results.append({"step": i, "tool": tname, "ok": false, "error": "unknown tool: %s" % tname})
			failed_at = i
			if stop:
				break
			continue
		var tool: Dictionary = registry.get_tool(tname)
		var gate := str(server._gate(tname, tool, sargs))
		if not gate.is_empty():
			results.append({"step": i, "tool": tname, "ok": false, "error": gate})
			failed_at = i
			if stop:
				break
			continue
		var handler: Callable = tool["handler"]
		var raw: Variant = handler.call(sargs)
		var rd: Dictionary = raw if raw is Dictionary else {"text": str(raw)}
		if rd.has("error"):
			results.append({"step": i, "tool": tname, "ok": false, "error": str(rd["error"])})
			failed_at = i
			if stop:
				break
			continue
		results.append({"step": i, "tool": tname, "ok": true, "result": _summarize(rd)})

	var out: Dictionary = {
		"ok": failed_at == -1,
		"total": (steps as Array).size(),
		"ran": results.size(),
		"failed_at": failed_at,
		"results": results,
	}
	if failed_at != -1 and want_rollback and uredo != null:
		var rolled_back := _rollback(uredo, v0)
		out["rolled_back"] = rolled_back
		out["note"] = "Stopped at step %d. Scene edits %s; file/resource writes are not rolled back." % [
			failed_at, "rolled back" if rolled_back else "left in place"]
	elif failed_at != -1:
		out["rolled_back"] = false
	return {"json": out}


# ---------------------------------------------------------------- rollback

## The plain UndoRedo for the open scene's history (or null if unavailable).
func _scene_undo() -> UndoRedo:
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	if ur == null or not ur.has_method("get_object_history_id"):
		return null
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var hid: int = ur.get_object_history_id(root)
	return ur.get_history_undo_redo(hid)


## Undo back to the snapshot version — precisely the actions this batch committed.
func _rollback(uredo: UndoRedo, v0: int) -> bool:
	var guard := 0
	while uredo.get_version() != v0 and uredo.has_undo() and guard < 1000:
		uredo.undo()
		guard += 1
	return uredo.get_version() == v0


func _summarize(rd: Dictionary) -> String:
	if rd.has("text"):
		return str(rd["text"])
	if rd.has("json"):
		return JSON.stringify(rd["json"])
	if rd.has("image_png_base64"):
		return "(image)"
	return "(ok)"
