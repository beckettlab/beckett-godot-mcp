extends RefCounted
## Per-physics-frame invariants for a playtest (v1.16). A suite's `invariants` are rules that must hold
## on EVERY physics frame of a run, where an `expr` assert only looks at the end state: "health never
## goes below 0", "the player never leaves the arena", "the score never goes down". A rule that was
## broken for three frames in the middle and mended itself passes every end-state assert and is
## exactly what this catches. (Per-tick rule checks on observable state: GameLogicBench,
## arXiv 2609.21562.)
##
## The checker runs GAME-side, because it has to read the live scene on every frame. mcp_runtime arms
## it for the deterministic replay window and for the ui_do window; the headless playtest runner arms
## its own copy of this same module. No editor classes, parse-safe on 4.2+ (it ships in the game).
##
## Contract
##  * An invariant is {name, expr}: a PURE GDScript boolean expression, evaluated against the scene root
##    exactly like an `expr` assert and time_control step_until (`get_node('Player').health >= 0`). It
##    runs every frame, so it must only read.
##  * It is evaluated at the START of each physics frame, so it sees the state the previous frame left.
##    `frame` is the replay's own physics-frame number (0 = the first frame of the window), the same
##    numbering as the `f` stamps of a recorded event.
##  * The FIRST violation of each rule is kept: its frame, and the values the expression read (see
##    reads_of). Later violations are only counted.
##  * An expression that cannot be evaluated on a frame (a node it names is missing) is not a violation:
##    the frame is counted under `errors`. A rule that was never once evaluated is `blocked` (nothing was
##    judged), not `pass`.
##  * At most MAX_ITEMS rules: the cost is one Expression.execute per rule per frame (measured ~1.5 us
##    for a rule that evaluates, ~100-170 us for one that errors every frame).

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # the result of an expression can be any type

const MAX_ITEMS := 16
const MAX_NAME := 60
const MAX_EXPR := 400
const REPORT_CAP := 160      # characters of any expression, value or error text echoed in a result
const MAX_READS := 6         # operand values reported for the first violation
## Calls an operand may hold and still be read a second time (see is_pure_read): node lookups, sizes and the maths
## and conversions an expression is made of. The names starting is_ / has_ and the capitalised ones (constructors) are accepted too.
const PURE_CALLS := ["get_node", "get_node_or_null", "get_parent", "get_child", "get_child_count", "get_children", "get_tree", "get_nodes_in_group", "get_path",
	"size", "length", "has", "abs", "absf", "absi", "min", "max", "mini", "maxi", "minf", "maxf", "clamp", "clampi", "clampf", "floor", "floorf", "floori",
	"ceil", "ceilf", "ceili", "round", "roundf", "roundi", "sqrt", "sign", "signf", "signi", "pow", "len", "str", "int", "float", "bool", "lerp", "lerpf"]

static var _re_call: RegEx = null

var active := false          # a rule set is loaded (cheap early-out for the per-frame call)
var _items: Array = []


