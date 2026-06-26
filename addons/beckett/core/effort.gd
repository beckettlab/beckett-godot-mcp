@tool
extends RefCounted
class_name BeckettEffort

## AI effort tiers (1..5) — the dial behind the dock's effort slider.
##
## Every tool we advertise costs the model prompt tokens (its description + JSON
## schema ships on every tools/list). Most sessions only need a slice of the 68
## tools, so we let the user cap the surface: a lower tier exposes fewer tools =
## cheaper context = a sharper, faster model, at the cost of capability.
##
## Tiers are CUMULATIVE and follow the real workflow: inspect -> author -> run
## -> playtest -> ship. Level N exposes its own tools plus every lower level's.
##
## L3 is also the EDITION line: the free Lite build ships L1..L3 (inspect, author,
## and the human-in-the-loop run loop — play, logs), so the basic dev loop is never
## paywalled. L4..L5 (the agent itself drives, sees and verifies the game; shipping
## tools) are Full-edition modules.

const MAX_LEVEL := 5
const DEFAULT_LEVEL := 5  # full surface — dialing down is opt-in, never a silent loss

# Human-facing label and a short tagline for each level (shown on the dock).
const LEVELS := {
	1: {"name": "Inspect",  "tag": "Read-only recon"},
	2: {"name": "Author",   "tag": "Edit and build"},
	3: {"name": "Run",      "tag": "Dev loop"},
	4: {"name": "Playtest", "tag": "AI drives and verifies"},
	5: {"name": "Max",      "tag": "Orchestrate and ship"},
}

# Tools UNLOCKED AT each level (the delta over the level below). Grouped by the
# tool module they come from. When you add a tool, slot it here — an UNLISTED
# tool falls back to level 1 (always visible), so a new tool never silently
# vanishes; it just won't help thin out the low tiers until it's classified.
const _DELTA := {
	# L1 — pure read: understand the project without touching it. Cheapest surface.
	1: [
		# reflection (read)
		"get_scene_tree", "get_godot_version", "describe_class", "describe_object",
		"find_classes", "find_methods",
		# files & project (read)
		"read_script", "read_file", "list_dir", "search_files", "get_project_setting",
		# project overview (read) + lazy knowledge packs
		"get_project_statistics", "list_skills", "load_skill",
	],
	# L2 — author static content: the core editor authoring loop.
	2: [
		# reflection (write)
		"set_property", "call_method",
		# scene & nodes
		"create_node", "delete_node", "duplicate_node", "instance_scene", "move_node",
		"open_scene", "rename_node", "reparent_node", "save_scene",
		# scripts (write)
		"attach_script", "script_patch", "validate_script", "write_script",
		# resources
		"create_resource", "set_resource",
		# signals
		"connect_signal", "disconnect_signal", "list_signals",
		# files & project (write)
		"write_file", "set_project_setting",
		# scaffold from a bundled/project template
		"apply_template",
		# batching authoring steps
		"batch_execute",
	],
	# L3 — run: close the basic dev loop (edit -> play -> read errors -> fix).
	# The human plays and reports; the agent launches, waits, and tails the log.
	# This tier is the Lite edition's ceiling — every free competitor can run the
	# game, so the free tier must too.
	3: [
		"play_scene", "stop_scene", "get_play_state", "wait_until", "logs_read",
	],
	# L4 — playtest: the agent itself drives, sees and verifies the RUNNING game,
	# plus the authoring power tools that loop needs (tests, animation).
	4: [
		# observe the running game
		"get_remote_tree", "find_nodes", "wait_for_node", "screenshot",
		"monitor_properties", "get_performance_monitors", "game_logs",
		# drive it
		"runtime_call", "runtime_get_property", "runtime_set_property",
		"simulate_input", "click_button_by_text", "click_control",
		"click_node3d", "click_world", "scroll", "drag",
		"get_control_rect", "find_ui_elements",
		"record_input", "replay_input",
		# verify it
		"assert_node_state", "assert_screen_text", "assert_scene", "compare_screenshots",
		"test_run",
		# animation authoring + playback
		"animation_manage",
		# scene authoring at scale (Scene Paint analog)
		"scatter_nodes",
	],
	# L5 — ship & advanced: niche, slower, or external-facing tools.
	5: [
		# export (job_status polls background exports)
		"export_project", "list_export_presets", "job_status",
		# asset library
		"asset_lib_search", "asset_lib_info", "asset_lib_install",
		# project analysis (heavier scans)
		"detect_circular_dependencies", "find_unused_resources",
	],
}


## The minimum effort level at which `tool_name` becomes visible.
## Unmapped tools default to 1 so a freshly added tool is never hidden by accident.
static func tier_of(tool_name: String) -> int:
	for lvl in range(1, MAX_LEVEL + 1):
		if tool_name in _DELTA[lvl]:
			return lvl
	return 1


## Is `tool_name` advertised at this effort `level`?
static func allows(tool_name: String, level: int) -> bool:
	return tier_of(tool_name) <= level


## The tools UNLOCKED at exactly this level — the delta over the level below (drives the
## dock's "what this tier adds" list). Empty for an out-of-range level.
static func adds_at(level: int) -> Array:
	return _DELTA.get(level, [])


## Clamp any caller-supplied level into the valid 1..MAX_LEVEL range.
static func clamp_level(level: int) -> int:
	return clampi(level, 1, MAX_LEVEL)
