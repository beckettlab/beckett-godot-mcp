# Beckett — MCP for Godot

> *Stop waiting for Godot.*

**Beckett** is a **zero-sidecar** Model Context Protocol (MCP) server embedded directly in the **Godot 4** editor as a GDScript `EditorPlugin`. AI agents (Claude and others) drive the editor over HTTP — no Node/Python bridge, no second process, no cloud.

## Why

Existing Godot MCP servers either shell out to the CLI (can't play the game, screenshot, or inspect runtime) or run a Node/Python **sidecar** that relays to a thin in-editor addon. This one makes the **addon itself the MCP server**, and exposes **reflection-generic** tools that work on *any* class via `ClassDB` — instead of hundreds of hand-coded per-domain wrappers (an anti-pattern: LLMs degrade past ~40 tools).

## Highlights

- **Zero-sidecar** — `TCPServer` HTTP/JSON-RPC server polled on the editor main thread. No marshalling, nothing extra to install beyond the addon.
- **Reflection-first + discovery** — `find_classes` / `describe_class` / `find_methods` make the whole engine surface searchable; `describe_object` / `set_property` / `call_method` then drive any `Node` / `Resource` / `Object`. Reaches TileMap, GPUParticles, AnimationTree, NavMesh, shaders… with no per-domain code.
- **GDScript dev-loop with validate-before-write** — `write_script` parses the code first and refuses to write what doesn't compile (closing the #1 AI-on-Godot failure: hallucinated GDScript). Godot's edge over UE: reload needs no compile step.
- **Undoable authoring** — every scene/node mutation goes through `EditorUndoRedoManager` (atomic + undoable).
- **One-step install** — enabling the plugin auto-starts the server and writes `.mcp.json`, so `claude`/Cursor connects with zero hand-editing (no Node.js to install — the competitor needs it just to try).
- **Security** — localhost-only with `Origin` validation (anti DNS-rebind) + optional bearer token; read-only / allowlist / confirm-destructive gates; auto-start is opt-out (`beckett/autostart=false`).
- **Autonomous play-test loop** — `play_scene` → `screenshot` / `get_remote_tree` → `simulate_input` → `wait_until` → fix, driving the *running* game over a runtime channel (the gap every free Godot MCP has). Plus **MCP Resources + Prompts**.
- **Dock panel** — status, one-click Start/Stop, copy-client-config, and an **AI-effort slider** (1–5) that caps how many tools are advertised: cheaper model context when you only need a slice. **Applies live, no reconnect** — the server pushes `notifications/tools/list_changed` over its SSE stream and list-changed-aware clients (Claude Code, Cursor, …) re-fetch on the spot. **Skills** — 36 bundled knowledge packs cover the domains (particles, animation, ui, physics…) so reflection reaches them with no per-domain tools.
- **Background jobs** — `export_project` runs as a subprocess job (live output streaming, cancel, exit code) so the editor never freezes mid-export; poll `job_status`.
- **Responsive even unfocused** — while MCP traffic is active the server clamps the editor's low-processor sleep, so calls stay fast when you're focused on the terminal instead of the editor (the usual agent setup).
- **Spec-current MCP** — protocol version negotiation, tool **annotations** (`readOnlyHint`/`destructiveHint`/`openWorldHint`) on every tool, and `structuredContent` (2025-06-18) alongside text results. An **audit ring** (`audit://recent`) records the last 200 tool calls — see everything the AI did.
- Roadmap: gdUnit4 tests, more skill packs, packaging.

## Tools (77) · Resources (6) · Prompts (5) · Skills (36)

- **Reflection / discovery:** `get_godot_version`, `find_classes`, `describe_class`, `find_methods`, `describe_object`, `set_property`, `call_method`, `get_scene_tree`
- **Scene authoring (undoable):** `create_node`, `delete_node`, `rename_node`, `reparent_node`, `duplicate_node`, `move_node`, `instance_scene`, `scatter_nodes` (Scene-Paint-style mass placement), `save_scene`, `open_scene`
- **GDScript dev-loop:** `validate_script`, `write_script`, `read_script`, `attach_script`
- **Signals:** `connect_signal`, `disconnect_signal`, `list_signals`
- **Resource assets:** `create_resource`, `set_resource`
- **Files / project:** `read_file`, `write_file`, `list_dir`, `search_files`, `get_project_setting`, `set_project_setting`
- **Runtime play-test loop:** `play_scene`, `stop_scene`, `get_play_state`, `wait_until`, `game_logs`, `screenshot`, `simulate_input`, `get_remote_tree`, `find_nodes`, `runtime_get_property`, `runtime_set_property`, `runtime_call`, `wait_for_node`, `find_ui_elements`, `click_button_by_text`, `click_control`, `click_node3d`, `click_world`, `get_control_rect`, `scroll`, `drag`, `monitor_properties`, `record_input`, `replay_input`
- **QA / assertions:** `assert_node_state`, `assert_screen_text`, `compare_screenshots`
- **Profiling / code-analysis:** `get_performance_monitors` (game or editor), `get_project_statistics`, `find_unused_resources`, `detect_circular_dependencies`
- **Export & jobs:** `list_export_presets`, `export_project` (background by default), `job_status` (poll / list / cancel)
- **Asset Store / Library:** `asset_lib_search`, `asset_lib_info`, `asset_lib_install` — browse the Godot **Asset Store** (`store.godotengine.org`, 4.7+) or the legacy **Asset Library** (≤4.6), auto-selected by engine version, and install an addon straight into `res://` (downloads + extracts in-editor, optional plugin enable). Each search hit returns a `ref` for info/install.
- **Skills (knowledge packs):** `list_skills`, `load_skill` — 36 bundled: gdscript, reflection-discovery, signals, scene-management, save-load, input, mobile, settings-menu; 2D — physics2d, tilemap, lighting2d; 3D — node3d, physics3d, skeleton3d, raycast, navigation, gridmap, import-3d; visual — particles, particles3d, shaders, animation, animationtree, tween, viewport-camera; audio; ui, theme, localization; multiplayer; custom-resources, export-presets; gdunit4; **one-shot game layer** — game-oneshot (idea→spec→blueprint router with verify gates) + genre blueprints game-platformer-2d, game-topdown-2d (project override at `res://.beckett/skills/`)
- **MCP Resources:** `scene://tree`, `scene://selection`, `project://settings`, `assets://list`, `log://output`, `audit://recent`
- **MCP Prompts:** `inspect_node`, `audit_scene`, `setup_2d_player`, `fix_script_errors`, `build_test_fix`, `make_game`

The runtime loop talks to the running game through a small autoload (`BeckettRuntime`) that the plugin registers; `screenshot` of the game needs a normal (non-headless) play session.

## Use

1. Copy `addons/beckett/` into your Godot 4.2+ project (4.4+ recommended; verified on 4.6.2 & 4.7) and enable **Godot MCP** in *Project → Project Settings → Plugins*.
2. Done — enabling the plugin **auto-starts** the server and **writes `.mcp.json`**. (Opt out: `beckett/autostart=false`, `beckett/auto_write_client_config=false`. Other options: `BECKETT_PORT` default `8770`, `BECKETT_TOKEN`, `BECKETT_READONLY=1`, `BECKETT_ALLOWLIST`, `BECKETT_CONFIRM_DESTRUCTIVE=1`. Panel has Start/Stop.)
3. Connect your client. For **Claude Code**, just run `claude` in the project — the auto-written [`.mcp.json`](.mcp.json) wires it up (`/mcp` → **beckett**). For Cursor/others, point at `http://127.0.0.1:8770/mcp` (Streamable HTTP) or use the panel's **Set up …** buttons. See [INSTALL.md](INSTALL.md).

## Status

This is the free, MIT-licensed **Lite** edition — the **inspect + author + run** core: reflection/discovery, scene & script authoring, **signals**, **resource create/assign**, **files & project settings**, the **play → wait → `logs_read`** dev loop, and **Resources + Prompts + dock panel**. Built and verified live on Godot 4.6.2 and 4.7 (headless editor + a real HTTP MCP client).

The **Full** edition adds the agent-driven play-test layer (screenshots, input injection, UI clicks, assertions, the test runner, `animation_manage`), background export jobs, and the bundled skill packs — it can *see and drive* the running game.

## License

**Lite edition — MIT** (this repository). Free and open-source: use it, fork it, ship it. See [LICENSE](LICENSE).

The **Full** edition (the agent-driven play-test layer, background export jobs, and the skill packs) is a separate commercial product — one-time purchase with lifetime updates.