## Validate a suite's `invariants` value without loading it: shape, the cap, unique names, and that
## every expression PARSES. Used by playtest op=save (refuse a typo early) and by open(). Returns
## {ok: true, items: [{name, expr}]} or {ok: false, error}.
static func normalize(list: Variant) -> Dictionary:
	if list == null:
		return {"ok": true, "items": []}
	if not (list is Array):
		return {"ok": false, "error": "invariants must be an array of {name, expr} objects"}
	var arr: Array = list
	if arr.size() > MAX_ITEMS:
		return {"ok": false, "error": "at most %d invariants per suite (got %d): each one is evaluated on every physics frame, so the list is capped" % [MAX_ITEMS, arr.size()]}
	var items: Array = []
	var seen := {}
	for i in arr.size():
		var e: Variant = arr[i]
		if not (e is Dictionary):
			return {"ok": false, "error": "invariant %d must be an object {name, expr}, got: %s" % [i, str(e).left(60)]}
		var src: Variant = (e as Dictionary).get("expr", null)
		if not (src is String) or (src as String).strip_edges().is_empty():
			return {"ok": false, "error": "invariant %d needs an 'expr' string: a GDScript boolean such as \"get_node('Player').health >= 0\"" % i}
		var text := (src as String).strip_edges()
		if text.length() > MAX_EXPR:
			return {"ok": false, "error": "invariant %d: expr is %d characters, the limit is %d" % [i, text.length(), MAX_EXPR]}
		var nm_raw: Variant = (e as Dictionary).get("name", null)
		var nm := (str(nm_raw).strip_edges() if nm_raw != null else "")
		if nm.is_empty():
			nm = "inv%d" % (i + 1)
		if nm.length() > MAX_NAME:
			return {"ok": false, "error": "invariant %d: name is %d characters, the limit is %d" % [i, nm.length(), MAX_NAME]}
		if seen.has(nm):
			return {"ok": false, "error": "two invariants are named '%s': names identify them in the results, so they must differ" % nm}
		seen[nm] = true
		var ex := Expression.new()
		if ex.parse(text) != OK:
			return {"ok": false, "error": "invariant '%s' does not parse: %s" % [nm, ex.get_error_text()]}
		items.append({"name": nm, "expr": text})
	return {"ok": true, "items": items}


## Load a rule set (replacing any previous one) and arm the checker. {ok: true, count} or {ok: false, error}.
func open(list: Variant) -> Dictionary:
	close()
	var n := normalize(list)
	if not bool(n.get("ok", false)):
		return n
	for it in (n["items"] as Array):
		var ex := Expression.new()
		ex.parse(str(it["expr"]))
		_items.append({"name": str(it["name"]), "expr": str(it["expr"]), "ex": ex,
			"checked": 0, "violations": 0, "errors": 0, "last_error": "", "first": {}})
	active = not _items.is_empty()
	return {"ok": true, "count": _items.size()}


## Disarm and forget the rule set (results() is empty afterwards).
func close() -> void:
	active = false
	_items = []


## Evaluate every rule once, against `base` (the scene root), for physics frame `frame`.
func check(base: Object, frame: int) -> void:
	for it in _items:
		var ex: Expression = it["ex"]
		# show_error=false: an expression error is counted and reported once, not printed every frame (Node.get_node
		# on a missing path still logs its own engine error each frame, which is why the docs say get_node_or_null)
		var v: Variant = ex.execute([], base, false)
		if ex.has_execute_failed():
			it["errors"] = int(it["errors"]) + 1
			if str(it["last_error"]).is_empty():
				it["last_error"] = ex.get_error_text().left(REPORT_CAP)
			continue
		it["checked"] = int(it["checked"]) + 1
		if CallArgs.to_bool(v):
			continue
		it["violations"] = int(it["violations"]) + 1
		if (it["first"] as Dictionary).is_empty():
			var first := {"frame": frame, "reads": reads_of(str(it["expr"]), base)}
			if not (v is bool):
				first["value"] = _plain(v)
			it["first"] = first


## One result per rule, shaped like a playtest assert result ({type, status, detail}) so a run folds
## them into its `asserts` list and the verdict, the report and the repeat ranking need no special case.
func results() -> Array:
	var out: Array = []
	for it in _items:
		out.append(result_of(it))
	return out


static func result_of(it: Dictionary) -> Dictionary:
	var checked := int(it["checked"])
	var violations := int(it["violations"])
	var errors := int(it["errors"])
	var r := {"type": "invariant", "name": str(it["name"]), "checked": checked, "violations": violations}
	if errors > 0:
		r["errors"] = errors
	if violations > 0:
		var first: Dictionary = it["first"]
		r["status"] = "fail"
		r["expr"] = str(it["expr"]).left(REPORT_CAP)
		r["first_violation"] = first
		r["detail"] = "violated at frame %d (%d of %d checked frames): %s" % [int(first.get("frame", 0)), violations, checked, _reads_text(first)]
	elif checked == 0:
		r["status"] = "blocked"
		r["expr"] = str(it["expr"]).left(REPORT_CAP)
		r["detail"] = "never evaluated, so nothing was judged: %s" % (_with_hint(str(it["last_error"])) if errors > 0 else "no physics frame ran in the window")
	else:
		r["status"] = "pass"
		var d := "held on %d frame(s)" % checked
		if errors > 0:
			d += ", %d frame(s) could not be evaluated (%s)" % [errors, _with_hint(str(it["last_error"]))]
		r["detail"] = d
	return r


