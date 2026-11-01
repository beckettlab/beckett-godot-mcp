@tool
extends Node
class_name BeckettRuntimeBridge

## Editor side of the runtime channel (B2). Listens on a localhost port; the game's
## MCPRuntime autoload dials in when a scene plays. Lets editor tools reach INTO the
## running game — screenshot, input simulation, live scene tree, runtime get/set/call —
## the autonomous play→observe→fix loop that every free Godot MCP lacks.
##
## The game runs as a separate OS process, so this is the only way to see/drive it.
## Request/response is one JSON line each way; tool calls are synchronous so a bounded
## blocking read on the editor main thread is fine (the game answers in ms).

var running: bool = false
var port: int = 8771
## Shared secret for the game handshake (v1.9.1). Set per editor session by mcp_server and
## exported to launched games via BECKETT_RUNTIME_TOKEN (children inherit the environment).
## Empty = handshake not required (BECKETT_AUTH=0 / legacy runtimes).
var expected_token: String = ""

## The editor's break watch (core/break_watch.gd), set by plugin.gd; null outside an editor (the unit suite, a
## headless child), where nothing can be asked and the bridge behaves exactly as it did before 1.16.
var break_watch: Object = null

var _tcp := TCPServer.new()
var _peer: StreamPeerTCP = null
var _pending: StreamPeerTCP = null      # connected, hello not yet verified
var _pending_buf := PackedByteArray()
var _pending_t0 := 0
var _seq: int = 0

# --- on_ready queue (play_scene on_ready=[...]) ------------------------------------------
# A tool handler CANNOT wait for the game to connect: poll_until blocks the editor main
# thread and the editor needs frames to finish launching the game, so an in-call wait
# deadlocks the very event it waits for (the reason wait_until caps at ~1.5 s). So
# play_scene parks its writes here and the bridge applies them the moment a verified peer
# arrives. This is the restart boundary batch_execute cannot cross, crossed by the one
# object that sees both sides of it — and it takes the "stop, play, wait, re-place the
# camera, screenshot" loop from 9 calls to 3.
var on_ready_queue: Array = []
var on_ready_report: Array = []
var _on_ready_deadline := 0
const ON_READY_GRACE_MS := 4000  # how long a queued target may still be spawning
# A busy game answers late (1.17). The game reads this channel once a frame and answers in order, so a long frame (a
# scene still loading, a shader compiling) holds a write in its queue past any timeout, and the game still applies it
# when it catches up: on 2026-10-12 a 4.7.2 game took a write the drain had already reported as failed. So the drain
# waits ON_READY_WAIT_MS, then parks the write (sent, outcome unknown) and sends nothing more until the game answers
# again; then it reads the property back and reports the write landed (late_ms, with the value) or failed (with the
# value read). A write with no answer in ON_READY_LATE_MS (time paused in the debugger not counted) is unknown.
const ON_READY_WAIT_MS := 1500
const ON_READY_LATE_MS := 30000
var on_ready_wait_ms := ON_READY_WAIT_MS  # the unit suite shortens both
var on_ready_late_ms := ON_READY_LATE_MS
var _on_ready_waiting: Dictionary = {}  # the parked write: {item, sent, seq, paused_ms, seen}
# The game connection this batch went out on. A batch is never carried into another game: a game the person starts with
# F5 inherits the session token and connects as a verified peer, and the agent's writes must not land in it.
var _on_ready_peer: Object = null
# The read-back's judge: the coercion the game's own write uses (dependency-free, like this file).
const CallArgs := preload("res://addons/beckett/core/callargs.gd")


func start(p_port: int, bind_address: String = "127.0.0.1") -> int:
	stop()
	var err := _tcp.listen(p_port, bind_address)
	if err == OK:
		port = _tcp.get_local_port()
		running = true
	return err


func stop() -> void:
	running = false
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _pending != null:
		_pending.disconnect_from_host()
		_pending = null
	if _tcp.is_listening():
		_tcp.stop()


func _process(_delta: float) -> void:
	poll_once()


## Accept a pending game connection and refresh peer status. Exposed so a blocking
## tool (wait_until) can pump the bridge while it holds the main thread — otherwise the
## game could never connect during the wait.
##
## v1.9.1: new connections park in a single PENDING slot until their hello line verifies
## (see _pump_pending). Only a VERIFIED newcomer may displace a live peer — "newest play
## session wins" survives for real stop→play restarts (the new game carries the session
## token), while an unauthenticated local process can neither become the game nor kick
## the real game off the channel.
func poll_once() -> void:
	if not running:
		return
	if _tcp.is_connection_available():
		var p := _tcp.take_connection()
		if p != null:
			p.set_no_delay(true)
			if _pending != null:
				_pending.disconnect_from_host()
			_pending = p
			_pending_buf = PackedByteArray()
			_pending_t0 = Time.get_ticks_msec()
	_pump_pending()
	if _peer != null:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			_on_ready_lost(_peer, "the game disconnected")
			_peer = null
	if _peer != null and not on_ready_settled():
		_drain_on_ready()


