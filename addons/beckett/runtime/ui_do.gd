extends RefCounted
## ui_do macro window (v1.10 P1): ONE bridge call runs a whole semantic UI flow
## GAME-side across frames — the multi-round-trip killer. Steps:
##   {click: <selector dict | "text">}                    - click_control semantics
##   {type: {path/class/name..., text, clear?, submit?}}  - type_text semantics
##   {wait: {ms: N | node: "path" | condition: "expr"}}   - explicit sync point
##   {assert: {condition} | {node, property, equals}}     - EVENTUALLY semantics: polls
##                                                          until true or the step times out
##   {input: {events: [...]}}                             - raw event passthrough
##   {inject: {set: [{node, property, value}],            - patch state IN, then step `frames`
##             call: [{node, method, args}], frames: N}}    frames (default 1) before the next step
##   {state: {node, path, op, value}}                     - assert on the game-owned state a node exposes
##                                                          (_beckett_state(), see game_state.gd); EVENTUALLY
##                                                          semantics like assert
## Every step auto-waits (a not-yet-clickable click / not-yet-typed field / false
## condition just retries) under a per-step timeout (step.timeout_ms, else the window
## default). Stop-on-fail; per-step results report what happened. Mirrors the
## step/replay window shape: `ui_do_open` arms it and replies at once, mcp_runtime's
## _process ticks it, the editor polls `ui_do_status` (B7 rule: machine lives here,
## dispatch stays in mcp_runtime).
##
## Every step result carries a `status` (v1.16), the same words a playtest assert uses:
##   pass     the step did what it says (an assert held)
##   fail     an assert was EVALUATED and was false when its timeout ran out, or the step itself is
##            malformed (unknown step, a wait with nothing to wait for): the suite author's to fix
##   blocked  the step could not get to a judgement: its target never appeared, a control was never
##            clickable, a wait timed out, an inject could not be applied. Nothing was judged.

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # the assert condition's result can be any type
const GameState := preload("res://addons/beckett/runtime/game_state.gd")  # the `state` step: read and judge a node's _beckett_state()

const INJECT_MAX_FRAMES := 600

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
var _evaluated := false         # the CURRENT assert / state step read a value at least once: a timeout then means "false", not "never judged"
var _inj_applied := false       # the CURRENT inject step has applied its state (it must never apply twice: a call is not idempotent)
var _inj_report: Array = []
var _inj_frames := 1
var _inj_f0_process := 0
var _inj_f0_physics := 0


func open(rt: Node, msg: Dictionary) -> Dictionary:
	if active:
		return {"ok": false, "error": "a ui_do window is already open — poll ui_do op=status, or op=abort it"}
	var steps: Variant = msg.get("steps", null)
	if not (steps is Array) or (steps as Array).is_empty():
		return {"ok": false, "error": "steps must be a non-empty array of {click|type|wait|assert|input|inject|state} objects"}
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
			# An assert (or a state step) that READ a value and found it false is a fail; everything else
			# that runs out of time (a click that never became possible, a wait, an assert whose target
			# never existed) never got to judge anything.
			var verdict := "fail" if ((step.has("assert") or is_state(step)) and _evaluated) else "blocked"
			_finish_step(step, {"ok": false, "status": verdict, "error": why})
		return
	_finish_step(step, r)


func _finish_step(step: Dictionary, r: Dictionary) -> void:
	r["step"] = _i
	r["op"] = _op_of(step)
	if not r.has("status"):
		# A step that stopped the flow without saying why could not perform its action: blocked.
		r["status"] = "pass" if bool(r.get("ok", false)) else "blocked"
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
	_evaluated = false
	_inj_applied = false
	_inj_report = []


func _step_timeout(step: Dictionary) -> int:
	return maxi(100, int(step.get("timeout_ms", _default_timeout)))


func _op_of(step: Dictionary) -> String:
	for k in ["click", "type", "wait", "assert", "input"]:
		if step.has(k):
			return k
	if is_inject(step):
		return "inject"
	return "state" if is_state(step) else "?"


## Is this step an inject, in either spelling: {inject: {set, call, frames}} or the flat
## {kind: "inject", set, call, frames}?
static func is_inject(step: Dictionary) -> bool:
	return step.has("inject") or str(step.get("kind", "")) == "inject"


## The body of an inject step (the nested object, or the flat step itself).
static func inject_body(step: Dictionary) -> Variant:
	return step["inject"] if step.has("inject") else step


## Is this step a state assertion, in either spelling: {state: {node, path, op, value}} or the flat
## {kind: "state", node, path, op, value}?
static func is_state(step: Dictionary) -> bool:
	return step.has("state") or str(step.get("kind", "")) == "state"


