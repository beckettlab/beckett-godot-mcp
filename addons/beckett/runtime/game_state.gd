extends RefCounted
## Game-owned state (v1.16). A game knows what "state" means for itself: a score, an inventory, the phase
## of a boss fight. A property read cannot tell which of a node's fields matter, and a screenshot cannot
## show a number the UI never draws, so a node SAYS what its state is:
##
##   - put the node in the group "beckett_state";
##   - give it `func _beckett_state() -> Dictionary` that returns plain data: numbers, strings, bools,
##     arrays and dictionaries of them (a Vector2 or a Color is fine, it is read as text).
##
## The same convention under the other name in use, so a game written for leftos/godot-mcp or
## wgt19861219/godot-mcp-enhanced works unchanged: the group "mcp_state" with `_mcp_state()`. A node that
## has both is read through `_beckett_state`.
##
## It is used twice. get_remote_tree state=true (a See tool, so Lite has it) returns every node's state
## through collect(); a playtest `state` step asserts on dotted paths into one node's dictionary through
## evaluate(), with the ops eq ne lt le gt ge contains exists. The standalone test that playtest
## op=export_gd writes carries its own copy of lookup / compare / evaluate (it must not touch
## addons/beckett): extend BOTH, the unit suite pins that they agree.
##
## HARD CONSTRAINT on this file: no editor classes, parse-safe on 4.2+ (it ships in the game).

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # coercing a JSON expectation to the state value's type

const GROUP := "beckett_state"
const METHOD := "_beckett_state"
const GROUP_ALT := "mcp_state"
const METHOD_ALT := "_mcp_state"
const OPS := ["eq", "ne", "lt", "le", "gt", "ge", "contains", "exists"]

## What one collection may carry. A game's state dictionary is the game's to size, and it crosses the
## bridge into a tool reply a model reads, so every limit says so when it cuts.
const MAX_NODES := 40        # nodes read per collection (a call may ask for fewer, or up to MAX_NODES_HARD)
const MAX_NODES_HARD := 200
const MAX_DEPTH := 6         # nesting of one value
const MAX_ITEMS := 64        # entries kept of one dictionary or array
const MAX_STRING := 120      # characters kept of one string value
const MAX_KEY := 60          # characters kept of one key
const MAX_PATH := 200        # characters kept of a node path used as a key
const MAX_CHARS := 12000     # characters of data in the whole reply (about 3k tokens)
const MAX_CHARS_NODE := 6000 # of which one node may spend this much, so one big dictionary cannot starve the rest
const REPORT_CAP := 160      # characters of any value or error echoed in a result
const MAX_ERRORS := 10

## Types that read as a list (an array and every packed array).
const LIST_TYPES := [TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY,
	TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY]


# ---------------------------------------------------------------- finding the nodes

## The method a node answers to, "" when it has neither.
static func method_of(node: Object) -> String:
	if node.has_method(METHOD):
		return METHOD
	if node.has_method(METHOD_ALT):
		return METHOD_ALT
	return ""


## Every node in either group, sorted by path so a collection reads the same twice.
static func members(tree: SceneTree) -> Array:
	var out: Array = []
	if tree == null:
		return out
	for g in [GROUP, GROUP_ALT]:
		for n in tree.get_nodes_in_group(g):
			if n is Node and is_instance_valid(n) and not out.has(n):
				out.append(n)
	out.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	return out


## A node's name for a reply: relative to the scene root when it is inside the scene ("." for the root
## itself), the absolute /root/... path for an autoload or anything else outside it. Both resolve through
## the runtime's own path resolver, so a key of a collection can be fed straight back into a `state` step.
static func path_of(node: Node, scene_root: Node) -> String:
	if scene_root != null and (node == scene_root or scene_root.is_ancestor_of(node)):
		return "." if node == scene_root else str(scene_root.get_path_to(node))
	return str(node.get_path())