## Apply the queued play_scene on_ready writes. Runs a frame or more AFTER promotion, and
## re-queues targets that have not spawned yet until the grace window closes — a scene root
## exists the instant the game dials in, but its children may still be instantiating, and a
## write silently lost to "node not found" would be exactly the dishonesty we just removed.
## A write the game does not answer in time is parked, not failed (see ON_READY_WAIT_MS), and nothing more is sent
## until the game answers it, so the writes still land in the order given and the timeouts do not stack.
func _drain_on_ready() -> void:
	if not _on_ready_waiting.is_empty() and not _settle_waiting():
		return
	var queue := on_ready_queue
	on_ready_queue = []
	var still: Array = []
	for i in queue.size():
		var d: Dictionary = queue[i]
		var cmd := {"cmd": "set", "prop": str(d.get("property", "")), "value": d.get("value")}
		_on_ready_target_into(cmd, d)
		var sent := Time.get_ticks_msec()
		var r: Dictionary = send_command(cmd, on_ready_wait_ms)
		var err := str(r.get("error", ""))
		var ok := bool(r.get("ok", false))
		if not ok and (err.begins_with("game not running") or (err.contains(BREAK_MARK) and not r.has("delivered"))):
			# Not sent at all: the game went away a moment ago, or it is paused in the debugger. A batch none of whose
			# writes reached this game stays queued for the next one; one this game has seen is never carried over.
			on_ready_queue = still + queue.slice(i)
			if err.contains(BREAK_MARK):
				_on_ready_not_sent("not sent: the game is paused in the debugger")
			elif _on_ready_peer != null:
				_on_ready_not_sent("not sent: the game disconnected")
			return
		_on_ready_peer = _peer
		if r.has("timeout") or r.has("delivered"):
			# Sent and not answered: a busy game applies it when it catches up, a paused one when it resumes.
			_on_ready_waiting = {"item": d, "sent": sent, "seq": _seq, "paused_ms": 0, "seen": Time.get_ticks_msec()}
			on_ready_queue = still + queue.slice(i + 1)
			return
		if not ok and err.begins_with("runtime disconnected"):
			on_ready_report.append(_on_ready_entry(d, {"ok": false, "unknown": true, "error": "the game disconnected before it answered this write: whether it landed is unknown"}))
			on_ready_queue = still + queue.slice(i + 1)
			_on_ready_not_sent("not sent: the game disconnected")
			return
		if not ok and is_target_missing(err) and Time.get_ticks_msec() < _on_ready_deadline:
			still.append(d)
			continue
		on_ready_report.append(_on_ready_entry(d, r))
	on_ready_queue = still
	if not on_ready_queue.is_empty() and Time.get_ticks_msec() >= _on_ready_deadline:
		for d in on_ready_queue:
			on_ready_report.append(_on_ready_entry(d, {
				"ok": false,
				"error": "target never appeared within %d ms of the game connecting" % ON_READY_GRACE_MS,
			}))
		on_ready_queue = []


## Is this error the game saying that node is not there (yet)? That is all the on_ready drain retries. Every other error
## is final, and a refusal in particular (a write aimed at Beckett's own runtime, which the game answers with "off
## limits", or a path with a ':' in it, which names a property and so never a node) must never read as a node that
## has not appeared: it would be retried for the whole grace window. Only the START of the error is read: both of the
## game's misses begin that way, and a refusal echoes the caller's own words, which can hold "not found" anywhere.
static func is_target_missing(err: String) -> bool:
	return err.begins_with("node not found") or err.begins_with("no node matches")


## The parked write, once the game shows it is answering again: true when it is settled (reported, or queued again
## because its target is still not there) and the drain may go on, false while the game still owes the answer. It asks
## only on a sign of life: bytes in the socket (most likely this write's own late answer), a command another tool sent
## since (whose reply may have taken that answer), or the wait running out. Asking a busy game would only stall the
## editor. The game answers in order, so once its read-back comes, the write before it has been applied or refused.
func _settle_waiting() -> bool:
	var w := _on_ready_waiting
	var now := Time.get_ticks_msec()
	if not break_text().is_empty():
		# Paused in the debugger: nothing can answer until someone presses Continue, and that time is not the game's delay.
		w["paused_ms"] = int(w["paused_ms"]) + now - int(w["seen"])
		w["seen"] = now
		return false
	w["seen"] = now
	var waited := now - int(w["sent"]) - int(w["paused_ms"])
	if _peer == null:
		return false  # no channel: _on_ready_lost reports the write when the peer drops
	_peer.poll()
	if _peer.get_available_bytes() == 0 and _seq == int(w["seq"]) and waited < on_ready_late_ms:
		return false
	var d: Dictionary = w["item"]
	var cmd := {"cmd": "get", "prop": str(d.get("property", ""))}
	_on_ready_target_into(cmd, d)
	var r: Dictionary = send_command(cmd, on_ready_wait_ms)
	var err := str(r.get("error", ""))
	var ok := bool(r.get("ok", false))
	if not ok and (r.has("timeout") or r.has("delivered") or err.contains(BREAK_MARK)):
		w["seq"] = _seq  # that read now waits in the game too: its answer is the next sign of life
		if waited < on_ready_late_ms:
			return false
		_on_ready_waiting = {}
		var cap := ("%d s" % int(on_ready_late_ms / 1000.0)) if on_ready_late_ms >= 1000 else ("%d ms" % on_ready_late_ms)
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "unknown": true,
			"error": "the game has not answered this write in %s: it may still land, so read it back with runtime_get_property" % cap}))
		_on_ready_not_sent("not sent: the game has not answered an earlier on_ready write in %s" % cap)
		return false
	_on_ready_waiting = {}
	if not ok and (err.begins_with("game not running") or err.begins_with("runtime disconnected")):
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "unknown": true, "error": "the game disconnected before it answered this write: whether it landed is unknown"}))
		_on_ready_not_sent("not sent: the game disconnected")
		return false
	var late := Time.get_ticks_msec() - int(w["sent"])
	# The time it waited went to the game's stall, not to spawning: targets still missing get their grace again.
	_on_ready_deadline = maxi(_on_ready_deadline, Time.get_ticks_msec() + ON_READY_GRACE_MS)
	if not ok:
		if is_target_missing(err):
			on_ready_queue.push_front(d)  # its target is not there, so the write could not land: tried again first
		else:
			on_ready_report.append(_on_ready_entry(d, {"ok": false, "error": "the game answered late, and reading the property back says: " + err}, late))
		return true
	var got: Variant = r.get("value")
	var verdict := read_back_verdict(d.get("value"), got)
	if verdict == 1:
		on_ready_report.append(_on_ready_entry(d, {"ok": true, "after": got}, late))
	elif verdict == 0:
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "after": got,
			"error": "the game answered late, and the property reads back as %s, not the %s written: the write did not land, or game code changed it since" % [_shown(got), _shown(d.get("value"))]}, late))
	else:
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "unknown": true, "after": got,
			"error": "the game answered late, and the property reads back as %s, which Beckett cannot compare with the %s written: read it with runtime_get_property" % [_shown(got), _shown(d.get("value"))]}, late))
	return true


