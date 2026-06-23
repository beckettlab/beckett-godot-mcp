@tool
extends RefCounted
class_name BeckettPrompts

## MCP Prompts (D4) — workflow recipes the client can surface as slash-commands. They
## teach the agent the good path through this server's own tools (discovery-first,
## validate-before-write, the play→observe→fix loop).

var server


func list() -> Array:
	return [
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
			return _one("Autonomous build-test-fix: %s" % goal,
				"Loop until the goal is met:\n1) BUILD with the authoring tools (validate_script before write_script; create_node/set_property; save_scene).\n2) play_scene, then wait_until condition=game_connected.\n3) OBSERVE: screenshot (you can see it), get_remote_tree, runtime_get_property — compare against the goal.\n4) DRIVE: simulate_input to exercise it; screenshot again.\n5) If wrong, stop_scene, fix, repeat. Be skeptical — verify from the screenshot, not assumptions. Goal: %s" % goal)
		"make_game":
			var idea := str(args.get("idea", "<idea>"))
			return _one("One-shot game: %s" % idea,
				"Build a small, FINISHED, playable game from this idea alone — do not ask follow-up questions: %s\n1) load_skill name=game-oneshot and follow it exactly: expand the idea into its GameSpec using the defaults table, route to the blueprint pack it names, and reskin only names/colors/shapes to the theme.\n2) Build phase by phase. After every phase run its gate: play_scene, wait_until condition=game_connected (answers 'not yet'? call it again), simulate_input, screenshot (look at it), assert_node_state, logs_read — fix before moving on; if a gate fails twice apply the blueprint's fallback row instead of debugging further.\n3) Never write GDScript from memory: copy the blueprint's scripts verbatim and adapt names/numbers only; confirm anything beyond them with describe_class / find_methods first.\n4) Finish with the juice pass and the quality-bar 60-second playtest from game-oneshot. The game is done only when every quality-bar line passes." % [idea, idea])
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