## Ask a node for its state: {ok: true, state: Dictionary, method} or {ok: false, error, missing?}. A node
## with no method answers `missing`, which is a different finding from a method that misbehaves.
static func read_node(node: Object) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {"ok": false, "error": "the node is gone"}
	var m := method_of(node)
	if m.is_empty():
		return {"ok": false, "missing": true, "error": "the node has no %s() or %s(): add `func %s() -> Dictionary` to its script and put the node in the group \"%s\"" % [METHOD, METHOD_ALT, METHOD, GROUP]}
	var v: Variant = node.call(m)
	if not (v is Dictionary):
		return {"ok": false, "error": "%s() returned %s, not a Dictionary (if it raised an error, game_logs has it)" % [m, type_string(typeof(v))]}
	return {"ok": true, "state": v, "method": m}


# ---------------------------------------------------------------- collecting (get_remote_tree state=true)

## {states: {path: data}, count, nodes_total, truncated?, truncated_nodes?, errors?}: every node of the tree
## that exposes state, each dictionary converted to JSON-safe data under the caps above. `truncated` says
## that the reply is not the whole state (a node past a cap, a long list, a deep value, a long string).
static func collect(tree: SceneTree, scene_root: Node, max_nodes: int = MAX_NODES) -> Dictionary:
	var nodes := members(tree)
	var cap := clampi(max_nodes, 1, MAX_NODES_HARD)
	var spent := 0
	var states := {}
	var cut_nodes: Array = []
	var errors: Array = []
	var read := 0
	for n in nodes:
		var key := path_of(n, scene_root).left(MAX_PATH)  # a node name is the game's to choose: capped like any other text
		if read >= cap or spent >= MAX_CHARS or states.has(key):
			cut_nodes.append(key)
			continue
		var r := read_node(n)
		if not bool(r.get("ok", false)):
			if errors.size() < MAX_ERRORS:
				errors.append({"node": key, "error": str(r.get("error", "")).left(REPORT_CAP)})
			continue
		var budget := {"chars": 0, "max": mini(MAX_CHARS_NODE, MAX_CHARS - spent), "truncated": false}
		states[key] = json_safe(r["state"], budget, 0)
		spent += int(budget["chars"])
		if bool(budget["truncated"]):
			cut_nodes.append(key)
		read += 1
	var out := {"states": states, "count": read, "nodes_total": nodes.size()}
	if not cut_nodes.is_empty():
		out["truncated"] = true
		out["truncated_nodes"] = cut_nodes.slice(0, MAX_ERRORS)
	if not errors.is_empty():
		out["errors"] = errors
	return out


## A JSON-safe copy of a value under the caps. bool / int / finite float stay as they are, a string, a
## key, a StringName or a NodePath is a capped string, a dictionary or array (packed ones included) is
## copied entry by entry, and everything else (a Vector2, a Color, an Object) is its text, the way
## runtime_get_property reports it. `budget` = {chars, max, truncated}: characters spent so far, the limit,
## and whether anything was cut.
static func json_safe(v: Variant, budget: Dictionary, depth: int = 0) -> Variant:
	var t := typeof(v)
	if t == TYPE_NIL or t == TYPE_BOOL or t == TYPE_INT:
		_spend(budget, 6)
		return v
	if t == TYPE_FLOAT:
		_spend(budget, 8)
		return v if (not is_nan(v) and not is_inf(v)) else str(v)
	if t == TYPE_STRING or t == TYPE_STRING_NAME or t == TYPE_NODE_PATH:
		return _text(str(v), budget, MAX_STRING)
	if t == TYPE_DICTIONARY:
		if depth >= MAX_DEPTH:
			budget["truncated"] = true
			return _text(str(v), budget, MAX_STRING)
		var out := {}
		var kept := 0
		for k in v:
			if kept >= MAX_ITEMS or int(budget["chars"]) >= int(budget["max"]):
				budget["truncated"] = true
				break
			var ks := _text(str(k), budget, MAX_KEY)
			out[ks] = json_safe(v[k], budget, depth + 1)
			kept += 1
		return out
	if t in LIST_TYPES:
		if depth >= MAX_DEPTH:
			budget["truncated"] = true
			return _text(str(v), budget, MAX_STRING)
		var arr: Array = []
		for e in v:
			if arr.size() >= MAX_ITEMS or int(budget["chars"]) >= int(budget["max"]):
				budget["truncated"] = true
				break
			arr.append(json_safe(e, budget, depth + 1))
		return arr
	if t == TYPE_OBJECT and not is_instance_valid(v):
		return _text("<freed object>", budget, MAX_STRING)
	return _text(str(v), budget, MAX_STRING)


