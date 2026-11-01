extends RefCounted
## UI inspection for the runtime channel (v1.10 UI-playtest pillar). Two jobs:
##  1. `ui_snapshot` - ONE call returns the visible UI as a structured accessibility
##     tree (path/class/text/rect + semantic state: disabled/focused/checked/value/
##     selected/editable), so the agent reads a screen without a screenshot round-trip
##     and asserts on exact values instead of pixels. A stable content hash makes
##     re-reads cheap (`since_hash` -> `unchanged`).
##  2. The shared HIT TEST behind click_control's occlusion precheck: `pick_at` answers
##     "which control actually receives a click at this point?" (reverse paint order
##     across CanvasLayers, clip_contents, mouse_filter, embedded/exclusive Windows),
##     and `click_reaches` answers "does that receiver drive the target?" - so a click
##     on a covered/modal-blocked control is REFUSED with the blocker's path instead of
##     silently activating the wrong control.
## Since 1.17 both work in GUI space and follow a click through SubViewportContainers and
## embedded windows (route, hit_along): see "coordinate spaces" below.
##
## Static and stateless (one cached engine probe aside): mcp_runtime resolves targets and
## delegates here (B7 rule - transport/dispatch stay in mcp_runtime, feature logic lives in
## its own module).
## 4.2+ floor: only 4.0-era APIs (get_global_transform_with_canvas, Viewport.get_final_transform,
## Window.is_embedded, Node.get_children(include_internal), mouse_filter, clip_contents, gui_get_focus_owner,
## Window.position/size/exclusive, String.md5_text), plus one 4.5+ method,
## Control.get_mouse_filter_with_override, found through ClassDB and reached with call().
## What only the Full edition's drive tools need (the push point of a click, the focused-window rule for a press,
## GUI space -> window pixels for injected input) is in runtime/drive_aim.gd, which pack.ps1 trims from Lite.

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # the two flags below can arrive as text
const TEXT_CAP := 160  # per-node text cap - dialogue Labels can be huge
# 150 entries comfortably fits any menu screen while keeping a world-HUD sweep from
# ballooning the payload (a real RPG's full Control set measured ~14k tokens at 400) -
# the truncation hint teaches scoping instead.
const DEFAULT_MAX_NODES := 150
# Each occlusion check is a full-tree hit test; cap them so a control-heavy world
# screen stays sub-second (the flag says the tail was skipped, never guessed).
const OCCLUSION_BUDGET := 60


## ---- ui_snapshot ------------------------------------------------------------

## Build the snapshot. `scope` = subtree to walk (callers default it to the SceneTree
## root so autoload HUD layers and popup Windows outside the current scene are seen).
## msg options: interactive_only (default false), occlusion (default true),
## max_nodes (default 400), since_hash (skip payload when nothing changed).
static func snapshot(vp: Viewport, tree_root: Node, scene_root: Node, scope: Node, msg: Dictionary) -> Dictionary:
	var ctx := {
		"vp": vp,
		"tree_root": tree_root,
		"scene_root": scene_root,
		"interactive_only": CallArgs.flag(msg, "interactive_only"),
		"occlusion": CallArgs.flag(msg, "occlusion", true),
		"max": maxi(1, int(msg.get("max_nodes", DEFAULT_MAX_NODES))),
		"controls": [],
		"windows": [],
		"truncated": false,
		"occl_left": OCCLUSION_BUDGET,
		"occl_capped": false,
		"routes": {},  # one route() per viewport for the whole snapshot
	}
	_snap_walk(scope, ctx)
	var focus := ""
	var fo := vp.gui_get_focus_owner()
	if fo != null:
		focus = path_of(fo, scene_root)
	var vr := vp.get_visible_rect()
	var payload := {
		"scene": str(scene_root.name) if scene_root != null else "",
		"viewport": [int(vr.size.x), int(vr.size.y)],
		"focus": focus,
		"controls": ctx["controls"],
		"windows": ctx["windows"],
	}
	# Hash BEFORE the envelope so identical UI state -> identical hash across calls.
	var h := JSON.stringify(payload).md5_text()
	if str(msg.get("since_hash", "")) == h:
		return {"ok": true, "unchanged": true, "hash": h,
			"control_count": (ctx["controls"] as Array).size()}
	var out := {"ok": true, "hash": h, "control_count": (ctx["controls"] as Array).size()}
	out.merge(payload)
	if bool(ctx["truncated"]):
		out["truncated"] = true
		out["hint"] = "output capped - narrow with path=, interactive_only=true, or raise max_nodes="
	if bool(ctx["occl_capped"]):
		out["occlusion_capped"] = true
	return out


static func _snap_walk(n: Node, ctx: Dictionary) -> void:
	if (ctx["controls"] as Array).size() >= int(ctx["max"]):
		ctx["truncated"] = true
		return
	# Invisible canvas subtree: nothing below can be visible - prune.
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Window and n != ctx["tree_root"]:
		var w := n as Window
		if not w.visible:
			return
		(ctx["windows"] as Array).append(_window_entry(w, ctx["scene_root"]))
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and (not bool(ctx["interactive_only"]) or _is_interactive(c)):
			(ctx["controls"] as Array).append(_entry(c, ctx))
	for child in n.get_children():
		_snap_walk(child, ctx)


## An embedded window's rect is its position and size in the GUI space of the viewport it is
## embedded in (the root's, where the controls' rects are). A native window's position is on the
## screen instead, so it says native.
static func _window_entry(w: Window, scene_root: Node) -> Dictionary:
	var d := {"path": path_of(w, scene_root), "class": w.get_class(),
		"rect": [w.position.x, w.position.y, w.size.x, w.size.y]}
	if w.title != "":
		d["title"] = w.title
	if w.exclusive:
		d["exclusive"] = true
	if not w.is_embedded():
		d["native"] = true
	return d