## The game this batch went out on is gone (it disconnected, or another game took the channel): a write it had not
## answered is unknown, and the writes never sent are reported as not sent, so none of them reaches the next game.
func _on_ready_lost(peer: Object, why: String) -> void:
	if _on_ready_peer == null or _on_ready_peer != peer:
		return
	_on_ready_peer = null
	if not _on_ready_waiting.is_empty():
		var d: Dictionary = _on_ready_waiting["item"]
		_on_ready_waiting = {}
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "unknown": true, "error": "%s before it answered this write: whether it landed is unknown" % why}))
	_on_ready_not_sent("not sent: " + why)


## Report every write still queued as never sent, and empty the queue.
func _on_ready_not_sent(why: String) -> void:
	for d in on_ready_queue:
		on_ready_report.append(_on_ready_entry(d, {"ok": false, "error": why}))
	on_ready_queue = []


## Whether the value read back is the one written: 1 yes, 0 no, -1 cannot tell. `want` is what the batch sent (any
## spelling the game's write takes), `got` what the game's get answered (mcp_runtime.gd _safe: a number, a bool, text, or
## a struct as str() prints it, "(0, 6, 11)" or "[P: (0.0, 0.0), S: (10.0, 10.0)]"). The print is read back as each type
## it can be, and `want` goes through the coercion the game's write itself uses (core/callargs.gd) toward that type, so
## "Vector3(0, 6, 11)", [0, 6, 11] and "0 6 11" all match "(0, 6, 11)", and a value that coercion refuses could not have
## been written, so it does not match. Pure.
static func read_back_verdict(want: Variant, got: Variant) -> int:
	match typeof(got):
		TYPE_NIL:
			return 1 if want == null else -1
		TYPE_BOOL:
			var b: Dictionary = CallArgs.coerce(want, TYPE_BOOL)
			return 1 if bool(b.get("ok", false)) and bool(b["value"]) == bool(got) else 0
		TYPE_INT, TYPE_FLOAT:
			var n: Dictionary = CallArgs.coerce(want, TYPE_FLOAT)
			return 1 if bool(n.get("ok", false)) and is_equal_approx(float(n["value"]), float(got)) else 0
		TYPE_STRING:
			var text := str(got)
			if want is String and str(want) == text:
				return 1
			if text.begins_with("<") and text.ends_with(">") and text.contains("#"):
				return -1  # an object prints as <Class#id>: no written value compares with that
			var held := _printed_values(text)
			for v in held:
				var b: Dictionary = CallArgs.coerce(want, typeof(v))
				if bool(b.get("ok", false)):
					return 1 if (v == b["value"] if v is Rect2i else v.is_equal_approx(b["value"])) else 0
			if not held.is_empty():
				return 0  # no type the print can be takes the value written, so the game's write refused it too
			if text.begins_with("[") and text.contains(": ("):
				return -1  # a struct print this cannot read back (a Projection, or a number printed as inf)
			if want == null:
				return 1 if text.is_empty() else 0  # null clears a NodePath, which reads back ""
			for t in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]:  # &"walk" and ^"A/B" store walk and A/B
				var s: Dictionary = CallArgs.coerce(want, t)
				if bool(s.get("ok", false)) and str(s["value"]) == text:
					return 1
			return 0
	return -1


## What str() printed `text` from, read back as each type it can be: "(0.0, 6.0, 11.0)" is a vector or a color by how
## many numbers it holds, and "[P: (0.0, 0.0), S: (10.0, 10.0)]" a Rect2 (or Rect2i), an AABB, a Plane, a Transform2D,
## a Basis or a Transform3D by its keys and numbers (str() prints a matrix by its columns, the order these constructors
## take); [] for any other text.
static func _printed_values(text: String) -> Array:
	var bracket := text.begins_with("[") and text.ends_with("]")
	if not bracket and not (text.begins_with("(") and text.ends_with(")")):
		return []
	var keys := ""
	var n: Array = []
	for tok in text.substr(1, text.length() - 2).replace("(", " ").replace(")", " ").replace(",", " ").split(" ", false):
		if bracket and tok.ends_with(":"):
			keys += tok.trim_suffix(":")
		elif tok.is_valid_float():
			n.append(tok.to_float())
		else:
			return []
	if bracket and keys.is_empty():
		return []  # "[1, 2]" is a list, not a struct
	match keys + str(n.size()):
		"2":
			return [Vector2(n[0], n[1])]
		"3":
			return [Vector3(n[0], n[1], n[2])]
		"4":
			return [Color(n[0], n[1], n[2], n[3]), Vector4(n[0], n[1], n[2], n[3]), Quaternion(n[0], n[1], n[2], n[3])]
		"PS4":
			return [Rect2(n[0], n[1], n[2], n[3]), Rect2i(int(n[0]), int(n[1]), int(n[2]), int(n[3]))]
		"PS6":
			return [AABB(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]))]
		"ND4":
			return [Plane(Vector3(n[0], n[1], n[2]), n[3])]
		"XYO6":
			return [Transform2D(Vector2(n[0], n[1]), Vector2(n[2], n[3]), Vector2(n[4], n[5]))]
		"XYZ9":
			return [Basis(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8]))]
		"XYZO12":
			return [Transform3D(Vector3(n[0], n[1], n[2]), Vector3(n[3], n[4], n[5]), Vector3(n[6], n[7], n[8]), Vector3(n[9], n[10], n[11]))]
	return []


