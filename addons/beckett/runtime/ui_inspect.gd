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
##
## Static and stateless: mcp_runtime resolves targets and delegates here (B7 rule -
## transport/dispatch stay in mcp_runtime, feature logic lives in its own module).
## 4.2+ floor: only 4.0-era APIs (get_global_rect, mouse_filter, clip_contents,
## gui_get_focus_owner, Window.position/size/exclusive, String.md5_text).

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
		"interactive_only": bool(msg.get("interactive_only", false)),
		"occlusion": bool(msg.get("occlusion", true)),
		"max": maxi(1, int(msg.get("max_nodes", DEFAULT_MAX_NODES))),
		"controls": [],
		"windows": [],
		"truncated": false,
		"occl_left": OCCLUSION_BUDGET,
		"occl_capped": false,
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


static func _window_entry(w: Window, scene_root: Node) -> Dictionary:
	var d := {"path": path_of(w, scene_root), "class": w.get_class(),
		"rect": [w.position.x, w.position.y, w.size.x, w.size.y]}
	if w.title != "":
		d["title"] = w.title
	if w.exclusive:
		d["exclusive"] = true
	return d


## One control -> one compact entry. Keys are OMITTED at their defaults so a real
## menu stays in the hundreds of tokens, not thousands.
static func _entry(c: Control, ctx: Dictionary) -> Dictionary:
	var scene_root: Node = ctx["scene_root"]
	var vp: Viewport = ctx["vp"]
	var d := {"path": path_of(c, scene_root), "class": c.get_class()}
	var gn := _script_name(c)
	if gn != "":
		d["script"] = gn
	var r := c.get_global_rect()
	d["rect"] = [roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]
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
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
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
	# controls only; a full menu costs one tree walk per interactive node.
	if _is_interactive(c):
		var center := r.get_center()
		if point_clipped(c, center, vp):
			d["clipped"] = true
		elif bool(ctx["occlusion"]) and not inside_embedded_window(c, ctx["tree_root"]):
			if int(ctx["occl_left"]) <= 0:
				ctx["occl_capped"] = true
			else:
				ctx["occl_left"] = int(ctx["occl_left"]) - 1
				var receiver: Node = pick_at(vp, ctx["tree_root"], center)
				if receiver != null and receiver != c and not click_reaches(receiver, c):
					d["occluded_by"] = path_of(receiver, scene_root)
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


## ---- hit test (shared with click_control) -----------------------------------

## True if gui-space point p on ctrl is outside the viewport or clipped away by a
## clip_contents ancestor (ScrollContainer and friends) - a click there can't reach it.
static func point_clipped(ctrl: Control, p: Vector2, vp: Viewport) -> bool:
	if not vp.get_visible_rect().has_point(p):
		return true
	var a := ctrl.get_parent()
	while a != null:
		if a is Control and (a as Control).clip_contents and not (a as Control).get_global_rect().has_point(p):
			return true
		a = a.get_parent()
	return false


## The node that would RECEIVE a click at gui-space p: the top-most visible Control
## whose mouse_filter is not IGNORE, honoring reverse paint order (later siblings and
## higher CanvasLayers on top), clip_contents, and rotated/scaled controls (inverse-
## transform point test). Embedded Windows sit above the canvas: a click inside one
## resolves within it (or returns the Window itself); a visible EXCLUSIVE window
## blocks every click outside itself (the modal case). Returns null when nothing
## interactive is at the point.
static func pick_at(vp: Viewport, tree_root: Node, p: Vector2) -> Node:
	var wins: Array = []
	_collect_windows(tree_root, wins)
	for i in range(wins.size() - 1, -1, -1):  # later window = on top (approximation)
		var w: Window = wins[i]
		var wr := Rect2(Vector2(w.position), Vector2(w.size))
		if wr.has_point(p):
			var inner := _pick_canvas(w, p - Vector2(w.position))
			return inner if inner != null else w
		if w.exclusive:
			return w  # modal: clicks outside it never reach the UI below
	return _pick_canvas(tree_root, p)


