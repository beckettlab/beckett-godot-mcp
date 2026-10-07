@tool
extends RefCounted

## Beckett's own objects are off limits to Beckett's own tools.
##
## Why this exists: a tool that takes a node path resolves it against the whole editor tree, and Beckett lives in
## that tree (the EditorPlugin, below it GodotMCPServer and BeckettRuntimeBridge, and the dock among the editor's
## panels). Before this file, call_method on the bridge's absolute path ran send_command, which hands any dictionary
## to the running game: eval, input injection, clicks, time control, the whole drive layer, from the free
## edition's reflection tools. propagate_call from any ancestor of those nodes, connect_signal, an object argument
## and the scene tools (delete, reparent, duplicate) reach the same objects by the same road. A deny-list of tool
## names cannot close that, so the rule sits where every one of those tools starts: the resolver (reflection.gd),
## and, in the game, the one place a write or a call lands (mcp_runtime.gd).
##
## What counts as Beckett's own:
##  * an object whose script, or a script it extends, lives under res://addons/beckett/;
##  * a node below one of those (the dock's labels and buttons carry no script of their own);
##  * for a method that fans out to other objects by name (call, callv, propagate_call, ...), a node that HOLDS
##    one of those below it, which is every ancestor of Beckett's nodes, the tree root included.
## A Script resource itself (res://addons/beckett/core/callargs.gd as a target) is data about code, not one of
## the live objects, and stays reachable: its methods are static helpers that touch nothing running.
##
## HARD CONSTRAINT on this file: no editor classes and no state. The game's runtime preloads it too, and it must
## parse inside a plain engine run.

## Every file Beckett ships lives under this folder. Compared lower-cased and simplified, because a script loaded
## by "res://Addons/BECKETT/../beckett/x.gd" is the same code under another spelling.
const ADDON_DIR := "res://addons/beckett/"

## The sentence every refusal carries, so an agent (and a test) can tell this refusal from a plain miss.
const OFF_LIMITS := "Beckett's own internals are off limits to its tools"

## Methods that run something on every node below the one they are called on, or on whatever is connected to it.
const FAN_OUT := ["propagate_call", "propagate_notification", "emit_signal"]

## Methods that run another method by name, so a call through one of them is the call it names:
## call("propagate_call", ...) is propagate_call. The name is the first argument, the second for rpc_id, and
## callv takes the arguments of the call as one array.
const RELAY := ["call", "callv", "call_deferred", "call_thread_safe", "call_deferred_thread_group", "rpc", "rpc_id"]

## Relays inside relays that an honest call never needs: past this many, a node that holds Beckett is refused.
const RELAY_DEPTH_MAX := 8
## Bounds on the walks below. A tree or a script chain longer than this is no tree an editor has, and the answer
## on running out is "yes, it holds Beckett's objects": a bound must never turn into an opening.
const PARENT_HOPS_MAX := 512
const SCRIPT_HOPS_MAX := 16
const HOLDS_SCAN_MAX := 200000
## How much of a caller's own words a refusal echoes back.
const SHOWN_MAX := 80


# ---------------------------------------------------------------- what is Beckett's own

## Is `path` (a res:// path, or a uid:// that names one) a file of Beckett's own? What a tool that puts a script or
## a scene INTO the player's project must ask first: a copy of Beckett's bridge or runtime running on a node of
## the player's scene is one more object of Beckett's own, planted where the player's game would carry it.
static func is_beckett_path(path: String) -> bool:
	var p := path
	if p.begins_with("uid://"):
		var id := ResourceUID.text_to_id(p)
		if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
			return false
		p = ResourceUID.get_id_path(id)
	return p.simplify_path().to_lower().begins_with(ADDON_DIR)


## Does this object run a script that lives in Beckett's folder, or that extends one that does?
static func owns_script(obj: Object) -> bool:
	if obj == null or not is_instance_valid(obj):
		return false
	var s: Variant = obj.get_script()
	var hops := 0
	while s is Script and hops < SCRIPT_HOPS_MAX:
		var path := str((s as Script).resource_path).simplify_path().to_lower()
		if path.begins_with(ADDON_DIR):
			return true
		s = (s as Script).get_base_script()
		hops += 1
	return s is Script  # a chain too long to follow is not given the benefit of the doubt


## Is this one of Beckett's own live objects: one that owns a Beckett script, or a node below one that does?
static func is_internal(obj: Object) -> bool:
	if obj == null or not is_instance_valid(obj):
		return false
	if owns_script(obj):
		return true
	if obj is Node:
		var up := (obj as Node).get_parent()
		var hops := 0
		while up != null and hops < PARENT_HOPS_MAX:
			if owns_script(up):
				return true
			up = up.get_parent()
			hops += 1
		return up != null  # still going after PARENT_HOPS_MAX: no real tree is that deep
	return false


