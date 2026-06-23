# Beckett - MCP for Godot (Lite)

Zero-sidecar Model Context Protocol server embedded in the Godot 4 editor.
No Node.js, no Python, no second process. Enable the plugin in Project
Settings > Plugins; it auto-starts and writes .mcp.json so Claude / Cursor /
VS Code connect over local HTTP. Try "get_scene_tree".

This free Lite edition does the whole basic loop: the AI inspects any node
via reflection, authors scenes/scripts/resources (every script parse-checked
before it touches disk), runs your game and reads its logs while you play.

The Full edition makes the AI the playtester - it sees the screen, presses
the buttons and asserts the results - and adds animation tools, background
exports, and the bundled knowledge packs:
https://beckettlabs.itch.io/beckett-godot-mcp

MIT licensed (see LICENSE in this folder). Beckett is a third-party tool,
not affiliated with or endorsed by the Godot Foundation.
