# Install & Connect — Beckett (MCP for Godot)

## Requirements
- **Godot 4.2+** (4.4+ recommended; CI-verified on 4.4.1, and on 4.6.3 & 4.7.2 across Windows, macOS and Linux, with a warn-only 4.8-dev lane). Standard editor: no Node.js, no Python, nothing else.
- An MCP client: **Claude Code**, **Cursor**, **VS Code** (Copilot or Cline), **Codex**, **Gemini CLI**, **Antigravity**, **Devin Desktop** (formerly Windsurf), **Claude Desktop** (through a bridge), or any Streamable-HTTP MCP client.

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
Lite sees the running game and does not drive it: the runtime that answers it ships as MIT source in `addons/beckett/runtime/`, Lite's tools never send it drive commands, and Lite's bridge refuses them.

## 3. The server starts automatically
Enabling the plugin **starts the server** (`http://127.0.0.1:8770/mcp`, localhost-only, with exact Host and Origin checks) and **writes `.mcp.json`** into your project (merged, never clobbers other entries). The **Beckett** dock panel (a **Beckett** tab in the right-hand dock, next to the Inspector) shows status and has **Start/Stop**, a **Connect Detected Clients** button and the **Auth token** switch.

The server comes up about a second after the editor finishes its first filesystem scan, so `godot --import` and export runs never start one. A new project gets a per-project token (`res://.beckett/token`, ignored by git), and the client configs carry it. [SECURITY.md](SECURITY.md) says what is protected, what is not, and how to report a problem.

Opt out with project settings `beckett/autostart=false` / `beckett/auto_write_client_config=false`, or env `BECKETT_ENABLE=0`. For headless/CI, `BECKETT_ENABLE=1` forces it on.

## 4. Connect your AI client

The server speaks **MCP Streamable HTTP**, so any HTTP-capable MCP client connects directly; stdio-only clients bridge with `npx mcp-remote` (Beckett pins an exact version).