static func _spend(budget: Dictionary, n: int) -> void:
	budget["chars"] = int(budget["chars"]) + n


static func _text(s: String, budget: Dictionary, cap: int) -> String:
	var t := s.left(cap)
	if t.length() < s.length():
		budget["truncated"] = true
	_spend(budget, t.length() + 4)
	return t


# ---------------------------------------------------------------- asserting (the `state` step)

## "" when `spec` is a well-formed state step body, else what is wrong with it. Static and dependency-free
## so playtest op=save can refuse a malformed step before it is ever run.
static func spec_error(spec: Variant) -> String:
	if not (spec is Dictionary):
		return "state takes an object: {node, path, op, value} (ops: %s)" % ", ".join(OPS)
	var d: Dictionary = spec
	if str(d.get("node", "")).strip_edges().is_empty():
		return "state needs a 'node': the path or name of a node that exposes state"
	if str(d.get("path", "")).strip_edges().is_empty():
		return "state needs a 'path' into the node's state dictionary (dotted: stats.hp, inventory.0)"
	var op := str(d.get("op", "eq")).strip_edges().to_lower()
	if not OPS.has(op):
		return "state op '%s' is not one of: %s" % [op, ", ".join(OPS)]
	if op != "exists" and not d.has("value"):
		return "state op %s needs a 'value' to compare with" % op
	return ""


## Judge one state step against a node: {status: pass | fail | blocked, detail, evaluated}.
##   pass     the state was read and the condition holds
##   fail     the state was read and the condition is false (or the value cannot be compared that way)
##   blocked  nothing could be judged: the node has no state method, or it did not return a dictionary
## `evaluated` is true when a state dictionary was read at all, which is what lets a polling caller tell a
## condition that stayed false from a node that never answered.
static func evaluate(node: Object, spec: Dictionary) -> Dictionary:
	var op := str(spec.get("op", "eq")).strip_edges().to_lower()
	var path := str(spec.get("path", "")).strip_edges()
	var label := "state %s.%s" % [str(spec.get("node", "")).left(60), path.left(60)]
	var r := read_node(node)
	if not bool(r.get("ok", false)):
		return {"status": "blocked", "evaluated": false, "detail": "%s: %s" % [label, str(r.get("error", "no state"))]}
	var found := lookup(r["state"], path)
	if op == "exists":
		var want := CallArgs.to_bool(spec.get("value"), true)
		if bool(found["found"]) == want:
			return {"status": "pass", "evaluated": true, "detail": "%s %s" % [label, "exists" if want else "does not exist"]}
		return {"status": "fail", "evaluated": true, "detail": "%s %s" % [label, "does not exist" if want else "exists"]}
	if not bool(found["found"]):
		return {"status": "fail", "evaluated": true, "detail": "%s: %s" % [label, missing_text(found)]}
	var actual: Variant = found["value"]
	var expected: Variant = spec.get("value")
	var cmp := compare(op, actual, expected)
	var shown := "%s = %s" % [label, preview(actual)]
	if str(cmp["error"]) != "":
		return {"status": "fail", "evaluated": true, "detail": "%s: %s" % [shown, str(cmp["error"])]}
	if bool(cmp["holds"]):
		return {"status": "pass", "evaluated": true, "detail": "%s (%s %s)" % [shown, op, preview(expected)]}
	return {"status": "fail", "evaluated": true, "detail": "%s, wanted %s %s" % [shown, op, preview(expected)]}


## "has no 'b' under 'a' (it has: x, y)" for a lookup that found nothing.
static func missing_text(found: Dictionary) -> String:
	var at := str(found.get("at", ""))
	var s := "has no '%s'" % str(found.get("missing", ""))
	if not at.is_empty():
		s += " under '%s'" % at
	var keys: Variant = found.get("keys", [])
	if keys is Array and not (keys as Array).is_empty():
		s += " (it has: %s)" % ", ".join(PackedStringArray(keys)).left(REPORT_CAP)
	return s