## Is this node one of Beckett's, or does it have one of Beckett's below it? What a method that fans out to
## everything beneath a node must be asked about first.
static func holds_internal(node: Node) -> bool:
	if node == null:
		return false
	if is_internal(node):
		return true
	var pending: Array = [node]
	var seen := 0
	while not pending.is_empty():
		var cur: Node = pending.pop_back()
		for child in cur.get_children():
			seen += 1
			if seen > HOLDS_SCAN_MAX:
				return true
			if owns_script(child):
				return true
			pending.append(child)
	return false


# ---------------------------------------------------------------- what a tool may name

## "" when a tool may touch `obj`, else the reason in plain words. `scene_root` is the root of the scene open in
## the editor: a node that sits in the tree but outside that scene is the editor's own (its panels, its docks, the
## plugin nodes, the tree root itself) and is refused whether or not it is Beckett's, because the tools address
## the open scene and everything below it, and an ancestor of Beckett's nodes is one call from them. A node that is
## not in a tree at all is judged by what it is, not by where it is. `what` is how the caller named it.
static func refusal(obj: Object, scene_root: Node, what: String = "") -> String:
	if obj == null:
		return ""
	if is_internal(obj):
		return internal_text(what if not what.is_empty() else describe(obj))
	if obj is Node and (obj as Node).is_inside_tree():
		var n := obj as Node
		if scene_root == null or not (n == scene_root or scene_root.is_ancestor_of(n)):
			return outside_text(what if not what.is_empty() else describe(n))
	return ""


## "" when calling `method` on `target` with `args` cannot reach one of Beckett's objects, else why it would.
## Only a node that holds Beckett's objects needs the question, and only a method that fans out (or relays to
## one that does) can reach past the node itself: calling get_class on an ancestor is no way in.
static func dispatch_refusal(target: Object, method: String, args: Array) -> String:
	if not (target is Node):
		return ""
	var node := target as Node
	var name := method.strip_edges()
	var rest: Array = args
	var holds := -1  # asked at most once, and only when a dispatching method is in play
	for _i in RELAY_DEPTH_MAX:
		var fans := FAN_OUT.has(name)
		var relays := RELAY.has(name)
		if not fans and not relays:
			return ""
		if holds == -1:
			holds = 1 if holds_internal(node) else 0
		if holds == 0:
			return ""
		if fans:
			return dispatch_text(describe(node), name)
		# a relay: what it runs is the call it names
		var at := 1 if name == "rpc_id" else 0
		if rest.size() <= at:
			return ""
		var inner: Array = rest.slice(at + 1)
		if name == "callv":
			inner = (rest[at + 1] as Array) if (rest.size() > at + 1 and rest[at + 1] is Array) else []
		name = str(rest[at]).strip_edges()
		rest = inner
	return dispatch_text(describe(node), method)  # relays all the way down: no honest call looks like that


# ---------------------------------------------------------------- the words

## "Name (Class)" for a node, the class alone for anything else: what a refusal calls an object it was handed
## without the text the caller used for it.
static func describe(obj: Object) -> String:
	if obj == null:
		return "null"
	if obj is Node:
		return "%s (%s)" % [str((obj as Node).name), obj.get_class()]
	return obj.get_class()


static func internal_text(what: String) -> String:
	return "%s is part of Beckett itself, and %s. Use a node of the open scene instead (get_scene_tree lists them)." % [_shown(what), OFF_LIMITS]


static func outside_text(what: String) -> String:
	return "%s is part of the editor, outside the open scene. %s, and the editor's own nodes lead to them, so they are refused too. Use a node of the open scene instead (get_scene_tree lists them)." % [_shown(what), OFF_LIMITS]


static func dispatch_text(what: String, method: String) -> String:
	return "%s has Beckett's own internals below it, so %s would reach them, and %s." % [_shown(what), _shown(method), OFF_LIMITS]


static func file_text(path: String) -> String:
	return "%s is one of Beckett's own files, and %s: a copy of it on a node of your scene would be one more of its internals. Use one of your own scripts and scenes instead." % [_shown(path), OFF_LIMITS]


## The sentence for a write or a call aimed at the game's own runtime (the BeckettRuntime autoload and what it
## holds), which is what the game side says when the editor asks it to.
static func runtime_text(what: String) -> String:
	return "%s is part of Beckett's own runtime, and %s. Write to a node of your game instead." % [_shown(what), OFF_LIMITS]


## "" when `obj` is a node of the player's game, else the sentence for a write or a call aimed at Beckett's runtime.
static func runtime_refusal(obj: Object) -> String:
	if is_internal(obj):
		return runtime_text(describe(obj))
	return ""


static func _shown(text: String) -> String:
	var t := text.replace("\n", " ").replace("\r", " ").strip_edges()
	if t.length() > SHOWN_MAX:
		t = t.substr(0, SHOWN_MAX) + "..."
	return t