static func _shown(v: Variant) -> String:
	return str(v).left(120)


static func _on_ready_target(d: Dictionary) -> String:
	return str(d.get("path", d.get("name", d.get("class", "?"))))


## Copy an on_ready entry's target (a path or a live selector) into a command.
static func _on_ready_target_into(cmd: Dictionary, d: Dictionary) -> void:
	for k in ["path", "class", "name", "text", "nth", "under"]:
		if d.has(k):
			cmd[k] = d[k]


func _on_ready_entry(d: Dictionary, r: Dictionary, late_ms: int = -1) -> Dictionary:
	var entry := {
		"target": _on_ready_target(d),
		"property": str(d.get("property", "")),
		"ok": bool(r.get("ok", false)),
	}
	if r.has("after"):
		entry["after"] = r.get("after")
	if r.has("error"):
		entry["error"] = str(r.get("error"))
	if bool(r.get("unknown", false)):
		entry["unknown"] = true
	if late_ms >= 0:
		entry["late_ms"] = late_ms
	return entry


## Queue writes to apply as soon as the next game connects, and clear any earlier report.
func queue_on_ready(items: Array) -> void:
	on_ready_queue = items.duplicate()
	on_ready_report = []
	_on_ready_waiting = {}
	_on_ready_peer = null
	_on_ready_deadline = Time.get_ticks_msec() + ON_READY_GRACE_MS


## Every queued write has been tried and none is waiting for the game's answer.
func on_ready_settled() -> bool:
	return on_ready_queue.is_empty() and _on_ready_waiting.is_empty()


## Report for the last on_ready batch, or {} if there was none. Non-destructive: several
## tools (wait_until, get_play_state) may surface it. failed counts the writes that did not land
## (refused, read back wrong, never sent); unknown, when there is one, those whose outcome nobody
## can say; waiting names the write the game has not answered yet.
func on_ready_status() -> Dictionary:
	if on_ready_report.is_empty() and on_ready_settled():
		return {}
	var failed := 0
	var unknown := 0
	for e in on_ready_report:
		if bool((e as Dictionary).get("unknown", false)):
			unknown += 1
		elif not bool((e as Dictionary).get("ok", false)):
			failed += 1
	var out := {
		"applied": on_ready_report,
		"pending": on_ready_queue.size() + (0 if _on_ready_waiting.is_empty() else 1),
		"failed": failed,
	}
	if unknown > 0:
		out["unknown"] = unknown
	if not _on_ready_waiting.is_empty():
		var d: Dictionary = _on_ready_waiting["item"]
		out["waiting"] = {"target": _on_ready_target(d), "property": str(d.get("property", "")), "waited_ms": Time.get_ticks_msec() - int(_on_ready_waiting["sent"])}
	return out


## "" while no write waits for the game's answer, else the sentence wait_until's "not yet" carries.
func on_ready_wait_note() -> String:
	if _on_ready_waiting.is_empty():
		return ""
	var d: Dictionary = _on_ready_waiting["item"]
	var more := "" if on_ready_queue.is_empty() else " (%d more queued behind it)" % on_ready_queue.size()
	return "the game is connected, and on_ready write %s.%s was sent %.1f s ago and is not answered yet%s: a busy game answers late, and the report then says how late" % [
		_on_ready_target(d), str(d.get("property", "")), float(Time.get_ticks_msec() - int(_on_ready_waiting["sent"])) / 1000.0, more]


## Read the pending peer's first line ({"hello": <token>}) and promote or drop it. The
## hello is consumed HERE either way, so it can never surface as a stray reply inside
## send_command's line reads.
func _pump_pending() -> void:
	if _pending == null:
		return
	_pending.poll()
	var st := _pending.get_status()
	if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
		_pending = null
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		if Time.get_ticks_msec() - _pending_t0 > 3000:
			_pending.disconnect_from_host()
			_pending = null
		return
	var avail := _pending.get_available_bytes()
	if avail > 0:
		var res: Array = _pending.get_partial_data(avail)
		if res[0] == OK:
			_pending_buf.append_array(res[1])
	var nl := _pending_buf.find(10)
	if nl == -1:
		# No hello line yet. Auth off: promote a silent peer after a short grace so an
		# OLDER runtime (predates the handshake) still connects. Auth on: silence past
		# the window is a strike-out — the real game sends hello immediately.
		if Time.get_ticks_msec() - _pending_t0 > 1500:
			if expected_token.is_empty():
				_promote()
			else:
				_pending.disconnect_from_host()
				_pending = null
		return
	var line := _pending_buf.slice(0, nl).get_string_from_utf8()
	_pending_buf = _pending_buf.slice(nl + 1)
	var parsed: Variant = JSON.parse_string(line)
	var has_hello: bool = parsed is Dictionary and (parsed as Dictionary).has("hello")
	if expected_token.is_empty():
		_promote()  # hello (or junk) consumed; nothing to verify with auth off
		return
	if has_hello and _secure_equals(str((parsed as Dictionary).get("hello", "")), expected_token):
		_promote()
		return
	push_warning("[beckett] runtime channel: rejected a peer with a missing/invalid handshake token")
	_pending.disconnect_from_host()
	_pending = null


