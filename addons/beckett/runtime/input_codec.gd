extends RefCounted
## Input event codec (v1.9.1, extracted from mcp_runtime as part of the B7 split): the ONE
## place a wire-format event dictionary becomes an InputEvent (build) and back (serialize).
## Used by the runtime's recorder, the `input` command, and the deterministic replay window.
## The headless playtest_runner keeps its own LOCAL copy of build_event by design (it is a
## self-contained standalone tool with no addon-internal dependencies) — when an event type
## is added, extend BOTH, plus serialize_event here so the recorder can capture it.
##
## Wire shapes (all optional fields defaulted):
##   {type:"key", keycode:"Right", pressed, unicode?}          — keycode is the STRING name;
##       unicode = optional codepoint (int, or a 1-char string) so a key event can CARRY
##       TEXT: LineEdit/TextEdit insert from unicode, not keycode (drives type_text + lets
##       the recorder round-trip real typing)
##   {type:"action", action, pressed, strength}
##   {type:"mouse_button", button, position:[x,y], pressed}
##   {type:"mouse_motion", position:[x,y], relative:[x,y]}
##   {type:"joy_button", button, pressed, device}
##   {type:"joy_axis", axis, value(-1..1), device}
##   {type:"touch", index, position:[x,y], pressed}
##   {type:"touch_drag", index, position:[x,y], relative:[x,y]}

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # "pressed" can arrive as text from a lenient client


## Godot 4.7 gave synthesized keyboard/mouse events a real device id; before that, an
## injected event carried device 0 and code that filters on the device could not tell it
## from a joypad. Resolved through ClassDB rather than referenced directly: naming
## InputEvent.DEVICE_ID_KEYBOARD in source would be a PARSE error on 4.2-4.6, which a
## runtime `if` cannot guard (same trap as the 4.5+ Logger APIs). -1 means "not available",
## and then nothing is stamped and 4.2-4.6 behave exactly as before.
static var _device_keyboard: int = -1
static var _device_mouse: int = -1
static var _device_ids_probed := false


static func _probe_device_ids() -> void:
	if _device_ids_probed:
		return
	_device_ids_probed = true
	# ASSIGN the -1 sentinel, never lean on the declared default. This script is not @tool,
	# and when the editor preloads it from one that is, the static initialisers do not run:
	# `_device_keyboard` then sits at the int default 0, which reads as a REAL device id.
	# That made doctor report "stamped (keyboard=0)" on an engine with no such constant -
	# a tool confidently reporting a capability it does not have.
	_device_keyboard = -1
	_device_mouse = -1
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD"):
		_device_keyboard = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_MOUSE"):
		_device_mouse = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_MOUSE")


## The device ids this engine exposes, for doctor/tests. {keyboard, mouse}; -1 = absent.
static func device_ids() -> Dictionary:
	_probe_device_ids()
	return {"keyboard": _device_keyboard, "mouse": _device_mouse}


static func build_event(e: Dictionary) -> InputEvent:
	_probe_device_ids()
	match str(e.get("type", "")):
		"key":
			var k := InputEventKey.new()
			var kc: int = OS.find_keycode_from_string(str(e.get("keycode", "")))
			k.keycode = kc
			k.physical_keycode = kc
			k.pressed = CallArgs.flag(e, "pressed", true)
			var uni: Variant = e.get("unicode", 0)
			if uni is String and (uni as String).length() > 0:
				k.unicode = (uni as String).unicode_at(0)
			else:
				k.unicode = int(uni) if (uni is int or uni is float) else 0
			if _device_keyboard >= 0:
				k.device = _device_keyboard
			return k
		"action":
			var a := InputEventAction.new()
			a.action = StringName(str(e.get("action", "")))
			a.pressed = CallArgs.flag(e, "pressed", true)
			a.strength = float(e.get("strength", 1.0)) if a.pressed else 0.0
			return a
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(e.get("button", 1))
			mb.pressed = CallArgs.flag(e, "pressed", true)
			mb.position = vec2(e.get("position", [0, 0]))
			if _device_mouse >= 0:
				mb.device = _device_mouse
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = vec2(e.get("position", [0, 0]))
			mm.relative = vec2(e.get("relative", [0, 0]))
			if _device_mouse >= 0:
				mm.device = _device_mouse
			return mm
		"joy_button":
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(e.get("button", 0))
			jb.pressed = CallArgs.flag(e, "pressed", true)
			jb.device = int(e.get("device", 0))
			return jb
		"joy_axis":
			var ja := InputEventJoypadMotion.new()
			ja.axis = int(e.get("axis", 0))
			ja.axis_value = clampf(float(e.get("value", 0.0)), -1.0, 1.0)
			ja.device = int(e.get("device", 0))
			return ja
		"touch":
			var st := InputEventScreenTouch.new()
			st.index = int(e.get("index", 0))
			st.position = vec2(e.get("position", [0, 0]))
			st.pressed = CallArgs.flag(e, "pressed", true)
			return st
		"touch_drag":
			var sd := InputEventScreenDrag.new()
			sd.index = int(e.get("index", 0))
			sd.position = vec2(e.get("position", [0, 0]))
			sd.relative = vec2(e.get("relative", [0, 0]))
			return sd
		_:
			return null