## One control -> one compact entry. Keys are OMITTED at their defaults so a real
## menu stays in the hundreds of tokens, not thousands.
static func _entry(c: Control, ctx: Dictionary) -> Dictionary:
	var scene_root: Node = ctx["scene_root"]
	var d := {"path": path_of(c, scene_root), "class": c.get_class()}
	var gn := _script_name(c)
	if gn != "":
		d["script"] = gn
	# Where the control is drawn, in the root's GUI space: the space click_control, drag and scroll
	# take (get_global_rect left out the CanvasLayer and the Camera2D, and stopped at a SubViewport).
	var rt := _route_cached(ctx["routes"], c.get_viewport(), scene_root)
	var r: Rect2 = ((rt["xf"] as Transform2D) * c.get_global_transform_with_canvas()) * Rect2(Vector2.ZERO, c.size)
	d["rect"] = [roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]
	if rt["vp"] != ctx["tree_root"]:
		d["space"] = path_of(rt["vp"], scene_root)  # a SubViewport no container shows, or a native window: its own pixels
	var t := _text_of(c)
	if t != "":
		if t.length() > TEXT_CAP:
			d["text"] = t.substr(0, TEXT_CAP)
			d["text_truncated"] = true
		else:
			d["text"] = t
	if is_disabled(c):
		d["disabled"] = true
	if c.has_focus():
		d["focused"] = true
	if mouse_filter_of(c) == Control.MOUSE_FILTER_IGNORE:  # the filter the hit test acts on (4.5+ inherits it)
		d["mouse_ignore"] = true
	if c.tooltip_text != "":
		d["tooltip"] = c.tooltip_text
	if c is BaseButton:
		var b := c as BaseButton
		if b.toggle_mode:
			d["checked"] = b.button_pressed
	if c is Range:
		var rg := c as Range
		d["value"] = snappedf(rg.value, 0.001)
		d["range"] = [snappedf(rg.min_value, 0.001), snappedf(rg.max_value, 0.001)]
	if c is OptionButton:
		var ob := c as OptionButton
		d["selected"] = ob.selected
		if ob.selected >= 0:
			d["selected_text"] = ob.get_item_text(ob.selected)
		d["item_count"] = ob.item_count
	if c is ItemList:
		var il := c as ItemList
		d["selected"] = Array(il.get_selected_items())
		d["item_count"] = il.item_count
	if c is TabBar:
		var tb := c as TabBar
		d["selected"] = tb.current_tab
		d["tabs"] = _tab_titles(tb.tab_count, func(i: int) -> String: return tb.get_tab_title(i))
	if c is TabContainer:
		var tc := c as TabContainer
		d["selected"] = tc.current_tab
		d["tabs"] = _tab_titles(tc.get_tab_count(), func(i: int) -> String: return tc.get_tab_title(i))
	if c is LineEdit:
		var le := c as LineEdit
		if not le.editable:
			d["editable"] = false
		if le.text == "" and le.placeholder_text != "":
			d["placeholder"] = le.placeholder_text
		if le.secret:
			d["secret"] = true
	if c is TextEdit and not (c as TextEdit).editable:
		d["editable"] = false
	# Would a click at the center actually land? Cheap honesty flags: scrolled-out-of-view
	# (clipped) and covered-by-something-else (occluded_by) - computed for interactive
	# controls only; a full menu costs one tree walk per level of the route per interactive node.
	if _is_interactive(c):
		if route_clipped(c, rt):
			d["clipped"] = true
		elif bool(ctx["occlusion"]) and str(rt["why"]).is_empty():
			if int(ctx["occl_left"]) <= 0:
				ctx["occl_capped"] = true
			else:
				ctx["occl_left"] = int(ctx["occl_left"]) - 1
				var blocker: Node = hit_along(c, rt, gui_center(c))["blocker"]
				if blocker != null:
					d["occluded_by"] = path_of(blocker, scene_root)
	return d


static func _tab_titles(count: int, get_title: Callable) -> Array:
	var out: Array = []
	for i in mini(count, 12):
		out.append(str(get_title.call(i)))
	if count > 12:
		out.append("(+%d more)" % (count - 12))
	return out


## Interactive = the classes a player actually operates, plus anything focusable.
static func _is_interactive(c: Control) -> bool:
	return c is BaseButton or c is Range or c is LineEdit or c is TextEdit \
		or c is ItemList or c is Tree or c is TabBar or c is TabContainer \
		or c is GraphEdit or c.focus_mode != Control.FOCUS_NONE


static func is_disabled(n: Node) -> bool:
	return "disabled" in n and bool(n.get("disabled"))


static func _text_of(n: Node) -> String:
	for p in n.get_property_list():
		if str(p.get("name", "")) == "text":
			return str(n.get("text"))
	return ""


## Custom class_name of a node's script (4.3+ API, duck-typed), "" if none.
static func _script_name(n: Node) -> String:
	var s = n.get_script()
	if s == null:
		return ""
	if s.has_method("get_global_name"):
		var g = s.get_global_name()
		if g != null and str(g) != "":
			return str(g)
	return ""


## Path relative to the current scene when the node lives under it (matches every
## other tool's addressing), absolute /root/... otherwise (autoload layers, popups).
static func path_of(n: Node, scene_root: Node) -> String:
	if scene_root != null and (n == scene_root or scene_root.is_ancestor_of(n)):
		return str(scene_root.get_path_to(n))
	return str(n.get_path())


## ---- coordinate spaces (1.17) -----------------------------------------------

