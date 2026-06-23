# Install & Connect — Beckett (MCP for Godot)

## Requirements
- **Godot 4.2+** (4.4+ recommended; verified on 4.6.2 & 4.7). Standard editor — no Node.js, no Python, nothing else.
- An MCP client: **Claude Code**, **Cursor**, **VS Code (Cline)**, **Windsurf**, or any Streamable-HTTP MCP client.

## Quickest path (TL;DR)
1. Put `addons/beckett/` in your project and enable **Beckett — MCP for Godot** in Project Settings → Plugins.
2. That's it — the server auto-starts and `.mcp.json` is written for you.
3. Run `claude` in the project folder (or open Cursor) → it connects. Try *"find_classes Button"*.

Details below.

## 1. Add the addon to your project
Copy the `addons/beckett/` folder into your project so you have:
```
<your project>/addons/beckett/plugin.cfg
```
(Or just open this repo — it's already a Godot project with the addon in place.)

## 2. Enable the plugin
Open the project in Godot → **Project → Project Settings → Plugins** → enable **Godot MCP**.
This also registers a `BeckettRuntime` autoload (used to drive the *running* game; harmless when the server is off).

## 3. The server starts automatically
Enabling the plugin **starts the server** (`http://127.0.0.1:8770/mcp`, localhost-only + Origin-checked) and **writes `.mcp.json`** into your project (merged — never clobbers other entries). The **Godot MCP** dock panel shows status and has **Start/Stop** + **Set up Claude Code / Cursor** buttons.

Opt out with project settings `beckett/autostart=false` / `beckett/auto_write_client_config=false`, or env `BECKETT_ENABLE=0`. For headless/CI, `BECKETT_ENABLE=1` forces it on.

## 4. Connect your AI client

The server speaks **MCP Streamable HTTP**, so any HTTP-capable MCP client connects directly; stdio-only clients bridge with `npx mcp-remote`.

| Client | Transport | Setup |
|---|---|---|
| **Claude Code** | HTTP | auto — `.mcp.json` is written; run `claude` in the project |
| **Cursor** | HTTP | panel **Set up Cursor** → `.cursor/mcp.json` |
| **VS Code** (Copilot) | HTTP | panel **Connect Detected Clients** → `.vscode/mcp.json` |
| **VS Code** (Cline) | HTTP | panel **Connect Detected Clients** → Cline's own `cline_mcp_settings.json` (Cline **ignores** `.vscode/mcp.json`) |
| **Windsurf / Zed / Continue / others** | HTTP | point at `http://127.0.0.1:8770/mcp` (or paste the `mcpServers` block) |
| **Claude Desktop** | stdio only | panel **Copy Claude Desktop config** → paste into `claude_desktop_config.json` (uses `npx mcp-remote`) |
| **Any MCP client** | Streamable HTTP | URL `http://127.0.0.1:8770/mcp` |

The panel writes the right file shape per client (Claude Code/Cursor use `mcpServers`; VS Code uses `servers`). Only stdio-only clients (Claude Desktop) need Node/`npx` — for the bridge, on their side.

### Claude Code
`.mcp.json` is **already written for you** — just run `claude` in the project folder and it connects (`/mcp` → **beckett**). To wire it up manually elsewhere: `claude mcp add --transport http beckett http://127.0.0.1:8770/mcp`, or click the panel's **Set up Claude Code** button. The written file:
```json
{
  "mcpServers": {
    "beckett": { "type": "http", "url": "http://127.0.0.1:8770/mcp" }
  }
}
```

### Cursor / Windsurf
Add to the client's MCP config (`.cursor/mcp.json`, etc.) the same `mcpServers` block as above (type `http`, url `http://127.0.0.1:8770/mcp`).

### VS Code — Cline
Cline keeps its **own** MCP list and **ignores `.vscode/mcp.json`** (that file is Copilot's). The panel's **Connect Detected Clients** writes Cline's `cline_mcp_settings.json` for you. To add it by hand: Cline panel → **MCP Servers** icon → **Remote Servers** → Name `beckett`, URL `http://127.0.0.1:8770/mcp`. Or edit `cline_mcp_settings.json` directly — note `type` must be `streamableHttp`, not `http`:
```json
{ "mcpServers": { "beckett": { "url": "http://127.0.0.1:8770/mcp", "type": "streamableHttp" } } }
```
**Using a local model (LM Studio / Ollama)?** Two gotchas: (1) in Cline's API settings **uncheck "Use compact prompt"** — it strips MCP out (Cline labels it *"Does not support Mcp"*); (2) the model must support **tool / function calling** — small models (e.g. 7B) are flaky over many tools, so drop the Beckett **AI-effort slider to L1–L2** to expose fewer.

### Claude Desktop
Desktop currently expects stdio servers; for an HTTP server use a bridge:
```json
{ "mcpServers": { "beckett": { "command": "npx", "args": ["mcp-remote", "http://127.0.0.1:8770/mcp"] } } }
```
(Claude Code / Cursor connect to the URL directly — prefer those.)

## 5. Try it
Ask the agent: *"call get_godot_version"*, *"get_scene_tree"*, or *"describe_class CharacterBody2D"*. For a full loop: *"create a Button, play the scene, then read errors with logs_read."*

## Options (env vars at editor launch)
| Var | Effect |
|---|---|
| `BECKETT_ENABLE=0` / `=1` | Force the server off / on (default: on when the plugin is enabled) |
| `BECKETT_PORT=8770` | Change the port |
| `BECKETT_TOKEN=…` | Require `Authorization: Bearer <token>` |
| `BECKETT_READONLY=1` | Block all mutating tools |
| `BECKETT_ALLOWLIST=spawn_.*,list_.*` | Only allow tools matching these regexes |
| `BECKETT_CONFIRM_DESTRUCTIVE=1` | Destructive tools require `confirm:"true"` |

Project settings (Project Settings UI, persist in `project.godot`): `beckett/autostart` (default true), `beckett/auto_write_client_config` (default true), `beckett/port` (default 8770).

## Troubleshooting
- **Client can't connect:** confirm the panel shows *Running*; check the port; the server is off until you Start it.
- **`/mcp` shows failed:** make sure the editor is open with the server started before the client connects.
- **Cline connects but the AI only chats / won't use Godot tools:** uncheck **"Use compact prompt"** in Cline's API settings (it disables MCP), confirm Beckett is listed under Cline's **MCP Servers → Remote Servers** (Cline ignores `.vscode/mcp.json` — use **Connect Detected Clients** or add it by hand), and use a model that does **tool calling** (small local models are unreliable — lower the effort slider to L1).
- **Runtime tools say "game not running":** call `play_scene`, then `wait_until condition=game_connected` before `screenshot` / `get_remote_tree` / `simulate_input`.
- **Two editors open:** they'd both try port 8770 — give one a different `BECKETT_PORT`.