## The recorder's half: a live InputEvent back to the wire shape. Echo keys serialize to {}
## (drop) — replays re-synthesize their own echoes. Synthetic InputEventAction is NOT
## serialized (documented recorder limit: record with key/mouse/joy/touch events).
static func serialize_event(e: InputEvent) -> Dictionary:
	if e is InputEventKey:
		var k := e as InputEventKey
		if k.echo:
			return {}
		var kc: int = k.keycode if k.keycode != 0 else k.physical_keycode
		var d := {"type": "key", "keycode": OS.get_keycode_string(kc), "pressed": k.pressed}
		if k.unicode != 0:
			d["unicode"] = k.unicode
		return d
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		return {"type": "mouse_button", "button": mb.button_index, "position": [mb.position.x, mb.position.y], "pressed": mb.pressed}
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		return {"type": "mouse_motion", "position": [mm.position.x, mm.position.y], "relative": [mm.relative.x, mm.relative.y]}
	if e is InputEventJoypadButton:
		var jb := e as InputEventJoypadButton
		return {"type": "joy_button", "button": jb.button_index, "pressed": jb.pressed, "device": jb.device}
	if e is InputEventJoypadMotion:
		var ja := e as InputEventJoypadMotion
		return {"type": "joy_axis", "axis": ja.axis, "value": ja.axis_value, "device": ja.device}
	if e is InputEventScreenTouch:
		var st := e as InputEventScreenTouch
		return {"type": "touch", "index": st.index, "position": [st.position.x, st.position.y], "pressed": st.pressed}
	if e is InputEventScreenDrag:
		var sd := e as InputEventScreenDrag
		return {"type": "touch_drag", "index": sd.index, "position": [sd.position.x, sd.position.y], "relative": [sd.relative.x, sd.relative.y]}
	return {}


static func vec2(v: Variant) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(v[0], v[1])
	if v is Dictionary:
		return Vector2(v.get("x", 0), v.get("y", 0))
	return Vector2.ZERO


# --- held-input bookkeeping (v1.16, playtest op=repeat) -------------------------------------------
# A run that ends with a key still down would hand the NEXT run a game that already believes the key
# is held, and the second run would read as flaky for a reason that has nothing to do with the game.
# mcp_runtime remembers what its injected events pressed (track), so a scene restart can let go.

## What an event presses, as a stable key: "" for an event that holds nothing (motion, drag).
static func held_signature(e: InputEvent) -> String:
	if e is InputEventKey:
		return "key:%d:%d" % [(e as InputEventKey).keycode, (e as InputEventKey).physical_keycode]
	if e is InputEventMouseButton:
		return "mouse:%d" % (e as InputEventMouseButton).button_index
	if e is InputEventJoypadButton:
		return "joy:%d:%d" % [(e as InputEventJoypadButton).device, (e as InputEventJoypadButton).button_index]
	if e is InputEventJoypadMotion:
		return "axis:%d:%d" % [(e as InputEventJoypadMotion).device, (e as InputEventJoypadMotion).axis]
	if e is InputEventScreenTouch:
		return "touch:%d" % (e as InputEventScreenTouch).index
	if e is InputEventAction:
		return "action:%s" % str((e as InputEventAction).action)
	return ""


## Is the event holding its input down (a press, a non-zero axis)?
static func holds(e: InputEvent) -> bool:
	if e is InputEventJoypadMotion:
		return absf((e as InputEventJoypadMotion).axis_value) > 0.0
	return e.is_pressed()


## The event that lets go of what `e` pressed: a copy with pressed=false, the axis at 0, no strength.
static func release_of(e: InputEvent) -> InputEvent:
	var r := e.duplicate() as InputEvent
	if r is InputEventJoypadMotion:
		(r as InputEventJoypadMotion).axis_value = 0.0
	elif r is InputEventAction:
		(r as InputEventAction).pressed = false
		(r as InputEventAction).strength = 0.0
	elif "pressed" in r:
		r.set("pressed", false)
	return r


## Update `held` (signature -> release event) after `e` was injected.
static func track(held: Dictionary, e: InputEvent) -> void:
	var sig := held_signature(e)
	if sig.is_empty():
		return
	if holds(e):
		held[sig] = release_of(e)
	else:
		held.erase(sig)


## Let go of everything `held` remembers, and forget it. Returns how many inputs were released.
static func release_all(held: Dictionary) -> int:
	var n := held.size()
	for sig in held:
		Input.parse_input_event(held[sig])
	held.clear()
	return n