## Three spaces, and which numbers live in which:
##   canvas  get_global_rect(): leaves out the CanvasLayer's transform and the viewport's canvas_transform (a Camera2D),
##           and stops at a SubViewport. Nothing here takes a point from it any more: a HUD on a layer scaled by 2 was
##           hit-tested at half its position, where the view under it is (the 4.7.2 field report).
##   GUI     get_global_transform_with_canvas(), per viewport: where Godot's own GUI looks for the control under a click
##           (Viewport::gui_find_control), what push_input(event, true) takes and what Camera3D.unproject_position gives.
##           Every point and rect Beckett takes or reports (ui_snapshot, click_control, get_control_rect's gui_*, drag,
##           scroll, simulate_input, the recorder) is in the ROOT viewport's GUI space.
##   window  get_final_transform() on top of GUI (the content-scale stretch, the KEEP margins, the window's own scale):
##           what Input.parse_input_event takes (drive_aim.gd's gui_to_window) and get_control_rect's screen_rect.
## A capture's pixels are a space of their own (image_xf): the texture has the stretch but not the window's own part.
## route() carries a point up from a control's viewport to the one that takes the push, through each
## SubViewportContainer (sub_hop) and each embedded Window (window_hop): the inverse of how Godot hands a real click
## down, the same in 4.2, 4.4.1, 4.6.2 and 4.7.

const ROUTE_HOPS_MAX := 8

# Godot 4.5 reads a control's EFFECTIVE mouse filter in its own hit test (mouse_behavior_recursive = Disabled on an
# ancestor makes it IGNORE); 4.2 to 4.4 have no such method. Probed once.
static var _filter_probed := false
static var _filter_override := false


## The mouse filter Godot's GUI acts on: get_mouse_filter_with_override() where the engine has it (4.5+), else
## mouse_filter. Both statics are assigned inside the probe: a script that is not @tool may skip its static
## initialisers when an editor script preloads it (input_codec.gd has the story).
static func mouse_filter_of(c: Control) -> int:
	if not _filter_probed:
		_filter_probed = true
		_filter_override = ClassDB.class_has_method("Control", "get_mouse_filter_with_override")
	if _filter_override:
		return int(c.call("get_mouse_filter_with_override"))
	return c.mouse_filter


## A control's center in its own viewport's GUI space.
static func gui_center(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)


## Does gui-space point p fall on c, asked the way Godot's hit test asks it (Control::has_point on the point taken back
## through the control's transform)? A script's own _has_point (a round or shaped button) is asked too, as the engine
## asks it. A transform with no area (a pop-in tween at scale 0) holds no point: the engine skips such a node, and
## inverting it would fail.
static func gui_has_point(c: Control, p: Vector2) -> bool:
	var xf := c.get_global_transform_with_canvas()
	if is_zero_approx(xf.determinant()):
		return false
	var local: Vector2 = xf.affine_inverse() * p
	if c.get_script() != null and c.has_method("_has_point"):
		return bool(c.call("_has_point", local))
	return Rect2(Vector2.ZERO, c.size).has_point(local)


## One SubViewportContainer level, from the SubViewport's GUI space to the container's viewport's:
## container_xf (its get_global_transform_with_canvas) * scale(stretch_shrink when stretch is on) * the SubViewport's
## final transform. SubViewportContainer.gui_input takes the container-local point, divides it by the shrink (only when
## stretch is on and shrink > 1, so k = shrink is exact either way) and SubViewport.push_input applies the inverse
## final transform: this is that, inverted.
static func sub_hop(container_xf: Transform2D, sub_final: Transform2D, stretch: bool, shrink: int) -> Transform2D:
	var k := float(maxi(1, shrink)) if stretch else 1.0
	return container_xf * Transform2D.IDENTITY.scaled(Vector2(k, k)) * sub_final


## One embedded Window level, from the window's GUI space to its embedder's: the window's position plus its final
## transform. Viewport._sub_windows_forward_input moves the event by -position and Window._window_input pushes it with
## the inverse final transform: this is that, inverted.
static func window_hop(win_pos: Vector2i, win_final: Transform2D) -> Transform2D:
	return Transform2D(0.0, Vector2(win_pos)) * win_final


## The viewport a Window is embedded in, found the way Window::get_embedder finds it (not bound to scripts): the nearest
## viewport above it with gui_embed_subwindows on, or null.
static func embedder_of(w: Window) -> Viewport:
	var par := w.get_parent()
	var vp: Viewport = par.get_viewport() if par != null else null
	while vp != null and not vp.gui_embed_subwindows:
		var up := vp.get_parent()
		vp = up.get_viewport() if up != null else null
	return vp


