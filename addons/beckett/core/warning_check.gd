@tool
extends RefCounted

## Editor half of validate_script's GDScript warning check. core/warning_probe.gd explains
## why it takes a second process: the editor never receives the analyzer's warnings itself.
##
## One call is one short headless child of the SAME editor binary on the SAME project, so the
## warnings are the engine's own, with the project's warning settings and @warning_ignore
## annotations applied. About 0.2 s on a small project. The child dials back over Godot's
## remote-debug wire format, [len:u32][Variant], which is exactly what StreamPeer.get_var()
## reads. A warning arrives as
##   ["error", thread, [hr, min, sec, msec, file, func, line, code, message, is_warning, ...]]
## and that layout is identical on 4.4.1, 4.6.2 and 4.7 (checked 2026-09-30).

const PROBE := "res://addons/beckett/core/warning_probe.gd"
const WORK_DIR := "res://.godot/beckett"
const TIMEOUT_MS := 10000
## A static initializer that throws while the script loads puts the child into a debugger
## break. The warnings it had queued are flushed right behind the break message, so read on
## for this long before ending the child.
const BREAK_GRACE_MS := 150


## Compile `content` as `target_path` in a child process and collect what the engine says.
## Returns {"ok": true, "warnings": [{line, code, message}], "errors": [{line, message}],
## "ms": int} or {"ok": false, "reason": String}.
static func collect(content: String, target_path: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if not ResourceLoader.exists(PROBE):
		return {"ok": false, "reason": "the probe script is missing (%s)" % PROBE}
	var work := ProjectSettings.globalize_path(WORK_DIR)
	if not DirAccess.dir_exists_absolute(work):
		DirAccess.make_dir_recursive_absolute(work)
	var input := work.path_join("validate_input.gd.txt")
	var f := FileAccess.open(input, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "cannot write %s (%s)" % [input, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	f.close()
	var server := TCPServer.new()
	var lerr := server.listen(0, "127.0.0.1")
	if lerr != OK:
		DirAccess.remove_absolute(input)
		return {"ok": false, "reason": "cannot open a loopback socket (%s)" % error_string(lerr)}
	var args := PackedStringArray([
		"--headless", "--quiet", "--no-header",
		# The child is a game run of this project, so by default it would log to (and rotate)
		# the game's own user://logs, pushing real play logs out. Keep its log in .godot.
		"--log-file", work.path_join("validate_probe.log"),
		"--path", ProjectSettings.globalize_path("res://"),
		"--remote-debug", "tcp://127.0.0.1:%d" % server.get_local_port(),
		"--script", PROBE, "--", input, target_path,
	])
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		server.stop()
		DirAccess.remove_absolute(input)
		return {"ok": false, "reason": "could not start a check process from %s" % OS.get_executable_path()}
	var got := _read(server, pid)
	if OS.is_process_running(pid):
		OS.kill(pid)
	server.stop()
	DirAccess.remove_absolute(input)
	var out := shape(got.get("messages", []), target_path)
	match str(got.get("ended", "")):
		"timeout":
			return {"ok": false, "reason": "the check process did not finish within %d s" % (TIMEOUT_MS / 1000.0)}
		"no_connection":
			return {"ok": false, "reason": "the check process exited without reporting (could it boot this project headless?)"}
	out["ok"] = true
	out["ms"] = Time.get_ticks_msec() - t0
	return out


## Pump the socket until the child has said everything: it exits, or it breaks and the grace
## window runs out, or the timeout hits.
static func _read(server: TCPServer, pid: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	var peer: StreamPeerTCP = null
	var msgs: Array = []
	var grace_until := -1
	while Time.get_ticks_msec() < deadline:
		if grace_until > 0 and Time.get_ticks_msec() > grace_until:
			return {"messages": msgs, "ended": "break"}
		if peer == null:
			if server.is_connection_available():
				peer = server.take_connection()
			elif not OS.is_process_running(pid):
				return {"messages": msgs, "ended": "no_connection"}
		else:
			peer.poll()
			if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				while peer.get_available_bytes() >= 4:
					var m: Variant = peer.get_var()
					if not (m is Array) or (m as Array).size() < 3:
						continue
					msgs.append(m)
					if str(m[0]) == "debug_enter" and grace_until < 0:
						grace_until = Time.get_ticks_msec() + BREAK_GRACE_MS
			elif not OS.is_process_running(pid):
				return {"messages": msgs, "ended": "exited"}
		OS.delay_msec(5)
	return {"messages": msgs, "ended": "timeout"}


## Debugger messages -> {warnings, errors} for ONE file. Scripts the target loads (preloads,
## class_name types) report their own warnings on the same channel, so filter by path.
## Pure, so the unit suite pins the wire layout.
static func shape(messages: Array, target_path: String) -> Dictionary:
	var warnings: Array = []
	var errors: Array = []
	var breaks: Array = []
	for m in messages:
		if not (m is Array) or (m as Array).size() < 3:
			continue
		var data: Variant = m[2]
		match str(m[0]):
			"error":
				if not (data is Array) or (data as Array).size() < 10:
					continue
				if not _is_target(str(data[4]), target_path):
					continue
				if bool(data[9]):
					warnings.append({"line": int(data[6]), "code": str(data[7]), "message": str(data[8])})
				else:
					var text := str(data[7]) if str(data[8]).is_empty() else "%s: %s" % [data[7], data[8]]
					errors.append({"line": int(data[6]), "message": text})
			"debug_enter":
				# A break while loading: a static initializer threw, or the child could not
				# compile what the editor could. Engines before 4.6 send no separate error
				# message for it, so the break text is sometimes the only report there is.
				if data is Array and (data as Array).size() >= 2 and not str(data[1]).is_empty():
					breaks.append(str(data[1]))
	for b in breaks:
		var known := false
		for e in errors:
			if _bare(str(e["message"])) == _bare(b):
				known = true
				break
		if not known:
			errors.append({"line": 0, "message": b})
	warnings.sort_custom(func(a, b): return int(a["line"]) < int(b["line"]))
	return {"warnings": warnings, "errors": errors}


## Is this message about the script under check? A pathless compile is reported under a
## pseudo-path like gdscript://-9223372010430659145.gd, and it is the only pathless script the
## child compiles: everything it loads on the way has a real res:// path.
static func _is_target(file: String, target_path: String) -> bool:
	if target_path.is_empty():
		return file.is_empty() or file.begins_with("gdscript://")
	return file == target_path


## One error, told twice (as a debugger break and as an error message), carries a different
## prefix each time.
static func _bare(msg: String) -> String:
	for p in ["Parser Error: ", "Parse Error: ", "Compile Error: "]:
		if msg.begins_with(p):
			return msg.substr(p.length())
	return msg
