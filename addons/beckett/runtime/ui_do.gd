extends RefCounted
## ui_do macro window (v1.10 P1): ONE bridge call runs a whole semantic UI flow
## GAME-side across frames — the multi-round-trip killer. Steps:
##   {click: <selector dict | "text">}                    - click_control semantics
##   {type: {path/class/name..., text, clear?, submit?}}  - type_text semantics
##   {wait: {ms: N | node: "path" | condition: "expr"}}   - explicit sync point
##   {assert: {condition} | {node, property, equals}}     - EVENTUALLY semantics: polls
##                                                          until true or the step times out
##   {input: {events: [...]}}                             - raw event passthrough
## Every step auto-waits (a not-yet-clickable click / not-yet-typed field / false
## condition just retries) under a per-step timeout (step.timeout_ms, else the window
## default). Stop-on-fail; per-step results report what happened. Mirrors the
## step/replay window shape: `ui_do_open` arms it and replies at once, mcp_runtime's
## _process ticks it, the editor polls `ui_do_status` (B7 rule: machine lives here,
## dispatch stays in mcp_runtime).

var active := false
var failed := false

var _rt: Node = null            # the mcp_runtime autoload (click/type/resolve/input live there)
var _steps: Array = []
var _i := 0
var _results: Array = []
var _default_timeout := 5000
var _deadline := 0
var _step_t0 := 0
var _settle := 2                # frames to let the UI react between steps
var _settle_left := 0
var _cond: Expression = null    # compiled condition for the CURRENT wait/assert step
var _cond_src := ""
var _last_wait := ""            # last not-ready reason, reported on step timeout


func open(rt: Node, msg: Dictionary) -> Dictionary:
	if active:
		return {"ok": false, "error": "a ui_do window is already open — poll ui_do op=status, or op=abort it"}
	var steps: Variant = msg.get("steps", null)
	if not (steps is Array) or (steps as Array).is_empty():
		return {"ok": false, "error": "steps must be a non-empty array of {click|type|wait|assert|input} objects"}
	for s in (steps as Array):
		if not (s is Dictionary):
			return {"ok": false, "error": "every step must be an object, got: %s" % str(s)}
	_rt = rt
	_steps = (steps as Array).duplicate(true)
	_default_timeout = maxi(100, int(msg.get("step_timeout_ms", 5000)))
	_settle = clampi(int(msg.get("settle_frames", 2)), 0, 60)
	_i = 0
	_results = []
	failed = false
	_settle_left = 0
	active = true
	_arm_step()
	return {"ok": true, "started": true, "steps": _steps.size()}


func status() -> Dictionary:
	return {"ok": true, "active": active, "total": _steps.size(), "current": _i,
		"done": not active, "failed": failed, "results": _results.duplicate(true)}


func abort() -> Dictionary:
	var was := active
	active = false
	return {"ok": true, "aborted": was, "completed_steps": _results.size()}


## One attempt per frame, driven by mcp_runtime._process while the window is open.
func tick() -> void:
	if not active:
		return
	if _settle_left > 0:
		_settle_left -= 1
		return
	var step: Dictionary = _steps[_i]
	var r := _try(step)
	if r.is_empty():
		if Time.get_ticks_msec() > _deadline:
			var why := "step %d timed out after %d ms" % [_i, _step_timeout(step)]
			if _last_wait != "":
				why += " — last blocker: %s" % _last_wait
			_finish_step(step, {"ok": false, "error": why})
		return
	_finish_step(step, r)


func _finish_step(step: Dictionary, r: Dictionary) -> void:
	r["step"] = _i
	r["op"] = _op_of(step)
	_results.append(r)
	if not bool(r.get("ok", false)):
		failed = true
		active = false
		return
	_i += 1
	if _i >= _steps.size():
		active = false
		return
	_settle_left = _settle
	_arm_step()


func _arm_step() -> void:
	_deadline = Time.get_ticks_msec() + _step_timeout(_steps[_i])
	_step_t0 = Time.get_ticks_msec()
	_cond = null
	_cond_src = ""
	_last_wait = ""


func _step_timeout(step: Dictionary) -> int:
	return maxi(100, int(step.get("timeout_ms", _default_timeout)))


func _op_of(step: Dictionary) -> String:
	for k in ["click", "type", "wait", "assert", "input"]:
		if step.has(k):
			return k
	return "?"


## {} = not ready yet (retry next frame); anything else finishes the step.
func _try(step: Dictionary) -> Dictionary:
	if step.has("click"):
		return _try_click(_sel(step["click"]))
	if step.has("type"):
		return _try_type(step["type"] if step["type"] is Dictionary else {})
	if step.has("wait"):
		return _try_wait(step["wait"] if step["wait"] is Dictionary else {})
	if step.has("assert"):
		return _try_assert(step["assert"] if step["assert"] is Dictionary else {})
	if step.has("input"):
		var events: Variant = (step["input"] as Dictionary).get("events", []) if step["input"] is Dictionary else []
		var ri: Dictionary = _rt._run_input(events)
		if bool(ri.get("ok", false)):
			return {"ok": true, "detail": "dispatched %d event(s)" % int(ri.get("dispatched", 0))}
		return {"ok": false, "error": str(ri.get("error", "input failed"))}
	return {"ok": false, "error": "unknown step — use one of click/type/wait/assert/input"}