func _promote() -> void:
	if _peer != null:
		_on_ready_lost(_peer, "another game connected")
	if not on_ready_queue.is_empty() and _on_ready_peer == null:
		_on_ready_peer = _pending  # the first game after play_scene takes the batch: a drop before any write is tried reports it, never hands it on
	_peer = _pending
	_pending = null
	_pending_buf = PackedByteArray()
	# Restart the on_ready grace HERE, not at queue time: the launch itself can eat seconds,
	# and the window is meant to cover the scene finishing its spawn, not the game booting.
	if not on_ready_queue.is_empty():
		_on_ready_deadline = Time.get_ticks_msec() + ON_READY_GRACE_MS


## Constant-time compare (mirrors mcp_server._secure_equals; kept local so the bridge
## stays dependency-free).
static func _secure_equals(a: String, b: String) -> bool:
	var ab := a.to_utf8_buffer()
	var bb := b.to_utf8_buffer()
	var diff := ab.size() ^ bb.size()
	for i in mini(ab.size(), bb.size()):
		diff |= ab[i] ^ bb[i]
	return diff == 0


func is_game_connected() -> bool:
	if _peer == null:
		return false
	_peer.poll()
	return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


# --- Game workspace embedding (v1.13 S11) ------------------------------------------------
# Since 4.4 the editor can run the game INSIDE itself (the Game workspace) instead of in its
# own OS window, and embedding on play is the DEFAULT — so this is the common case, not an
# exotic one. It decides whether a window-mode assert can ever pass, and it is the first half
# of the Suspend diagnosis in send_command below.
#
# The engine resolves the mode as TWO booleans (embed_on_play / make_floating_on_play), so we
# report the same shape: `mode` is "embedded" whenever the game runs inside the editor, and
# main-window-vs-floating goes in `placement` (a floating Game workspace is still embedded).
# Every read is reflection-guarded, and a read we cannot actually perform degrades to
# mode "unknown" with a `source` naming what was missing — a probe that guesses is worse
# than no probe.
const EMBED_MODE_SETTING := "run/window_placement/game_embed_mode"

## What holds in BOTH modes, and what only bites in the embedded one. Beckett captures the
## game's own viewport and pushes events in-process, so nothing it does goes through the OS
## window — which is why embedding costs the agent nothing except these three caveats.
const GAME_VIEW_NOTE := ("capture and input work in both modes (Beckett reads the game's own"
	+ " viewport and injects events in-process, never through the OS window). Embedded"
	+ " caveats: the Game workspace's Suspend button stops the whole SceneTree, so every"
	+ " runtime call times out until you resume; the game cannot go fullscreen or move/resize"
	+ " its window; and frames come back sized to the workspace, not to the project resolution.")


## Is the game played inside the editor, and how do we know? Static so `doctor` can mount it
## without a live bridge instance. Never throws: every failure path returns a stated "unknown".
static func game_view_state() -> Dictionary:
	# No editor, no EditorSettings — the unit suite and any exported build land here. Say so
	# instead of inventing a mode from whatever display server a headless run happens to have.
	if not Engine.is_editor_hint():
		return _game_view("unknown", "unknown", "not running inside the editor, so the Game workspace settings are unreadable")

	# The engine applies the mode only when the display server can embed windows at all, so
	# ask it the same question first. FEATURE_WINDOW_EMBEDDING is 4.4+ and is reached by
	# reflection so that naming it can never parse-fail an older engine. Probed as a BOUND
	# ClassDB constant on 4.4.1 and 4.7 (both = 29) before this code was written.
	if not ClassDB.class_has_integer_constant("DisplayServer", "FEATURE_WINDOW_EMBEDDING"):
		return _game_view("windowed", "own_window",
			"this Godot build exposes no DisplayServer.FEATURE_WINDOW_EMBEDDING, so it cannot embed the game at all")
	if not DisplayServer.has_feature(ClassDB.class_get_integer_constant("DisplayServer", "FEATURE_WINDOW_EMBEDDING")):
		return _game_view("windowed", "own_window",
			"this display server (%s) does not advertise window embedding, so the game always runs in its own window" % DisplayServer.get_name())

	var es: Object = EditorInterface.get_editor_settings()
	if es == null or not es.has_method("has_setting") or not bool(es.call("has_setting", EMBED_MODE_SETTING)):
		return _game_view("unknown", "unknown", "editor setting %s is not present on this build" % EMBED_MODE_SETTING)
	return _game_view_from_setting(es, int(es.call("get_setting", EMBED_MODE_SETTING)))


## The setting -> {mode, placement} mapping, split from the reads above so the unit suite can
## pin all four documented values (and an unrecognised fifth) against a stub, with no editor.
## Values are inlined ints, never engine enums: the hint string is
## "Disabled:-1,Use Per-Project Configuration:0,Embed Game:1,Make Game Workspace Floating:2"
## in the shipped 4.4.1 AND 4.7 binaries. Anything outside that set belongs to a build we have
## not seen (the Android editor substitutes its own hint set), so it reads as unknown.
static func _game_view_from_setting(es: Object, mode: int) -> Dictionary:
	var where := "Editor Settings > Run > Window Placement > Game Embed Mode"
	# The labels below are the DESKTOP hint set. The Android editor rebinds the same integers
	# to its own ("Disabled:-1,Auto (based on screen size):0,Enabled:1", and "Disabled:-1"
	# alone under xr_editor), so 0 there means "auto by screen size", NOT "read this project's
	# metadata" — reading it with the desktop labels would print a confident lie in the one
	# field whose whole job is to be checkable. Only -1 carries across unchanged.
	if mode != -1 and OS.has_feature("android"):
		return _game_view("unknown", "unknown",
			"%s = %d on the Android editor, which rebinds these values to its own hint set (Auto by screen size / Enabled); treat as unknown" % [where, mode])
	match mode:
		-1:
			return _game_view("windowed", "own_window", "%s = Disabled" % where)
		1:
			return _game_view("embedded", "main", "%s = Embed Game" % where)
		2:
			return _game_view("embedded", "floating", "%s = Make Game Workspace Floating" % where)
		0:
			return _game_view_per_project(es, where)
	return _game_view("unknown", "unknown",
		"%s = %d, a value this build introduced; treat as unknown" % [where, mode])


