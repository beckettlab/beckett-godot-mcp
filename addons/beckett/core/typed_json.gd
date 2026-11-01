extends RefCounted

## Values from the running game, with their types (1.17).
##
## Why this exists: every value used to cross the game channel as JSON text. The game wrote each Vector, Color and
## Transform as the text str() prints, because JSON has no such types, so a bone pose came back as
## "[X: (0.707107, 0.0, -0.707107), ...]" and an agent pulled the numbers back out with a regex. And the editor's
## JSON.parse_string reads every number as a float: find_bone's 12 came back as 12.0, which broke a script that passed
## it where a whole number was wanted, and an int above 2^53 (an object's instance id) came back as another number.
##
## Now a reply crosses in the engine's own binary form (var_to_bytes, exact for every type and any nesting), and the
## editor renders it once, at the one place every reply comes back through (RuntimeBridge.send_command), into JSON a
## client reads:
##   - an int stays an int and a float a float, a StringName or a NodePath is its text;
##   - a vector, a Color or a Quaternion is the array of its components: [0, 6, 11], [r, g, b, a], [x, y, z, w];
##   - the matrix family is an array of arrays: a Transform3D is [[x axis], [y axis], [z axis], [origin]], a Basis
##     [[x], [y], [z]], a Transform2D [[x], [y], [origin]], a Projection [[x], [y], [z], [w]] (each one a column, the
##     order of Godot's own constructors), a Rect2 or an AABB [[position], [size]], a Plane [[normal], d];
##   - a component of any of those (a float32 in a standard build) is the shortest decimal that reads back as the same
##     float32, and an int when it is whole: [-3.4, 0.58, 4.6], not [-3.40000009536743, 0.579999983310699, ...];
##   - an object, a Callable, a Signal or an RID is its text, written in the game where it lives; a float that is not
##     finite is "nan", "inf" or "-inf", which JSON can carry (a bare nan made the whole reply line unreadable).
## CallArgs takes every one of these shapes back, so a value read can be written straight back.
##
## Either side may be the older one. The editor asks for the binary reply with a flag on each command (ASK); a game
## that predates the flag ignores it and answers in JSON, and a game asked by an editor that predates it answers in
## JSON too. The editor decodes with bytes_to_var, which never builds an object (an object id would come back as an
## EncodedObjectAsID; the game sends its objects as text anyway).
##
## same() is the one rule every node_state assert judges by: the editor's playtest run, the headless runner, the test
## playtest op=export_gd writes (a verbatim copy, pinned by the unit suite), ui_do's assert step and assert_node_state.
##
## HARD CONSTRAINTS on this file: no editor classes (the game preloads it); parse-safe on Godot 4.2+, so no type
## constant newer than 4.2 is named (a packed array type is recognised by its place in the list of types instead).

const CallArgs := preload("res://addons/beckett/core/callargs.gd")

## The key a command carries to ask for the binary reply, and its value: the version of the reply's form.
const ASK := "tv"
const VERSION := 1
## The key of a binary reply: {"_id": n, "__bk": 1, "b": "<base64 of var_to_bytes(reply)>"}.
const MARK := "__bk"
## The types whose Godot literal ("Vector3(0, 6, 11)", "Transform3D(...)") same() reads as that type.
const LITERAL_TYPES := ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Quaternion", "Rect2", "Rect2i",
	"Transform2D", "Basis", "Transform3D", "Projection", "AABB", "Plane"]
## The labels str() writes inside a matrix-family value ("[X: (1.0, 0.0), Y: ..., O: ...]", "[P: ..., S: ...]",
## "[N: ..., D: 2]"), dropped with the brackets and commas when same() reads the numbers of such text.
const PRINT_MARKS := ["X:", "Y:", "Z:", "W:", "O:", "P:", "S:", "N:", "D:", "(", ")", "[", "]", ","]


# ---------------------------------------------------------------- the wire

## Does this command ask for the binary reply? JSON hands the flag's 1 over as a float, so it is compared as a number.
static func asks_typed(msg: Dictionary) -> bool:
	var v: Variant = msg.get(ASK)
	return (v is int or v is float) and v == VERSION


## Game side: a reply in its binary form, ready for JSON.stringify.
static func pack(resp: Dictionary) -> Dictionary:
	return {MARK: VERSION, "b": Marshalls.raw_to_base64(var_to_bytes(to_plain(resp)))}