## The body of a state step (the nested object, or the flat step itself).
static func state_body(step: Dictionary) -> Variant:
	return step["state"] if step.has("state") else step


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
	if is_inject(step):
		var body: Variant = inject_body(step)
		return _try_inject(body if body is Dictionary else {})
	if is_state(step):
		return _try_state(state_body(step))
	return {"ok": false, "status": "fail", "error": "unknown step: use one of click/type/wait/assert/input/inject/state"}


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
	return {"ok": false, "status": "fail", "error": "wait needs one of ms / node / condition"}


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
		_evaluated = true
		if _values_equal(actual, a.get("equals")):
			return {"ok": true, "detail": "%s.%s == %s" % [str(a["node"]), str(a["property"]), str(a.get("equals"))]}
		_last_wait = "%s.%s = %s (want %s)" % [str(a["node"]), str(a["property"]), str(actual), str(a.get("equals"))]
		return {}
	return {"ok": false, "status": "fail", "error": "assert needs condition, or node+property+equals"}


func _eval_eventually(src: String, what: String) -> Dictionary:
	if _cond == null or _cond_src != src:
		_cond = Expression.new()
		_cond_src = src
		if _cond.parse(src) != OK:
			return {"ok": false, "status": "fail", "error": "%s condition parse error: %s" % [what, _cond.get_error_text()]}
	var base: Object = _rt._root()
	if base == null:
		_last_wait = "no current scene"
		return {}
	var v: Variant = _cond.execute([], base, true)
	if _cond.has_execute_failed():
		_last_wait = "%s condition exec error: %s" % [what, _cond.get_error_text()]
		return {}  # a node referenced mid-scene-change may appear next frame
	_evaluated = true
	if CallArgs.to_bool(v):
		return {"ok": true, "detail": "%s: %s -> true" % [what, src]}
	_last_wait = "%s: %s -> %s" % [what, src, str(v)]
	return {}


## {state: {node, path, op, value}}: assert on the game-owned state a node exposes (game_state.gd), with the
## same EVENTUALLY semantics as an assert: the step polls until the condition holds or its timeout runs
## out. A malformed step fails at once. A node that does not exist yet is waited for; a node that exists
## but has no _beckett_state() / _mcp_state(), or whose method does not return a dictionary, ends the
## step `blocked` at once (waiting would not change it). A state that was read and does not satisfy the
## condition keeps the step polling, and a timeout then is a `fail`: it was judged.
func _try_state(spec: Dictionary) -> Dictionary:
	var bad := GameState.spec_error(spec)
	if not bad.is_empty():
		return {"ok": false, "status": "fail", "error": bad}
	var n: Node = _rt._resolve(str(spec["node"]))
	if n == null:
		_last_wait = "state node not found yet: %s" % str(spec["node"]).left(80)
		return {}
	var r: Dictionary = GameState.evaluate(n, spec)
	if bool(r.get("evaluated", false)):
		_evaluated = true
	match str(r.get("status", "")):
		"pass":
			return {"ok": true, "detail": str(r["detail"])}
		"blocked":
			return {"ok": false, "status": "blocked", "error": str(r["detail"])}
	_last_wait = str(r.get("detail", ""))
	return {}


