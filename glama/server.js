#!/usr/bin/env node
'use strict';

/*
 * Beckett - MCP for Godot: Glama directory-inspection shim.
 *
 * THIS IS NOT THE PRODUCT. Beckett is a zero-sidecar MCP server embedded in the
 * Godot 4 editor (GDScript, Streamable-HTTP transport) - there is no standalone
 * process to install and run. That is why the Glama registry (https://glama.ai)
 * could never build it, and its quality axis sat "not evaluated".
 *
 * This tiny stdio server exists ONLY so Glama can build a container, run the
 * standard MCP introspection exchange (initialize -> tools/list), and grade Tool
 * Definition Quality + Server Coherence. It serves the REAL Lite-edition tool
 * definitions (names, descriptions, input schemas) captured from the running
 * addon into tools.json - all already public in this MIT repo's addons/beckett/.
 * It stubs every tools/call: the actual tools run inside the Godot editor.
 *
 * Regenerate tools.json with dev/glama-dump-tools.ps1 (monorepo). Pure Node, no
 * dependencies. See README.md.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const TOOLS = JSON.parse(fs.readFileSync(path.join(__dirname, 'tools.json'), 'utf8'));

const LATEST_PROTOCOL = '2025-06-18';
const SERVER_INFO = {
  name: 'beckett-godot-mcp',
  title: 'Beckett - MCP for Godot (Lite)',
  version: '1.0.0',
};
const INSTRUCTIONS =
  'Directory-inspection shim for the Glama registry. Beckett is a zero-sidecar MCP ' +
  'server embedded in the Godot 4 editor: enable the addon ' +
  '(https://github.com/beckettlab/beckett-godot-mcp) and it auto-starts inside the ' +
  'editor over local HTTP. The tools below are the real tool definitions, advertised ' +
  'here for scoring; they execute in the editor, not in this stub.';

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}
function result(id, res) {
  send({ jsonrpc: '2.0', id: id, result: res });
}
function error(id, code, message) {
  send({ jsonrpc: '2.0', id: id, error: { code: code, message: message } });
}

function handle(msg) {
  const id = msg.id;
  const method = msg.method;
  const params = msg.params || {};

  // JSON-RPC notifications carry no id and never get a reply.
  if (id === undefined || id === null) return;

  switch (method) {
    case 'initialize':
      result(id, {
        // Echo the client's requested revision when it sends one (max compat),
        // otherwise offer our latest.
        protocolVersion: params.protocolVersion || LATEST_PROTOCOL,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
      break;

    case 'ping':
      result(id, {});
      break;

    case 'tools/list':
      result(id, { tools: TOOLS });
      break;

    // This server has no resources or prompts; answer emptily so a client that
    // probes them (Glama does) gets a clean result rather than method-not-found.
    case 'resources/list':
      result(id, { resources: [] });
      break;
    case 'resources/templates/list':
      result(id, { resourceTemplates: [] });
      break;
    case 'prompts/list':
      result(id, { prompts: [] });
      break;

    case 'tools/call':
      // Definitions only: the real tool runs inside the Godot editor.
      result(id, {
        content: [{
          type: 'text',
          text: "This is a directory-inspection stub for the Glama registry. Beckett's " +
            'tools run inside the Godot 4 editor - install the addon at ' +
            'https://github.com/beckettlab/beckett-godot-mcp and it auto-starts there.',
        }],
        isError: true,
      });
      break;

    default:
      error(id, -32601, 'Method not found: ' + method);
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try {
    msg = JSON.parse(s);
  } catch (e) {
    return; // ignore non-JSON lines
  }
  try {
    handle(msg);
  } catch (e) {
    if (msg && msg.id !== undefined && msg.id !== null) {
      error(msg.id, -32603, 'Internal error');
    }
  }
});
