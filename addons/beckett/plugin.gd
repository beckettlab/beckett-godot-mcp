@tool
extends EditorPlugin

## Beckett (MCP for Godot) — EditorPlugin entry point.
## Wires up the embedded MCP server (zero-sidecar) and an optional dock panel.
## The server is OFF by default; it starts only when BECKETT_ENABLE=1 (or via the panel).

const MCPServerScript := preload("res://addons/beckett/core/mcp_server.gd")
const PanelScript := preload("res://addons/beckett/panel/panel.gd")
const MCPClientConfig := preload("res://addons/beckett/core/client_config.gd")

const DEFAULT_PORT := 8770
const RUNTIME_AUTOLOAD := "BeckettRuntime"
const RUNTIME_SCRIPT := "res://addons/beckett/runtime/mcp_runtime.gd"

var _server: MCPServerScript = null
var _panel: Control = null


func _enter_tree() -> void:
	# Runtime helper autoload — runs only in the played game (non-@tool); drives the
	# play→observe→fix loop. Harmless when the server is off (it just fails to dial).
	if not ProjectSettings.has_setting("autoload/" + RUNTIME_AUTOLOAD):
		add_autoload_singleton(RUNTIME_AUTOLOAD, RUNTIME_SCRIPT)

	_server = MCPServerScript.new()
	_server.name = "GodotMCPServer"
	_server.plugin = self
	add_child(_server)
	_server.setup()

	# Default OFF for safety (opt-in start, like best-ue-mcp). Env var is the
	# headless/CI on-ramp; a Start button on the dock panel is the interactive one.
	var port := _port()
	# Easiest install: enabling the plugin starts the server (localhost-only, Origin-checked).
	# Opt out with project setting beckett/autostart=false or env BECKETT_ENABLE=0.
	if _autostart():
		var err := _server.start_server(port)
		if err == OK:
			print("[beckett] server listening on http://127.0.0.1:%d/mcp" % port)
		else:
			push_error("[beckett] failed to start server: %s" % error_string(err))

	# Zero-click connect: write/merge configs for the clients that actually exist here
	# (.mcp.json always; .cursor / .vscode when that app is installed). Merge, never
	# clobber. Claude Desktop stays button-only (global file + npx bridge) — see panel.
	if _auto_write_config():
		MCPClientConfig.ensure_auto(port)

	# Dock panel — status, Start/Stop, set up client, copy config.
	_panel = PanelScript.new()
	_panel.name = "Beckett"  # set BEFORE add so the dock tab title is correct on 4.2-4.4 too
	_panel.server = _server
	_panel.plugin = self
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _panel)
	_reveal_dock_once()


## First time the plugin is enabled in a project, bring our dock tab to the front so it's
## discoverable. The editor's right dock can overflow, hiding a 4th tab (ours) behind the
## tab-scroll arrows — and on Godot 4.2-4.4 a control renamed *after* add_control_to_dock
## keeps a blank tab title, so without this the tab is effectively invisible. Gated by a
## project flag so we reveal once (first enable / first launch after update) and never
## fight the user's chosen layout afterward.
func _reveal_dock_once() -> void:
	if bool(ProjectSettings.get_setting("beckett/dock_revealed", false)):
		return
	ProjectSettings.set_setting("beckett/dock_revealed", true)
	ProjectSettings.save()
	# Defer past the editor's own dock-layout restore, which runs after _enter_tree.
	get_tree().create_timer(0.7).timeout.connect(_bring_dock_to_front)


func _bring_dock_to_front() -> void:
	if not is_instance_valid(_panel):
		return
	var p: Node = _panel.get_parent()
	while p != null and not (p is TabContainer):
		p = p.get_parent()
	if p is TabContainer:
		var idx := _panel.get_index()
		if idx >= 0:
			(p as TabContainer).current_tab = idx


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		remove_control_from_docks(_panel)
		_panel.free()
	_panel = null
	if is_instance_valid(_server):
		_server.stop_server()
		_server.queue_free()
	_server = null
	if ProjectSettings.has_setting("autoload/" + RUNTIME_AUTOLOAD):
		remove_autoload_singleton(RUNTIME_AUTOLOAD)


func _port() -> int:
	var penv := OS.get_environment("BECKETT_PORT")
	if penv != "" and penv.is_valid_int():
		return penv.to_int()
	return int(ProjectSettings.get_setting("beckett/port", DEFAULT_PORT))


func _autostart() -> bool:
	var env := OS.get_environment("BECKETT_ENABLE")
	if env != "":
		return env == "1" or env.to_lower() == "true"
	return bool(ProjectSettings.get_setting("beckett/autostart", true))


func _auto_write_config() -> bool:
	# Env override first (lets CI/smoke boots leave the project's .mcp.json alone).
	var env := OS.get_environment("BECKETT_AUTO_CONFIG")
	if env != "":
		return env == "1" or env.to_lower() == "true"
	return bool(ProjectSettings.get_setting("beckett/auto_write_client_config", true))