## {inject: {set, call, frames}}: patch state in, then let the game run on it. One attempt per frame
## like every step. Until EVERY target node exists nothing is applied (a menu or a spawned enemy may
## not be there yet, and a call is not idempotent, so a half-applied inject must never be retried);
## then all of it is applied at once, sets before calls, through the same game-side machinery as
## runtime_set_property / runtime_call (value coercion, write read-back, call-argument coercion);
## then the step holds until `frames` physics AND process frames have elapsed (default 1), so the
## next step reads the state AFTER the game ran on what was injected. A target that never appears,
## or a write or call the game refuses, ends the step `blocked`: the flow could not be arranged.
## (State-patching verification, GameGen-Verifier arXiv 2605.07442.)
func _try_inject(spec: Dictionary) -> Dictionary:
	if not _inj_applied:
		var bad := inject_error(spec)
		if not bad.is_empty():
			return {"ok": false, "status": "fail", "error": bad}
		var sets: Array = spec.get("set", []) if spec.get("set", []) is Array else []
		var calls: Array = spec.get("call", []) if spec.get("call", []) is Array else []
		for e in sets + calls:
			if _rt._resolve(str((e as Dictionary)["node"])) == null:
				_last_wait = "inject target not found yet: %s" % str((e as Dictionary)["node"]).left(80)
				return {}
		var applied: Array = []
		for e in sets:
			var ed: Dictionary = e
			var r: Dictionary = _rt._set_cmd(_rt._resolve(str(ed["node"])), {"prop": str(ed["property"]), "value": ed["value"]})
			if not bool(r.get("ok", false)):
				return {"ok": false, "status": "blocked", "applied": applied,
					"error": ("inject set %s.%s failed: %s" % [str(ed["node"]), str(ed["property"]), str(r.get("error", "refused"))]).left(240)}
			applied.append(("set %s.%s: %s -> %s" % [str(ed["node"]), str(ed["property"]), str(r.get("before")), str(r.get("after"))]).left(160))
		for e in calls:
			var cd: Dictionary = e
			var cr: Dictionary = _rt._call_cmd(_rt._resolve(str(cd["node"])), {"method": str(cd["method"]), "args": cd.get("args", [])})
			if not bool(cr.get("ok", false)):
				return {"ok": false, "status": "blocked", "applied": applied,
					"error": ("inject call %s.%s failed: %s" % [str(cd["node"]), str(cd["method"]), str(cr.get("error", "refused"))]).left(240)}
			applied.append(("call %s.%s -> %s" % [str(cd["node"]), str(cd["method"]), str(cr.get("result"))]).left(160))
		_inj_applied = true
		_inj_report = applied
		_inj_frames = clampi(int(spec.get("frames", 1)), 1, INJECT_MAX_FRAMES)
		_inj_f0_process = Engine.get_process_frames()
		_inj_f0_physics = Engine.get_physics_frames()
		# The stepping that follows is the game's own time, not the step waiting to get ready: 600 frames at 60 Hz are
		# ten seconds, past the five a step is given by default, so the step's clock restarts to cover them (a game
		# that really stops still runs out of the longer one).
		_deadline = maxi(_deadline, Time.get_ticks_msec() + inject_budget_ms(_inj_frames, Engine.physics_ticks_per_second, Engine.time_scale))
	if Engine.get_process_frames() - _inj_f0_process >= _inj_frames and Engine.get_physics_frames() - _inj_f0_physics >= _inj_frames:
		return {"ok": true, "detail": "applied %d change(s), stepped %d frame(s)" % [_inj_report.size(), _inj_frames], "applied": _inj_report}
	_last_wait = "stepping %d frame(s) after the inject" % _inj_frames
	return {}


## How long the stepping of an inject may take, in ms: `frames` physics frames at the project's rate (the engine's
## time scale makes a second of physics shorter or longer), doubled for a game that hitches, and a second on top.
## The step's deadline covers it (_try_inject) and so does the cap on a whole flow (playtest_tools._run_steps and the
## exported test's own). The exported test carries the same maths (inject_budget_ms there): the unit suite pins both.
static func inject_budget_ms(frames: int, ticks_per_second: int, time_scale: float) -> int:
	var rate := maxf(1.0, float(ticks_per_second)) * clampf(time_scale, 0.1, 10.0)
	return int(2000.0 * float(clampi(frames, 1, INJECT_MAX_FRAMES)) / rate) + 1000


## "" when `spec` is a well-formed inject step body, else what is wrong with it. Static and
## dependency-free so playtest op=save can refuse a malformed inject before it is ever run.
static func inject_error(spec: Variant) -> String:
	if not (spec is Dictionary):
		return "inject takes an object: {set: [{node, property, value}], call: [{node, method, args}], frames: N}"
	var sets: Variant = (spec as Dictionary).get("set", [])
	var calls: Variant = (spec as Dictionary).get("call", [])
	if not (sets is Array) or not (calls is Array):
		return "inject: set and call must be arrays"
	if (sets as Array).is_empty() and (calls as Array).is_empty():
		return "inject needs set and/or call (nothing to apply)"
	for i in (sets as Array).size():
		var s: Variant = (sets as Array)[i]
		if not (s is Dictionary) or str((s as Dictionary).get("node", "")).is_empty() or str((s as Dictionary).get("property", "")).is_empty() or not (s as Dictionary).has("value"):
			return "inject set[%d] needs {node, property, value}" % i
	for i in (calls as Array).size():
		var c: Variant = (calls as Array)[i]
		if not (c is Dictionary) or str((c as Dictionary).get("node", "")).is_empty() or str((c as Dictionary).get("method", "")).is_empty():
			return "inject call[%d] needs {node, method, args?}" % i
		if (c as Dictionary).has("args") and not ((c as Dictionary)["args"] is Array):
			return "inject call[%d]: args must be an array" % i
	return ""


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