| Client | Transport | Setup |
|---|---|---|
| **Claude Code** | HTTP | auto — `.mcp.json` is written; run `claude` in the project |
| **Cursor** | HTTP | auto when Cursor is installed: `.cursor/mcp.json` |
| **VS Code** (Copilot) | HTTP | auto: VS Code 1.138+ reads the same `.mcp.json`, so no `.vscode/mcp.json` is created (one that already carries a Beckett entry is kept current) |
| **VS Code** (Cline) | HTTP | panel **Connect Detected Clients** → Cline's own `cline_mcp_settings.json` (Cline **ignores** `.vscode/mcp.json`) |
| **Codex** | HTTP | panel **Connect Detected Clients** → `~/.codex/config.toml` (a `[mcp_servers.beckett]` table) |
| **Gemini CLI** | HTTP | panel **Connect Detected Clients** → `~/.gemini/settings.json` |
| **Antigravity** | HTTP | panel **Connect Detected Clients** → `~/.gemini/config/mcp_config.json` |
| **Devin Desktop** (formerly Windsurf) | HTTP | panel **Connect Detected Clients** → `%APPDATA%\devin\mcp_config.json` (`~/.config/devin/mcp_config.json` on macOS and Linux; the Devin CLI reads the same file). Older Windsurf installs: `~/.codeium/windsurf/mcp_config.json` |
| **Zed / Continue / others** | HTTP | point at `http://127.0.0.1:8770/mcp` (or paste the `mcpServers` block from the panel's **Copy config JSON (other clients)**) |
| **Claude Desktop** | stdio only | panel **Connect Detected Clients** → `claude_desktop_config.json` (an `npx -y mcp-remote@0.14.3` bridge) |
| **Any MCP client** | Streamable HTTP | URL `http://127.0.0.1:8770/mcp` |

The panel writes the right file shape per client (Claude Code and Cursor use `mcpServers`, VS Code's own file uses `servers`, Codex uses TOML). **Connect Detected Clients** only writes for clients it finds on the machine, never writes through a symbolic link, and tells you why when it cannot write a file. Only stdio-only clients (Claude Desktop) need Node/`npx`, for the bridge, on their side.

### Claude Code
`.mcp.json` is **already written for you**: just run `claude` in the project folder and it connects (`/mcp` → **beckett**). To wire it up manually elsewhere: `claude mcp add --transport http beckett http://127.0.0.1:8770/mcp`, or press the panel's **Connect Detected Clients** button. The written file:
```json
{
  "mcpServers": {
    "beckett": { "type": "http", "url": "http://127.0.0.1:8770/mcp" }
  }
}
```

### Cursor
Beckett writes `.cursor/mcp.json` when Cursor is installed. By hand, add the same `mcpServers` block as above (type `http`, url `http://127.0.0.1:8770/mcp`).

### VS Code (Copilot)
VS Code 1.138 and later read the workspace `.mcp.json`, which Beckett already writes, so there is nothing to set up. Beckett no longer creates `.vscode/mcp.json`, because a second registration lists the server twice. If an older Beckett left a `.vscode/mcp.json` and VS Code shows Beckett twice, delete the `beckett` entry from that file.

### Devin Desktop
Devin Desktop is the renamed Windsurf. **Connect Detected Clients** writes `mcpServers.beckett.url` into `%APPDATA%\devin\mcp_config.json` on Windows or `~/.config/devin/mcp_config.json` on macOS and Linux (`XDG_CONFIG_HOME` is honored), and keeps any other key you added to that entry. The Devin CLI reads the same file. By hand:
```json
{ "mcpServers": { "beckett": { "url": "http://127.0.0.1:8770/mcp" } } }
```

### VS Code — Cline
Cline keeps its **own** MCP list and **ignores `.vscode/mcp.json`** (that file is Copilot's). The panel's **Connect Detected Clients** writes Cline's `cline_mcp_settings.json` for you. To add it by hand: Cline panel → **MCP Servers** icon → **Remote Servers** → Name `beckett`, URL `http://127.0.0.1:8770/mcp`. Or edit `cline_mcp_settings.json` directly — note `type` must be `streamableHttp`, not `http`:
```json
{ "mcpServers": { "beckett": { "url": "http://127.0.0.1:8770/mcp", "type": "streamableHttp" } } }
```
**Using a local model (LM Studio / Ollama)?** Two gotchas: (1) in Cline's API settings **uncheck "Use compact prompt"** — it strips MCP out (Cline labels it *"Does not support Mcp"*); (2) the model must support **tool / function calling** — small models (e.g. 7B) are flaky over many tools, so drop the Beckett **AI-effort slider to L1–L2** to expose fewer.

### Claude Desktop
Desktop currently expects stdio servers; for an HTTP server use a bridge. **Connect Detected Clients** writes this entry for you:
```json
{ "mcpServers": { "beckett": { "command": "npx", "args": ["-y", "mcp-remote@0.14.3", "http://127.0.0.1:8770/mcp"] } } }
```
The bridge package is pinned to an exact version on purpose: an unpinned `npx mcp-remote` runs whatever npm serves under that name every time Desktop launches, with the endpoint URL (and the token in it) in its arguments. Beckett raises the pin by hand with each release. An entry written before 1.16 runs an unpinned `mcp-remote`, and `doctor` warns about it. Press **Connect Detected Clients** once: it pins the version and refreshes the URL in place, and leaves a `cmd /c` wrapper, other arguments and `env` as they were.

(Claude Code and Cursor connect to the URL directly, so prefer those.)

## 5. Try it
Ask the agent: *"call get_godot_version"*, *"get_scene_tree"*, or *"describe_class CharacterBody2D"*. For a full loop: *"create a Button, play the scene, screenshot it, then read errors with logs_read."*

## Exports

**You do not have to do anything.** Beckett keeps itself out of your shipped game.

Enabling the plugin registers the `BeckettRuntime` autoload, and Godot bakes autoloads into
`project.godot`, so Beckett would otherwise ride into every export. It keeps itself out in these ways:

- **The autoload is a stub.** `runtime/beckett_autoload.gd` names no engine class beyond
  `Node`, and its first act is to require `OS.has_feature("editor")` and the absence of
  `OS.has_feature("template")`. In an export template the first is false and the second true,
  so it stays an empty, silent node: no socket, no timer, no commands served. The second test
  is there because a project's `override.cfg` can fake the `editor` feature but cannot remove
  `template`.
- **Everything else is stripped at export time.** Beckett registers an `EditorExportPlugin`
  that drops every other addon file from the pack. A Lite export goes from ~500 KB of Beckett
  down to a 1.3 KB stub, and the export log says so (measured on Godot 4.6.2):

  ```
  [beckett] kept 50 editor-only file(s) (897.7 KiB) out of the export; only the inert runtime autoload ships
  ```

- **The auth token is dropped too.** The MCP client configs Beckett writes into the project
  (`.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`) carry the token in their URL, and
  `res://.beckett/` holds the token itself. Godot's default filter never exports them, but an
  include filter such as `*.json` does, so the export plugin drops them explicitly:

  ```
  [beckett] kept 1 private file(s) out of the export: MCP client configs and res://.beckett/ carry the auth token
  ```

- **Export runs start no server.** `godot --headless --export-release`, `--export-debug`,
  `--export-pack` and `--export-patch` load every enabled plugin. Beckett detects such a run,
  keeps only the export filter, and prints `[beckett] one-shot run (<flag>)`. It starts no
  server and writes neither `res://.beckett/port` nor your `.mcp.json`, so an export on the
  same machine as a running editor leaves that editor's configs alone.

Opt out with project setting `beckett/strip_from_exports = false` if you want the full addon
in your pack. The opt-out keeps the addon's code; the private files above are dropped either way.

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
| `BECKETT_AUTH=0` | Turn token auth off (local testing only: any local process can then call the server) |
| `BECKETT_READONLY=1` | Block all mutating tools |
| `BECKETT_ALLOWLIST=spawn_.*,list_.*` | Only allow tools matching these regexes |
| `BECKETT_CONFIRM_DESTRUCTIVE=1` | Destructive tools require `confirm:"true"` |
| `BECKETT_ALLOW_OUTSIDE_READS=1` | Let the read tools open files outside the project (your switch, not the agent's). `=0` puts the confinement back over a project setting that a repository committed. Writes stay confined either way |
| `BECKETT_IGNORE_ERROR_BREAKS=0` | Let a game that `play_scene` starts pause in the debugger at a script error (Godot 4.5+). `=1` forces the default (no pause) over a project setting of `false` |

Project settings (Project Settings UI, persist in `project.godot`): `beckett/autostart` (default true), `beckett/auto_write_client_config` (default true), `beckett/port` (default 8770). Two more go under `[beckett]` in `project.godot`: `beckett/allow_outside_reads=true` lets the read tools leave the project (default off; `set_project_setting` refuses to turn it on, so you set it by hand) and `beckett/ignore_error_breaks=false` opts out of the no-pause launch for games `play_scene` starts (default on from Godot 4.5). The environment variable wins over either setting.

## Troubleshooting
- **Client can't connect:** confirm the panel shows *Running*; check the port; the server is off until you Start it. A `401` means the client's config carries a stale token: press **Connect Detected Clients**, or **Rotate** on the Auth token row.
- **A browser-based client or script gets `403` or `415`:** the endpoint refuses a non-loopback `Host` or `Origin`, and a POST that carries an `Origin` header must be `Content-Type: application/json`. Non-browser clients send no `Origin` and are unaffected.
- **You changed the effort dial and the Claude desktop app still shows the old tools:** that app does not rebuild its tool list when the dial moves. Start a new session or restart it.
- **`doctor` warns about an unpinned `mcp-remote`:** press **Connect Detected Clients** once (see Claude Desktop above).
- **`/mcp` shows failed:** make sure the editor is open with the server started before the client connects.
- **Cline connects but the AI only chats / won't use Godot tools:** uncheck **"Use compact prompt"** in Cline's API settings (it disables MCP), confirm Beckett is listed under Cline's **MCP Servers → Remote Servers** (Cline ignores `.vscode/mcp.json` — use **Connect Detected Clients** or add it by hand), and use a model that does **tool calling** (small local models are unreliable — lower the effort slider to L1).
- **A read tool says `Refused to read ...`:** reads are confined to the project folder and `user://`. Use a `res://` path, or an absolute path inside the project. A link that leaves the project is refused by name, and so is a relative path or one with `..`. To read outside the project on purpose, set `allow_outside_reads=true` under `[beckett]` in `project.godot` or start the editor with `BECKETT_ALLOW_OUTSIDE_READS=1`; `doctor` warns while it is on.
- **Runtime tools say the game is paused in the editor's debugger:** a script error or a breakpoint parked it. Press Continue (F12) in the editor's Debugger panel (the Game workspace's Suspend button is a different thing), then read `game_logs`, or call `stop_scene`, fix the script and `play_scene` again. Do not re-run the game outside the editor. On Godot 4.5+ a game that `play_scene` starts does not pause at script errors; one you start with F5 still does.
- **Runtime tools say "game not running":** call `play_scene`, then `wait_until condition=game_connected` before `screenshot` / `get_remote_tree` / `runtime_get_property`.
- **Two editors open:** they'd both try port 8770 — give one a different `BECKETT_PORT`.
