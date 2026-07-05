# Glama registry shim

A tiny **stdio MCP server** that exists for one reason: to let the
[Glama registry](https://glama.ai) grade Beckett's **quality score**.

## Why this exists

Beckett is a **zero-sidecar** MCP server: it is embedded inside the Godot 4 editor
(GDScript, Streamable-HTTP transport). There is no standalone process to install and
run. Glama grades an MCP server by building it, connecting over stdio, and running the
standard introspection exchange (`initialize` -> `tools/list`) to score **Tool
Definition Quality** and **Server Coherence**. With nothing to build, Beckett's quality
axis stayed *"not evaluated"* - which blocks listing on directories that require a
graded score (e.g. `awesome-mcp-servers`).

This shim closes that gap. It is a ~90-line, dependency-free Node server that:

- answers `initialize`, `ping`, `tools/list`, `resources/list`, `prompts/list`;
- serves the **real Lite-edition tool definitions** (`tools.json`) captured from the
  running addon - the exact names, descriptions, and input schemas Glama scores;
- **stubs `tools/call`**: the actual tools run inside the Godot editor, not here.

It exposes nothing that is not already public: `tools.json` holds the Lite tool schemas,
which already ship in this MIT repo under `addons/beckett/`.

## What it is NOT

- **Not the product.** It cannot drive Godot, edit a scene, or run a game. It returns an
  error on every `tools/call` pointing at the real addon.
- **Not shipped to users.** It is never in the addon zip. It lives only in this public
  repo so Glama can build it.

## Files

| file | purpose |
|---|---|
| `server.js` | the stdio MCP server (pure Node, no dependencies) |
| `tools.json` | captured Lite `tools/list` payload (generated - do not hand-edit) |
| `package.json` | Node metadata (no deps) |
| `Dockerfile` | how Glama builds + runs it (`node:20-alpine`) |

## Regenerating `tools.json`

`tools.json` is generated from the live addon so it never drifts. From the **monorepo**:

```powershell
pwsh dev/glama-dump-tools.ps1
```

That stages the Lite build, boots a headless editor, reads `tools/list` over HTTP, and
writes the sorted payload here. Re-run it whenever the Lite tool surface changes (it is
wired into `dev/RELEASE-PLAYBOOK.md`).

## Local smoke test

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | node server.js
```

You should get two JSON-RPC responses: the server info, then the full tool list.