func _try_click(msg: Dictionary) -> Dictionary:
	var r: Dictionary = _rt._click_control(msg)
	if bool(r.get("clicked", false)):
		var d := {"ok": true, "detail": "clicked %s" % str(r.get("path", ""))}
		if r.has("received_by"):
			d["received_by"] = r["received_by"]
		return d
	if not bool(r.get("ok", false)):
		var e := str(r.get("error", ""))
		if e.begins_with("node not found") or e.begins_with("no node matches"):
			_last_wait = e  # menus build async — keep waiting for it to appear
			return {}
		return {"ok": false, "error": e}
	_last_wait = str(r.get("warning", "not clickable yet"))
	return {}  # hidden/disabled/occluded/clipped are transient — auto-wait


func _try_type(msg: Dictionary) -> Dictionary:
	# per_frame streaming is a type_text-tool feature: a ui_do step must complete within
	# its own attempt, so strip it here (one-frame typing still fires every signal once).
	var m := msg.duplicate()
	m.erase("per_frame")
	var r: Dictionary = _rt._type_text(m)
	if bool(r.get("ok", false)):
		if r.has("warning"):
			_last_wait = str(r["warning"])  # hidden/disabled/not-editable may clear up
			return {}
		var d := {"ok": true, "detail": "typed %d char(s) into %s" % [int(r.get("typed", 0)), str(r.get("path", ""))]}
		if r.has("text_after"):
			d["text_after"] = r["text_after"]
		return d
	var e := str(r.get("error", ""))
	if e.begins_with("node not found") or e.begins_with("no node matches"):
		_last_wait = e
		return {}
	return {"ok": false, "error": e}  # focus_mode NONE / not a Control: permanent


func _try_wait(w: Dictionary) -> Dictionary:
	if w.has("ms"):
		if Time.get_ticks_msec() - _step_t0 >= int(w["ms"]):
			return {"ok": true, "detail": "waited %d ms" % int(w["ms"])}
		_last_wait = "waiting %d ms" % int(w["ms"])
		return {}
	if w.has("node"):
		if _rt._resolve(str(w["node"])) != null:
			return {"ok": true, "detail": "node appeared: %s" % str(w["node"])}
		_last_wait = "node not found yet: %s" % str(w["node"])
		return {}
	if w.has("condition"):
		return _eval_eventually(str(w["condition"]), "wait")
	return {"ok": false, "error": "wait needs one of ms / node / condition"}


## assert = the same eventually-true polling as wait{condition}, plus the
## node/property/equals shorthand (numeric-tolerant, same rule as playtest asserts).
func _try_assert(a: Dictionary) -> Dictionary:
	if a.has("condition"):
		return _eval_eventually(str(a["condition"]), "assert")
	if a.has("node") and a.has("property"):
		var n: Node = _rt._resolve(str(a["node"]))
		if n == null:
			_last_wait = "assert target not found yet: %s" % str(a["node"])
			return {}
		var actual: Variant = n.get(str(a["property"]))
		if _values_equal(actual, a.get("equals")):
			return {"ok": true, "detail": "%s.%s == %s" % [str(a["node"]), str(a["property"]), str(a.get("equals"))]}
		_last_wait = "%s.%s = %s (want %s)" % [str(a["node"]), str(a["property"]), str(actual), str(a.get("equals"))]
		return {}
	return {"ok": false, "error": "assert needs condition, or node+property+equals"}


func _eval_eventually(src: String, what: String) -> Dictionary:
	if _cond == null or _cond_src != src:
		_cond = Expression.new()
		_cond_src = src
		if _cond.parse(src) != OK:
			return {"ok": false, "error": "%s condition parse error: %s" % [what, _cond.get_error_text()]}
	var base: Object = _rt._root()
	if base == null:
		_last_wait = "no current scene"
		return {}
	var v: Variant = _cond.execute([], base, true)
	if _cond.has_execute_failed():
		_last_wait = "%s condition exec error: %s" % [what, _cond.get_error_text()]
		return {}  # a node referenced mid-scene-change may appear next frame
	if bool(v):
		return {"ok": true, "detail": "%s: %s -> true" % [what, src]}
	_last_wait = "%s: %s -> %s" % [what, src, str(v)]
	return {}


func _sel(v: Variant) -> Dictionary:
	# {"click": "Start"} is shorthand for a text selector (scoped to BaseButton by
	# click_control's own rule) — the way an agent naturally writes it.
	if v is String:
		return {"text": str(v)}
	return (v as Dictionary).duplicate() if v is Dictionary else {}


## Numeric-tolerant equality (mirrors playtest_tools/_runner): JSON numbers are floats.
static func _values_equal(actual: Variant, expected: Variant) -> bool:
	if (actual is int or actual is float) and (expected is int or expected is float):
		return is_equal_approx(float(actual), float(expected))
	return str(actual) == str(expected)
