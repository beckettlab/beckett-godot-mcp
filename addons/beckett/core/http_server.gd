@tool
extends Node
class_name BeckettHttpServer

## Zero-sidecar transport (D1). A minimal HTTP/1.1 server hand-rolled on TCPServer +
## StreamPeerTCP, polled on the editor main thread in _process — so request handling
## happens exactly where the editor API is safe to touch (no cross-thread marshalling).
##
## Connections are handled one-request-then-close (Connection: close). Each MCP client
## message is its own POST, so keep-alive buys nothing and costs state.
##
## Exception: a GET whose response carries {"sse": true} is upgraded to a long-lived
## Server-Sent-Events stream (the Streamable-HTTP server->client channel). SSE peers are
## kept open for server-initiated notifications (sse_broadcast) — e.g.
## notifications/tools/list_changed when the effort dial moves — with a comment
## heartbeat so idle streams aren't reaped by client timeouts.

signal logged(text: String)

## Set by the owner: func(req: Dictionary) -> Dictionary
##   req  = {method, path, headers (lowercased keys), body}
##   resp = {status:int, headers:Dictionary, body:String}
var request_handler: Callable

var running: bool = false
var port: int = 0

const _HEADER_LIMIT := 64 * 1024
const _BODY_LIMIT := 16 * 1024 * 1024

# Editor responsiveness: when unfocused, the editor raises its main-loop sleep
# (interface/editor/unfocused_low_processor_mode_sleep_usec, default 50000+ µs) —
# exactly the situation when an agent drives it from a terminal. Every request then
# pays multiple slowed ticks (accept → read → respond). While traffic is active we
# clamp the sleep down to the focused-editor default; once idle we stop touching it
# and the editor re-asserts its own value on the next focus change.
const _BOOST_SLEEP_USEC := 6900
const _BOOST_LINGER_MSEC := 10_000

const _SSE_HEARTBEAT_MSEC := 15_000  # comment ping cadence on idle event streams

var _tcp := TCPServer.new()
var _clients: Array[Dictionary] = []  # [{peer:StreamPeerTCP, buf:PackedByteArray, age:int, hdr_end:int, scan:int}]
var _sse_peers: Array[StreamPeerTCP] = []  # long-lived GET event streams
var _last_activity_msec: int = -1_000_000
var _last_heartbeat_msec: int = 0
# Re-entrancy guard. A request handler can pump the editor main loop (e.g.
# EditorInterface.save_scene() shows a progress dialog that runs Main::iteration),
# which re-enters _process. Without this the nested tick re-dispatches the SAME
# in-flight request (still in _clients until _try_handle returns) → the handler
# recurses into itself until the stack overflows and the editor crashes ("Task 'save'
# already exists" on the 2nd save_scene). Nested ticks no-op; the outer one finishes.
var _in_process: bool = false


func start(p_port: int, bind_address: String = "127.0.0.1") -> int:
	stop()
	var err := _tcp.listen(p_port, bind_address)
	if err == OK:
		port = _tcp.get_local_port()
		running = true
	return err


func stop() -> void:
	running = false
	for c in _clients:
		var peer: StreamPeerTCP = c["peer"]
		if peer != null:
			peer.disconnect_from_host()
	_clients.clear()
	for p in _sse_peers:
		if p != null:
			p.disconnect_from_host()
	_sse_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	port = 0


func _process(_delta: float) -> void:
	if not running:
		return
	if _in_process:
		return
	_in_process = true

	_update_responsiveness()

	# Accept new connections.
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if peer != null:
			peer.set_no_delay(true)
			_clients.append({"peer": peer, "buf": PackedByteArray(), "age": 0, "hdr_end": -1, "scan": 0})
			_last_activity_msec = Time.get_ticks_msec()

	# Service existing connections.
	var keep: Array[Dictionary] = []
	for c in _clients:
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			continue  # drop
		if status != StreamPeerTCP.STATUS_CONNECTED:
			c["age"] = int(c["age"]) + 1
			if int(c["age"]) < 600:  # ~10s @60fps grace for connecting sockets
				keep.append(c)
			continue

		var avail := peer.get_available_bytes()
		if avail > 0:
			var res: Array = peer.get_partial_data(avail)
			if res[0] == OK:
				var buf: PackedByteArray = c["buf"]
				buf.append_array(res[1])
				c["buf"] = buf

		var verdict := _try_handle(c)
		if verdict == 0:  # incomplete — wait for more bytes
			c["age"] = int(c["age"]) + 1
			if int(c["age"]) < 1800:  # ~30s to finish a request
				keep.append(c)
		# verdict == -1 means handled (closed, or upgraded to SSE) → drop from this list
	_clients = keep

	_service_sse()
	_in_process = false


## While the server has live or recent traffic, keep the editor main loop ticking
## at its focused rate so request latency stays low even with the editor in the
## background. Clamp-down only — never raise; the editor re-owns the value on the
## next focus in/out after the linger window passes.
func _update_responsiveness() -> void:
	if _clients.is_empty() and Time.get_ticks_msec() - _last_activity_msec > _BOOST_LINGER_MSEC:
		return
	if OS.low_processor_usage_mode_sleep_usec > _BOOST_SLEEP_USEC:
		OS.low_processor_usage_mode_sleep_usec = _BOOST_SLEEP_USEC


