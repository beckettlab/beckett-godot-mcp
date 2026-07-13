extends RefCounted
## Input event codec (v1.9.1, extracted from mcp_runtime as part of the B7 split): the ONE
## place a wire-format event dictionary becomes an InputEvent (build) and back (serialize).
## Used by the runtime's recorder, the `input` command, and the deterministic replay window.
## The headless playtest_runner keeps its own LOCAL copy of build_event by design (it is a
## self-contained standalone tool with no addon-internal dependencies) — when an event type
## is added, extend BOTH, plus serialize_event here so the recorder can capture it.
##
## Wire shapes (all optional fields defaulted):
##   {type:"key", keycode:"Right", pressed}                    — keycode is the STRING name
##   {type:"action", action, pressed, strength}
##   {type:"mouse_button", button, position:[x,y], pressed}
##   {type:"mouse_motion", position:[x,y], relative:[x,y]}
##   {type:"joy_button", button, pressed, device}
##   {type:"joy_axis", axis, value(-1..1), device}
##   {type:"touch", index, position:[x,y], pressed}
##   {type:"touch_drag", index, position:[x,y], relative:[x,y]}


static func build_event(e: Dictionary) -> InputEvent:
	match str(e.get("type", "")):
		"key":
			var k := InputEventKey.new()
			var kc: int = OS.find_keycode_from_string(str(e.get("keycode", "")))
			k.keycode = kc
			k.physical_keycode = kc
			k.pressed = bool(e.get("pressed", true))
			return k
		"action":
			var a := InputEventAction.new()
			a.action = StringName(str(e.get("action", "")))
			a.pressed = bool(e.get("pressed", true))
			a.strength = float(e.get("strength", 1.0)) if e.get("pressed", true) else 0.0
			return a
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(e.get("button", 1))
			mb.pressed = bool(e.get("pressed", true))
			mb.position = vec2(e.get("position", [0, 0]))
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = vec2(e.get("position", [0, 0]))
			mm.relative = vec2(e.get("relative", [0, 0]))
			return mm
		"joy_button":
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(e.get("button", 0))
			jb.pressed = bool(e.get("pressed", true))
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
			st.pressed = bool(e.get("pressed", true))
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
		return {"type": "key", "keycode": OS.get_keycode_string(kc), "pressed": k.pressed}
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