static func _collect_windows(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Window and (c as Window).visible:
			out.append(c)
		_collect_windows(c, out)  # recurse into windows too: an open dropdown/submenu is a nested Window


## Pick within one canvas scope: every CanvasLayer under `scope` is its own context
## stacked by its `layer` index (ties: later in tree on top); items outside any layer
## form the default layer-0 context. Contexts are tested top-down.
static func _pick_canvas(scope: Node, p: Vector2) -> Control:
	var contexts: Array = [[0, -1, scope, Transform2D()]]
	var layers: Array = []
	_collect_layers(scope, layers)
	for i in layers.size():
		var cl: CanvasLayer = layers[i]
		contexts.append([cl.layer, i, cl, cl.transform])
	contexts.sort_custom(func(a, b):
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	for i in range(contexts.size() - 1, -1, -1):
		var ctx: Array = contexts[i]
		var local: Vector2 = (ctx[3] as Transform2D).affine_inverse() * p
		var hit := _pick_walk(ctx[2], local, true)
		if hit != null:
			return hit
	return null


static func _collect_layers(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Window:
			continue  # windows are separate pick scopes
		if c is CanvasLayer and (c as CanvasLayer).visible:
			out.append(c)
		_collect_layers(c, out)


static func _pick_walk(n: Node, p: Vector2, is_ctx_root: bool) -> Control:
	if not is_ctx_root:
		if n is Window or n is CanvasLayer:
			return null  # separate contexts, handled by the callers above
		if n is CanvasItem and not (n as CanvasItem).visible:
			return null
		if n is Control:
			var c := n as Control
			if c.clip_contents and not _has_point(c, p):
				return null  # children are clipped to this rect too
	var kids := n.get_children()
	for i in range(kids.size() - 1, -1, -1):  # later sibling paints (and picks) first
		var hit := _pick_walk(kids[i], p, false)
		if hit != null:
			return hit
	if not is_ctx_root and n is Control:
		var c2 := n as Control
		if c2.mouse_filter != Control.MOUSE_FILTER_IGNORE and _has_point(c2, p):
			return c2
	return null


## Transform-aware point test (handles rotated/scaled controls, unlike a bare
## get_global_rect().has_point which is axis-aligned).
static func _has_point(c: Control, p: Vector2) -> bool:
	var local: Vector2 = c.get_global_transform().affine_inverse() * p
	return Rect2(Vector2.ZERO, c.size).has_point(local)


## Would a click delivered to `receiver` end up driving `target`?
##  - receiver IS the target;
##  - receiver is a descendant whose whole chain up to the target is
##    MOUSE_FILTER_PASS (the event bubbles up and the target consumes it);
##  - receiver is a SubViewportContainer ancestor of the target (it forwards
##    events into the SubViewport hosting the target - forwarded picking is
##    the sub-viewport's business, so give it the benefit of the doubt).
static func click_reaches(receiver: Node, target: Control) -> bool:
	if receiver == target:
		return true
	if receiver is Control and target.is_ancestor_of(receiver):
		var a: Node = receiver
		while a != null and a != target:
			if not (a is Control) or (a as Control).mouse_filter != Control.MOUSE_FILTER_PASS:
				return false
			a = a.get_parent()
		return true
	if receiver is SubViewportContainer and receiver.is_ancestor_of(target):
		return true
	return false


## True when the control lives inside an embedded Window (popup/dialog): its rect is
## window-local, so the main-canvas hit test does not apply (click_control skips the
## occlusion precheck for those and keeps the plain push - the pre-1.10 behavior).
static func inside_embedded_window(c: Control, tree_root: Node) -> bool:
	var a := c.get_parent()
	while a != null:
		if a is Window and a != tree_root:
			return true
		a = a.get_parent()
	return false


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


## Numbered marks for every visible, unclipped interactive control, in document order.
## rect is SCREEN-pixel space (final_transform math - the space screenshot pixels live
## in), so the boxes land exactly on the captured image even under content-scale.
static func marks(vp: Viewport, tree_root: Node, scene_root: Node, max_marks: int = 40) -> Array:
	var out: Array = []
	_marks_walk(tree_root, vp, tree_root, scene_root, out, maxi(1, max_marks))
	return out


static func _marks_walk(n: Node, vp: Viewport, tree_root: Node, scene_root: Node, out: Array, cap: int) -> void:
	if out.size() >= cap:
		return
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Window and n != tree_root and not (n as Window).visible:
		return
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and _is_interactive(c) \
				and not point_clipped(c, c.get_global_rect().get_center(), vp):
			var sr := screen_rect_of(c, vp)
			if sr.size.x >= 2.0 and sr.size.y >= 2.0:
				var m := {"i": out.size() + 1, "path": path_of(c, scene_root),
					"rect": [roundi(sr.position.x), roundi(sr.position.y), roundi(sr.size.x), roundi(sr.size.y)]}
				var t := _text_of(c)
				if t != "":
					m["text"] = t.substr(0, 40)
				out.append(m)
	for child in n.get_children():
		_marks_walk(child, vp, tree_root, scene_root, out, cap)


## Control rect in OUTPUT/screen pixels (content-scale applied) - the same math
## _control_rect uses for its screen_rect, which is proven to match screenshot pixels.
static func screen_rect_of(c: Control, vp: Viewport) -> Rect2:
	var xf := vp.get_final_transform() * c.get_global_transform_with_canvas()
	var a: Vector2 = xf * Vector2.ZERO
	var b: Vector2 = xf * c.size
	return Rect2(a, b - a).abs()


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
	for n in interactive:
		if issues.size() >= cap:
			break
		var c := n as Control
		var r := c.get_global_rect()
		var p := path_of(c, scene_root)
		if r.size.x < 1.0 or r.size.y < 1.0:
			issues.append({"type": "zero_size", "path": p, "rect": _r4(r),
				"detail": "visible interactive control with a degenerate rect"})
		elif not inside_embedded_window(c, tree_root) and not vr.intersects(r):
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
		var ra := a.get_global_rect()
		if ra.size.x < 1.0 or ra.size.y < 1.0:
			continue
		for j in range(i + 1, interactive.size()):
			if issues.size() >= cap:
				break
			var b := interactive[j] as Control
			if a.is_ancestor_of(b) or b.is_ancestor_of(a):
				continue
			if _host_window(a, tree_root) != _host_window(b, tree_root):
				continue
			var rb := b.get_global_rect()
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