## How a point in `vp`'s GUI space gets to the viewport that takes the push, the way Godot hands a real click down:
##   {vp: the viewport to push into, xf: vp's GUI space -> that viewport's, hops, direct, why, block}
## Each hop is {vp: the level it leaves, via: the SubViewportContainer or embedded Window that leads there, to: the next
## viewport up, xf_in: vp's GUI space -> the level's, xf: vp's GUI space -> to's}. The walk stops at a native window
## (the root included), at `stop`, or at a SubViewport no container shows: direct is true there, since no click from
## the screen reaches it (a GUI on a 3D panel, a render target), so a push goes straight into it.
## why says why a click from the screen would NOT get through, and block its kind: hidden (a container or window that
## is not visible; it outranks the others), ignore (a container whose mouse filter is IGNORE never forwards a click),
## no_input (gui_disable_input) or deep (more than ROUTE_HOPS_MAX levels). The walk goes on after a why, so xf always
## says where the point is drawn.
static func route(vp: Viewport, scene_root: Node = null, stop: Viewport = null) -> Dictionary:
	var xf := Transform2D.IDENTITY
	var hops: Array = []
	var why := ""
	var block := ""
	var direct := false
	var cur := vp
	while cur != null and cur != stop:
		var w := cur as Window
		var emb: Viewport = null
		var c: SubViewportContainer = null
		if w != null:
			emb = embedder_of(w) if w.is_embedded() else null
			if emb == null:
				break  # a native window (the root, embed_subwindows off, force_native): pushes land here
		elif cur is SubViewport:
			c = cur.get_parent() as SubViewportContainer
			if c == null:
				direct = true
				break
		else:
			break
		if hops.size() == ROUTE_HOPS_MAX:
			if block != "hidden":
				why = "viewports nested deeper than %d" % ROUTE_HOPS_MAX
				block = "deep"
			break
		if w != null:
			if not w.visible and block != "hidden":
				why = "%s is hidden" % path_of(w, scene_root)
				block = "hidden"
			elif w.gui_disable_input and why.is_empty():
				why = "%s has gui_disable_input on, so it receives no click" % path_of(w, scene_root)
				block = "no_input"
			var hw := window_hop(w.position, w.get_final_transform())
			hops.append({"vp": w, "via": w, "to": emb, "xf_in": xf, "xf": hw * xf})
			xf = hw * xf
			cur = emb
		else:
			if not c.is_visible_in_tree() and block != "hidden":
				why = "%s is hidden" % path_of(c, scene_root)
				block = "hidden"
			elif why.is_empty() and mouse_filter_of(c) == Control.MOUSE_FILTER_IGNORE:
				why = "%s has mouse_filter IGNORE, so Godot never forwards a click into %s" % [path_of(c, scene_root), path_of(cur, scene_root)]
				block = "ignore"
			elif why.is_empty() and cur.gui_disable_input:
				why = "%s has gui_disable_input on, so %s forwards nothing to it" % [path_of(cur, scene_root), path_of(c, scene_root)]
				block = "no_input"
			var hs := sub_hop(c.get_global_transform_with_canvas(), cur.get_final_transform(), c.stretch, c.stretch_shrink)
			hops.append({"vp": cur, "via": c, "to": c.get_viewport(), "xf_in": xf, "xf": hs * xf})
			xf = hs * xf
			cur = c.get_viewport()
	return {"vp": cur, "xf": xf, "hops": hops, "direct": direct, "why": why, "block": block}


static func _route_cached(cache: Dictionary, vp: Viewport, scene_root: Node, stop: Viewport = null) -> Dictionary:
	var key := vp.get_instance_id()
	if not cache.has(key):
		cache[key] = route(vp, scene_root, stop)
	return cache[key]


## The hop whose level does not show gui-space point p (p in the GUI space of the route's first viewport), or null when
## every level does: the point is outside a SubViewportContainer's rect or clipped away around it, or outside an
## embedded window or the viewport that holds it. The one-pixel-bigger pixel-art layout lands here: the outer ring of
## SubViewport pixels maps outside the window.
static func hop_clipping(p: Vector2, rt: Dictionary) -> Node:
	for h in rt.get("hops", []):
		var hop: Dictionary = h
		var up: Vector2 = (hop["xf"] as Transform2D) * p
		var via: Node = hop["via"]
		if via is Control:
			var cont := via as Control
			if not gui_has_point(cont, up) or point_clipped(cont, up, cont.get_viewport()):
				return via
		elif via is Window:
			var w := via as Window
			if not Rect2(Vector2(w.position), Vector2(w.size)).has_point(up) or not (hop["to"] as Viewport).get_visible_rect().has_point(up):
				return via
	return null


static func hops_clipped(p: Vector2, rt: Dictionary) -> bool:
	return hop_clipping(p, rt) != null


## Is the control's center out of reach for a click: outside its own viewport, clipped by an ancestor there, or not
## shown by a level above? rt is the control's own route.
static func route_clipped(c: Control, rt: Dictionary) -> bool:
	var p := gui_center(c)
	return point_clipped(c, p, c.get_viewport()) or hops_clipped(p, rt)


## ---- hit test (shared with click_control) -----------------------------------

## True if gui-space point p on ctrl is outside the viewport or clipped away by a
## clip_contents ancestor (ScrollContainer and friends) - a click there can't reach it.
## p and vp are ctrl's own viewport's: the walk stops at the first Viewport, and a level
## above it is hop_clipping's.
static func point_clipped(ctrl: Control, p: Vector2, vp: Viewport) -> bool:
	if not vp.get_visible_rect().has_point(p):
		return true
	var a := ctrl.get_parent()
	while a != null and not (a is Viewport):
		if a is Control and (a as Control).clip_contents and not gui_has_point(a as Control, p):
			return true
		a = a.get_parent()
	return false


## The node that would RECEIVE a click at gui-space p: the top-most visible Control
## whose mouse_filter is not IGNORE, honoring reverse paint order (later siblings and
## higher CanvasLayers on top), clip_contents, and rotated/scaled controls (inverse-
## transform point test). Embedded Windows sit above the canvas: a click inside one
## resolves within it (or returns the Window itself); a visible EXCLUSIVE window
## blocks every click outside itself (the modal case). Returns null when nothing
## interactive is at the point. `tree_root` is the viewport picked in (vp itself).
static func pick_at(_vp: Viewport, tree_root: Node, p: Vector2) -> Node:
	var wins := collect_windows(tree_root)
	for i in range(wins.size() - 1, -1, -1):  # later window = on top (approximation)
		var w: Window = wins[i]
		var wr := Rect2(Vector2(w.position), Vector2(w.size))
		if wr.has_point(p):
			var inner := _pick_canvas(w, w.get_final_transform().affine_inverse() * (p - Vector2(w.position)))
			return inner if inner != null else w
		if window_frame(w).has_point(p):
			return w  # its title bar or resize border: a press there drags or resizes the window
		if w.exclusive:
			return w  # modal: clicks outside it never reach the UI below
	return _pick_canvas(tree_root, p)