static func preview(v: Variant) -> String:
	return str(v).left(REPORT_CAP)


# ---------------------------------------------------------------- dotted paths

## Walk a dotted path through a state value: {found: true, value, at} or {found: false, at, missing, keys}.
## A segment names a dictionary key (a number is tried as an integer key too), an array index (negative
## counts from the end), a property of an object, or a component of a Vector / Color / Rect2.
static func lookup(state: Variant, dotted: String) -> Dictionary:
	var cur: Variant = state
	var at := ""
	for seg in dotted.split(".", false):
		var s := String(seg)
		var nxt := _child(cur, s)
		if not bool(nxt["found"]):
			return {"found": false, "at": at, "missing": s, "keys": keys_of(cur)}
		cur = nxt["value"]
		at = s if at.is_empty() else at + "." + s
	return {"found": true, "value": cur, "at": at}


static func _child(cur: Variant, seg: String) -> Dictionary:
	var t := typeof(cur)
	if t == TYPE_DICTIONARY:
		var d: Dictionary = cur
		if d.has(seg):
			return {"found": true, "value": d[seg]}
		if d.has(StringName(seg)):
			return {"found": true, "value": d[StringName(seg)]}
		if seg.is_valid_int() and d.has(seg.to_int()):
			return {"found": true, "value": d[seg.to_int()]}
	elif t in LIST_TYPES:
		if seg.is_valid_int():
			var n: int = cur.size()
			var i := seg.to_int()
			if i < 0:
				i += n
			if i >= 0 and i < n:
				return {"found": true, "value": cur[i]}
	elif t == TYPE_VECTOR2 or t == TYPE_VECTOR2I:
		if seg in ["x", "y"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_VECTOR3 or t == TYPE_VECTOR3I:
		if seg in ["x", "y", "z"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_VECTOR4 or t == TYPE_VECTOR4I or t == TYPE_QUATERNION:
		if seg in ["x", "y", "z", "w"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_COLOR:
		if seg in ["r", "g", "b", "a"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_RECT2 or t == TYPE_RECT2I:
		if seg in ["position", "size"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_OBJECT and is_instance_valid(cur):
		for p in (cur as Object).get_property_list():
			if str(p.get("name", "")) == seg:
				return {"found": true, "value": (cur as Object).get(seg)}
	return {"found": false}


## The names a value offers at one level, for "it has: ..." when a path misses.
static func keys_of(v: Variant) -> Array:
	var out: Array = []
	if v is Dictionary:
		for k in v:
			out.append(str(k).left(40))
			if out.size() >= 12:
				break
	return out


# ---------------------------------------------------------------- comparing

## {holds: bool, error: String}: does `actual` satisfy `op expected`? `error` is set when the comparison
## is not meaningful (an ordering between a string and a list, contains on a number): the caller reports
## it as a failed assertion, and `holds` is false. The expected value arrives as JSON, so a number, a
## string or an array is coerced to the type the state holds before it is compared (a Vector2 state and
## the expectation [1, 2]; a bool state and "true").
static func compare(op: String, actual: Variant, expected: Variant) -> Dictionary:
	match op:
		"eq":
			return {"holds": values_equal(actual, expected), "error": ""}
		"ne":
			return {"holds": not values_equal(actual, expected), "error": ""}
		"lt", "le", "gt", "ge":
			return _order(op, actual, expected)
		"contains":
			return _contains(actual, expected)
	return {"holds": false, "error": "unknown op '%s'" % op}


## Equality for state values: numbers by value (a 3 equals 3.0, a float within is_equal_approx), strings by
## text, arrays and dictionaries entry by entry, vectors and colors approximately. A JSON expectation of
## another type is coerced to the state's type first, and a value that cannot be coerced is simply not equal.
static func values_equal(actual: Variant, expected: Variant) -> bool:
	var ta := typeof(actual)
	var te := typeof(expected)
	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var e_num := te == TYPE_INT or te == TYPE_FLOAT
	if a_num and e_num:
		if ta == TYPE_INT and te == TYPE_INT:
			return actual == expected
		return is_equal_approx(float(actual), float(expected))
	if ta == TYPE_NIL or te == TYPE_NIL:
		return ta == te
	var a_text := ta == TYPE_STRING or ta == TYPE_STRING_NAME
	var e_text := te == TYPE_STRING or te == TYPE_STRING_NAME
	if a_text and e_text:
		return str(actual) == str(expected)
	if ta == TYPE_DICTIONARY and te == TYPE_DICTIONARY:
		if (actual as Dictionary).size() != (expected as Dictionary).size():
			return false
		for k in actual:
			var found := false
			for k2 in expected:
				if str(k2) == str(k):
					found = true
					if not values_equal(actual[k], expected[k2]):
						return false
					break
			if not found:
				return false
		return true
	if ta == TYPE_ARRAY and te == TYPE_ARRAY:
		if (actual as Array).size() != (expected as Array).size():
			return false
		for i in (actual as Array).size():
			if not values_equal(actual[i], expected[i]):
				return false
		return true
	if ta != te:
		var c := CallArgs.coerce(expected, ta)
		if not bool(c.get("ok", false)):
			return false
		return values_equal(actual, c["value"])
	if ta == TYPE_VECTOR2 or ta == TYPE_VECTOR3 or ta == TYPE_VECTOR4 or ta == TYPE_COLOR or ta == TYPE_QUATERNION or ta == TYPE_PLANE:
		return actual.is_equal_approx(expected)
	return actual == expected


static func _order(op: String, actual: Variant, expected: Variant) -> Dictionary:
	var e: Variant = expected
	var a_num := typeof(actual) == TYPE_INT or typeof(actual) == TYPE_FLOAT
	if a_num and typeof(e) == TYPE_STRING and (e as String).strip_edges().is_valid_float():
		e = (e as String).strip_edges().to_float()  # a number sent as text
	var e_num := typeof(e) == TYPE_INT or typeof(e) == TYPE_FLOAT
	if a_num and e_num:
		return {"holds": _order_numbers(op, actual, e), "error": ""}
	var a_text := typeof(actual) == TYPE_STRING or typeof(actual) == TYPE_STRING_NAME
	var e_text := typeof(e) == TYPE_STRING or typeof(e) == TYPE_STRING_NAME
	if a_text and e_text:
		var s := str(actual)
		var t := str(e)
		match op:
			"lt": return {"holds": s < t, "error": ""}
			"le": return {"holds": s <= t, "error": ""}
			"gt": return {"holds": s > t, "error": ""}
		return {"holds": s >= t, "error": ""}
	return {"holds": false, "error": "%s orders two numbers or two strings, but the state is %s and the step wants %s" % [op, type_string(typeof(actual)), type_string(typeof(expected))]}


## lt / le / gt / ge between two numbers. Two ints compare exactly; with a float on either side a value
## that is equal within is_equal_approx counts as equal, so `le` holds for it and `lt` does not.
static func _order_numbers(op: String, a: Variant, e: Variant) -> bool:
	if typeof(a) == TYPE_INT and typeof(e) == TYPE_INT:
		match op:
			"lt": return a < e
			"le": return a <= e
			"gt": return a > e
		return a >= e
	var x := float(a)
	var y := float(e)
	var same := is_equal_approx(x, y)
	match op:
		"lt": return x < y and not same
		"le": return x < y or same
		"gt": return x > y and not same
	return x > y or same


static func _contains(actual: Variant, expected: Variant) -> Dictionary:
	var t := typeof(actual)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return {"holds": str(actual).contains(str(expected)), "error": ""}
	if t == TYPE_DICTIONARY:
		for k in actual:
			if str(k) == str(expected):
				return {"holds": true, "error": ""}
		return {"holds": false, "error": ""}
	if t in LIST_TYPES:
		for e in actual:
			if values_equal(e, expected):
				return {"holds": true, "error": ""}
		return {"holds": false, "error": ""}
	return {"holds": false, "error": "contains works on a string, an array or a dictionary, but the state is %s" % type_string(t)}
