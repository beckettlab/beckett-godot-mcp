extends RefCounted
## Quiet play (v1.16 M5d): a game the agent launches should not disturb the person working next to it.
##
## play_scene quiet=true asks for it through the environment the launched game inherits (BECKETT_QUIET, the
## way BECKETT_RUNTIME_PORT already reaches it), and this applies it at startup, before the game's own scenes
## load. What applies depends on how the editor launched the game, which the variable says:
##
##   window    a separate game window. It is moved off every screen and flagged no-focus, so it neither covers
##             the person's work nor takes the keys they are typing. It is NOT left minimized: a minimized window
##             stops drawing, and the agent's screenshots read frames the game keeps drawing.
##   embedded  the editor's Game view. The window is a child of the editor's own, so it is left where the editor
##             put it (moving it would break the embedding); only the mute applies.
##   headless  (the game has no display server) there is no window, so only the mute applies.
##
## In every mode the game is MUTED: the master audio bus is muted, and kept muted, because a game that restores
## its saved volume in _ready would otherwise undo it. For the first REPARK_SECS a window that moves back on
## screen (a game that centres itself in _ready) is parked again.
##
## What the engine and the OS allow, measured on Windows 11 with 4.6.2 (tests/live-quiet.ps1 repeats the window checks on 4.4.1 and 4.7):
##  * a position given on the command line is clamped so a strip of the window stays on a screen, but
##    DisplayServer.window_set_position is not, so the window can really be taken off-screen;
##  * a new window takes the foreground when the OS lets it (always once the person has been idle past the
##    foreground-lock timeout, 200 s by default), and the no-focus flag set afterwards does not give it back. So
##    after parking, the window is minimized and restored: minimizing the active window makes Windows activate the
##    one behind it, and restoring a no-focus window does not take the activation back (the foreground returned
##    to the person's window about 0.2 s after the game started, in every measured run);
##  * the first moments of a launch, until this runs, are still on screen and may hold the keyboard: a project that
##    wants none of that sets display/window/size/no_focus itself.
## A game that pauses itself when its window loses focus will see that loss here: its own logic, not Beckett's.
##
## No editor classes; parse-safe on 4.2+. This ships in both editions (play_scene is a core tool).

const ENV := "BECKETT_QUIET"
const PARK_GAP := 200           # pixels beyond the right edge of the desktop where a quiet window waits
const REPARK_SECS := 15.0       # how long after startup a window that came back is parked again
const CHECK_SECS := 0.5         # how often the mute (and the parking) are looked at

var mode := ""                  # "" = not quiet, else window | embedded | headless
var _since := 0.0
var _next_check := 0.0
var _parked := 0                # times this moved the window off-screen (the first is the startup one)
var _remuted := 0               # times a game's own code unmuted the master bus and this muted it again
var _was_mode := -1             # the window mode the game asked for when it was not a plain window (maximized, fullscreen)
var _handed_back := false       # the minimize + restore that returns the keyboard ran


## The mode a BECKETT_QUIET value asks for: "" (not quiet), "window" or "embedded". "1" and the usual spellings
## of yes mean window.
static func parse_mode(value: String) -> String:
	match value.strip_edges().to_lower():
		"1", "true", "yes", "on", "window":
			return "window"
		"embedded":
			return "embedded"
	return ""


## The rectangles of the screens, as Rect2i.
static func screens() -> Array:
	var out: Array = []
	for i in DisplayServer.get_screen_count():
		out.append(Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)))
	return out


## Where a quiet window waits: just past the right edge of the desktop (the union of the screens), at its top.
## Always off every screen, whatever their arrangement.
static func park_position(screen_rects: Array) -> Vector2i:
	if screen_rects.is_empty():
		return Vector2i(30000, 0)
	var right := -2147483647
	var top := 2147483647
	for r in screen_rects:
		var rect: Rect2i = r
		right = maxi(right, rect.position.x + rect.size.x)
		top = mini(top, rect.position.y)
	return Vector2i(right + PARK_GAP, top)


