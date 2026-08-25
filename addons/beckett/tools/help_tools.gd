@tool
extends RefCounted
class_name BeckettHelpTools

## `help` (v1.14) — the other half of every tool's docs, served on demand.
##
## Why this tool exists: a tool's description ships on EVERY tools/list, to every client,
## at every effort tier, forever. v1.13.0's `doctor` context block measured what that costs;
## the fat descriptions were 14.7 KB of the 31.9 KB total, and most of those bytes were
## catalogues — the enumeration of `simulate_input`'s event types, `playtest`'s assert
## grammar, `time_control`'s per-frame input shape. A catalogue is what you read ONCE, when
## you are about to use the thing. So the short description names the capability (the model
## still has to learn it exists from tools/list, and nothing else can teach it that), and
## the catalogue moves here, one call away.
##
## Deliberately NOT a skill pack: `pack.ps1` trims addons/beckett/skills out of Lite
## entirely, so a catalogue parked in a pack would vanish for every free user. The long form
## has to live in the registry beside the tool it documents.
##
## L1, like `doctor` — a capped surface has to be able to explain itself at any tier.

const Reflect := preload("res://addons/beckett/core/reflection.gd")
const MCPEffortScript := preload("res://addons/beckett/core/effort.gd")

var server


func _register(registry) -> void:
	registry.register({
		"name": "help",
		# Kept deliberately terse: this tool is L1, so its own description is the one line
		# that ships at EVERY tier to EVERY client. The tool that exists to move bytes off
		# tools/list does not get to be fat itself.
		"description": "Full syntax for one tool - the argument catalogue and worked examples that descriptions no longer carry. Call help(tool=\"NAME\") before a call you are unsure of; bare help() lists what is documented.",
		"help": "help()            the index — every tool carrying an extended long form, with its effort tier and whether the current dial advertises it.\nhelp(tool=\"X\")    X's long form, plus its full argument list with types and which are required.\n\nWhy the long form is not in the tool description: a description ships on EVERY tools/list, to every client, at every tier, forever. A catalogue is read once, when you are about to use the thing. So the description names the CAPABILITY — enough for you to know the tool can do the job — and the syntax lives here. Ask before writing a call you are unsure of; it is one round trip and it costs nothing when you do not.\n\nA tool with no long form falls back to its own description, so this is never a dead end. An unknown name comes back as a normal tool result with a did-you-mean, never as a protocol error.\n\nIt answers for tools ABOVE the current effort tier too, and says so — that is how you find out what raising the dock's AI Effort dial would actually buy you.",
		"readonly": true,
		"idempotent": true,
		"input_schema": {"type": "object", "properties": {
			"tool": {"type": "string", "description": "tool name; omit for the index"},
		}},
		"handler": Callable(self, "_help"),
	})


func _help(args: Dictionary) -> Dictionary:
	var name := str(args.get("tool", "")).strip_edges()
	if name.is_empty():
		return _index()
	if not server.registry.has(name):
		# A tool RESULT, never a JSON-RPC error (SEP-1303, guarded by release.ps1): a bad
		# argument is the model's problem to fix, and it can only fix what it can read.
		var near: Array = Reflect.nearest(name, server.registry.names(), 3)
		var out := {"error": "no tool named '%s'" % name}
		if not near.is_empty():
			out["suggestion"] = "did you mean %s? (bare help() lists everything documented)" % ", ".join(near)
		else:
			out["suggestion"] = "call help() with no arguments for the index of documented tools"
		return out
	return _one(name)


# ---------------------------------------------------------------- index

func _index() -> Dictionary:
	var effort: int = server.get_effort()
	var docs: Array = server.registry.documented_names()
	var rows: Array = []
	for n in docs:
		rows.append({
			"name": n,
			"level": MCPEffortScript.tier_of(n),
			"advertised": MCPEffortScript.allows(n, effort),
		})
	var names: Array = []
	for r in rows:
		names.append(str(r["name"]) if bool(r["advertised"]) else "%s (needs effort %d)" % [str(r["name"]), int(r["level"])])
	return {
		"json": {"count": rows.size(), "effort": effort, "tools": rows},
		"text": ("Extended docs for %d tool(s) — help(tool=\"NAME\"):\n" % rows.size()) + ", ".join(names),
	}


# ---------------------------------------------------------------- one tool

func _one(name: String) -> Dictionary:
	var t: Dictionary = server.registry.get_tool(name)
	var long_form: String = server.registry.help_for(name)
	var schema: Dictionary = t.get("input_schema", {}) if t.get("input_schema") is Dictionary else {}
	var props: Dictionary = schema.get("properties", {}) if schema.get("properties") is Dictionary else {}
	var required: Array = schema.get("required", []) if schema.get("required") is Array else []
	var arg_names: Array = props.keys()
	arg_names.sort()
	var arguments: Array = []
	for k in arg_names:
		var decl: Dictionary = props[k] if props[k] is Dictionary else {}
		var a := {"name": str(k), "type": str(decl.get("type", "any")), "required": str(k) in required}
		if decl.has("description"):
			a["description"] = str(decl["description"])
		arguments.append(a)
	var level: int = MCPEffortScript.tier_of(name)
	var json := {
		"name": name,
		"level": level,
		"advertised": MCPEffortScript.allows(name, server.get_effort()),
		"description": str(t.get("description", "")),
		"help": long_form,
		"arguments": arguments,
		"read_only": bool(t.get("readonly", false)),
		"destructive": bool(t.get("destructive", false)),
	}
	return {"json": json, "text": _render(name, level, long_form, arguments)}


## The human-readable half. The model gets both channels; this one is what it actually
## reads, so it carries the same information without the JSON punctuation tax.
func _render(name: String, level: int, long_form: String, arguments: Array) -> String:
	var lines: Array = ["%s (effort tier %d)" % [name, level], "", long_form]
	if not arguments.is_empty():
		lines.append("")
		lines.append("Arguments:")
		for a in arguments:
			var d: Dictionary = a
			var line := "  %s: %s%s" % [str(d["name"]), str(d["type"]), " (required)" if bool(d["required"]) else ""]
			if d.has("description"):
				line += " — " + str(d["description"])
			lines.append(line)
	if not MCPEffortScript.allows(name, server.get_effort()):
		lines.append("")
		lines.append("NOT currently advertised: the AI effort dial is at %d and this tool needs %d. Raise it in the Beckett dock." % [server.get_effort(), level])
	return "\n".join(lines)
