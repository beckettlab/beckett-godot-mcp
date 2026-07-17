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

var _tcp := TCPServer.new()
var _peer: StreamPeerTCP = null
var _pending: StreamPeerTCP = null      # connected, hello not yet verified
var _pending_buf := PackedByteArray()
var _pending_t0 := 0
var _seq: int = 0


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
			_peer = null


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
	_peer = _pending
	_pending = null
	_pending_buf = PackedByteArray()


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


## Send one command to the running game and block (bounded) for its JSON-line reply.
## Each command carries a sequence id the game echoes back. A LATE reply from an earlier
## command that timed out (its handler errored or blocked past the deadline) lands in the
## socket with the OLD id — we skip it and keep reading for the CURRENT id, instead of
## mis-returning it and leaving every subsequent call to read one stale line behind (the
## desync that used to wedge the channel until stop_scene).
func send_command(cmd: Dictionary, timeout_ms: int = 4000) -> Dictionary:
	if not is_game_connected():
		return {"ok": false, "error": "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."}
	_seq += 1
	var id := _seq
	var tagged := cmd.duplicate()
	tagged["_id"] = id
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
						return parsed
					# stale reply (old id) or malformed line → drop and keep reading
		OS.delay_msec(4)
	return {"ok": false, "error": "runtime timeout after %d ms" % timeout_ms}
