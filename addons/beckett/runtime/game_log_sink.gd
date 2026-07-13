extends RefCounted
## Game-side log capture (v1.9.1, extracted from mcp_runtime as part of the B7 split).
## Owns the ring buffer + the runtime-compiled OS Logger that feeds it, and answers the
## bridge's `logs` command. The Logger base class and OS.add_logger() are Godot 4.5+; on
## 4.2-4.4 install() is a graceful no-op and snapshot() reports capture_active=false so an
## empty buffer reads as "capture unavailable", never as "the game logged nothing".
##
## The sink itself is compiled FROM SOURCE at install time: it `extends Logger`, a class
## absent before 4.5, so it can't exist as parsed code anywhere in the addon — that is
## exactly what used to break parsing on older engines. Callbacks may arrive on any thread
## (the engine logs from workers too), hence the mutex around every ring touch.

const CAP := 800

var _ring: Array = []
var _dropped := 0
var _mutex := Mutex.new()
var _logger: Object = null


## Install the OS Logger (4.5+; no-op otherwise). Safe to call once from the runtime's _ready.
func install() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
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
		return
	var sink: Object = gd.new()
	if sink == null:
		return
	sink.set("host", self)
	_logger = sink
	OS.call("add_logger", _logger)


func uninstall() -> void:
	if _logger != null:
		# OS.call(): OS.remove_logger() is compile-checked and absent on < 4.5; _logger is
		# only ever non-null on 4.5+, so this dynamic call is only reached where it exists.
		OS.call("remove_logger", _logger)
		_logger = null


## Called by the compiled Logger on every print() (and stderr writes).
func _on_message(message: String, error: bool) -> void:
	_push({"type": "stderr" if error else "print", "t": Time.get_ticks_msec(), "text": message})


## Called by the compiled Logger on every error/warning — including runtime SCRIPT errors,
## with their stack trace(s) in script_backtraces (ScriptBacktrace.format()).
func _on_error(function: String, file: String, line: int, code: String, rationale: String, error_type: int, script_backtraces: Array) -> void:
	var bt := ""
	for b in script_backtraces:
		# Duck-typed instead of `b is ScriptBacktrace`: that class is Godot 4.5+, and a
		# parse-time type reference would break this file on < 4.5. We only reach here from
		# the 4.5+ sink anyway, where these are genuine ScriptBacktraces.
		if b is Object and b.has_method("format") and b.has_method("is_empty") and not b.is_empty():
			bt += b.format(0, 2)
	_push({
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


func _push(e: Dictionary) -> void:
	_mutex.lock()
	_ring.append(e)
	if _ring.size() > CAP:
		_ring.pop_front()
		_dropped += 1
	_mutex.unlock()


## The `logs` bridge command: filtered, level-gated, newest-limited view of the ring.
func snapshot(msg: Dictionary) -> Dictionary:
	var level := str(msg.get("level", "error")).to_lower()
	var needle := str(msg.get("filter", ""))
	var limit: int = maxi(1, int(msg.get("limit", 100)))
	_mutex.lock()
	var snap: Array = _ring.duplicate()
	var dropped := _dropped
	if bool(msg.get("clear", false)):
		_ring.clear()
		_dropped = 0
	_mutex.unlock()
	var out: Array = []
	for e in snap:
		if not _level_pass(str(e.get("type", "")), level):
			continue
		if needle != "" and _entry_text(e).findn(needle) == -1:
			continue
		out.append(e)
	if out.size() > limit:
		out = out.slice(out.size() - limit, out.size())
	# capture_active tells the editor side whether the log sink is actually installed —
	# false on Godot < 4.5 (no Logger API). game_logs surfaces that distinction to the agent.
	return {"ok": true, "entries": out, "count": out.size(), "dropped": dropped, "buffer_size": snap.size(), "capture_active": _logger != null}


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
