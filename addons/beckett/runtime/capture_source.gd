extends RefCounted
## Which pixels a screenshot reads (1.17): the game window, or one SubViewport's own frame (screenshot viewport=).
##
## A pixel-art game renders its world into a SubViewport at game resolution and shows it enlarged through a stretch
## SubViewportContainer (the pixel-art-3d skill's layout: 288x162 game pixels in a 1152x648 window). A capture of the
## window repeats every game pixel N x N times, 16 times at stretch_shrink 4, so the same picture costs about 16 times
## the image tokens. viewport=<the SubViewport, or the container that shows it> reads that SubViewport's frame instead.
## A frame whose short side is under MIN_EDGE is enlarged in whole nearest steps until it reaches it: no blur and no
## new information, only a picture the model can read (Anthropic's vision guide says images under 200 px may be
## misread). 288x162 comes back as 576x324, a quarter of the window's image tokens.
##
## Nothing switches by itself: a bare screenshot is the window, exactly as before. A window capture of such a layout
## names the viewport= that reads it, once per game process (pixel_layout; mcp_runtime keeps the flag), because a
## SubViewport frame leaves out whatever the window draws outside it (a HUD on a CanvasLayer, a popup), and only the
## caller knows whether that matters.
##
## Static, no class_name, no editor classes, parse-safe on 4.2+: the played game runs it (mcp_runtime.gd preloads it
## by path), and the editor's runtime_observe_tools.gd preloads it for the sizing math both targets share. Ships in
## both editions, like the screenshot tool itself.


## The short side, in px, a game-pixel picture is enlarged to.
const MIN_EDGE := 200
## Whole steps never go past this, so a region of a few game pixels cannot turn into a huge picture.
const MAX_UPSCALE := 8
## The long-edge cap of a screenshot call with no framing argument (runtime_observe_tools.DEFAULT_MAX_DIM; the unit
## suite holds the two equal). An enlargement stays inside it when the call gives no max_dim of its own, and the hint
## quotes the size a bare viewport= capture comes back at under it.
const BARE_MAX_DIM := 1280


## The one resize factor a capture uses: the caller's scale dial, which only ever shrinks (0.05..1), reduced further
## so the long edge of a WxH frame lands inside max_dim (0 or less = no cap). mcp_runtime._capped_scale is this (the
## unit suite pins it there), and target=editor sizes its picture with it too.
static func capped_scale(scale: float, w: int, h: int, max_dim: int) -> float:
	var s := clampf(scale, 0.05, 1.0)
	if max_dim <= 0:
		return s
	var long_edge := maxi(w, h)
	if long_edge <= max_dim:
		return s
	return minf(s, float(max_dim) / float(long_edge))


## The whole-number enlargement of a WxH game-pixel picture: the smallest k that brings its short side to MIN_EDGE,
## at most MAX_UPSCALE, and no more than keeps the long edge inside max_dim, or inside BARE_MAX_DIM when max_dim is 0
## or less (a region, or max_dim=0, lifts the cap on the frame, never on what an enlargement may add: a 288x10 strip
## would otherwise come back 2304x80). 1 for an empty frame.
static func pixel_upscale(w: int, h: int, max_dim: int) -> int:
	if w <= 0 or h <= 0:
		return 1
	var k := clampi(ceili(float(MIN_EDGE) / float(mini(w, h))), 1, MAX_UPSCALE)
	var cap := max_dim if max_dim > 0 else BARE_MAX_DIM
	return mini(k, maxi(1, floori(float(cap) / float(maxi(w, h)))))


## About how many times the image tokens of a pic_w x pic_h picture a bare viewport= capture of a gw x gh SubViewport
## costs less: the picture's area over the game pixels' area as that capture returns them, rounded. 0 when either is
## empty. The window-capture hint is worth its line from 2 up, and both halves judge it here: the game spends its
## once-per-run hint only on a picture the editor will word it for.
static func hint_share(pic_w: int, pic_h: int, gw: int, gh: int) -> int:
	var k := pixel_upscale(gw, gh, BARE_MAX_DIM)
	var area := float(gw * k) * float(gh * k)
	if area <= 0.0 or pic_w <= 0 or pic_h <= 0:
		return 0
	return roundi(float(pic_w) * float(pic_h) / area)


## The SubViewport a viewport= argument names: the node itself, or the first SubViewport child of the
## SubViewportContainer that shows it. null for any other node.
static func subviewport_of(n: Node) -> SubViewport:
	if n is SubViewport:
		return n as SubViewport
	if n is SubViewportContainer:
		for c in n.get_children():
			if c is SubViewport:
				return c as SubViewport
	return null