## An embedded window's outer frame in its embedder's GUI space: its rect, plus the title bar above it and, when it can be
## resized, the resize margin around it, unless it is borderless. A left press on the frame drags or resizes the window
## (Viewport._sub_windows_forward_input), so nothing under it gets that press.
static func window_frame(w: Window) -> Rect2:
	var r := Rect2(Vector2(w.position), Vector2(w.size))
	if w.borderless:
		return r
	r = r.grow_individual(0.0, float(w.get_theme_constant("title_height")), 0.0, 0.0)
	if not w.unresizable:
		r = r.grow(float(w.get_theme_constant("resize_margin")))
	return r


## The visible windows embedded in `scope` itself, nested ones included (an open dropdown or submenu is a window of its
## own), in tree order. Internal children are walked too: an OptionButton's or a MenuButton's open dropdown is an
## INTERNAL PopupMenu, which get_children() leaves out. A native window's position is on the screen, not in scope's GUI
## space, so it is no part of this list.
static func collect_windows(scope: Node) -> Array:
	var out: Array = []
	_collect_windows(scope, scope, out)
	return out


static func _collect_windows(n: Node, scope: Node, out: Array) -> void:
	for c in n.get_children(true):
		if c is Window:
			var w := c as Window
			if w.visible and w.is_embedded() and embedder_of(w) == scope:
				out.append(w)
		_collect_windows(c, scope, out)