## A copy of `v` that var_to_bytes carries without an object in it: an object, a Callable, a Signal and an RID are their
## text, read here in the game, where the object lives (sent as they are, an object would arrive as an id the editor
## cannot read, a Callable as nothing, and a Signal as an id that names some other object there). That goes for a
## dictionary's keys as well as its values. Arrays and dictionaries come back plain: an Array[Node] cannot hold the
## text of its nodes, and a typed one (Array[int], an Array of a script's class) is rebuilt plain too, so no type a
## script declared travels with the bytes.
static func to_plain(v: Variant) -> Variant:
	match typeof(v):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return str(v)
		TYPE_ARRAY:
			if not _has_live(v):
				return v  # most replies hold no object at all: handed on as they are, not copied
			var out: Array = []
			for e in v:
				out.append(to_plain(e))
			return out
		TYPE_DICTIONARY:
			if not _has_live(v):
				return v
			var d := {}
			for k in v:
				d[to_plain(k)] = to_plain(v[k])
			return d
	return v


## Does `v` hold an object, a Callable, a Signal, an RID or a typed container anywhere, keys included? Those four and
## the two containers are the types TYPE_RID to TYPE_ARRAY (23 to 28 on every version), so a plain value is passed over
## without a call: a big tree reply is mostly strings and numbers.
static func _has_live(v: Variant) -> bool:
	var t := typeof(v)
	if t == TYPE_ARRAY:
		if (v as Array).is_typed():
			return true
		for e in v:
			var te := typeof(e)
			if te >= TYPE_RID and te <= TYPE_ARRAY and _has_live(e):
				return true
		return false
	if t == TYPE_DICTIONARY:
		if _dict_typed and v.is_typed():
			return true
		for k in v:
			var tk := typeof(k)
			if tk >= TYPE_RID and tk <= TYPE_ARRAY and _has_live(k):
				return true
			var e: Variant = v[k]
			var te := typeof(e)
			if te >= TYPE_RID and te <= TYPE_ARRAY and _has_live(e):
				return true
		return false
	return t >= TYPE_RID and t <= TYPE_SIGNAL


## Godot 4.4 brought typed dictionaries, and Dictionary.is_typed with them: called by name, so this file parses on 4.2.
static var _dict_typed := int(Engine.get_version_info().get("hex", 0)) >= 0x040400


## Editor side: a reply as it came off the socket, parsed. A binary one is unpacked and rendered; any other (a game
## that predates the binary reply) comes back as it is.
static func decode_reply(parsed: Dictionary) -> Dictionary:
	var mark: Variant = parsed.get(MARK)
	if not ((mark is int or mark is float) and mark == VERSION):
		return parsed
	var v: Variant = unpack(str(parsed.get("b", "")))
	if not (v is Dictionary):
		return {"ok": false, "error": "the running game sent a reply that does not decode: call stop_scene, then play_scene, and try again"}
	var out: Dictionary = render(v)
	if parsed.has("_id"):
		out["_id"] = parsed["_id"]
	return out


## The value a binary reply's text holds, or null. bytes_to_var builds no object: an object id comes back as an
## EncodedObjectAsID.
static func unpack(b64: String) -> Variant:
	if b64.is_empty():
		return null
	var raw := Marshalls.base64_to_raw(b64)
	if raw.is_empty():
		return null
	return bytes_to_var(raw)


# ---------------------------------------------------------------- the shape a client reads

## A value as JSON carries it to a client (the shapes are listed at the top of this file).
static func render(v: Variant) -> Variant:
	var t := typeof(v)
	match t:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v):
				return str(v)
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [component(v.x), component(v.y)]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [component(v.x), component(v.y), component(v.z)]
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return [component(v.x), component(v.y), component(v.z), component(v.w)]
		TYPE_COLOR:
			return [component(v.r), component(v.g), component(v.b), component(v.a)]
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return [render(v.position), render(v.size)]
		TYPE_PLANE:
			return [render(v.normal), component(v.d)]
		TYPE_TRANSFORM2D:
			return [render(v.x), render(v.y), render(v.origin)]
		TYPE_BASIS:
			return [render(v.x), render(v.y), render(v.z)]
		TYPE_TRANSFORM3D:
			return [render(v.basis.x), render(v.basis.y), render(v.basis.z), render(v.origin)]
		TYPE_PROJECTION:
			return [render(v.x), render(v.y), render(v.z), render(v.w)]
		TYPE_ARRAY:
			if _is_json(v):
				return v  # most replies are plain data already: handed on as they came, not copied
			var out: Array = []
			for e in v:
				out.append(render(e))
			return out
		TYPE_DICTIONARY:
			if _is_json(v):
				return v
			var d := {}
			for k in v:
				d[str(k)] = render(v[k])
			return d
		TYPE_PACKED_FLOAT32_ARRAY:
			var floats: Array = []
			for e in v:
				floats.append(component(e))
			return floats
	if t >= TYPE_PACKED_BYTE_ARRAY and t < TYPE_MAX:
		# Every other packed array, PackedVector4Array (4.3+) among them.
		var items: Array = []
		for e in v:
			items.append(render(e))
		return items
	return str(v)  # an object, a Callable, a Signal, an RID