## Mode 0 ("Use Per-Project Configuration") is the shipped default and the case that matters:
## the two booleans come from this project's Game workspace metadata, defaulting to embedded.
static func _game_view_per_project(es: Object, where: String) -> Dictionary:
	if not es.has_method("get_project_metadata"):
		return _game_view("unknown", "unknown",
			"%s = Use Per-Project Configuration, but EditorSettings on this build has no get_project_metadata to resolve it with" % where)
	var embed := _game_view_flag(es, "embed_on_play")
	var floating := _game_view_flag(es, "make_floating_on_play")
	var src := "%s = Use Per-Project Configuration, resolved from this project's Game workspace metadata: embed_on_play=%s (%s), make_floating_on_play=%s (%s)" % [
		where, str(bool(embed["value"])).to_lower(), str(embed["origin"]),
		str(bool(floating["value"])).to_lower(), str(floating["origin"]),
	]
	if not bool(embed["value"]):
		return _game_view("windowed", "own_window", src)
	return _game_view("embedded", "floating" if bool(floating["value"]) else "main", src)


## One game_view metadata flag, plus whether it was actually STORED. get_project_metadata
## cannot report presence, so ask twice with opposite defaults: an absent key hands back
## whichever default it was given, a stored one answers itself both times. Worth the second
## read — no real project stores these (checked three on this machine), so without it every
## source line would claim a stored setting the user never touched.
static func _game_view_flag(es: Object, key: String) -> Dictionary:
	var with_true := bool(es.call("get_project_metadata", "game_view", key, true))
	var with_false := bool(es.call("get_project_metadata", "game_view", key, false))
	if with_true == with_false:
		return {"value": with_true, "origin": "set in this project"}
	# Absent, which is the normal case: no project on this machine stores either key. Both
	# flags default to TRUE in the engine's own per-project read, so an untouched project
	# embeds on play — which is exactly why this probe exists. That default is read off the
	# engine's behaviour, not off anything we can measure from here, so `origin` says so out
	# loud: a user who sees the wrong placement knows which assumption to blame.
	return {"value": true, "origin": "engine default, never set here"}


static func _game_view(mode: String, placement: String, source: String) -> Dictionary:
	return {"mode": mode, "placement": placement, "source": source, "note": GAME_VIEW_NOTE}


# --- which commands this edition may send (v1.16) --------------------------------------------
# The game side of the channel understands the whole command set, drive commands included, in every edition: it is one
# file. What keeps the free edition from driving the game is that its OWN tools never send those commands. This is the
# second lock behind that: whatever reaches send_command in a Lite install, only the commands Lite itself sends go
# through, so a route to this object that nobody has found yet is still a route to the see-only commands.
#
# The sentinel is the one mcp_server.gd uses to cap the effort dial (tools/runtime_tools.gd, which pack.ps1 -Lite
# removes). It is repeated here, not preloaded, because the server preloads this file; a unit test holds the two equal.
const FULL_SENTINEL := "res://addons/beckett/tools/runtime_tools.gd"

## Every command the editor side of a Lite install sends, and the one the game answers to be sure it is there (ping):
## the see tools (screenshot, ui_snapshot, tree, game_state, find, render_probe, debug_draw, get, exists, perf, logs),
## describe_object's look at the running game, quiet_state for get_play_state, and the one write Lite makes, the
## play_scene on_ready batch (set). A unit test reads the core tool modules and fails when one of them sends a command
## that is not on this list, or when this list names one that no core module sends.
const LITE_COMMANDS := ["ping", "describe", "find", "quiet_state", "screenshot", "ui_snapshot", "tree", "game_state",
	"render_probe", "debug_draw", "get", "exists", "perf", "logs", "set"]

## null asks the install (is the Full sentinel there?); the unit suite sets true or false to stand in for an edition.
var lite: Variant = null
var _lite_seen := -1  # the install's answer, asked once: an edition does not change while the editor runs


## Is this the free edition? Same test as mcp_server.is_lite(), made on the install so no wiring can get it wrong.
func is_lite_edition() -> bool:
	if lite != null:
		return bool(lite)
	if _lite_seen == -1:
		_lite_seen = 0 if ResourceLoader.exists(FULL_SENTINEL) else 1
	return _lite_seen == 1


## "" when the edition may send `command`, else the reason in plain words. Pure.
static func command_refusal(command: String, lite_edition: bool) -> String:
	if not lite_edition or LITE_COMMANDS.has(command):
		return ""
	return "the '%s' command belongs to the Full edition: Lite sees the running game but does not drive it (input, clicks, calls, time control and the rest of the drive layer are Full features)." % command.left(40)


## Replies come back in the engine's binary form and are rendered once, here, for every caller (1.17): core/typed_json.gd.
const TypedJson := preload("res://addons/beckett/core/typed_json.gd")