## Returns 0 if the request is not fully received yet; -1 once handled & closed.
func _try_handle(c: Dictionary) -> int:
	var buf: PackedByteArray = c["buf"]
	# Find the end of the header block once, resuming the scan where the last tick
	# stopped (a fresh full scan per tick would be quadratic on chunked bodies).
	var sep := int(c.get("hdr_end", -1))
	if sep == -1:
		sep = _find_header_end(buf, maxi(0, int(c.get("scan", 0)) - 3))
		c["scan"] = maxi(0, buf.size() - 3)
		if sep == -1:
			if buf.size() > _HEADER_LIMIT:
				_respond(c["peer"], {"status": 431, "body": ""})
				return -1
			return 0
		c["hdr_end"] = sep

	var header_text := buf.slice(0, sep).get_string_from_utf8()
	var lines := header_text.split("\r\n", false)
	if lines.is_empty():
		_respond(c["peer"], {"status": 400, "body": ""})
		return -1

	var req_line := (lines[0] as String).split(" ", false)
	var method := req_line[0] if req_line.size() > 0 else ""
	var path := req_line[1] if req_line.size() > 1 else "/"

	var headers: Dictionary = {}
	for i in range(1, lines.size()):
		var ln: String = lines[i]
		var idx := ln.find(":")
		if idx > 0:
			headers[ln.substr(0, idx).strip_edges().to_lower()] = ln.substr(idx + 1).strip_edges()

	var content_length := int(headers.get("content-length", "0"))
	if content_length > _BODY_LIMIT:
		_respond(c["peer"], {"status": 413, "body": ""})
		return -1

	var body_start := sep + 4
	if buf.size() - body_start < content_length:
		return 0  # body still arriving

	var body := buf.slice(body_start, body_start + content_length).get_string_from_utf8()
	var req := {"method": method, "path": path, "headers": headers, "body": body}

	var resp: Dictionary = {"status": 503, "headers": {}, "body": ""}
	if request_handler.is_valid():
		resp = request_handler.call(req)
	if bool(resp.get("sse", false)):
		_upgrade_sse(c["peer"])
		return -1  # peer now lives in _sse_peers; just drop it from _clients
	_respond(c["peer"], resp)
	return -1


## Switch a connection to a long-lived Server-Sent-Events stream: send the SSE
## response head + an immediate comment frame (lets clients/tests confirm liveness
## without waiting for the first heartbeat), then park the peer in _sse_peers.
func _upgrade_sse(peer: StreamPeerTCP) -> void:
	_last_activity_msec = Time.get_ticks_msec()
	if peer == null:
		return
	var head := "HTTP/1.1 200 OK\r\n" \
		+ "Content-Type: text/event-stream\r\n" \
		+ "Cache-Control: no-cache\r\n" \
		+ "Connection: keep-alive\r\n\r\n"
	if peer.put_data(head.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()
		return
	peer.put_data(": connected\n\n".to_utf8_buffer())
	_sse_peers.append(peer)


## Send one JSON-RPC message (already stringified) to every open event stream.
## Returns how many peers it reached; dead peers are pruned.
func sse_broadcast(json_string: String) -> int:
	var frame := ("data: " + json_string + "\n\n").to_utf8_buffer()
	var keep: Array[StreamPeerTCP] = []
	var sent := 0
	for p in _sse_peers:
		p.poll()
		if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		if p.put_data(frame) == OK:
			sent += 1
			keep.append(p)
	_sse_peers = keep
	if sent > 0:
		_last_activity_msec = Time.get_ticks_msec()
	return sent


## Per-tick SSE upkeep: prune dead streams; heartbeat idle ones so client read
## timeouts and middleboxes don't reap them.
func _service_sse() -> void:
	if _sse_peers.is_empty():
		return
	var now := Time.get_ticks_msec()
	var hb := now - _last_heartbeat_msec >= _SSE_HEARTBEAT_MSEC
	if hb:
		_last_heartbeat_msec = now
	var keep: Array[StreamPeerTCP] = []
	for p in _sse_peers:
		p.poll()
		if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		if hb and p.put_data(": hb\n\n".to_utf8_buffer()) != OK:
			continue
		keep.append(p)
	_sse_peers = keep


func _respond(peer: StreamPeerTCP, resp: Dictionary) -> void:
	_last_activity_msec = Time.get_ticks_msec()  # keep the responsiveness boost alive
	if peer == null:
		return
	var status := int(resp.get("status", 200))
	var headers: Dictionary = resp.get("headers", {}).duplicate()
	var body := str(resp.get("body", ""))
	var body_bytes := body.to_utf8_buffer()

	if not headers.has("Content-Type") and body_bytes.size() > 0:
		headers["Content-Type"] = "application/json"
	headers["Content-Length"] = str(body_bytes.size())
	headers["Connection"] = "close"

	var head := "HTTP/1.1 %d %s\r\n" % [status, _reason(status)]
	for k in headers:
		head += "%s: %s\r\n" % [str(k), str(headers[k])]
	head += "\r\n"

	var out := head.to_utf8_buffer()
	out.append_array(body_bytes)
	peer.put_data(out)
	peer.disconnect_from_host()


static func _find_header_end(buf: PackedByteArray, from: int = 0) -> int:
	# locate the CRLF CRLF that ends the header block, scanning from `from`
	for i in range(from, buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


static func _reason(status: int) -> String:
	match status:
		200: return "OK"
		202: return "Accepted"
		400: return "Bad Request"
		401: return "Unauthorized"
		403: return "Forbidden"
		404: return "Not Found"
		405: return "Method Not Allowed"
		413: return "Payload Too Large"
		431: return "Request Header Fields Too Large"
		500: return "Internal Server Error"
		503: return "Service Unavailable"
		_: return "OK"
