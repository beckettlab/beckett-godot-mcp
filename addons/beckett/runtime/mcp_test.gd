@tool
extends RefCounted
class_name BeckettTestCase

## Optional base for tests run by the `test_run` tool. Inherit it and write `test_*`
## methods that use these NON-ABORTING assertions. Do NOT use the engine's built-in
## assert() — it crashes the debug editor on failure; these record the failure instead,
## so a whole suite runs to completion and reports every problem at once.

var _mcp_failures: Array = []


func _mcp_reset() -> void:
	_mcp_failures = []


func _mcp_get_failures() -> Array:
	return _mcp_failures


func fail(msg: String) -> void:
	_mcp_failures.append(msg)


func assert_true(cond: Variant, msg := "") -> void:
	if not cond:
		_mcp_failures.append(msg if msg != "" else "expected true")


func assert_false(cond: Variant, msg := "") -> void:
	if cond:
		_mcp_failures.append(msg if msg != "" else "expected false")


func assert_eq(a: Variant, b: Variant, msg := "") -> void:
	if a != b:
		_mcp_failures.append("%sexpected %s, got %s" % [_pfx(msg), str(b), str(a)])


func assert_ne(a: Variant, b: Variant, msg := "") -> void:
	if a == b:
		_mcp_failures.append("%sexpected != %s" % [_pfx(msg), str(b)])


func assert_null(v: Variant, msg := "") -> void:
	if v != null:
		_mcp_failures.append("%sexpected null, got %s" % [_pfx(msg), str(v)])


func assert_not_null(v: Variant, msg := "") -> void:
	if v == null:
		_mcp_failures.append(msg if msg != "" else "expected non-null")


func assert_almost_eq(a: float, b: float, tol := 0.0001, msg := "") -> void:
	if absf(a - b) > tol:
		_mcp_failures.append("%sexpected ~%s, got %s" % [_pfx(msg), str(b), str(a)])


func _pfx(msg: String) -> String:
	return (msg + ": ") if msg != "" else ""
