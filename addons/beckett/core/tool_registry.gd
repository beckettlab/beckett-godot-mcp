@tool
extends RefCounted
class_name BeckettToolRegistry

## Central tool registry (the "seam" — any module contributes tools here at setup).
## Keeps the dispatcher free of per-tool knowledge and makes an optional Pro tier
## or per-tool enable/disable trivial later.

# Preloaded-const, not the global class_name: the global class cache may not exist
# yet (fresh checkout, headless --check-only), and a cache miss would parse-fail us.
const MCPEffortScript := preload("res://addons/beckett/core/effort.gd")

## Claude Code's hard ceiling for `anthropic/maxResultSizeChars`. A larger declaration is
## clamped here rather than shipped, so a typo cannot promise a size the client will not honor.
const MAX_RESULT_CHARS_CEILING := 500000

# name -> {name, description, input_schema, handler:Callable, destructive:bool, readonly:bool[, title, idempotent, open_world]}
var _tools: Dictionary = {}


func register(spec: Dictionary) -> void:
	assert(spec.has("name"), "tool spec needs a name")
	assert(spec.has("handler"), "tool spec needs a handler Callable")
	var name: String = spec["name"]
	var t := {
		"name": name,
		"description": spec.get("description", ""),
		"input_schema": spec.get("input_schema", {"type": "object", "properties": {}}),
		"handler": spec["handler"],
		"destructive": bool(spec.get("destructive", false)),
		"readonly": bool(spec.get("readonly", false)),
	}
	# Optional annotation extras (see list_specs): human title, idempotency,
	# open-world (talks to something beyond this editor/project, e.g. the Asset Library).
	# Plus two v1.14 keys that are NOT annotations:
	#   help          — the long form. Deliberately NOT emitted by list_specs: it is the
	#                   half of a tool's docs that used to ride on every tools/list, and
	#                   moving it here is the whole point of the context diet. The `help`
	#                   tool serves it on demand.
	#   output_schema — advertised as `outputSchema` (spec 2025-06-18). Declare it ONLY on
	#                   a tool whose EVERY success path returns a Dictionary under `json`;
	#                   a text-only success would break the promise on first call (there is
	#                   a unit guard that runs a representative result through _tool_result).
	# And two v1.16 keys, hints for Claude Code that ride in the tool's `_meta` (see _client_hints):
	#   always_load      - bool. Claude Code defers every MCP tool schema behind tool search by
	#                      default; true keeps this one in context from the first turn. Spend it on
	#                      a few small bootstrap tools: each one is paid for in EVERY session.
	#   max_result_chars - int. Claude Code spills any result over 50,000 characters to a file; a
	#                      tool whose full output IS the answer raises its own line here.
	for opt in ["title", "idempotent", "open_world", "help", "output_schema", "always_load", "max_result_chars"]:
		if spec.has(opt):
			t[opt] = spec[opt]
	_tools[name] = t


func has(name: String) -> bool:
	return _tools.has(name)


func get_tool(name: String) -> Dictionary:
	return _tools.get(name, {})


func names() -> Array:
	return _tools.keys()


## MCP tools/list payload: [{name, description, inputSchema}].
## Only tools at or below `max_level` (the AI effort tier, 1..6) are advertised —
## a lower tier ships fewer tools, so the model pays less prompt context.
## `with_meta` gates the per-tool `_meta` hints: Tool._meta exists from spec 2025-06-18, so the
## server passes false for a peer that negotiated an older revision. It is applied AFTER the
## effort filter, so a tool the dial hides carries no hint because it is not listed at all.
func list_specs(max_level: int = -1, with_meta: bool = true) -> Array:
	if max_level < 0:
		max_level = MCPEffortScript.MAX_LEVEL
	var out: Array = []
	var keys := _tools.keys()
	keys.sort()
	for k in keys:
		if not MCPEffortScript.allows(k, max_level):
			continue
		var t: Dictionary = _tools[k]
		var spec := {
			"name": t["name"],
			"description": t["description"],
			"inputSchema": t["input_schema"],
			# MCP tool annotations (spec 2025-03-26+): hints that let clients render
			# safety UX (e.g. warn before destructive calls) without parsing prose.
			# Untrusted by definition — they mirror the same flags our own gates use.
			"annotations": _annotations(t),
		}
		# Typed results (spec 2025-06-18) for the family that is verifiably all-JSON on
		# success. `help` is never emitted here — that is the context diet.
		if t.has("output_schema"):
			spec["outputSchema"] = t["output_schema"]
		if with_meta:
			var hints := _client_hints(t)
			if not hints.is_empty():
				spec["_meta"] = hints
		out.append(spec)
	return out


## The long-form docs for one tool, or "" when it has none. Falls back to the short
## description so `help` is never a dead end for an undocumented tool.
func help_for(name: String) -> String:
	var t: Dictionary = _tools.get(name, {})
	if t.is_empty():
		return ""
	return str(t.get("help", t.get("description", "")))


## Names of the tools carrying an explicit long form, sorted. Drives help()'s index.
func documented_names() -> Array:
	var out: Array = []
	for k in _tools:
		if _tools[k].has("help"):
			out.append(k)
	out.sort()
	return out


## Claude Code's two per-tool hints, as the `_meta` the spec reserves for exactly this (the
## reverse-DNS prefix keeps them out of the way of every other client). A key is emitted ONLY
## for a tool that declared it, so an undeclared tool carries no `_meta` at all; any other
## client ignores the whole object.
func _client_hints(t: Dictionary) -> Dictionary:
	var hints := {}
	if t.has("always_load"):
		hints["anthropic/alwaysLoad"] = bool(t["always_load"])
	var cap := int(t.get("max_result_chars", 0))
	if cap > 0:
		hints["anthropic/maxResultSizeChars"] = mini(cap, MAX_RESULT_CHARS_CEILING)
	return hints


func _annotations(t: Dictionary) -> Dictionary:
	var a := {
		"readOnlyHint": bool(t["readonly"]),
		"destructiveHint": bool(t["destructive"]),
		"openWorldHint": bool(t.get("open_world", false)),
	}
	if t.has("title"):
		a["title"] = str(t["title"])
	if t.has("idempotent"):
		a["idempotentHint"] = bool(t["idempotent"])
	return a