## Send one command to the running game and block (bounded) for its JSON-line reply.
## Each command carries a sequence id the game echoes back. A LATE reply from an earlier
## command that timed out (its handler errored or blocked past the deadline) lands in the
## socket with the OLD id — we skip it and keep reading for the CURRENT id, instead of
## mis-returning it and leaving every subsequent call to read one stale line behind (the
## desync that used to wedge the channel until stop_scene).
## A command that went out and got no answer says so (1.17): timeout:true when the game did not answer in time (a busy
## game still runs it when it catches up), delivered:true when it was paused in the debugger by the end of the wait. Status
## polls read timeout as "not yet", the on_ready drain parks the write, and with_kind words what it may still do.
func send_command(cmd: Dictionary, timeout_ms: int = 4000) -> Dictionary:
	# First, before anything is looked at or sent: a command outside the edition's set never reaches the game, whether
	# or not one is connected.
	var barred := command_refusal(str(cmd.get("cmd", "")), is_lite_edition())
	if not barred.is_empty():
		return {"ok": false, "error": barred}
	# A game parked in the editor's debugger cannot answer until someone presses Continue: say so now. Waiting out
	# the timeout teaches nothing, and the command would sit unread in the socket and run, late, the moment the
	# game resumes (a click or a property write nobody is waiting for any more). A game that broke before its
	# runtime could say hello is not connected at all, and "game not running" would send the agent to restart it.
	var paused := break_text()
	if not paused.is_empty():
		return {"ok": false, "error": paused}
	if not is_game_connected():
		return {"ok": false, "error": "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."}
	_seq += 1
	var id := _seq
	var tagged := cmd.duplicate()
	tagged["_id"] = id
	# Ask for the reply in the engine's binary form (1.17), so an int and a vector come back as what they are. A game that
	# predates it ignores the flag and answers in JSON, which decode_reply passes through as it is.
	tagged[TypedJson.ASK] = TypedJson.VERSION
	_peer.put_data((JSON.stringify(tagged) + "\n").to_utf8_buffer())

	var buf := PackedByteArray()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return {"ok": false, "error": "runtime disconnected mid-request"}
		var avail := _peer.get_available_bytes()
		if avail > 0:
			var res: Array = _peer.get_partial_data(avail)
			if res[0] == OK:
				buf.append_array(res[1])
				while true:
					var nl := buf.find(10)
					if nl == -1:
						break
					var s := buf.slice(0, nl).get_string_from_utf8()
					buf = buf.slice(nl + 1)
					var parsed: Variant = JSON.parse_string(s)
					# A late handshake hello is NOT a reply: a heavy game's first _process can
					# run only after the bridge's silent-peer grace already promoted it (scene
					# load stalls >1.5 s), so its {"hello": ...} lands here — and, carrying no
					# _id, it would DEFAULT-MATCH below and corrupt the first command of the
					# session (found on rpg-village by the v1.10 UI e2e). Skip it explicitly.
					if parsed is Dictionary and (parsed as Dictionary).has("hello"):
						continue
					# Match on id; a reply without _id (older game build) defaults to a
					# match so the bridge keeps working across an un-synced runtime.
					if parsed is Dictionary and int((parsed as Dictionary).get("_id", id)) == id:
						return TypedJson.decode_reply(parsed)
					# stale reply (old id) or malformed line → drop and keep reading
		OS.delay_msec(4)
	# A break can begin while this call waits. The editor itself only learns of it a frame after it happens and
	# this call has held the main thread the whole time, so this read is usually still "no" and the NEXT call is
	# the one that answers at once; it costs nothing, and it is right whenever the state did move.
	paused = break_text()
	if not paused.is_empty():
		return {"ok": false, "error": paused, "delivered": true}  # sent before the pause: it runs when the game resumes
	return {"ok": false, "error": _timeout_error(timeout_ms), "timeout": true}  # sent: a busy game still runs it later


# --- The game is parked in the editor's debugger (v1.16) ---------------------------------------
# A script error in an editor-launched game breaks into the debugger; the game's main thread then waits there
# for Continue, so nothing on this channel is answered. See core/break_watch.gd for how it is detected.

## The phrase every "game is parked in the debugger" answer (break_message) contains and no other answer does,
## the timeout one included. playtest_tools.gd looks for it in a command's error: a break is a run that could
## not be judged, never a failed assert, and a batch that hits one stops instead of retrying.
const BREAK_MARK := "paused in the editor's debugger"

## Logger-based capture (game_logs, the error and its backtrace) and the --ignore-error-breaks launch flag are
## 4.5+. Engine.get_version_info()["hex"] of 4.5.0.
const LOGGER_SINCE_HEX := 0x040500


## The debugger's break state as the break watch reports it: {} when no game session is paused (or there is no
## watch at all), else {broken, sessions, broken_sessions, can_debug} (break_watch.gd state_of).
func debugger_break() -> Dictionary:
	if break_watch == null or not is_instance_valid(break_watch) or not break_watch.has_method("break_state"):
		return {}
	var state: Variant = break_watch.call("break_state")
	return state if state is Dictionary else {}


## "" when the game is not paused in the debugger, else break_message for the editor this runs in (its Game
## workspace mode and its engine version read here). What send_command answers with, and get_play_state shows.
func break_text() -> String:
	var brk := debugger_break()
	if brk.is_empty():
		return ""
	return break_message(brk, game_view_state(), int(Engine.get_version_info().get("hex", 0)), is_game_connected())


