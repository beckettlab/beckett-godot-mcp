@tool
extends RefCounted
class_name BeckettPrompts

## MCP Prompts (D4) — workflow recipes the client can surface as slash-commands. They
## teach the agent the good path through this server's own tools (discovery-first,
## validate-before-write, the play→observe→fix loop).
##
## Two of them, build_test_fix and make_game, are written around the Full edition's drive and skill tools. The free Lite
## edition has neither (no simulate_input, no asserts, no load_skill, no skill packs), so in Lite they read the Lite
## wording below, which sticks to the see tools and names the Full step as Full.

var server

## What list() shows in the free edition for the two prompts whose Full wording promises more than Lite can do.
const LITE_DESCRIPTIONS := {
	"build_test_fix": "Build a feature, then run it, watch it and iterate from screenshots and live game state.",
	"make_game": "One-shot: turn a one-line idea into a small finished game, with no follow-up questions.",
}

const LITE_BUILD_TEST_FIX := "Loop until the goal is met:\n1) BUILD with the authoring tools (validate_script before write_script; create_node/set_property; save_scene).\n2) play_scene, then wait_until condition=game_connected.\n3) OBSERVE: screenshot (you can see it), get_remote_tree, runtime_get_property, game_logs. Compare what you see against the goal.\n4) EXERCISE: Lite sees the running game but cannot press keys or click. Put the game in the state you want to check with play_scene on_ready (property writes applied when the game connects), let it run (wait_until condition=seconds:N), and watch it with monitor_properties and screenshot. If the check needs real input, ask the person to play it and report what they saw. (The Full edition adds a step where the AI plays the game itself and asserts the result.)\n5) If wrong, stop_scene, fix, repeat. Be skeptical: verify from the screenshot and the live state, not from assumptions. Goal: %s"

const LITE_MAKE_GAME := "Build a small, FINISHED, playable game from this idea alone, with no follow-up questions: %s\n1) Expand the idea yourself into a short spec: genre, what the player does, controls, how a round is won or lost, and the scenes you need. Decide whatever is left open and keep going.\n2) Build phase by phase with the authoring tools (create_node, set_property, validate_script then write_script, save_scene). After every phase run its check: play_scene, wait_until condition=game_connected, screenshot (look at it), game_logs and logs_read for errors. Fix before moving on.\n3) Never write GDScript from memory: confirm every class, property and method with describe_class and find_methods first.\n4) Lite sees the running game but cannot press keys or click, so judge it by the screen, the live scene tree (get_remote_tree) and runtime_get_property, and use play_scene on_ready when you need the game in a particular state. End by telling the person how to play it and what to look for.\n5) Finish with a juice pass (feedback on every hit, pickup and death) and review the whole game once more by screenshot. (The Full edition guides the whole build with a bundled game-making skill and genre blueprints, and plays and checks the game itself.)"

## True in the free Lite edition. A prompt object made without a server (the unit suite) reads as Full, which is the wording
## this file always had.
func _is_lite() -> bool:
	return server != null and server.has_method("is_lite") and bool(server.is_lite())


func list() -> Array:
	var out: Array = [
		{"name": "inspect_node", "description": "Inspect a node and summarize its key properties.",
			"arguments": [{"name": "target", "description": "node name/path in the open scene", "required": true}]},
		{"name": "audit_scene", "description": "Survey the open scene and flag likely issues.", "arguments": []},
		{"name": "setup_2d_player", "description": "Scaffold a basic 2D player (CharacterBody2D + sprite + movement script).", "arguments": []},
		{"name": "fix_script_errors", "description": "Walk through fixing GDScript errors, validating before writing.",
			"arguments": [{"name": "path", "description": "res:// script path", "required": false}]},
		{"name": "build_test_fix", "description": "Autonomously build a feature, then play-test it and iterate from screenshots + runtime state.",
			"arguments": [{"name": "goal", "description": "what to build/verify", "required": true}]},
		{"name": "make_game", "description": "One-shot: turn a one-line idea into a small finished, polished game — no follow-up questions.",
			"arguments": [{"name": "idea", "description": "the game idea, however short (e.g. 'a zombie game')", "required": true}]},
	]
	if _is_lite():
		for p in out:
			if LITE_DESCRIPTIONS.has(p["name"]):
				p["description"] = LITE_DESCRIPTIONS[p["name"]]
	return out


