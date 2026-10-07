# Security

Beckett is an MCP server that runs inside the Godot editor, so a connected AI agent gets real control of your project. This page says what the plugin exposes, what protects it, what does not, and how to report a problem. It describes Beckett 1.16. A tool or behavior that exists only in the paid Full edition carries the label (Full edition); the free Lite edition does not ship it.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting. Open the Security tab of [beckettlab/beckett-godot-mcp](https://github.com/beckettlab/beckett-godot-mcp/security) and choose "Report a vulnerability". The report stays between you and the maintainer until a fix is out. Please do not file a public issue for a vulnerability.

A useful report has the Beckett version (`doctor` returns `beckett_version`), the Godot version and OS, the steps that reproduce the problem, and what you expected to happen. The Lite and Full editions share this code, so one report covers both.

Fixes ship in a normal release and are named in its release notes. Run the latest release, since that is where fixes land.

## What Beckett exposes

- The MCP endpoint is HTTP on `127.0.0.1:8770/mcp`, served by the plugin from inside the editor process. When the port is busy the server tries the next nine ports in turn. `BECKETT_PORT` or the project setting `beckett/port` changes the base port. The server starts when you enable the plugin, and `beckett/autostart=false` or `BECKETT_ENABLE=0` stops that.
- The runtime bridge is a second listener on `127.0.0.1:8771`. The game you launch from the editor dials into it, which is how tools screenshot and inspect a running game and, in the Full edition, drive it. It speaks a line protocol, not HTTP, and each editor session mints a secret that the game must present first (`BECKETT_AUTH=0` turns that secret off).
- Both listeners bind loopback only, so no other machine can reach them.

A connected client can do what the tools do: change scenes and scripts, run the project and read the project's files, and in the Full edition install addons and export builds. A script it writes runs with your user rights when the editor or the game loads it. Connecting an agent hands it the editor, so connect only agents you trust with your project.

## What protects the endpoint

### Host and Origin checks

Every request passes these before anything else, and they hold with the token switched off.

- The Host header must name `127.0.0.1`, `localhost` or `[::1]`, and the port the server listens on when it names one. A DNS-rebinding page reaches the server under its own hostname, so its Host header gives it away and it gets 403.
- An Origin header, when there is one, is parsed. The scheme must be `http` or `https` and the host exactly `127.0.0.1`, `localhost` or `[::1]`, with an optional numeric port. `http://127.0.0.1.example.com`, `http://localhost:80@example.com`, `null` and `file://` get 403. A request with no Origin header passes, because Claude Code, Cursor and curl are not browsers.
- A POST that carries an Origin header must use `Content-Type: application/json`, otherwise it gets 415. A browser sends a cross-origin POST without a preflight only as a "simple request" (`text/plain` or a form type), and the server never answers a preflight, so a web page that has to send JSON never reaches a tool. That includes pages served from other local ports, which do pass the Origin check.

### The token

A fresh project gets a random 32-character token, stored in `res://.beckett/token`. That folder holds its own `.gitignore`, so the token stays out of version control. On macOS and Linux the file is owner read and write only (0600), and an older token file is tightened when the server starts. Windows has no such permission bit, so the file keeps the access rules of the project folder.

Requests carry the token as `Authorization: Bearer <token>` or in the URL path (`/mcp/<token>`, the form the client configs Beckett writes use). The comparison does not stop at the first wrong character, and a wrong or missing token gets 401. The dock's Auth token switch turns auth on and off, and Rotate mints a new token and rewrites the detected client configs. `BECKETT_TOKEN` sets the token yourself, for CI.

`BECKETT_AUTH=0` turns auth off. Use it for local testing only: with auth off, any process on the machine can call the server. A project that already has a Beckett entry in its client configs but no token file keeps auth off until you switch it on in the dock, so its clients do not start getting 401. `doctor` warns while auth is off.

### Access controls

These decide what a connected client may do. They run when a tool is called.

- Read-only mode (`BECKETT_READONLY=1`) refuses every tool that changes anything.
- The per-tool switches in the dock turn individual tools off. A switched-off tool leaves the tool list and is refused if a client calls it anyway.
- The allowlist (`BECKETT_ALLOWLIST=regex,regex`) refuses every tool whose name matches none of the patterns.
- `BECKETT_CONFIRM_DESTRUCTIVE=1` makes each destructive tool need `confirm:"true"` in the call.

The editor keeps the last 200 tool calls (the `audit://recent` resource and the dock's activity list), so you can see what an agent did.

### Beckett's own objects and the edition boundary

The tools that take a node path or a resource work on the scene open in the editor, on editor singletons and engine classes, and on `res://` resources. They refuse Beckett's own objects (the plugin, its server, its bridge and its dock, anything below them, and any object whose script lives under `res://addons/beckett/`) and any node outside the open scene, with an error that says Beckett's own internals are off limits. In the game, the runtime of either edition refuses a `set`, `call`, click, typing or scroll command that lands on the runtime or on a node that runs a Beckett script, however the command names its target, and a `play_scene` `on_ready` write that does so is reported as failed, with the reason.

The Lite edition ships the game-side runtime, `runtime/mcp_runtime.gd`, as MIT source, and the Full edition's drive tools use that same file. It understands drive commands (input, clicks, method calls, time control) which only the Full edition's tools send. Lite's tools never send them, and Lite's bridge refuses them: it passes only the commands Lite's own tools use, and it tells the editions apart by the Full-only module `tools/runtime_tools.gd`.

### Where tools read and write

Reads and writes ask one shared check (`core/path_guard.gd`), so the rule cannot drift from tool to tool.

Writes go only under `res://` or `user://`. `write_file`, `write_script`, `script_patch`, `create_resource`, `save_scene` and `apply_template` follow that rule, and so do the files `asset_lib_install` extracts (Full edition), the playtest baseline, suite, report and `.actual.png` files (Full edition), and `compare_screenshots` (Full edition). A path with `..` or a control character is refused. So is a path that goes through a symbolic link or junction whose target lies outside the project and `user://`: the OS follows the link, the file lands somewhere else, and a cloned repository can ship such a link. `screenshot` with `save_to` gets the same link check when the path is a `res://` or `user://` one.

Reads are confined to the project. `read_file`, `read_script`, `list_dir`, `logs_read`, `apply_template`, `build_csharp`, `validate_script` with a path, `load_skill` (Full edition), `test_run` (Full edition), and every tool that opens a scene, script or resource by path accept `res://`, `user://`, or an absolute path inside the project folder or the project's `user://` folder. Anything else is a tool error that names the path: a folder elsewhere on the machine, a relative path (it could mean any folder), a path with `..`, a control character, or a path through a link that leaves the project. A link that stays inside the project is fine. A link that cannot be followed (dangling, looping, unreadable, or on Windows pointing at a network share) is refused. Windows paths compare without regard to case and accept both slashes, and `C:foo` counts as relative. `logs_read` with no path reads the file that `debug/file_logging/log_path` names, under the same rule, because `project.godot` comes with a cloned repository.

The tools that walk the project (`search_files`, `get_project_statistics`, `rescan_filesystem`, the `assets://list` resource, and in the Full edition `find_unused_resources`, `detect_circular_dependencies`, `test_run` and `list_skills`) do not follow a link that leaves it. They list what they skipped in `skipped_links`.

You can opt out for reads only. Set the project setting `beckett/allow_outside_reads=true` (under `[beckett]` in `project.godot`), or start the editor with `BECKETT_ALLOW_OUTSIDE_READS=1`. The environment variable wins in both directions: `BECKETT_ALLOW_OUTSIDE_READS=0` puts the confinement back over a setting that a repository committed. While reads are open, each reply to an outside read carries an `outside_read` note, `doctor` reports `security.file_reads` and warns, and writes stay confined whatever the setting says. The setting belongs to you: `set_project_setting` refuses to turn it on, so an agent cannot lift its own confinement with a call.

### Native code in addons (Full edition)

`asset_lib_install` is a Full edition tool. It reads the file names in the archive before it writes anything. A package that holds native code (`.gdextension`, `.dll`, `.so`, `.dylib`, `.wasm`, `.a`, `.lib`, or anything inside a `.framework` or `.xcframework` folder) is refused, with the file names and a count. Native code runs with your full user rights as soon as the editor loads it, so the agent has to ask you and then call again with `allow_native=true`. An archive entry whose name contains a colon is never written. On Windows such a name can address an NTFS alternate stream and land as a real file.

### Config files

The writers behind Connect Detected Clients and the automatic project `.mcp.json` never write through a symbolic link or junction (the file, or the folder that holds it) and leave read-only files alone. They replace a file atomically and keep its permissions. A JSON file they cannot parse is copied aside before the rewrite, and a TOML file they cannot read is left untouched. The token file and the port file get the same link refusal.

### Shipped games

Beckett registers an autoload, and Godot bakes autoloads into exports. The autoload is a stub that does nothing unless the game runs under the editor: it returns at once when the `editor` feature is missing or the `template` feature is present. The second test matters because a project's `override.cfg` can fake the `editor` feature, while `template` exists only in a real export template. An export plugin also drops every other addon file from the pack, plus the client configs and `res://.beckett/`, so the token does not ship even under an include filter like `*.json`. Export runs and the other one-shot editor modes (`--import`, for one) start no server and leave `.mcp.json` and `.beckett/port` alone.

### Supply chain

Beckett has no npm or PyPI package. The addon is GDScript files that you copy into your project, and the plugin starts child processes from argument lists: the Godot binary (for checks, and for exports in the Full edition), `dotnet` for `build_csharp`, and `git` for `playtest` `since` (Full edition). Windows starts each program directly. On Linux and macOS Godot's `OS.execute` hands one command line to `sh` with every argument inside double quotes, and `sh` still expands `$(...)` and backticks there, so the one free-form value an agent gives to `git`, the ref of `playtest` `since` (Full edition), is refused when it holds either one. The children that run the Godot binary get their arguments as positional parameters of a fixed script instead. `build_csharp` takes a path to an existing `.csproj` inside the project, and `dotnet build` runs whatever that project says.

The one third-party package in the picture is `mcp-remote`. Claude Desktop only speaks stdio, so its config entry runs `npx -y mcp-remote@0.14.3 <url>` to bridge to the endpoint. The version is pinned to an exact release and raised by hand, so a bad publish under that name does not reach you on launch. That package still runs on your machine whenever the bridge starts, with the endpoint URL (token included) in its arguments.

Beckett sends no telemetry. The Lite edition makes no requests to the internet itself: the dock's Get Full button opens a store page in your browser when you press it. In the Full edition the only requests are the Asset Store and Asset Library lookups and downloads that you or your agent ask `asset_lib_search`, `asset_lib_info` and `asset_lib_install` (all Full edition) to make.

## What is not a security boundary

- The effort dial trims what `tools/list` advertises, to save context. A tool the dial hides still runs when a client calls it by name, so the dial restricts nothing. The access controls above do that job.
- Token auth keeps other local processes and web pages from calling the server. The agent you connected holds the token and can use every tool the access controls allow.
- `allow_native` (a parameter of `asset_lib_install`, Full edition) covers native libraries. Any addon is code, and its scripts run in your editor once you enable the plugin.
- In the Full edition a playtest suite is code, and `playtest op=export_gd` writes a GDScript file that runs it under `godot --script`. A suite's `expr` asserts, per-frame rules and `inject` steps run inside your game. Replaying or exporting a suite from a repository you did not write runs whatever it holds, so read it first.
- The split between the Lite and Full editions is a product boundary, not a sandbox. Lite is MIT source and carries the game-side runtime, and code an agent writes runs with your user rights, so the split keeps Lite's tools from driving a game and nothing more.

## Known limits

- The read confinement is a guard rail, not a sandbox. A script an agent writes runs with your user rights once the editor or the game loads it, and it can read whatever you can. The check stops a tool call from reaching a file outside the project. It does not contain code.
- A path is judged when the call arrives. A link swapped in between that check and the read or write is not caught, and a hard link looks like an ordinary file, so neither is detected.
- An agent can still edit `project.godot` with `write_file`, the `[beckett]` section included. The running editor does not re-read `beckett/allow_outside_reads`, so the confinement holds for that session, but the setting would apply the next time the project opens. `doctor` warns while outside reads are on, and a diff of `project.godot` shows the change.
- Two tools write outside `res://` on purpose. `screenshot` with `save_to` accepts an absolute path, and `export_project` (Full edition) writes the build to the preset's export path or to `output_path`.
- The headless playtest runner (Full edition), which you start from a shell, reads suites and scenes without the read check.
- Native-code detection in `asset_lib_install` (Full edition) reads names. A library hidden under a suffix that is not on the list passes. The check exists so that an agent asks you first, and it does not scan file contents.
- The token is easy to leak by accident. With auth on, `.mcp.json`, `.cursor/mcp.json` and `.vscode/mcp.json` carry it in their URL, Beckett does not add them to `.gitignore` (only `res://.beckett/` ignores itself), and the editor's Output panel prints the endpoint URL at startup. Keep those files and that log out of public places. If the token leaks, press Rotate in the dock.
- The rule that keeps Beckett's tools off Beckett's own objects judges the objects a tool is asked to resolve. A `NodePath` kept inside a value, such as the path of an animation track, is stored as written and resolved later by the engine, so the rule does not read it.
- That rule does not contain code an agent writes. A `@tool` script, or any script the editor loads, runs with your user rights in the editor process and can reach every object there, Beckett's own included.

## Fixed issues

In 1.16.0 the Origin check was fixed. Through 1.15.2 it compared prefixes against `http://127.0.0.1`, `http://localhost` and `http://[::1]`. A page served from a hostname that starts that way, such as `localhost.example.com`, passed it, and a browser can send a `text/plain` POST cross-origin without a preflight. With token auth off, such a page could trigger tool calls blindly, since it cannot read the reply. With auth on, the missing token stopped it. Token auth defaults to on only for new projects, so older projects stayed exposed until they enabled it. 1.16.0 parses the Origin header and requires `application/json` on POSTs that carry one.

1.16.0 also ends two limits that this page listed for 1.15.2 and earlier. The read tools opened any path the editor process could read, and a write to a path under a symbolic link or junction went wherever the link pointed. Reads are now confined to the project and `user://`, and neither a read nor a write follows a link out of them (see Where tools read and write).

1.16.0 also closes two routes by which the Lite edition's own tools reached game commands that only the Full edition's tools send. An audit of the published 1.16.0 Lite package on 2026-10-07 found them, and earlier Lite releases have them too. `call_method` accepted the absolute path of Beckett's runtime bridge as its target and `send_command` as its method, and the bridge passed any command to the running game, where `eval`, input injection, clicks, method calls and time control ran. `play_scene` `on_ready` is a `set` in the game, so it could also write the private variables of the runtime autoload (`_recording`, `_step_inputs`, `_stepping` and others), and the game then injected input, recorded and replayed. In both cases the caller was an agent you had connected, and such an agent can already write scripts that run in your game, so the effect was on the edition boundary. The tools now refuse Beckett's own objects, the runtime refuses writes and calls that land on itself, and a Lite install's bridge passes only the commands Lite's own tools send (see Beckett's own objects and the edition boundary).