## Is any part of the window on a screen? (A zero-size rectangle is nowhere.)
static func on_screen(window: Rect2i, screen_rects: Array) -> bool:
	if window.size.x <= 0 or window.size.y <= 0:
		return false
	for r in screen_rects:
		if window.intersects(r as Rect2i):
			return true
	return false


## Is this game running inside the editor's Game view? Engine.is_embedded_in_editor is 4.4+ and is reached by name:
## older engines cannot embed a game at all.
static func embedded() -> bool:
	return Engine.has_method("is_embedded_in_editor") and bool(Engine.call("is_embedded_in_editor"))


## Apply the quiet a BECKETT_QUIET value asks for (nothing when it asks for none). Called first thing in the
## runtime's _ready, so the window is moved before the game loads anything.
func apply(env_value: String) -> void:
	mode = parse_mode(env_value)
	if mode.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		mode = "headless"
	elif embedded():
		mode = "embedded"  # the editor's Game view holds this window, whatever the editor expected: leave it alone
	elif mode == "window":
		_unmaximize()
		_park()
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		_hand_back_foreground()
	_next_check = CHECK_SECS
	_mute()


## Keep it applied: called every frame by the runtime, acts a couple of times a second.
func tick(delta: float) -> void:
	if mode.is_empty():
		return
	_since += delta
	_next_check -= delta
	if _next_check > 0.0:
		return
	_next_check = CHECK_SECS
	if AudioServer.bus_count > 0 and not AudioServer.is_bus_mute(0):
		_remuted += 1
		_mute()
	if mode == "window" and _since <= REPARK_SECS:
		_park()


## What is in force, for the editor's get_play_state / wait_until: {ok, requested, mode, muted, window{...}}.
func report() -> Dictionary:
	if mode.is_empty():
		return {"ok": true, "requested": false}
	var out := {"ok": true, "requested": true, "mode": mode, "muted": AudioServer.bus_count > 0 and AudioServer.is_bus_mute(0)}
	if _remuted > 0:
		out["remuted"] = _remuted  # the game keeps unmuting itself
	if mode == "window":
		var pos := DisplayServer.window_get_position()
		var size := DisplayServer.window_get_size()
		out["window"] = {
			"position": [pos.x, pos.y], "size": [size.x, size.y],
			"on_screen": on_screen(Rect2i(pos, size), screens()),
			"no_focus": DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS),
			"parked": _parked,
			"handed_back_focus": _handed_back,
			"can_draw": DisplayServer.window_can_draw(),
			"frames_drawn": Engine.get_frames_drawn(),
		}
		if _was_mode != -1:
			(out["window"] as Dictionary)["was_mode"] = _was_mode  # DisplayServer.WindowMode: 1 minimized, 2 maximized, 3 fullscreen, 4 exclusive fullscreen
	elif mode == "embedded":
		out["window"] = {"embedded": true, "moved": false}
	elif mode == "headless":
		out["window"] = {"headless": true}
	return out


## Mute the master bus (bus 0 always exists in a game with audio; a game on a dummy audio driver has it too).
func _mute() -> void:
	if AudioServer.bus_count > 0:
		AudioServer.set_bus_mute(0, true)


## A maximized or fullscreen window is bound to its screen and cannot be parked off it, and a minimized one does not
## draw: make it a normal window first (the report says so). The game's own layout may differ from a fullscreen run;
## covering the person's screen, or a frame that is never drawn, is worse.
func _unmaximize() -> void:
	var m := DisplayServer.window_get_mode()
	if m != DisplayServer.WINDOW_MODE_WINDOWED:
		_was_mode = m
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


## Give the keyboard back to the window behind this one (see the header: minimize, then restore a no-focus window).
func _hand_back_foreground() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_handed_back = true


## Move the window off every screen when any part of it is on one.
func _park() -> void:
	var rects := screens()
	var win := Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size())
	if on_screen(win, rects):
		DisplayServer.window_set_position(park_position(rects))
		_parked += 1