## Is `v` already what render makes of it: null, a bool, an int, a finite float, a String, or a plain array or a
## dictionary with String keys holding only those? A plain entry is checked in the loop, without a call: a big tree
## reply is mostly strings and numbers.
static func _is_json(v: Variant) -> bool:
	var t := typeof(v)
	if t == TYPE_ARRAY:
		if (v as Array).is_typed():
			return false
		for e in v:
			var te := typeof(e)
			if te == TYPE_STRING or te == TYPE_INT or te == TYPE_BOOL or te == TYPE_NIL:
				continue
			if te == TYPE_FLOAT and not (is_nan(e) or is_inf(e)):
				continue
			if (te == TYPE_ARRAY or te == TYPE_DICTIONARY) and _is_json(e):
				continue
			return false
		return true
	if t == TYPE_DICTIONARY:
		for k in v:
			if typeof(k) != TYPE_STRING:
				return false
			var e: Variant = v[k]
			var te := typeof(e)
			if te == TYPE_STRING or te == TYPE_INT or te == TYPE_BOOL or te == TYPE_NIL:
				continue
			if te == TYPE_FLOAT and not (is_nan(e) or is_inf(e)):
				continue
			if (te == TYPE_ARRAY or te == TYPE_DICTIONARY) and _is_json(e):
				continue
			return false
		return true
	if t == TYPE_FLOAT:
		return not (is_nan(v) or is_inf(v))
	return t == TYPE_STRING or t == TYPE_INT or t == TYPE_BOOL or t == TYPE_NIL


## One component of a vector, a color or a matrix: an int when it is whole, else the shortest decimal that reads back as
## the same float32 (short_float). Not finite: its text.
static func component(x: Variant) -> Variant:
	if x is int:
		return x
	var f := float(x)
	if is_nan(f) or is_inf(f):
		return str(f)
	if f == floorf(f) and absf(f) < 9007199254740992.0:
		return int(f)
	return short_float(f)


## The shortest decimal, 6 to 9 significant digits, that reads back as the same float32 as `f`: what the value is, where
## its long form (0.579999983310699 for 0.58) is noise a client pays for in every reply. A value that is no float32 (a
## double-precision build, a plain GDScript float) is left as it is.
static func short_float(f: float) -> float:
	if PackedFloat32Array([f])[0] != f:
		return f
	var magnitude := floori(log(absf(f)) / log(10.0))
	for digits in range(6, 10):
		var back := String.num(f, clampi(digits - 1 - magnitude, 0, 32)).to_float()
		if PackedFloat32Array([back])[0] == f:
			return back
	return f


# ---------------------------------------------------------------- judging a value

## Does `actual` hold the value `expected` asks for? Both are rendered first, so a live Vector3 (the runner, ui_do, the
## exported test) and the [0, 6, 11] a reply carries (the editor) read the same. Then: two numbers by value (two whole
## numbers exactly, so 12 matches the 12.0 JSON makes of it and 123456 is not 123457; with a fraction on either side,
## within is_equal_approx); arrays and dictionaries entry by entry; then the same text; and last, where the value read
## is a vector, a color or a matrix in some spelling (numbers_comparable), the numbers each one spells, in order. So a
## suite saved with the text a read printed before 1.17 ("(0.0, 6.0, 11.0)", "[X: (1.0, 0.0, 0.0), ...]") still
## matches, and so do "0 6 11", "Vector3(0, 6, 11)", {"x": 0, "y": 6, "z": 11} and a transform's numbers flat.
static func same(actual: Variant, expected: Variant) -> bool:
	return _same(render(actual), render(expected))


