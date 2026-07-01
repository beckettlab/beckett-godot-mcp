extends Node

## Game side of the runtime channel (B2). Registered as a project autoload by the
## plugin. NOT a @tool script — it runs ONLY in the played game, never in the editor.
## When a scene plays it dials the editor's BeckettRuntimeBridge and serves commands:
## screenshot, input simulation, live scene tree, runtime get/set/call.
##
## If the MCP server isn't running, the dial just fails and the game runs normally —
## zero impact when the bridge is off.

const RETRY_INTERVAL := 2.0

var _peer := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _port := 8771
var _since_retry := 0.0
var _was_connected := false

# Input recording (record_input / replay_input over the bridge).
var _recording := false
var _rec: Array = []
var _rec_t0 := 0

# Captured game output — runtime script errors WITH stack traces, push_error/warning,
# and print() — via a custom OS Logger installed in the played game. This is the
# real-time play->see-error->fix signal the agent reads through the game_logs tool;
# no file logging, no editor debugger needed (the engine routes built-in error/output
# to the internal debugger, not to EditorDebuggerPlugin captures — so we tap them here,
# at the source, in the game process itself).
#
# The Logger base class + OS.add_logger() are Godot 4.5+. On older engines (4.2–4.4)
# there's no such API, so capture gracefully no-ops and game_logs returns empty (see
# _install_log_sink). Everything Logger-typed is kept out of parse scope — typed Object
# here, the sink compiled at runtime — so this file still parses/loads on 4.2–4.4.
const _LOG_CAP := 800
var _log_ring: Array = []
var _log_dropped := 0
var _log_mutex := Mutex.new()
var _logger: Object = null


func _ready() -> void:
	# Keep serving while the game is paused (get_tree().paused = true) — pause
	# menus and game-over screens are exactly when the agent needs to look at the
	# game and click buttons; an INHERIT-mode autoload would freeze the channel.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var p := OS.get_environment("BECKETT_RUNTIME_PORT")
	if p != "" and p.is_valid_int():
		_port = p.to_int()
	_dial()
	set_process(true)
	set_process_input(true)
	# Tap the game's own log stream (errors/warnings/stack traces/prints).
	# Logger + OS.add_logger() are Godot 4.5+; on 4.2–4.4 this is a graceful no-op.
	_install_log_sink()


func _exit_tree() -> void:
	if _logger != null:
		# OS.call(): OS.remove_logger() is compile-checked and absent on < 4.5; _logger is
		# only ever non-null on 4.5+, so this dynamic call is only reached where it exists.
		OS.call("remove_logger", _logger)
		_logger = null


func _input(event: InputEvent) -> void:
	if not _recording:
		return
	var d := _serialize_event(event)
	if not d.is_empty():
		d["t"] = float(Time.get_ticks_msec() - _rec_t0)
		_rec.append(d)


func _dial() -> void:
	_peer = StreamPeerTCP.new()
	_peer.connect_to_host("127.0.0.1", _port)


func _process(delta: float) -> void:
	_peer.poll()
	var st := _peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTED:
		_was_connected = true
		var avail := _peer.get_available_bytes()
		if avail > 0:
			var res: Array = _peer.get_partial_data(avail)
			if res[0] == OK:
				_buf.append_array(res[1])
		while true:
			var nl := _buf.find(10)
			if nl == -1:
				break
			var line := _buf.slice(0, nl).get_string_from_utf8()
			_buf = _buf.slice(nl + 1)
			_handle(line)
	elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
		# Reconnect on DROP too, not just before the first connect. A mid-session drop
		# (bridge restart, editor focus loss) used to be permanent — the old retry was
		# gated on `not _was_connected`, so once connected it never re-dialed until a
		# stop+replay. Now we re-dial on the same interval whenever the link is down.
		if _was_connected:
			# Just lost an established link: reset read state and re-dial promptly.
			_was_connected = false
			_buf = PackedByteArray()
			_since_retry = RETRY_INTERVAL
		_since_retry += delta
		if _since_retry >= RETRY_INTERVAL:
			_since_retry = 0.0
			_dial()


func _handle(line: String) -> void:
	var msg: Variant = JSON.parse_string(line)
	if not (msg is Dictionary):
		return
	var resp := _dispatch(msg)
	# Echo the editor's sequence id so a late reply (this handler ran past the editor's
	# read deadline) is recognised as stale on the next command instead of desyncing.
	if (msg as Dictionary).has("_id"):
		resp["_id"] = (msg as Dictionary)["_id"]
	_peer.put_data((JSON.stringify(resp) + "\n").to_utf8_buffer())


