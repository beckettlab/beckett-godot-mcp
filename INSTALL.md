# Install & Connect — Beckett (MCP for Godot)

## Requirements
- **Godot 4.2+** (4.4+ recommended; CI-verified on 4.4.1, and on 4.6.2 & 4.7.2 across Windows, macOS and Linux, with a warn-only 4.8-dev lane). Standard editor: no Node.js, no Python, nothing else.
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
Open the project in Godot → **Project → Project Settings → Plugins** → enable **Beckett**.
This also registers a `BeckettRuntime` autoload (the bridge that lets the AI see the *running* game; harmless when the server is off).
It is a tiny stub that goes inert outside the editor, and Beckett strips itself from your exports automatically. See [Exports](#exports).

## 3. The server starts automatically
Enabling the plugin **starts the server** (`http://127.0.0.1:8770/mcp`, localhost-only + Origin-checked) and **writes `.mcp.json`** into your project (merged, never clobbers other entries). The **Beckett** dock panel (a **Beckett** tab in the right-hand dock, next to the Inspector) shows status and has **Start/Stop** + **Set up Claude Code / Cursor** buttons.

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
Ask the agent: *"call get_godot_version"*, *"get_scene_tree"*, or *"describe_class CharacterBody2D"*. For a full loop: *"create a Button, play the scene, screenshot it, then read errors with logs_read."*

## Exports

**You do not have to do anything.** Beckett keeps itself out of your shipped game.

Enabling the plugin registers the `BeckettRuntime` autoload, and Godot bakes autoloads into
`project.godot`, so Beckett would otherwise ride into every export. Two things prevent that:

- **The autoload is a stub.** `runtime/beckett_autoload.gd` names no engine class beyond
  `Node`, and its first act is to check `OS.has_feature("editor")`. In an export template
  that is false, so it stays an empty, silent node: no socket, no timer, no commands served.
- **Everything else is stripped at export time.** Beckett registers an `EditorExportPlugin`
  that drops every other addon file from the pack. A Lite export goes from ~340 KB of Beckett
  down to a 1 KB stub, and the export log says so (measured on Godot 4.6.2):

  ```
  [beckett] kept 36 editor-only file(s) (555.5 KiB) out of the export; only the inert runtime autoload ships
  ```

Opt out with project setting `beckett/strip_from_exports = false` if you want the full addon
in your pack.

### Custom engine builds

If you compile Godot with a build profile that disables engine classes (common for small web
builds), this matters more than size. GDScript resolves class names at **parse** time, so a
script naming a class your engine no longer has fails to load, and a failed *autoload* prints
errors before your main scene does. The stub is written to survive that: it names only
`Node`, `OS` and `ResourceLoader`, none of which a build profile can remove. A unit test
enforces it, so it cannot regress.

**Upgrading from Beckett 1.14 or earlier?** Your `project.godot` points the autoload straight
at `runtime/mcp_runtime.gd`, which *does* name `Camera3D`, `MeshInstance3D`, `ShaderMaterial`,
`GraphEdit` and others. Just open the project once: Beckett re-points the autoload at the stub
and saves it. You will see:

```
[beckett] runtime autoload re-pointed at the export-safe stub (res://addons/beckett/runtime/beckett_autoload.gd)
```

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
- **Runtime tools say "game not running":** call `play_scene`, then `wait_until condition=game_connected` before `screenshot` / `get_remote_tree` / `runtime_get_property`.
- **Two editors open:** they'd both try port 8770 — give one a different `BECKETT_PORT`.