static func _same(a: Variant, e: Variant) -> bool:
	if (a is int or a is float) and (e is int or e is float):
		if _whole(a) and _whole(e):
			return int(a) == int(e)
		return is_equal_approx(float(a), float(e))
	if a is Array and e is Array and (a as Array).size() == (e as Array).size():
		var items_same := true
		for i in (a as Array).size():
			if not _same(a[i], e[i]):
				items_same = false
				break
		if items_same:
			return true
	if a is Dictionary and e is Dictionary and (a as Dictionary).size() == (e as Dictionary).size():
		var keys_same := true
		for k in a:
			if not (e as Dictionary).has(k) or not _same(a[k], e[k]):
				keys_same = false
				break
		if keys_same:
			return true
	if str(a) == str(e):
		return true
	if not numbers_comparable(a, e):
		return false
	var an: Variant = numbers_of(a)
	var en: Variant = numbers_of(e)
	if an == null or en == null or (an as Array).is_empty() or (an as Array).size() != (en as Array).size():
		return false
	for i in (an as Array).size():
		if not _same(an[i], en[i]):
			return false
	return true


## Is the number `x` whole, and small enough that a double holds it exactly? Two such numbers compare exactly: the
## relative tolerance of is_equal_approx (1e-5) would let 123457 pass for 123456.
static func _whole(x: Variant) -> bool:
	return x is int or (absf(x) < 9007199254740992.0 and x == floorf(x))


## May the value read (`a`, rendered) and the one asked for (`e`) be judged by the numbers they spell? Only where `a` is a
## vector, a color or a matrix in some spelling: its array against text ("0 6 11", "Vector3(0, 6, 11)") or {"x": ..}, and
## a nested one (a transform, a rect) against its numbers flat; the text a game from before 1.17 sent for one
## ("(0.0, 6.0, 11.0)", "[X: ...]") against any spelling; and a number against its text ("12.0"). So 12 is not [12], a
## String property "1 2 3" is not [1, 2, 3], and an Array [1, 2, 3, 4] is not [[1, 2], [3, 4]].
static func numbers_comparable(a: Variant, e: Variant) -> bool:
	if a is Array:
		return e is String or e is Dictionary or (e is Array and _nested(a) and not _nested(e))
	if a is String:
		var s := (a as String).strip_edges()
		return s.begins_with("(") or s.begins_with("[")
	return (a is int or a is float) and e is String


static func _nested(v: Array) -> bool:
	for x in v:
		if x is Array:
			return true
	return false


## The numbers a value spells, in order, or null when it spells anything else: a number; an array of them, nested or
## flat; {x, y[, z[, w]]} or {r, g, b[, a]}; or text (text_numbers).
static func numbers_of(v: Variant) -> Variant:
	if v is int or v is float:
		return [v]
	if v is String:
		return text_numbers(v)
	if v is Array:
		var out: Array = []
		for e in v:
			var part: Variant = numbers_of(e)
			if part == null:
				return null
			out.append_array(part)
		return out
	if v is Dictionary:
		var d: Dictionary = v
		for names in [["x", "y", "z", "w"], ["r", "g", "b", "a"]]:
			if d.size() < 2 or d.size() > 4 or not d.has(names[0]):
				continue
			var out: Array = []
			for i in d.size():
				var c: Variant = d.get(names[i])
				if not (c is int or c is float):
					return null
				out.append(c)
			return out
	return null


## The numbers in text: a Godot literal of a vector, matrix or color type, read as that type so its numbers come in
## render's order (var_to_str writes a basis row by row); the way str() prints a value ("(0.0, 6.0, 11.0)",
## "[X: (1.0, 0.0, 0.0), ..., O: (0.0, 0.0, 0.0)]", "[P: (0.0, 0.0), S: (2.0, 2.0)]", "[N: (0.0, 1.0, 0.0), D: 2]");
## or bare ("0 6 11", "0, 6, 11"). A component that is not finite stays its text (inf, -inf, nan), as render writes it.
## null for any other text.
static func text_numbers(text: String) -> Variant:
	var s := text.strip_edges()
	var open := s.find("(")
	if open > 0 and s.ends_with(")"):
		var type_name := s.left(open).strip_edges()
		if type_name == "Color":
			var c: Dictionary = CallArgs.coerce(s, TYPE_COLOR)
			if not bool(c.get("ok", false)):
				return null
			return numbers_of(render(c.get("value")))
		if LITERAL_TYPES.has(type_name):
			var lit: Variant = CallArgs.literal(s, [type_name])
			if lit == null:
				return null
			return numbers_of(render(lit))
		return null
	for m in PRINT_MARKS:
		s = s.replace(m, " ")
	var out: Array = []
	for part in s.split(" ", false):
		if part.is_valid_int():
			out.append(part.to_int())
		elif part.is_valid_float():
			out.append(part.to_float())
		elif part in ["inf", "-inf", "nan"]:
			out.append(part)
		else:
			return null
	if out.is_empty():
		return null
	return out
