# Beckett — MCP for Godot

> *Stop waiting for Godot.*

[![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/pBAugYuerR)

**Beckett** is a **zero-sidecar** Model Context Protocol (MCP) server embedded directly in the **Godot 4** editor as a GDScript `EditorPlugin`. AI agents (Claude and others) drive the editor over HTTP — no Node/Python bridge, no second process, no cloud.

This repository is the free, **MIT-licensed Lite edition** — the complete **inspect → author → run** dev loop (41 tools). The paid **Full** edition makes the AI *play* your game (screenshots, input, asserts) and adds a test runner, animation tools, background exports, and 36 knowledge packs — see [What Full adds](#what-full-adds).

**Lite: you play, the AI reads the logs. Full: the AI plays.**

## Why

Existing Godot MCP servers either shell out to the CLI (can't play the game, screenshot, or inspect runtime) or run a Node/Python **sidecar** that relays to a thin in-editor addon. This one makes the **addon itself the MCP server**, and exposes **reflection-generic** tools that work on *any* class via `ClassDB` — instead of hundreds of hand-coded per-domain wrappers (an anti-pattern: LLMs degrade past ~40 tools).

## Highlights

- **Zero-sidecar** — `TCPServer` HTTP/JSON-RPC server polled on the editor main thread. No marshalling, nothing extra to install beyond the addon.
- **Reflection-first + discovery** — `find_classes` / `describe_class` / `find_methods` make the whole engine surface searchable; `describe_object` / `set_property` / `call_method` then drive any `Node` / `Resource` / `Object`. Reaches TileMap, GPUParticles, AnimationTree, NavMesh, shaders… with no per-domain code.
- **GDScript dev-loop with validate-before-write** — `write_script` / `script_patch` parse the code first and refuse to write what doesn't compile (closing the #1 AI-on-Godot failure: hallucinated GDScript). Godot's edge over UE: reload needs no compile step.
- **Undoable authoring** — every scene/node mutation goes through `EditorUndoRedoManager` (atomic + undoable); `batch_execute` rolls a whole batch back on failure.
- **One-step install** — enabling the plugin auto-starts the server and writes `.mcp.json`, so `claude`/Cursor connects with zero hand-editing (no Node.js to install — the competitor needs it just to try).
- **Security** — localhost-only with `Origin` validation (anti DNS-rebind) + optional bearer token; read-only / allowlist / confirm-destructive gates; auto-start is opt-out (`beckett/autostart=false`).
- **Run + read-the-logs loop** — `play_scene` → `wait_until` → `logs_read` → fix: launch the game and tail its output and errors while you play. (Full closes the loop autonomously — the AI itself sees and drives the running game.) Plus **MCP Resources + Prompts**.
- **Dock panel** — status, one-click Start/Stop, copy-client-config, and an **AI-effort slider** (1–3 in Lite) that caps how many tools are advertised: cheaper model context when you only need a slice. **Applies live, no reconnect** — the server pushes `notifications/tools/list_changed` over its SSE stream and list-changed-aware clients (Claude Code, Cursor, …) re-fetch on the spot.
- **Responsive even unfocused** — while MCP traffic is active the server clamps the editor's low-processor sleep, so calls stay fast when you're focused on the terminal instead of the editor (the usual agent setup).
- **Spec-current MCP** — protocol version negotiation, tool **annotations** (`readOnlyHint`/`destructiveHint`/`openWorldHint`) on every tool, and `structuredContent` (2025-06-18) alongside text results. An **audit ring** (`audit://recent`) records the last 200 tool calls — see everything the AI did.

## Tools (41) · Resources (6) · Prompts (5)

The free Lite edition — the complete inspect → author → run loop:

- **Reflection / discovery:** `get_godot_version`, `find_classes`, `describe_class`, `find_methods`, `describe_object`, `set_property`, `call_method`, `get_scene_tree`
- **Scene authoring (undoable):** `create_node`, `delete_node`, `rename_node`, `reparent_node`, `duplicate_node`, `move_node`, `instance_scene`, `save_scene`, `open_scene`
- **GDScript dev-loop:** `validate_script`, `write_script`, `script_patch`, `read_script`, `attach_script`
- **Signals:** `connect_signal`, `disconnect_signal`, `list_signals`
- **Resource assets:** `create_resource`, `set_resource`
- **Files / project:** `read_file`, `write_file`, `list_dir`, `search_files`, `get_project_setting`, `set_project_setting`
- **Run + logs loop:** `play_scene`, `stop_scene`, `get_play_state`, `wait_until`, `logs_read`
- **Project / authoring helpers:** `get_project_statistics`, `apply_template`, `batch_execute`
- **MCP Resources:** `scene://tree`, `scene://selection`, `project://settings`, `assets://list`, `log://output`, `audit://recent`
- **MCP Prompts:** `inspect_node`, `audit_scene`, `setup_2d_player`, `fix_script_errors`, `build_test_fix`, `make_game`

## What Full adds

The **Full** edition is the same core plus a premium layer that makes the AI the *playtester* — it sees the screen, presses the buttons, and verifies the result:

- **The AI plays:** `screenshot`, `get_remote_tree`, `simulate_input`, UI clicks in 2D + 3D (`click_control` / `click_node3d` / `click_world`), `scroll` / `drag`, `find_nodes`, live `game_logs` with stack traces, `record_input` / `replay_input`.
- **The AI verifies:** `assert_node_state`, `assert_screen_text`, `compare_screenshots`, plus the in-editor **test runner** (`test_run`).
- **Author + ship:** `animation_manage` (keys / tracks / presets), `scatter_nodes` (Scene-Paint mass placement), background `export_project` + `job_status`, project-wide analysis (`find_unused_resources`, `detect_circular_dependencies`), and the Godot **Asset Store / Library** browser-installer (`asset_lib_search` / `asset_lib_info` / `asset_lib_install`).
- **36 skill knowledge packs** (`list_skills` / `load_skill`): gdscript, particles, animation, ui, physics, multiplayer, and more — so reflection reaches each domain with no per-domain tools.

Full is a one-time purchase with lifetime updates: **https://beckettlabs.itch.io/beckett-godot-mcp**

## Use

1. Copy `addons/beckett/` into your Godot **4.4+** project (verified on 4.4.1, 4.6.2 & 4.7) and enable **Beckett — MCP for Godot** in *Project → Project Settings → Plugins*.
2. Done — enabling the plugin **auto-starts** the server and **writes `.mcp.json`**. (Opt out: `beckett/autostart=false`, `beckett/auto_write_client_config=false`. Other options: `BECKETT_PORT` default `8770`, `BECKETT_TOKEN`, `BECKETT_READONLY=1`, `BECKETT_ALLOWLIST`, `BECKETT_CONFIRM_DESTRUCTIVE=1`. Panel has Start/Stop.)
3. Connect your client. For **Claude Code**, just run `claude` in the project — the auto-written [`.mcp.json`](.mcp.json) wires it up (`/mcp` → **beckett**). For Cursor/others, point at `http://127.0.0.1:8770/mcp` (Streamable HTTP) or use the panel's **Set up …** buttons. See [INSTALL.md](INSTALL.md).

## Status

This is the free, MIT-licensed **Lite** edition — the **inspect + author + run** core: reflection/discovery, scene & script authoring, **signals**, **resource create/assign**, **files & project settings**, the **play → wait → `logs_read`** dev loop, and **Resources + Prompts + dock panel**. **41 tools.** Built and verified live on Godot 4.4.1, 4.6.2 and 4.7 (headless editor + a real HTTP MCP client).

The **Full** edition adds the agent-driven play-test layer (screenshots, input injection, UI clicks, assertions, the test runner, `animation_manage`), background export jobs, and the bundled skill packs — it can *see and drive* the running game.

## License

**Lite edition — MIT** (this repository). Free and open-source: use it, fork it, ship it. See [LICENSE](LICENSE).

The **Full** edition (the agent-driven play-test layer, background export jobs, and the skill packs) is a separate commercial product — one-time purchase with lifetime updates.

---

*Beckett is a third-party tool, not affiliated with or endorsed by the Godot Foundation. "Godot" is a trademark of the Godot Foundation.*