## How `window` shows `sv`: {rect, factor} when its parent is a visible SubViewportContainer that draws into the
## window, else {}. rect is the container in the window's GUI space, factor the GUI px per SubViewport pixel (measured,
## so a size stretch_shrink does not divide reads as, say, 4.01). GUI space is where every position Beckett takes
## lives (simulate_input, drag, scroll position=, click_control's at, get_control_rect's gui_*): a CanvasLayer's
## transform counts there and the window's content scale does not, so the mapping a capture gives is one a click can use.
static func shown_by(sv: SubViewport, window: Window) -> Dictionary:
	var c := sv.get_parent() as SubViewportContainer
	if c == null or c.get_viewport() != window or not c.is_visible_in_tree():
		return {}
	# With stretch on the container draws the SubViewport over its whole rect; without it, at the SubViewport's size.
	var across: float = float(sv.size.x) if c.stretch else c.size.x
	if across <= 0.0:
		return {}
	var rect := gui_rect_of(c)
	return {"rect": rect, "factor": rect.size.x / across}


## A control's rect in its viewport's GUI space: where Godot draws it and where it takes a click.
static func gui_rect_of(c: Control) -> Rect2:
	return c.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, c.size)


## Why `sv` may hold an old frame, or "": its container is hidden (a hidden SubViewportContainer stops its
## SubViewports from updating), or its update mode is Disabled or Once. The engine renders a SubViewport only when
## its update mode lets it, and a capture reads the last frame it rendered.
static func stale_reason(sv: SubViewport) -> String:
	var c := sv.get_parent() as SubViewportContainer
	if c != null and not c.is_visible_in_tree():
		return "its container is hidden"
	if sv.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		return "update mode Disabled"
	if sv.render_target_update_mode == SubViewport.UPDATE_ONCE:
		return "update mode Once"
	return ""


## The pixel-art layout a capture of `window` can point at: the SubViewport of the largest visible
## SubViewportContainer that draws into the window with stretch on and stretch_shrink 2 or more, covering at least half
## of what the window shows. Both are measured in GUI space (the container's rect, the window's visible rect), so a
## content scale, its KEEP bars or a viewport-mode stretch change nothing. null when there is none. find_children walks
## the tree natively, and owned=false sees the nodes a game builds in code too.
static func pixel_layout(window: Window) -> SubViewport:
	var full := window.get_visible_rect()
	var half := full.get_area() * 0.5
	var best: SubViewport = null
	var best_area := 0.0
	for n in window.find_children("*", "SubViewportContainer", true, false):
		var c := n as SubViewportContainer
		if c == null or not c.stretch or c.stretch_shrink < 2 or c.get_viewport() != window or not c.is_visible_in_tree():
			continue
		var sv := subviewport_of(c)
		if sv == null:
			continue
		var area := gui_rect_of(c).intersection(full).get_area()
		if area >= half and area > best_area:
			best = sv
			best_area = area
	return best


## Where the OS cursor is in a picture of game pixels, or (-1, -1) when there is nothing true to say. A screenshot
## never draws the cursor, but what it hovers (a highlighted button) is in the picture. This reads the engine's facts
## and cursor_point decides; no mouse or a minimized window says nothing (get_mouse_position answers (0, 0) there).
## shown is shown_by(); off is the region origin in game pixels, f the picture's scale per game pixel, size its size.
static func cursor_in_picture(window: Window, shown: Dictionary, off: Vector2, f: float, size: Vector2i) -> Vector2i:
	if shown.is_empty() or not DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE) or window.mode == Window.MODE_MINIMIZED:
		return Vector2i(-1, -1)
	var under := DisplayServer.get_window_at_screen_position(DisplayServer.mouse_get_position())
	return cursor_point(Input.mouse_mode, under, window.get_window_id(), window.get_mouse_position(), shown, off, f, size)


## The decision behind cursor_in_picture, from plain values so the unit suite can pin it: the cursor in a picture of
## game pixels, or (-1, -1). Only a cursor the player sees counts (mode is Input.mouse_mode: VISIBLE or CONFINED; a
## hidden or captured one, which mouse-look parks unseen at the window centre, hovers nothing), and only over the game
## window (under is the id of the window under it, game_id the game's, so another window on top says nothing).
## mouse is the cursor in the window's GUI space (Viewport.get_mouse_position takes the content scale out already),
## the space shown's rect and factor are measured in.
static func cursor_point(mode: int, under: int, game_id: int, mouse: Vector2, shown: Dictionary, off: Vector2, f: float, size: Vector2i) -> Vector2i:
	var none := Vector2i(-1, -1)
	if shown.is_empty() or under != game_id:
		return none
	if mode != Input.MOUSE_MODE_VISIBLE and mode != Input.MOUSE_MODE_CONFINED:
		return none
	var rect: Rect2 = shown["rect"]
	return picture_point((mouse - rect.position) / float(shown["factor"]), off, f, size)


## A point in game pixels as a pixel of the picture: (g - off) * f, or (-1, -1) when that falls outside it.
static func picture_point(g: Vector2, off: Vector2, f: float, size: Vector2i) -> Vector2i:
	var q := ((g - off) * f).floor()
	if q.x < 0.0 or q.y < 0.0 or q.x >= float(size.x) or q.y >= float(size.y):
		return Vector2i(-1, -1)
	return Vector2i(q)