## The engine's text for a read through a missing node ("Invalid named index 'health' for base type Object")
## does not say a node is missing; add the usual cause and the fix when it looks like that.
static func _with_hint(err: String) -> String:
	if err.contains("base type Object") or err.contains("instance is null"):
		return err + " - a node it names may be missing: guard it, e.g. get_node_or_null('X') == null or get_node('X').health >= 0"
	return err


static func _reads_text(first: Dictionary) -> String:
	var reads: Variant = first.get("reads", {})
	var parts: Array = []
	if reads is Dictionary:
		for k in reads:
			parts.append("%s = %s" % [str(k), str(reads[k])])
	if parts.is_empty():
		return "value %s" % str(first.get("value", false))
	return ", ".join(parts)


## The values an expression read, for a violation report: the operands of its comparisons, evaluated
## on their own. `get_node('Player').health >= 0` reports {"get_node('Player').health": -3}; literals
## (the `0`) read nothing and are left out. Expression only returns the final bool, so the operands are
## found by splitting the source at the top level (outside brackets and quotes): first on and / or /
## && / ||, then on the first comparison operator of each clause. Best effort and called ONCE, at the
## first violation: an operand that cannot be evaluated is left out.
## An operand is evaluated here a SECOND time, after the whole expression ran once, so one that calls
## something with an effect of its own (a game's method, a draw of random numbers) would run twice and
## report a value other than the one that was judged: only operands made of property reads and calls that
## are safe to repeat are read (is_pure_read). The rest are left out, like an operand that cannot be evaluated.
static func reads_of(src: String, base: Object) -> Dictionary:
	var out := {}
	for operand in operands_of(src):
		if out.size() >= MAX_READS:
			break
		if not is_pure_read(operand):
			continue
		var ex := Expression.new()
		if ex.parse(operand) != OK:
			continue
		var v: Variant = ex.execute([], base, false)
		if ex.has_execute_failed():
			continue
		out[operand.left(REPORT_CAP)] = _plain(v)
	return out