func _dispatch(msg: Dictionary) -> Dictionary:
	match str(msg.get("cmd", "")):
		"ping":
			return {"ok": true, "scene": _scene_name()}
		"tree":
			return _tree_cmd(msg)
		"screenshot":
			return _screenshot(msg)
		"input":
			return _run_input(msg.get("events", []))
		"get":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			return {"ok": true, "value": _safe(n.get(str(msg.get("prop", "")))), "resolved": str(_root().get_path_to(n))}
		"set":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			var prop := str(msg.get("prop", ""))
			n.set(prop, _coerce_value(n, prop, msg.get("value")))
			return {"ok": true, "resolved": str(_root().get_path_to(n))}
		"call":
			var n := _resolve_target(msg)
			if n == null:
				return {"ok": false, "error": _not_found(msg)}
			var args: Array = msg.get("args", []) if msg.get("args", []) is Array else []
			return {"ok": true, "result": _safe(n.callv(str(msg.get("method", "")), args)), "resolved": str(_root().get_path_to(n))}
		"exists":
			return {"ok": true, "exists": _resolve_target(msg) != null}
		"find":
			return _find(msg)
		"click_text":
			return _click_text(msg)
		"click_control":
			return _click_control(msg)
		"control_rect":
			return _control_rect(msg)
		"click_node3d":
			return _click_node3d(msg)
		"click_world":
			return _click_world(msg)
		"scroll":
			return _scroll_cmd(msg)
		"drag":
			return _drag_cmd(msg)
		"perf":
			return {"ok": true, "monitors": _perf_monitors()}
		"logs":
			return _logs_cmd(msg)
		"record_start":
			_recording = true
			_rec = []
			_rec_t0 = Time.get_ticks_msec()
			return {"ok": true}
		"record_stop":
			_recording = false
			return {"ok": true, "events": _rec.duplicate()}
		_:
			return {"ok": false, "error": "unknown cmd"}


# ---------------------------------------------------------------- runtime ops

func _root() -> Node:
	var t := get_tree()
	if t == null:
		return null
	return t.current_scene if t.current_scene != null else t.root


func _scene_name() -> String:
	var r := _root()
	return str(r.name) if r != null else ""


## Resolve a node by path/name. Base is the current scene, but ALSO accepts an
## absolute SceneTree path (/root/...) and falls back to a tree-wide name search,
## so both "Player" and "/root/Main/Player" work (the #1 'node not found' trap).
func _resolve(path: String) -> Node:
	var root := _root()
	if root == null:
		return null
	if path.is_empty() or path == "." or path == root.name:
		return root
	var tree := get_tree()
	# Absolute SceneTree path (/root/...).
	if path.begins_with("/root") and tree != null:
		var abs := tree.root.get_node_or_null(NodePath(path))
		if abs != null:
			return abs
	# Relative to the current scene.
	var n := root.get_node_or_null(NodePath(path))
	if n != null:
		return n
	n = root.find_child(path, true, false)
	if n != null:
		return n
	# Last resort: name search from the SceneTree root (covers autoloads / overlays).
	if tree != null and tree.root != null:
		n = tree.root.find_child(path, true, false)
	return n


## Custom class_name of a node's script (Godot 4.3+), "" if none / built-in.
func _script_global_name(n: Node) -> String:
	var s = n.get_script()
	if s == null:
		return ""
	if s.has_method("get_global_name"):
		var gn = s.get_global_name()
		if gn != null and str(gn) != "":
			return str(gn)
	return ""


## Resolve a node from a command: by "path" if given, else by a live SELECTOR
## (class / name / text [+ nth]) — so the agent can address a node without re-fetching
## volatile auto-generated paths (@Node@NN) every session. class matches custom
## class_name too (see _class_match).
## All live nodes matching a command's target spec, in document (DFS pre-order) order.
## Spec = "path" (exact, 0/1 result; supports /root and %UniqueName) OR a selector:
## class (native or custom class_name) / name / text, optionally scoped to a subtree
## via "under". ONE resolver for every tool that takes a target (click_control,
## click_node3d/world, runtime_get/set/call) so nth never means different things.
func _resolve_matches(msg: Dictionary) -> Array:
	var path := str(msg.get("path", ""))
	if not path.is_empty():
		var direct := _resolve(path)
		return [direct] if direct != null else []
	var cls := str(msg.get("class", ""))
	var name_q := str(msg.get("name", ""))
	var text_q := str(msg.get("text", ""))
	if cls == "" and name_q == "" and text_q == "":
		return []
	var scope := _root()
	var under := str(msg.get("under", ""))
	if not under.is_empty():
		scope = _resolve(under)
	if scope == null:
		return []
	var out: Array = []
	_select_walk(scope, cls, name_q, text_q, out)
	return out