## The sentence an agent reads when the game is paused in the debugger. A user report of this bug described
## an agent that, after each bare timeout, abandoned the runtime tools and redid the work by running the game
## headless outside the editor, where no debugger is attached and the error just scrolls past. So it says what
## is going on, that Beckett is still connected, what NOT to do, and the ways forward: Continue and read the
## log (4.5+ captured the error before the break, so game_logs has it once the game resumes), or stop, fix and
## play again. Pure, so the unit suite can pin it for every case: a script error vs a breakpoint, 4.5+ vs
## older, embedded vs windowed, connected or not. `brk` is break_state()'s dictionary, `gv` game_view_state()'s.
## `connected` false is a game that broke before its runtime said hello (an error in the main scene's _ready):
## with the handshake on, the editor drops a peer that stays silent, so the game never shows as connected at all.
static func break_message(brk: Dictionary, gv: Dictionary, version_hex: int, connected: bool = true) -> String:
	var at_error := not bool(brk.get("can_debug", false))
	var msg := "game %s at %s: " % [BREAK_MARK, "a script error" if at_error else "a breakpoint (or the debugger's Pause button)"]
	if connected:
		msg += "Beckett is still connected, but the game is parked inside the debugger, so it cannot answer runtime calls until it resumes."
	else:
		msg += "it stopped before it could connect to Beckett and is parked inside the debugger, so it cannot connect until it resumes."
	msg += " Do not re-run the game outside the editor to get around this."
	var sessions := int(brk.get("sessions", 1))
	if sessions > 1:
		msg += " %d of %d running game instances are paused." % [int(brk.get("broken_sessions", 1)), sessions]
	var then_read := "then read game_logs" if connected else "then wait_until condition=game_connected and read game_logs"
	if at_error and version_hex >= LOGGER_SINCE_HEX:
		msg += " Next step: ask the user to press Continue (F12) in the editor's Debugger panel, %s (this Godot version already captured the error and its backtrace); or call stop_scene, fix the script and play_scene again." % then_read
	elif at_error:
		msg += " Next step: ask the user to read the error in the editor's Debugger panel (this Godot version does not log it while the debugger is attached, so game_logs cannot show it) and press Continue (F12) there; or call stop_scene, fix the script and play_scene again."
	else:
		msg += " Next step: ask the user to press Continue (F12) in the editor's Debugger panel, or call stop_scene to end the run."
	if str(gv.get("mode", "")) == "embedded":
		msg += " Continue is on the Debugger panel's toolbar in the bottom panel; the Game workspace's Suspend button is a different thing and does not resume this."
	return msg


## v1.13 S12: an embedded game has one failure mode that looks exactly like a dead channel.
## The Game workspace's Suspend button suspends the whole SceneTree, and the runtime autoload's
## PROCESS_MODE_ALWAYS (mcp_runtime.gd) only survives get_tree().paused, not suspension — so
## the game stops answering, every runtime call times out, and nothing else is visibly wrong.
## Both placements are embedded, so both get the line.
static func _timeout_error(timeout_ms: int) -> String:
	return _timeout_message(timeout_ms, game_view_state())


## The timeout answer when the game is NOT known to be paused in the debugger (a known pause is break_message's).
## Split from the probe so the unit suite can pin the sentence the agent actually reads:
## the embedded branch only fires in a real editor with a real Game workspace, which no
## headless check can stage. The debugger comes first because it is the likelier cause, and because it is the one
## that sent an agent off to the wrong fix (the Suspend button) before 1.16: a break that begins while a call
## waits is only visible to the editor a frame later, so this first timeout cannot name it, but get_play_state can.
static func _timeout_message(timeout_ms: int, gv: Dictionary) -> String:
	var msg := ("runtime timeout after %d ms: the game did not answer in time. If it just hit a script error or a breakpoint it is stopped in the editor's debugger,"
		+ " which Beckett learns of a frame after it happens: call get_play_state (it reports debugger_break and the next step).") % timeout_ms
	if str(gv.get("mode", "")) == "embedded":
		msg += (" If that says false: the game is running EMBEDDED in the editor's Game workspace (placement: %s),"
			+ " so the likeliest cause is its Suspend button: suspending stops the entire SceneTree,"
			+ " this channel included, and every runtime call then times out with no other symptom."
			+ " Press Suspend again (or Next Frame) to resume it. This is NOT time_control op=freeze (Full),"
			+ " which pauses the game and leaves the channel answering.") % str(gv.get("placement", "?"))
	else:
		msg += " If that says false, the game is busy or hung."
	return msg


# --- what a command that got no answer may still do (1.17) ----------------------------------------
# The game reads this channel once a frame and answers in order, so a busy game (a long frame, a scene loading) holds a
# command past any timeout and still runs it when it catches up. On 2026-10-12 a write reported as "runtime timeout
# ... the game stopped answering" had landed, and an agent told that sends a call or an input again, which then runs
# twice. A call site that knows what its command does opts in (with_kind); playtest's own sends and every call that
# does not say keep the plain answer.
const KIND_CHANGE := "change"  # changes the game: a write, a call, input, a click, time control, a ui_do flow, eval
const KIND_READ := "read"  # only reads


## r with the sentence its kind adds when the command went out and no answer came back: a timeout, or a debugger
## break that began while the call waited (send_command's timeout and delivered keys). Any other answer comes back as
## it was. Pure.
static func with_kind(r: Dictionary, kind: String) -> Dictionary:
	var late := bool(r.get("timeout", false))
	if not (late or bool(r.get("delivered", false))) or not (r.get("error") is String):
		return r
	var out := r.duplicate()
	out["error"] = str(r["error"]) + kind_tail(kind, not late)
	return out


## The sentence itself; `paused` is a break that began after the send, else the game did not answer in time.
static func kind_tail(kind: String, paused: bool) -> String:
	if kind == KIND_READ:
		return " This command only reads, so nothing changed." + ("" if paused else " Ask again.")
	if paused:
		return " The command was delivered before the pause and runs when the game resumes: read the state back before you send it again."
	return " The command was delivered, and the game may still run it when it catches up: read the state back before you send it again."
