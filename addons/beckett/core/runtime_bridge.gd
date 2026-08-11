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
	if not on_ready_queue.is_empty() and _peer != null:
		_drain_on_ready()


## Apply the queued play_scene on_ready writes. Runs a frame or more AFTER promotion, and
## re-queues targets that have not spawned yet until the grace window closes — a scene root
## exists the instant the game dials in, but its children may still be instantiating, and a
## write silently lost to "node not found" would be exactly the dishonesty we just removed.
func _drain_on_ready() -> void:
	var still: Array = []
	for item in on_ready_queue:
		var d: Dictionary = item
		var cmd := {"cmd": "set", "prop": str(d.get("property", "")), "value": d.get("value")}
		for k in ["path", "class", "name", "text", "nth", "under"]:
			if d.has(k):
				cmd[k] = d[k]
		var r: Dictionary = send_command(cmd)
		var err := str(r.get("error", ""))
		var not_there := err.contains("not found") or err.contains("no node matches")
		if not bool(r.get("ok", false)) and not_there and Time.get_ticks_msec() < _on_ready_deadline:
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


func _on_ready_entry(d: Dictionary, r: Dictionary) -> Dictionary:
	var entry := {
		"target": str(d.get("path", d.get("name", d.get("class", "?")))),
		"property": str(d.get("property", "")),
		"ok": bool(r.get("ok", false)),
	}
	if r.has("after"):
		entry["after"] = r.get("after")
	if r.has("error"):
		entry["error"] = str(r.get("error"))
	return entry


## Queue writes to apply as soon as the next game connects, and clear any earlier report.
func queue_on_ready(items: Array) -> void:
	on_ready_queue = items.duplicate()
	on_ready_report = []
	_on_ready_deadline = Time.get_ticks_msec() + ON_READY_GRACE_MS


## Report for the last on_ready batch, or {} if there was none. Non-destructive: several
## tools (wait_until, get_play_state) may surface it.
func on_ready_status() -> Dictionary:
	if on_ready_report.is_empty() and on_ready_queue.is_empty():
		return {}
	var failed := 0
	for e in on_ready_report:
		if not bool((e as Dictionary).get("ok", false)):
			failed += 1
	return {
		"applied": on_ready_report,
		"pending": on_ready_queue.size(),
		"failed": failed,
	}


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
	return {"ok": false, "error": _timeout_error(timeout_ms)}


## v1.13 S12: an embedded game has one failure mode that looks exactly like a dead channel.
## The Game workspace's Suspend button suspends the whole SceneTree, and the runtime autoload's
## PROCESS_MODE_ALWAYS (mcp_runtime.gd) only survives get_tree().paused, not suspension — so
## the game stops answering, every runtime call times out, and nothing else is visibly wrong.
## Both placements are embedded, so both get the line.
static func _timeout_error(timeout_ms: int) -> String:
	return _timeout_message(timeout_ms, game_view_state())


## Split from the probe so the unit suite can pin the sentence the agent actually reads:
## the embedded branch only fires in a real editor with a real Game workspace, which no
## headless check can stage.
static func _timeout_message(timeout_ms: int, gv: Dictionary) -> String:
	var msg := "runtime timeout after %d ms" % timeout_ms
	if str(gv.get("mode", "")) == "embedded":
		msg += (" - the game is running EMBEDDED in the editor's Game workspace (placement: %s),"
			+ " so the likeliest cause is its Suspend button: suspending stops the entire SceneTree,"
			+ " this channel included, and every runtime call then times out with no other symptom."
			+ " Press Suspend again (or Next Frame) and retry. This is NOT time_control op=freeze,"
			+ " which pauses the game and leaves the channel answering.") % str(gv.get("placement", "?"))
	return msg