func _resolve_target(msg: Dictionary) -> Node:
	var matches := _resolve_matches(msg)
	if matches.is_empty():
		return null
	var nth := int(msg.get("nth", 0))
	if nth < 0 or nth >= matches.size():
		return null
	return matches[nth]


## Coerce a JSON value to the live property's current type before set — a value that
## arrives as a JSON string ("19", "[1,0,0]") must not be stored raw, or game code like
## `coins += 1` errors ("String + int") and aborts the dispatch (no response → the editor's
## runtime channel times out and desyncs). Parse stringified arrays/objects, then mirror scalars.
func _coerce_value(obj: Object, prop: String, value: Variant) -> Variant:
	if value is String:
		var raw := (value as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	match typeof(obj.get(prop)):
		TYPE_INT:
			return int(value) if (value is String or value is float) else value
		TYPE_FLOAT:
			return float(value) if (value is String or value is int) else value
		TYPE_BOOL:
			if value is String:
				return (value as String).to_lower() in ["true", "1", "yes"]
			return bool(value)
		TYPE_STRING:
			return str(value)
		TYPE_VECTOR2:
			return _vec2(value)
		TYPE_VECTOR3:
			return _vec3(value)
		TYPE_COLOR:
			if value is Array and value.size() >= 3:
				return Color(value[0], value[1], value[2], value[3] if value.size() > 3 else 1.0)
			if value is String:
				return Color(value)
	return value


func _select_walk(node: Node, cls: String, name_q: String, text_q: String, out: Array) -> void:
	var ok := true
	if cls != "" and not _class_match(node, cls):
		ok = false
	if ok and name_q != "" and str(node.name).findn(name_q) == -1:
		ok = false
	if ok and text_q != "" and _node_text(node).findn(text_q) == -1:
		ok = false
	if ok:
		out.append(node)
	for c in node.get_children():
		_select_walk(c, cls, name_q, text_q, out)


## Human-readable reason a _resolve_target call failed (path vs selector).
func _not_found(msg: Dictionary) -> String:
	var path := str(msg.get("path", ""))
	if not path.is_empty():
		return "node not found: %s" % path
	var sel: Array = []
	for k in ["class", "name", "text"]:
		var v := str(msg.get(k, ""))
		if v != "":
			sel.append("%s=%s" % [k, v])
	if sel.is_empty():
		return "no path or selector (class/name/text) given"
	return "no node matches selector %s (nth=%d)" % [", ".join(sel), int(msg.get("nth", 0))]


# ---------------------------------------------------------------- tree (scoped)

func _tree_cmd(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	var start := root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		start = _resolve(p)
		if start == null:
			return {"ok": false, "error": "node not found: %s" % p}
	var depth := int(msg.get("depth", -1))
	var max_nodes := int(msg.get("max_nodes", 250))
	if max_nodes <= 0:
		max_nodes = 1 << 30
	var max_children := int(msg.get("max_children", 50))
	if max_children <= 0:
		max_children = 1 << 30
	var ctx := {"count": 0, "max": max_nodes, "max_children": max_children,
		"collapse": bool(msg.get("collapse", true)), "truncated": false}
	var tree := _tree2(start, root, depth, ctx)
	var out := {"ok": true, "tree": tree, "node_count": int(ctx["count"])}
	if bool(ctx["truncated"]):
		out["truncated"] = true
		out["hint"] = "output capped — narrow with path=, lower depth=, or raise max_nodes="
	return out


func _tree2(n: Node, root: Node, depth: int, ctx: Dictionary) -> Dictionary:
	ctx["count"] = int(ctx["count"]) + 1
	var d: Dictionary = {"name": str(n.name), "class": n.get_class()}
	var gn := _script_global_name(n)
	if gn != "":
		d["script"] = gn
	var child_count := n.get_child_count()
	if child_count == 0:
		return d
	if depth == 0:
		d["children_omitted"] = child_count
		return d
	var kids := n.get_children()
	var out_kids: Array = []
	var shown := 0
	var i := 0
	while i < kids.size():
		if int(ctx["count"]) >= int(ctx["max"]):
			ctx["truncated"] = true
			break
		if shown >= int(ctx["max_children"]):
			out_kids.append({"more": kids.size() - i})
			ctx["truncated"] = true
			break
		var c: Node = kids[i]
		# Collapse a run of identical childless leaf siblings (e.g. 8 CPUParticles2D)
		# into one entry — the #1 source of token-bloat in real scene trees.
		if bool(ctx["collapse"]) and c.get_child_count() == 0 and _script_global_name(c) == "":
			var cls := c.get_class()
			var j := i
			while j < kids.size() and kids[j].get_child_count() == 0 \
					and kids[j].get_class() == cls and _script_global_name(kids[j]) == "":
				j += 1
			var run := j - i
			if run >= 5:
				ctx["count"] = int(ctx["count"]) + run
				out_kids.append({"class": cls, "count": run, "collapsed": true,
					"first": str(c.name), "last": str(kids[j - 1].name)})
				shown += 1
				i = j
				continue
		out_kids.append(_tree2(c, root, depth - 1, ctx))
		shown += 1
		i += 1
	if not out_kids.is_empty():
		d["children"] = out_kids
	return d


func _screenshot(msg: Dictionary = {}) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var tex := vp.get_texture()
	if tex == null:
		return {"ok": false, "error": "no viewport texture (headless / no RHI?)"}
	var img := tex.get_image()
	if img == null:
		return {"ok": false, "error": "could not read viewport image (headless / no RHI?)"}
	var full_w := img.get_width()
	var full_h := img.get_height()
	img = _maybe_crop(img, msg)
	var png := img.save_png_to_buffer()
	return {"ok": true, "png": Marshalls.raw_to_base64(png),
		"w": img.get_width(), "h": img.get_height(), "full_w": full_w, "full_h": full_h}


## Crop to region=[x,y,w,h] (pixels, clamped to bounds) to save tokens; returns the
## image unchanged when no valid region is given.
func _maybe_crop(img: Image, msg: Dictionary) -> Image:
	var r = msg.get("region", null)
	if not (r is Array and r.size() >= 4):
		return img
	var x := clampi(int(r[0]), 0, img.get_width() - 1)
	var y := clampi(int(r[1]), 0, img.get_height() - 1)
	var w := clampi(int(r[2]), 1, img.get_width() - x)
	var h := clampi(int(r[3]), 1, img.get_height() - y)
	return img.get_region(Rect2i(x, y, w, h))


func _run_input(events: Array) -> Dictionary:
	var count := 0
	for e in events:
		if not (e is Dictionary):
			continue
		var ev := _build_event(e)
		if ev != null:
			Input.parse_input_event(ev)
			count += 1
	return {"ok": true, "dispatched": count}


func _build_event(e: Dictionary) -> InputEvent:
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
			mb.position = _vec2(e.get("position", [0, 0]))
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = _vec2(e.get("position", [0, 0]))
			mm.relative = _vec2(e.get("relative", [0, 0]))
			return mm
		_:
			return null


func _vec2(v: Variant) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(v[0], v[1])
	if v is Dictionary:
		return Vector2(v.get("x", 0), v.get("y", 0))
	return Vector2.ZERO


# ---------------------------------------------------------------- find (live nodes)

func _find(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	var scope := root
	var p := str(msg.get("path", ""))
	if not p.is_empty():
		scope = _resolve(p)
		if scope == null:
			return {"ok": false, "error": "node not found: %s" % p}
	var cls := str(msg.get("class", ""))
	var text_q := str(msg.get("text", ""))
	var name_q := str(msg.get("name", ""))
	var recursive := bool(msg.get("recursive", true))
	var maxn := int(msg.get("max", 100))
	var out: Array = []
	for c in scope.get_children():
		if out.size() >= maxn:
			break
		if recursive:
			_find_walk(c, root, cls, text_q, name_q, out, maxn)
		else:
			_match_into(c, root, cls, text_q, name_q, out)
	return {"ok": true, "nodes": out, "count": out.size()}


func _find_walk(node: Node, root: Node, cls: String, text_q: String, name_q: String, out: Array, maxn: int) -> void:
	if out.size() >= maxn:
		return
	_match_into(node, root, cls, text_q, name_q, out)
	for c in node.get_children():
		if out.size() >= maxn:
			return
		_find_walk(c, root, cls, text_q, name_q, out, maxn)


func _match_into(node: Node, root: Node, cls: String, text_q: String, name_q: String, out: Array) -> void:
	if not _class_match(node, cls):
		return
	var ntext := _node_text(node)
	if text_q != "" and ntext.findn(text_q) == -1:
		return
	if name_q != "" and str(node.name).findn(name_q) == -1:
		return
	var entry := {"path": str(root.get_path_to(node)), "class": node.get_class()}
	var gn := _script_global_name(node)
	if gn != "":
		entry["script"] = gn
	if ntext != "":
		entry["text"] = ntext
	out.append(entry)


## Match a class filter against BOTH the native class chain AND the custom script
## class_name — is_class() alone misses custom nodes (they read as @Node@NN).
func _class_match(node: Node, cls: String) -> bool:
	if cls == "":
		return true
	if node.is_class(cls):
		return true
	var gn := _script_global_name(node)
	return gn != "" and gn.nocasecmp_to(cls) == 0


func _node_text(n: Node) -> String:
	for p in n.get_property_list():
		if str(p.get("name", "")) == "text":
			return str(n.get("text"))
	return ""


# ---------------------------------------------------------------- click

func _click_text(msg: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return {"ok": false, "error": "no current scene"}
	# Same resolver as click_control, scoped to buttons: the two tools agree on the
	# match set and nth ordering (a bare text selector elsewhere also scopes to BaseButton).
	var sel := msg.duplicate()
	if str(sel.get("class", "")) == "":
		sel["class"] = "BaseButton"
	var matches := _resolve_matches(sel)
	var text := str(msg.get("text", ""))
	if matches.is_empty():
		var where := (" under %s" % str(msg.get("under", ""))) if str(msg.get("under", "")) != "" else ""
		return {"ok": false, "error": "no button with text containing '%s'%s" % [text, where]}
	if bool(msg.get("all", false)):
		var list: Array = []
		for b in matches:
			list.append({"path": str(root.get_path_to(b)), "text": _node_text(b), "class": b.get_class()})
		return {"ok": true, "matches": list, "count": list.size()}
	var idx := int(msg.get("nth", 0))
	if idx < 0 or idx >= matches.size():
		return {"ok": false, "error": "nth %d out of range (%d match(es) for '%s')" % [idx, matches.size(), text]}
	var btn: Node = matches[idx]
	btn.emit_signal("pressed")
	return {"ok": true, "clicked": true, "path": str(root.get_path_to(btn)), "match_count": matches.size()}


## Click a Control by injecting press+release at its center straight into the
## viewport in GUI space (push_input local). This bypasses the content-scale /
## stretch transform that makes Input.parse_input_event miss buttons in containers.
##
## Guards the false-positive where the target is scrolled out of a ScrollContainer:
## a click there would silently miss (clipped) yet look successful. If the center is
## clipped/off-screen we scroll it into view and report clicked=false (the re-sort is
## deferred one frame) so the caller calls again to land the click — never a fake hit.
func _click_control(msg: Dictionary) -> Dictionary:
	# Clicking by bare text means "a button": scope it to BaseButton so nth indexes the
	# SAME set/order as click_button_by_text. Without this, a text-only selector also
	# counts Labels and other text-bearing nodes, shifting nth onto the wrong control.
	if str(msg.get("text", "")) != "" and str(msg.get("class", "")) == "" \
			and str(msg.get("path", "")) == "" and str(msg.get("name", "")) == "":
		msg = msg.duplicate()
		msg["class"] = "BaseButton"
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s) — use simulate_input for non-Control targets" % n.get_class()}
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var ctrl := n as Control
	var path := str(_root().get_path_to(ctrl))
	if not ctrl.is_visible_in_tree():
		return {"ok": true, "clicked": false, "path": path,
			"warning": "control is hidden (not visible in tree) — nothing to click"}
	var center: Vector2 = ctrl.get_global_rect().get_center()
	if _is_point_clipped(ctrl, center, vp):
		if not _scroll_into_view(ctrl):
			return {"ok": true, "clicked": false, "scrolled": false, "path": path, "at": [center.x, center.y],
				"warning": "control is off-screen/clipped and has no ScrollContainer ancestor to bring it into view"}
		# Flush the deferred re-sort so the scrolled position applies THIS call (no retry).
		_force_sort(ctrl)
		center = ctrl.get_global_rect().get_center()
		if _is_point_clipped(ctrl, center, vp):
			return {"ok": true, "clicked": false, "scrolled": true, "path": path, "at": [center.x, center.y],
				"warning": "scrolled toward view but still clipped (nested scroll?) — call click_control again to land the click"}
	var button := int(msg.get("button", 1))
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = center
	down.global_position = center
	vp.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = center
	up.global_position = center
	vp.push_input(up, true)
	return {"ok": true, "clicked": true, "path": path, "at": [center.x, center.y]}


## True if point p (GUI space) is outside the viewport OR clipped by a clip_contents
## ancestor (ScrollContainer and friends) — i.e. a click there would not reach ctrl.
func _is_point_clipped(ctrl: Control, p: Vector2, vp: Viewport) -> bool:
	if not vp.get_visible_rect().has_point(p):
		return true
	var a := ctrl.get_parent()
	while a != null:
		if a is Control and (a as Control).clip_contents and not (a as Control).get_global_rect().has_point(p):
			return true
		a = a.get_parent()
	return false


## Scroll every ScrollContainer ancestor so ctrl becomes visible. Returns true if at
## least one did (the position update is deferred to the next layout pass).
func _scroll_into_view(ctrl: Control) -> bool:
	var did := false
	var a := ctrl.get_parent()
	while a != null:
		if a is ScrollContainer:
			(a as ScrollContainer).ensure_control_visible(ctrl)
			did = true
		a = a.get_parent()
	return did


## Force every Container ancestor to re-sort its children NOW, instead of waiting for
## the queued sort next frame — lets click_control scroll a control into view and click
## it in the SAME call. Best-effort: if positions still aren't settled, the caller falls
## back to the call-again path.
func _force_sort(ctrl: Control) -> void:
	var a := ctrl.get_parent()
	while a != null:
		if a is Container:
			a.notification(Container.NOTIFICATION_SORT_CHILDREN)
		a = a.get_parent()


## Report a Control's rect in BOTH GUI/canvas space and screen space (content-scale
## applied), so the agent can click with the right coordinates — or just call click_control.
func _control_rect(msg: Dictionary) -> Dictionary:
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s)" % n.get_class()}
	var ctrl := n as Control
	var gr: Rect2 = ctrl.get_global_rect()
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	# local -> canvas (gui) -> output(physical). The final_transform carries the
	# content-scale/stretch, so screen_rect matches screenshot pixels (gui_rect doesn't
	# when the window is larger than the canvas, e.g. a 1.735x stretch).
	var xf := vp.get_final_transform() * ctrl.get_global_transform_with_canvas()
	var s0: Vector2 = xf * Vector2.ZERO
	var s1: Vector2 = xf * ctrl.size
	var sr := Rect2(s0, s1 - s0).abs()
	return {"ok": true, "rect": {
		"path": str(_root().get_path_to(ctrl)),
		"gui_rect": [gr.position.x, gr.position.y, gr.size.x, gr.size.y],
		"gui_center": [gr.get_center().x, gr.get_center().y],
		"screen_rect": [sr.position.x, sr.position.y, sr.size.x, sr.size.y],
		"screen_center": [sr.get_center().x, sr.get_center().y],
	}}


## Click a 3D node by projecting its world origin to the screen via the active
## Camera3D, then injecting motion+press+release there — for games that do their own
## mouse picking (CollisionObject3D._input_event / a camera raycast from the cursor).
func _click_node3d(msg: Dictionary) -> Dictionary:
	var n := _resolve_target(msg)
	if n == null:
		return {"ok": false, "error": _not_found(msg)}
	if not (n is Node3D):
		return {"ok": false, "error": "not a Node3D (%s)" % n.get_class()}
	var n3 := n as Node3D
	# Target the visible CENTER for meshes: their origin is often at (0,0,0) while the
	# geometry sits elsewhere, so projecting the bare origin misses the screen. Use the
	# world-space AABB center when the node is a VisualInstance3D.
	var world: Vector3 = n3.global_position
	if n3 is VisualInstance3D:
		var ab: AABB = (n3 as VisualInstance3D).get_aabb()
		if ab.size != Vector3.ZERO:
			world = n3.global_transform * ab.get_center()
	return _world_click(world, int(msg.get("button", 1)), str(_root().get_path_to(n3)))


## Click at a 3D WORLD position (unprojected to the screen via the active Camera3D).
func _click_world(msg: Dictionary) -> Dictionary:
	var p: Variant = msg.get("position", null)
	if not (p is Array and (p as Array).size() >= 3):
		return {"ok": false, "error": "position must be [x, y, z]"}
	return _world_click(_vec3(p), int(msg.get("button", 1)), "world")


func _world_click(world: Vector3, button: int, label: String) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var cam := vp.get_camera_3d()
	if cam == null:
		return {"ok": false, "error": "no active Camera3D in the running scene"}
	if cam.is_position_behind(world):
		return {"ok": true, "clicked": false, "target": label,
			"warning": "world point is behind the camera — not on screen"}
	var screen: Vector2 = cam.unproject_position(world)
	if not vp.get_visible_rect().has_point(screen):
		return {"ok": true, "clicked": false, "target": label, "at": [screen.x, screen.y],
			"warning": "world point projects off-screen at (%d, %d)" % [int(screen.x), int(screen.y)]}
	# Hover first (pickers track the moused-over object), then press+release.
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	motion.global_position = screen
	vp.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = screen
	down.global_position = screen
	vp.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = screen
	up.global_position = screen
	vp.push_input(up, true)
	return {"ok": true, "clicked": true, "target": label,
		"at": [screen.x, screen.y], "world": [world.x, world.y, world.z]}


func _vec3(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(v[0], v[1], v[2])
	if v is Dictionary:
		return Vector3(v.get("x", 0), v.get("y", 0), v.get("z", 0))
	return Vector3.ZERO


## Mouse-wheel scroll at a target Control's center (path/selector) or an explicit
## gui-space position. amount>0 scrolls down, <0 up; |amount| = wheel notches.
func _scroll_cmd(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var pos: Vector2
	if msg.has("position"):
		pos = _vec2(msg.get("position", []))
	else:
		var n := _resolve_target(msg)
		if n == null:
			return {"ok": false, "error": _not_found(msg)}
		if not (n is Control):
			return {"ok": false, "error": "scroll target must be a Control, or give position=[x,y]"}
		pos = (n as Control).get_global_rect().get_center()
	var amount := int(msg.get("amount", 1))
	if amount == 0:
		amount = 1
	var btn := MOUSE_BUTTON_WHEEL_UP if amount < 0 else MOUSE_BUTTON_WHEEL_DOWN
	var notches := absi(amount)
	for i in notches:
		var down := InputEventMouseButton.new()
		down.button_index = btn
		down.pressed = true
		down.factor = 1.0
		down.position = pos
		down.global_position = pos
		vp.push_input(down, true)
		var up := InputEventMouseButton.new()
		up.button_index = btn
		up.pressed = false
		up.position = pos
		up.global_position = pos
		vp.push_input(up, true)
	return {"ok": true, "scrolled": notches, "direction": "up" if amount < 0 else "down", "at": [pos.x, pos.y]}


## Press at `from`, glide through interpolated motion to `to`, release — for sliders,
## drag-and-drop, camera pans. Coordinates are gui-space (like click_control).
func _drag_cmd(msg: Dictionary) -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {"ok": false, "error": "no viewport"}
	var f: Variant = msg.get("from", null)
	var t: Variant = msg.get("to", null)
	if not (f is Array and (f as Array).size() >= 2 and t is Array and (t as Array).size() >= 2):
		return {"ok": false, "error": "from and to must both be [x, y]"}
	var from := _vec2(f)
	var to := _vec2(t)
	var button := int(msg.get("button", 1))
	var mask := 1 << (button - 1)
	var steps: int = clampi(int(msg.get("steps", 8)), 1, 60)
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = from
	down.global_position = from
	vp.push_input(down, true)
	var prev := from
	for i in range(1, steps + 1):
		var p: Vector2 = from.lerp(to, float(i) / float(steps))
		var mm := InputEventMouseMotion.new()
		mm.position = p
		mm.global_position = p
		mm.relative = p - prev
		mm.button_mask = mask
		vp.push_input(mm, true)
		prev = p
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = to
	up.global_position = to
	vp.push_input(up, true)
	return {"ok": true, "dragged": true, "from": [from.x, from.y], "to": [to.x, to.y], "steps": steps}


func _safe(v: Variant) -> Variant:
	var t := typeof(v)
	if t == TYPE_OBJECT:
		return str(v)
	# Stringify built-in math structs — JSON can't encode them and they'd come back
	# as null (the global_rect / transform 'returns null' trap).
	var structs := [TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I,
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_COLOR, TYPE_RECT2, TYPE_RECT2I,
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION,
		TYPE_AABB, TYPE_PLANE, TYPE_PROJECTION]
	if t in structs:
		return str(v)
	return v


func _perf_monitors() -> Dictionary:
	var pairs := [
		["fps", Performance.TIME_FPS],
		["process_time", Performance.TIME_PROCESS],
		["physics_process_time", Performance.TIME_PHYSICS_PROCESS],
		["memory_static", Performance.MEMORY_STATIC],
		["memory_static_max", Performance.MEMORY_STATIC_MAX],
		["object_count", Performance.OBJECT_COUNT],
		["resource_count", Performance.OBJECT_RESOURCE_COUNT],
		["node_count", Performance.OBJECT_NODE_COUNT],
		["orphan_node_count", Performance.OBJECT_ORPHAN_NODE_COUNT],
		["draw_calls", Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME],
		["render_objects", Performance.RENDER_TOTAL_OBJECTS_IN_FRAME],
		["render_primitives", Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME],
		["video_mem_used", Performance.RENDER_VIDEO_MEM_USED],
		["texture_mem", Performance.RENDER_TEXTURE_MEM_USED],
		["buffer_mem", Performance.RENDER_BUFFER_MEM_USED],
		["physics_2d_active", Performance.PHYSICS_2D_ACTIVE_OBJECTS],
		["physics_3d_active", Performance.PHYSICS_3D_ACTIVE_OBJECTS],
	]
	var out: Dictionary = {}
	for p in pairs:
		out[p[0]] = Performance.get_monitor(p[1])
	return out


# ---------------------------------------------------------------- log capture

## Called by the OS Logger on every print() (and stderr writes).
func _on_message(message: String, error: bool) -> void:
	_push_log({"type": "stderr" if error else "print", "t": Time.get_ticks_msec(), "text": message})


## Called by the OS Logger on every error/warning — including runtime SCRIPT errors,
## with their stack trace(s) in script_backtraces (ScriptBacktrace.format()).
func _on_error(function: String, file: String, line: int, code: String, rationale: String, error_type: int, script_backtraces: Array) -> void:
	var bt := ""
	for b in script_backtraces:
		# Duck-typed instead of `b is ScriptBacktrace`: that class is Godot 4.5+, and a
		# parse-time type reference would break this file on < 4.5. We only reach here from
		# the 4.5+ sink anyway, where these are genuine ScriptBacktraces.
		if b is Object and b.has_method("format") and b.has_method("is_empty") and not b.is_empty():
			bt += b.format(0, 2)
	_push_log({
		"type": _err_type_name(error_type),
		"t": Time.get_ticks_msec(),
		"function": function, "file": file, "line": line,
		"rationale": rationale if str(rationale) != "" else code,
		"backtrace": bt,
	})


func _err_type_name(t: int) -> String:
	# Logger.ERROR_TYPE_* values (Godot 4.5+): ERROR=0, WARNING=1, SCRIPT=2, SHADER=3.
	# Inlined as literals so this file parses on < 4.5 where the Logger class is absent.
	match t:
		1:
			return "warning"
		2:
			return "script"
		3:
			return "shader"
		_:
			return "error"


func _push_log(e: Dictionary) -> void:
	_log_mutex.lock()
	_log_ring.append(e)
	if _log_ring.size() > _LOG_CAP:
		_log_ring.pop_front()
		_log_dropped += 1
	_log_mutex.unlock()


func _logs_cmd(msg: Dictionary) -> Dictionary:
	var level := str(msg.get("level", "error")).to_lower()
	var needle := str(msg.get("filter", ""))
	var limit: int = maxi(1, int(msg.get("limit", 100)))
	_log_mutex.lock()
	var snapshot: Array = _log_ring.duplicate()
	var dropped := _log_dropped
	if bool(msg.get("clear", false)):
		_log_ring.clear()
		_log_dropped = 0
	_log_mutex.unlock()
	var out: Array = []
	for e in snapshot:
		if not _level_pass(str(e.get("type", "")), level):
			continue
		if needle != "" and _entry_text(e).findn(needle) == -1:
			continue
		out.append(e)
	if out.size() > limit:
		out = out.slice(out.size() - limit, out.size())
	# capture_active tells the editor side whether the log sink is actually installed —
	# false on Godot < 4.5 (no Logger API), where an empty buffer means "capture off",
	# NOT "the game logged nothing". game_logs surfaces that distinction to the agent.
	return {"ok": true, "entries": out, "count": out.size(), "dropped": dropped, "buffer_size": snapshot.size(), "capture_active": _logger != null}


func _level_pass(ty: String, level: String) -> bool:
	if level == "all":
		return true
	var is_err := ty == "error" or ty == "script" or ty == "shader"
	if level == "warning":
		return is_err or ty == "warning"
	return is_err


func _entry_text(e: Dictionary) -> String:
	if e.has("text"):
		return str(e["text"])
	return "%s %s %s" % [str(e.get("file", "")), str(e.get("rationale", "")), str(e.get("backtrace", ""))]


func _serialize_event(e: InputEvent) -> Dictionary:
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
	return {}


## Install a custom OS Logger that forwards the played game's log stream (prints,
## warnings, errors, script stack traces) into our ring buffer. The Logger class and
## OS.add_logger() are Godot 4.5+; on 4.2–4.4 there's no such API, so this is a graceful
## no-op (game_logs just returns an empty buffer) and the runtime module still loads.
func _install_log_sink() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var sink := _make_log_sink()
	if sink == null:
		return
	_logger = sink
	OS.call("add_logger", _logger)


## Build the Logger sink by compiling it from source at runtime. It `extends Logger` — a
## base class absent before 4.5 — so it can't live as a parsed inner class here: that is
## exactly what broke parsing on older engines. Compiling from a string keeps every
## Logger reference out of this file's parse scope; the source is only compiled on 4.5+.
## Kept tiny and print-free — anything the sink itself logged would re-enter the logger.
func _make_log_sink() -> Object:
	var src := "\n".join([
		"extends Logger",
		"var host",
		"func _log_message(message, error):",
		"\tif host != null: host._on_message(message, error)",
		"func _log_error(function, file, line, code, rationale, editor_notify, error_type, script_backtraces):",
		"\tif host != null: host._on_error(function, file, line, code, rationale, error_type, script_backtraces)",
	])
	var gd := GDScript.new()
	gd.source_code = src
	if gd.reload() != OK:
		return null
	var sink: Object = gd.new()
	if sink == null:
		return null
	sink.set("host", self)
	return sink