## Returns {ok:true, description:String, messages:Array} or {ok:false, error}.
func get_prompt(name: String, args: Dictionary) -> Dictionary:
	match name:
		"inspect_node":
			var target := str(args.get("target", "<node>"))
			return _one("Inspect a node.",
				"Use describe_object target=\"%s\" to read its properties, and get_scene_tree for context. Summarize its type, transform, script, and anything notable or misconfigured." % target)
		"audit_scene":
			return _one("Audit the open scene.",
				"Call get_scene_tree. For each notable node use describe_object. Flag: missing scripts/textures, zero-size or off-screen nodes, suspicious transforms, nodes with no children that should have some. Report findings concisely with fixes.")
		"setup_2d_player":
			return _one("Scaffold a 2D player.",
				"1) create_node type=CharacterBody2D name=Player. 2) create_node type=Sprite2D name=Sprite parent=Player. 3) create_node type=CollisionShape2D name=Col parent=Player. 4) Author a movement script with validate_script, then write_script res://player.gd, then attach_script target=Player path=res://player.gd. 5) save_scene. Use describe_class CharacterBody2D / find_methods to confirm the real API before writing — don't guess GDScript.")
		"fix_script_errors":
			var path := str(args.get("path", ""))
			var where := (" for %s" % path) if not path.is_empty() else ""
			return _one("Fix GDScript errors%s." % where,
				"Read the script with read_script. Run validate_script to see if it compiles; check the log://output resource for the exact parser line. Confirm any uncertain API with describe_class / find_methods (GDScript is easy to hallucinate). Re-validate, then write_script (validate-before-write will refuse anything that still doesn't compile).")
		"build_test_fix":
			var goal := str(args.get("goal", "<goal>"))
			if _is_lite():
				return _one("Build, run and watch: %s" % goal, LITE_BUILD_TEST_FIX % goal)
			return _one("Autonomous build-test-fix: %s" % goal,
				"Loop until the goal is met:\n1) BUILD with the authoring tools (validate_script before write_script; create_node/set_property; save_scene).\n2) play_scene, then wait_until condition=game_connected.\n3) OBSERVE: screenshot (you can see it), get_remote_tree, runtime_get_property — compare against the goal.\n4) DRIVE: simulate_input to exercise it; screenshot again.\n5) If wrong, stop_scene, fix, repeat. Be skeptical — verify from the screenshot, not assumptions. Goal: %s" % goal)
		"make_game":
			var idea := str(args.get("idea", "<idea>"))
			if _is_lite():
				return _one("One-shot game: %s" % idea, LITE_MAKE_GAME % idea)
			return _one("One-shot game: %s" % idea,
				"Build a small, FINISHED, playable game from this idea alone, with no follow-up questions: %s\n1) load_skill name=game-oneshot and follow it exactly: expand the idea into its GameSpec using the defaults table, route to the blueprint pack it names, and reskin only names/colors/shapes to the theme.\n2) Build phase by phase. After every phase run its gate: play_scene, wait_until condition=game_connected (answers 'not yet'? call it again), simulate_input, screenshot (look at it), assert_node_state, logs_read, then fix before moving on; if a gate fails twice apply the blueprint's fallback row instead of debugging further.\n3) Never write GDScript from memory: copy the blueprint's scripts verbatim and adapt names/numbers only; confirm anything beyond them with describe_class / find_methods first.\n4) Finish with the juice pass and the quality-bar 60-second playtest from game-oneshot. The game is done only when every quality-bar line passes." % idea)
		_:
			return {"ok": false, "error": "unknown prompt: %s" % name}


func _one(description: String, text: String) -> Dictionary:
	return {
		"ok": true,
		"description": description,
		"messages": [
			{"role": "user", "content": {"type": "text", "text": text}},
		],
	}