## Pick within one canvas scope: every CanvasLayer under `scope` is its own context
## stacked by its `layer` index (ties: later in tree on top); items outside any layer
## form the default layer-0 context. Contexts are tested top-down, all with the same
## gui-space point: gui_has_point carries each control's own canvas transform (a layer's
## final transform with follow_viewport, a Camera2D's on layer 0).
static func _pick_canvas(scope: Node, p: Vector2) -> Control:
	var contexts: Array = [[0, -1, scope]]
	var layers: Array = []
	_collect_layers(scope, layers)
	for i in layers.size():
		var cl: CanvasLayer = layers[i]
		contexts.append([cl.layer, i, cl])
	contexts.sort_custom(func(a, b):
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	for i in range(contexts.size() - 1, -1, -1):
		var hit := _pick_walk((contexts[i] as Array)[2], p, true)
		if hit != null:
			return hit
	return null


static func _collect_layers(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Viewport:
			continue  # a SubViewport or a window is a pick scope of its own, its CanvasLayers included
		if c is CanvasLayer and (c as CanvasLayer).visible:
			out.append(c)
		_collect_layers(c, out)


static func _pick_walk(n: Node, p: Vector2, is_ctx_root: bool) -> Control:
	if not is_ctx_root:
		if n is Viewport or n is CanvasLayer:
			return null  # separate scopes and contexts: the root's GUI sees a SubViewport's container, not its insides
		if n is CanvasItem:
			var ci := n as CanvasItem
			if not ci.visible:
				return null
			if is_zero_approx(ci.get_global_transform_with_canvas().determinant()):
				return null  # no area: Godot's own pick skips the whole subtree
		if n is Control:
			var c := n as Control
			if c.clip_contents and not gui_has_point(c, p):
				return null  # children are clipped to this rect too
	var kids := n.get_children()
	for i in range(kids.size() - 1, -1, -1):  # later sibling paints (and picks) first
		var hit := _pick_walk(kids[i], p, false)
		if hit != null:
			return hit
	if not is_ctx_root and n is Control:
		var c2 := n as Control
		if mouse_filter_of(c2) != Control.MOUSE_FILTER_IGNORE and gui_has_point(c2, p):
			return c2
	return null


## Would a click delivered to `receiver` end up driving `target`? Walked the way
## Viewport._gui_call_input hands a pointer event to the receiver's parents:
##  - receiver IS the target;
##  - the target is up the receiver's chain of CanvasItem parents, and nothing on the
##    way ends it: a control with mouse_filter STOP takes the event, a top_level item
##    has no parent item, a plain Node breaks the chain. IGNORE controls and Node2Ds
##    pass it on. The target itself must not be IGNORE (it would never get it);
##  - receiver is a SubViewportContainer ancestor of the target (it forwards
##    events into the SubViewport hosting the target - forwarded picking is
##    the sub-viewport's business, so give it the benefit of the doubt).
static func click_reaches(receiver: Node, target: Control) -> bool:
	if receiver == target:
		return true
	if receiver is CanvasItem and target.is_ancestor_of(receiver):
		var ci: CanvasItem = receiver
		while ci != target:
			if ci is Control and mouse_filter_of(ci as Control) == Control.MOUSE_FILTER_STOP:
				return false
			if ci.top_level:
				return false
			var up := ci.get_parent()
			if not (up is CanvasItem):
				return false
			ci = up as CanvasItem
		return mouse_filter_of(target) != Control.MOUSE_FILTER_IGNORE
	if receiver is SubViewportContainer and receiver.is_ancestor_of(target):
		return true
	return false


## A click's way down a route, the way Godot hands it on: at each level, the control the press lands on must deliver it
## to the container that leads one level in, or that control takes the click. p is in the GUI space of the route's first
## viewport (where `target` lives). Returns {receiver: what the innermost level reached hands the press to, blocker: what
## takes it instead of the next level or of `target` (null when nothing does), level: the hop index whose container the
## blocker kept the click from (-1: the target's own level), skipped: a level was not judged}.
## Whether a control reaches an embedded WINDOW is not judged (pick_at only approximates window stacking, so no refusal
## rests on it, the pre-1.17 rule): the walk goes on inside the window. A level whose pick finds nothing ends the walk
## with no blocker: never block on a guess.
static func hit_along(target: Control, rt: Dictionary, p: Vector2) -> Dictionary:
	var hops: Array = rt.get("hops", [])
	var out := {"receiver": null, "blocker": null, "level": -1, "skipped": false}
	var receiver: Node = null
	var k := hops.size() - 1
	if k >= 0 and (hops[k] as Dictionary)["via"] is Window:
		out["skipped"] = true
	else:
		receiver = pick_at(rt["vp"], rt["vp"], (rt["xf"] as Transform2D) * p)
	while k >= 0:
		var hop: Dictionary = hops[k]
		if hop["via"] is Window:
			out["skipped"] = true
		else:
			if receiver == null:
				return out
			if not click_reaches(receiver, hop["via"]):
				out["receiver"] = receiver
				out["blocker"] = receiver
				out["level"] = k
				return out
		receiver = _pick_canvas(hop["vp"], (hop["xf_in"] as Transform2D) * p)
		k -= 1
	out["receiver"] = receiver
	if target != null and receiver != null and receiver != target and not click_reaches(receiver, target):
		out["blocker"] = receiver
	return out


## ---- Set-of-Mark annotation (screenshot annotate=ui, P1) ----------------------

const MARK_COLOR := Color(1.0, 0.0, 1.0)  # magenta reads on most game art
const TAG_FG := Color(1.0, 1.0, 1.0)
# 3x5 digit bitmaps (rows top->bottom, 3 bits left->right) - lets the annotator stamp
# mark numbers straight onto the captured Image with zero font dependencies.
const _DIGITS := {
	"0": [0b111, 0b101, 0b101, 0b101, 0b111],
	"1": [0b010, 0b110, 0b010, 0b010, 0b111],
	"2": [0b111, 0b001, 0b111, 0b100, 0b111],
	"3": [0b111, 0b001, 0b111, 0b001, 0b111],
	"4": [0b101, 0b101, 0b111, 0b001, 0b001],
	"5": [0b111, 0b100, 0b111, 0b001, 0b111],
	"6": [0b111, 0b100, 0b111, 0b101, 0b111],
	"7": [0b111, 0b001, 0b010, 0b010, 0b010],
	"8": [0b111, 0b101, 0b111, 0b101, 0b111],
	"9": [0b111, 0b101, 0b111, 0b001, 0b111],
}


## Numbered marks for every visible, unclipped interactive control that a click on vp
## reaches, in document order. rect is in the pixels of vp's own captured image
## (image_xf), so the boxes land on the picture under any content scale, KEEP margin or
## viewport-mode stretch, and a control inside a SubViewport or a dialog is boxed where it
## appears. vp is where the routes stop: the window for a window capture, a SubViewport
## for a capture of that SubViewport.
static func marks(vp: Viewport, tree_root: Node, scene_root: Node, max_marks: int = 40) -> Array:
	var out: Array = []
	_marks_walk(tree_root, vp, tree_root, scene_root, out, maxi(1, max_marks), {}, image_xf(vp))
	return out


static func _marks_walk(n: Node, vp: Viewport, tree_root: Node, scene_root: Node, out: Array, cap: int, routes: Dictionary, img_xf: Transform2D) -> void:
	if out.size() >= cap:
		return
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Window and n != tree_root and not (n as Window).visible:
		return
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and _is_interactive(c):
			var rt := _route_cached(routes, c.get_viewport(), scene_root, vp)
			# Only what a click on this picture reaches: not a SubViewport no container shows, not a
			# native window, not behind a hidden or IGNORE container, not clipped at any level.
			if rt["vp"] == vp and not bool(rt["direct"]) and str(rt["why"]).is_empty() and not route_clipped(c, rt):
				var sr: Rect2 = (img_xf * (rt["xf"] as Transform2D) * c.get_global_transform_with_canvas()) * Rect2(Vector2.ZERO, c.size)
				if sr.size.x >= 2.0 and sr.size.y >= 2.0:
					var m := {"i": out.size() + 1, "path": path_of(c, scene_root),
						"rect": [roundi(sr.position.x), roundi(sr.position.y), roundi(sr.size.x), roundi(sr.size.y)]}
					var t := _text_of(c)
					if t != "":
						m["text"] = t.substr(0, 40)
					out.append(m)
	for child in n.get_children():
		_marks_walk(child, vp, tree_root, scene_root, out, cap, routes, img_xf)


## vp's GUI space -> the pixels of vp's own captured image (get_texture().get_image()).
## The texture holds the content-scale stretch and global_canvas_transform but not the
## window's own transform: the KEEP margins, and in viewport mode the whole scale-up. So a
## window keeps get_final_transform()'s scale without its margin, and a window in
## content_scale_mode viewport renders at its design size, where the image IS the GUI
## space. Measured against real captures on 4.4.1, 4.6.2 and 4.7 (1000x500 window, 576x324
## design): canvas_items KEEP gives an 888x500 image at x1.5417 with no margin offset,
## viewport KEEP a 576x324 image at x1. get_texture().get_size() cannot stand in for the
## image size: for a stretched window it reports the size times the stretch (1369x772 for
## that 888x500 capture).
static func image_xf(vp: Viewport) -> Transform2D:
	var g := vp.global_canvas_transform
	if vp is Window:
		var w := vp as Window
		if w.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT and w.content_scale_size.x > 0 and w.content_scale_size.y > 0:
			return g
		var fin := vp.get_final_transform()
		var stretch: Transform2D = Transform2D(fin.x, fin.y, Vector2.ZERO) * Transform2D(g.x, g.y, Vector2.ZERO).affine_inverse()
		return Transform2D(fin.x, fin.y, stretch * g.origin)
	return vp.get_final_transform()


## A control's rect in WINDOW pixels (the content-scale stretch and the window's own
## transform applied): what Input.parse_input_event and OS-level input aim at, and
## get_control_rect's screen_rect. The route stops at vp; rt is the control's route when
## the caller has it (the two-argument call keeps working).
static func screen_rect_of(c: Control, vp: Viewport, rt: Dictionary = {}) -> Rect2:
	var r := rt if not rt.is_empty() else route(c.get_viewport(), null, vp)
	var land: Viewport = r["vp"]
	return (land.get_final_transform() * (r["xf"] as Transform2D) * c.get_global_transform_with_canvas()) * Rect2(Vector2.ZERO, c.size)


## Draw the numbered boxes onto a CAPTURED image (never touches the scene). The caller
## already cropped/scaled the image, so each mark rect maps as (xy - offset) * scale.
static func annotate_image(img: Image, marks_list: Array, offset: Vector2, scale: float) -> void:
	var lw := maxi(1, roundi(2.0 * scale))
	for m in marks_list:
		var r4: Array = (m as Dictionary).get("rect", [])
		if r4.size() < 4:
			continue
		var pos := (Vector2(float(r4[0]), float(r4[1])) - offset) * scale
		var size := Vector2(float(r4[2]), float(r4[3])) * scale
		var rr := Rect2i(roundi(pos.x), roundi(pos.y), maxi(1, roundi(size.x)), maxi(1, roundi(size.y)))
		if rr.position.x >= img.get_width() or rr.position.y >= img.get_height() \
				or rr.end.x <= 0 or rr.end.y <= 0:
			continue  # cropped/scaled out of the picture
		_outline(img, rr, lw)
		_tag(img, rr.position + Vector2i(lw, lw), str((m as Dictionary).get("i", 0)))


static func _outline(img: Image, r: Rect2i, w: int) -> void:
	img.fill_rect(Rect2i(r.position, Vector2i(r.size.x, w)), MARK_COLOR)                                # top
	img.fill_rect(Rect2i(Vector2i(r.position.x, r.end.y - w), Vector2i(r.size.x, w)), MARK_COLOR)      # bottom
	img.fill_rect(Rect2i(r.position, Vector2i(w, r.size.y)), MARK_COLOR)                                # left
	img.fill_rect(Rect2i(Vector2i(r.end.x - w, r.position.y), Vector2i(w, r.size.y)), MARK_COLOR)      # right


## A filled number plate at `at`: 2x-scaled 3x5 digits on the mark color.
static func _tag(img: Image, at: Vector2i, s: String) -> void:
	var origin := Vector2i(maxi(0, at.x), maxi(0, at.y))
	var plate := Rect2i(origin, Vector2i(4 + s.length() * 8, 14))
	img.fill_rect(plate, MARK_COLOR)
	for k in s.length():
		_digit(img, origin + Vector2i(3 + k * 8, 2), s[k])


static func _digit(img: Image, at: Vector2i, ch: String) -> void:
	var rows: Array = _DIGITS.get(ch, [])
	for ry in rows.size():
		var bits: int = rows[ry]
		for rx in 3:
			if bits & (1 << (2 - rx)):
				img.fill_rect(Rect2i(at + Vector2i(rx * 2, ry * 2), Vector2i(2, 2)), TAG_FG)


## ---- ui_audit: deterministic layout QA (P1) -----------------------------------

## Structured checks vision does badly and rect math does exactly: interactive
## controls that are offscreen / zero-size / overlapping each other / below a touch
## floor / unreachable without a mouse, plus text that no longer fits its control.
## Read-only; issues capped by max (default 100).
static func audit(vp: Viewport, tree_root: Node, scene_root: Node, scope: Node, msg: Dictionary) -> Dictionary:
	var touch_min := maxf(0.0, float(msg.get("touch_min", 0)))
	var overlap_min := clampf(float(msg.get("overlap_min_ratio", 0.25)), 0.01, 1.0)
	var cap := maxi(1, int(msg.get("max", 100)))
	var interactive: Array = []
	var texty: Array = []
	_audit_collect(scope, tree_root, interactive, texty)
	var issues: Array = []
	var vr := vp.get_visible_rect()
	# Every rect in the root's GUI space, where the controls are drawn (one route per
	# viewport): controls on different CanvasLayers, inside SubViewports and in dialogs line
	# up as on screen. `here` is false for a control a click on vp cannot reach the normal
	# way (a SubViewport no container shows, a native window); it sits out offscreen and
	# overlap, whose rects would be in another space.
	var routes := {}
	var rects: Array = []
	var here: Array = []
	for n in interactive:
		var rc := n as Control
		var rt := _route_cached(routes, rc.get_viewport(), scene_root)
		rects.append(((rt["xf"] as Transform2D) * rc.get_global_transform_with_canvas()) * Rect2(Vector2.ZERO, rc.size))
		here.append(rt["vp"] == vp and not bool(rt["direct"]))
	for ci in interactive.size():
		if issues.size() >= cap:
			break
		var c := interactive[ci] as Control
		var r: Rect2 = rects[ci]
		var p := path_of(c, scene_root)
		if r.size.x < 1.0 or r.size.y < 1.0:
			issues.append({"type": "zero_size", "path": p, "rect": _r4(r),
				"detail": "visible interactive control with a degenerate rect"})
		elif bool(here[ci]) and not vr.intersects(r):
			issues.append({"type": "offscreen", "path": p, "rect": _r4(r),
				"detail": "visible interactive control entirely outside the viewport"})
		if touch_min > 0.0 and (r.size.x < touch_min or r.size.y < touch_min):
			issues.append({"type": "small_target", "path": p, "rect": _r4(r),
				"detail": "interactive target below %d px (touch guideline)" % int(touch_min)})
		if c is BaseButton and c.focus_mode == Control.FOCUS_NONE:
			issues.append({"type": "mouse_only", "path": p,
				"detail": "focus_mode NONE - keyboard/gamepad can never reach it"})
	# Overlapping interactive pairs (same window, neither an ancestor of the other).
	for i in interactive.size():
		if issues.size() >= cap:
			break
		var a := interactive[i] as Control
		var ra: Rect2 = rects[i]
		if ra.size.x < 1.0 or ra.size.y < 1.0 or not bool(here[i]):
			continue
		for j in range(i + 1, interactive.size()):
			if issues.size() >= cap:
				break
			var b := interactive[j] as Control
			if a.is_ancestor_of(b) or b.is_ancestor_of(a) or not bool(here[j]):
				continue
			if _host_window(a, tree_root) != _host_window(b, tree_root):
				continue
			var rb: Rect2 = rects[j]
			if rb.size.x < 1.0 or rb.size.y < 1.0:
				continue
			var inter := ra.intersection(rb)
			if inter.size.x <= 0.0 or inter.size.y <= 0.0:
				continue
			var smaller := minf(ra.get_area(), rb.get_area())
			if smaller <= 0.0:
				continue
			var ratio := inter.get_area() / smaller
			if ratio >= overlap_min:
				issues.append({"type": "overlap", "a": path_of(a, scene_root), "b": path_of(b, scene_root),
					"ratio": snappedf(ratio, 0.01),
					"detail": "interactive controls overlap (%.0f%% of the smaller)" % (ratio * 100.0)})
	# Text wider than its control (measured with the control's own font — minimum-size
	# math can't catch this: the engine clamps size >= min, and trim-ellipsis SHRINKS
	# the min, so trimmed/clipped text hides from both).
	for n2 in texty:
		if issues.size() >= cap:
			break
		var t := n2 as Control
		if t is Label and (t as Label).autowrap_mode != TextServer.AUTOWRAP_OFF:
			continue  # wrapping labels grow down by design
		var txt := _text_of(t)
		if txt == "":
			continue
		var font := t.get_theme_font("font")
		if font == null:
			continue
		var text_w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, t.get_theme_font_size("font_size")).x
		if text_w > t.size.x + 1.0:
			issues.append({"type": "text_overflow", "path": path_of(t, scene_root),
				"need": roundi(text_w), "have": roundi(t.size.x),
				"detail": "text is %d px wide, the control gives it %d (trimmed or clipped)" % [roundi(text_w), roundi(t.size.x)]})
	# Focus graph (v1.11): can a keyboard/gamepad user actually WALK this UI? Build the
	# moves Godot itself offers (Tab / Shift+Tab / the four neighbors) over the visible
	# interactive controls, then BFS from the entry - the current focus owner, else the
	# first focusable in tree order (where the user's first Tab would likely land).
	var focusables: Array = []
	for fn in interactive:
		if (fn as Control).focus_mode != Control.FOCUS_NONE:
			focusables.append(fn)
	var focus_summary := {"focusable": focusables.size(), "entry": "", "reachable": 0}
	if not focusables.is_empty():
		var fowner: Control = vp.gui_get_focus_owner()
		var entry: Control = fowner if fowner != null and focusables.has(fowner) else (focusables[0] as Control)
		focus_summary["entry"] = path_of(entry, scene_root)
		if fowner == null and issues.size() < cap:
			issues.append({"type": "no_initial_focus", "path": str(focus_summary["entry"]),
				"detail": "focusable controls exist but nothing HAS focus - a gamepad/keyboard user cannot start navigating; grab_focus() one control when the menu opens"})
		var reach := {}
		var fqueue: Array = [entry]
		reach[entry.get_instance_id()] = true
		while not fqueue.is_empty():
			var cur: Control = fqueue.pop_front()
			for nb in _focus_edges(cur):
				if nb != null and not reach.has((nb as Control).get_instance_id()):
					reach[(nb as Control).get_instance_id()] = true
					fqueue.append(nb)
		focus_summary["reachable"] = reach.size()
		for fx in focusables:
			if issues.size() >= cap:
				break
			var fxc := fx as Control
			if not reach.has(fxc.get_instance_id()):
				issues.append({"type": "focus_unreachable", "path": path_of(fxc, scene_root),
					"detail": "focusable, but no chain of Tab/arrow moves from '%s' reaches it - unreachable on gamepad/keyboard" % str(focus_summary["entry"])})
		for fy in focusables:
			if issues.size() >= cap:
				break
			var fyc := fy as Control
			var can_leave := false
			for nb2 in _focus_edges(fyc):
				if nb2 != null and nb2 != fyc:
					can_leave = true
					break
			if not can_leave and focusables.size() > 1:
				issues.append({"type": "focus_dead_end", "path": path_of(fyc, scene_root),
					"detail": "focus can enter but never leave (every move stays here) - a gamepad user gets stuck"})
	var counts := {}
	for is_ in issues:
		var k := str((is_ as Dictionary).get("type", ""))
		counts[k] = int(counts.get(k, 0)) + 1
	return {"ok": true, "issues": issues, "counts": counts,
		"checked": {"interactive": interactive.size(), "text_controls": texty.size()},
		"focus": focus_summary,
		"viewport": [int(vr.size.x), int(vr.size.y)],
		"truncated": issues.size() >= cap}


static func _audit_collect(n: Node, tree_root: Node, interactive: Array, texty: Array) -> void:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Window and n != tree_root and not (n as Window).visible:
		return
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree():
			if _is_interactive(c):
				interactive.append(c)
			if (c is Label or c is BaseButton) and _text_of(c) != "":
				texty.append(c)
	for child in n.get_children():
		_audit_collect(child, tree_root, interactive, texty)


static func _host_window(c: Control, tree_root: Node) -> Node:
	var a := c.get_parent()
	while a != null:
		if a is Window and a != tree_root:
			return a
		a = a.get_parent()
	return tree_root


static func _r4(r: Rect2) -> Array:
	return [roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]


## The focus moves Godot itself offers from a control: Tab, Shift+Tab, and the four
## directional neighbors. find_valid_focus_neighbor is newer than the 4.2 floor, so it
## is duck-typed; without it the Tab chain alone still defines reachability.
static func _focus_edges(c: Control) -> Array:
	var out: Array = [c.find_next_valid_focus(), c.find_prev_valid_focus()]
	if c.has_method("find_valid_focus_neighbor"):
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			out.append(c.call("find_valid_focus_neighbor", side))
	return out
