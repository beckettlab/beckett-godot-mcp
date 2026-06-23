@tool
extends RefCounted
class_name BeckettJsonRpc

## JSON-RPC 2.0 envelope helpers + standard error codes (MCP speaks JSON-RPC 2.0).

const PARSE_ERROR := -32700
const INVALID_REQUEST := -32600
const METHOD_NOT_FOUND := -32601
const INVALID_PARAMS := -32602
const INTERNAL_ERROR := -32603


static func result(id: Variant, value: Variant) -> String:
	return JSON.stringify({
		"jsonrpc": "2.0",
		"id": id,
		"result": value,
	})


## Server-initiated notification (no id) — e.g. notifications/tools/list_changed.
## (Named make_notification because Object already claims notification().)
static func make_notification(method: String, params: Variant = null) -> String:
	var msg := {"jsonrpc": "2.0", "method": method}
	if params != null:
		msg["params"] = params
	return JSON.stringify(msg)


static func error(id: Variant, code: int, message: String, data: Variant = null) -> String:
	var err := {"code": code, "message": message}
	if data != null:
		err["data"] = data
	return JSON.stringify({
		"jsonrpc": "2.0",
		"id": id,
		"error": err,
	})
