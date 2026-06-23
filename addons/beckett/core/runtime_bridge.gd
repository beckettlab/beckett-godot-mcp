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

var _tcp := TCPServer.new()
var _peer: StreamPeerTCP = null
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
	if _tcp.is_listening():
		_tcp.stop()


func _process(_delta: float) -> void:
	poll_once()


## Accept a pending game connection and refresh peer status. Exposed so a blocking
## tool (wait_until) can pump the bridge while it holds the main thread — otherwise the
## game could never connect during the wait.
func poll_once() -> void:
	if not running:
		return
	if _tcp.is_connection_available():
		var p := _tcp.take_connection()
		if p != null:
			p.set_no_delay(true)
			_peer = p  # newest play session wins
	if _peer != null:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			_peer = null


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
					# Match on id; a reply without _id (older game build) defaults to a
					# match so the bridge keeps working across an un-synced runtime.
					if parsed is Dictionary and int((parsed as Dictionary).get("_id", id)) == id:
						return parsed
					# stale reply (old id) or malformed line → drop and keep reading
		OS.delay_msec(4)
	return {"ok": false, "error": "runtime timeout after %d ms" % timeout_ms}