## Is this operand safe to evaluate again? Property reads are; so are the calls in PURE_CALLS, any name that starts
## with is_ or has_ (a test), and a capitalised name (a constructor: Vector2(1, 2)). A call to anything else
## (bump(), get_node('P').take_damage(1), randi(), Time.get_ticks_msec()) is not: it may change the game, or
## answer differently the second time. Text inside a string literal is not code and is not looked at.
static func is_pure_read(operand: String) -> bool:
	if _re_call == null:
		_re_call = RegEx.create_from_string("([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for m in _re_call.search_all(_without_strings(operand)):
		var fn := m.get_string(1)
		if PURE_CALLS.has(fn) or fn.begins_with("is_") or fn.begins_with("has_") or (fn[0] >= "A" and fn[0] <= "Z"):
			continue
		return false
	return true


## `s` with the inside of every string literal emptied ('a(b' becomes ''), so a call-shaped text in a string is
## not mistaken for a call.
static func _without_strings(s: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
				out += c
		elif c == "'" or c == "\"":
			quote = c
			out += c
		else:
			out += c
		i += 1
	return out


## The non-literal operands of an expression's comparisons, in source order, de-duplicated. Pure, so
## the unit suite pins it.
static func operands_of(src: String, depth: int = 0) -> Array:
	var out: Array = []
	for clause in _split_logic(src):
		var c := _strip_wrapping(String(clause).strip_edges())
		if c.is_empty():
			continue
		# A parenthesised group that holds a logical connective is its own expression.
		if depth < 4 and c != String(clause).strip_edges() and _split_logic(c).size() > 1:
			for o in operands_of(c, depth + 1):
				if not out.has(o):
					out.append(o)
			continue
		var sides := _split_comparison(c)
		for side in sides:
			var s := _strip_wrapping(String(side).strip_edges())
			if s.is_empty() or _is_literal(s) or out.has(s):
				continue
			out.append(s)
	return out


## Cut `src` at every top-level and / or / && / || (not inside (), [], {} or a string).
static func _split_logic(src: String) -> Array:
	var out: Array = []
	var depth := 0
	var quote := ""
	var start := 0
	var i := 0
	var n := src.length()
	while i < n:
		var c := src[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if c == "'" or c == "\"":
			quote = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif depth == 0:
			var skip := _logic_len(src, i)
			if skip > 0:
				out.append(src.substr(start, i - start))
				i += skip
				start = i
				continue
		i += 1
	out.append(src.substr(start))
	return out


## Length of a logical connective starting at i (&&, ||, and, or at a word boundary), else 0.
static func _logic_len(src: String, i: int) -> int:
	var two := src.substr(i, 2)
	if two == "&&" or two == "||":
		return 2
	for word in ["and", "or"]:
		var w: String = word
		if src.substr(i, w.length()) == w and (i == 0 or not _is_ident(src[i - 1])) \
				and (i + w.length() >= src.length() or not _is_ident(src[i + w.length()])):
			return w.length()
	return 0


## The two sides of a clause's first top-level comparison (==, !=, <=, >=, <, >), or the clause alone.
static func _split_comparison(clause: String) -> Array:
	var depth := 0
	var quote := ""
	var i := 0
	var n := clause.length()
	while i < n:
		var c := clause[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if c == "'" or c == "\"":
			quote = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif depth == 0:
			var two := clause.substr(i, 2)
			if two == "==" or two == "!=" or two == "<=" or two == ">=":
				return [clause.substr(0, i), clause.substr(i + 2)]
			if (c == "<" or c == ">") and two != "<<" and two != ">>":
				return [clause.substr(0, i), clause.substr(i + 1)]
		i += 1
	return [clause]


## Drop a leading not / ! and one pair of parentheses that wraps the whole text.
static func _strip_wrapping(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("!") and not t.begins_with("!="):
		t = t.substr(1).strip_edges()
	elif t.begins_with("not ") or t.begins_with("not("):
		t = t.substr(3).strip_edges()
	while t.length() >= 2 and t.begins_with("(") and t.ends_with(")") and _closes_at_end(t):
		t = t.substr(1, t.length() - 2).strip_edges()
	return t


## Does the "(" at index 0 close at the LAST character (so the pair wraps everything)?
static func _closes_at_end(t: String) -> bool:
	var depth := 0
	var quote := ""
	var i := 0
	while i < t.length():
		var c := t[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "'" or c == "\"":
			quote = c
		elif c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth == 0:
				return i == t.length() - 1
		i += 1
	return false


static func _is_ident(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


## A number, true/false/null or a string literal: nothing was read to produce it.
static func _is_literal(s: String) -> bool:
	if s == "true" or s == "false" or s == "null":
		return true
	if s.is_valid_float():
		return true
	if s.length() >= 2 and (s[0] == "'" or s[0] == "\"") and s[s.length() - 1] == s[0]:
		return true
	return false


## A JSON-safe copy of a value for a result: bool/int/finite float/String stay as they are, anything
## else (Vector2, Object, NaN) becomes its text. Length-capped: a value comes from a running game.
static func _plain(v: Variant) -> Variant:
	if v is bool or v is int:
		return v
	if v is float:
		return v if (not is_nan(v) and not is_inf(v)) else str(v)
	if v is String:
		return (v as String).left(REPORT_CAP)
	return str(v).left(REPORT_CAP)
