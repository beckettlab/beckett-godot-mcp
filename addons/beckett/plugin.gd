@tool
extends EditorPlugin

## Beckett (MCP for Godot) — EditorPlugin entry point.
## Wires up the embedded MCP server (zero-sidecar) and an optional dock panel.
## The server is OFF by default; it starts only when BECKETT_ENABLE=1 (or via the panel).

const MCPServerScript := preload("res://addons/beckett/core/mcp_server.gd")
const PanelScript := preload("res://addons/beckett/panel/panel.gd")
const MCPClientConfig := preload("res://addons/beckett/core/client_config.gd")
const ExportFilterScript := preload("res://addons/beckett/core/export_filter.gd")

const RUNTIME_AUTOLOAD := "BeckettRuntime"
## A parse-safe stub, NOT the implementation. It is the one Beckett file that reaches a
## shipped game, so it names no engine class that a custom build profile could strip and
## it goes inert outside the editor. See runtime/beckett_autoload.gd for the full why.
const RUNTIME_SCRIPT := "res://addons/beckett/runtime/beckett_autoload.gd"
## What the autoload pointed at before the stub existed; projects set up then get re-pointed.
const LEGACY_RUNTIME_SCRIPT := "res://addons/beckett/runtime/mcp_runtime.gd"

var _server: MCPServerScript = null
var _panel: Control = null   # the dock content (VBox of cards)
var _dock: Control = null    # ScrollContainer wrapping _panel; the control actually docked
var _export_filter: EditorExportPlugin = null  # strips the addon out of the user's exports


func _enter_tree() -> void:
	# Runtime helper autoload — runs only in the played game (non-@tool); drives the
	# play→observe→fix loop. Harmless when the server is off (it just fails to dial).
	_install_runtime_autoload()

	# The autoload is baked into project.godot, so Beckett rides into every export whether
	# the user wants it or not. This strips the addon back out at export time, leaving only
	# the inert stub. Registered before anything can fail below it, and paired with the
	# remove_export_plugin in _exit_tree.
	_export_filter = ExportFilterScript.new()
	add_export_plugin(_export_filter)

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
			print("[beckett] server listening on " + MCPClientConfig.mcp_url(_server.http.port, _server.auth_token())
				+ (" (token auth on)" if _server.auth_enabled() else ""))
		else:
			push_error("[beckett] failed to start server: %s" % error_string(err))

	# Zero-click connect: write/merge configs for the clients that actually exist here
	# (.mcp.json always; .cursor / .vscode when that app is installed). Merge, never
	# clobber. Claude Desktop stays button-only (global file + npx bridge) — see panel.
	# The auth token (when on) rides in the URL, and the LIVE port is used (B5: it may
	# have walked past a busy one), so configs stay in lockstep with both.
	if _auto_write_config():
		MCPClientConfig.ensure_auto(_server.http.port if _server.is_running() else port, _server.auth_token())

	# Dock panel — status, Start/Stop, set up client, copy config.
	_panel = PanelScript.new()
	_panel.server = _server
	_panel.plugin = self
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Wrap the panel in a ScrollContainer before docking. The panel is a tall stack of
	# cards; on a short screen or a high editor scale their combined min height can exceed
	# the dock's available height and force the whole editor window taller than the monitor,
	# pushing the bottom panels (Output/Debugger/Shader…) below the screen edge. A
	# ScrollContainer keeps the DOCKED control's min height near-zero (content scrolls
	# instead), so Beckett can never drive the editor past the screen. The wrapper is the
	# control added to the dock, so it carries the "Beckett" name for the tab title (set
	# BEFORE add so it's correct on 4.2-4.4 too).
	_dock = ScrollContainer.new()
	_dock.name = "Beckett"
	_dock.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dock.add_child(_panel)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
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
	if not is_instance_valid(_dock):
		return
	var p: Node = _dock.get_parent()
	while p != null and not (p is TabContainer):
		p = p.get_parent()
	if p is TabContainer:
		var idx := _dock.get_index()
		if idx >= 0:
			(p as TabContainer).current_tab = idx


func _exit_tree() -> void:
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.free()  # frees _panel too (its child)
	_dock = null
	_panel = null
	if is_instance_valid(_server):
		_server.stop_server()
		_server.queue_free()
	_server = null
	if _export_filter != null:
		remove_export_plugin(_export_filter)
	_export_filter = null
	if ProjectSettings.has_setting("autoload/" + RUNTIME_AUTOLOAD):
		remove_autoload_singleton(RUNTIME_AUTOLOAD)


## Register the runtime autoload, or re-point an older one at the stub.
##
## Projects set up before the stub existed have the autoload aimed straight at
## mcp_runtime.gd. That file names Camera3D, MeshInstance3D, ShaderMaterial, GraphEdit and
## friends at parse time, so on an engine built with a stripped class profile it fails to
## parse and the player sees the errors at boot. Re-pointing is the whole upgrade.
func _install_runtime_autoload() -> void:
	var key := "autoload/" + RUNTIME_AUTOLOAD
	if not ProjectSettings.has_setting(key):
		add_autoload_singleton(RUNTIME_AUTOLOAD, RUNTIME_SCRIPT)
		return
	if _autoload_target(str(ProjectSettings.get_setting(key, ""))) != LEGACY_RUNTIME_SCRIPT:
		return
	remove_autoload_singleton(RUNTIME_AUTOLOAD)
	add_autoload_singleton(RUNTIME_AUTOLOAD, RUNTIME_SCRIPT)
	# add/remove_autoload_singleton only touch ProjectSettings in memory; the editor happens
	# to flush that on a fresh add but not on this re-point, which would leave project.godot
	# still naming mcp_runtime.gd forever (correct at runtime, wrong in the file the user and
	# their CI actually read). Persist it once, here, since we know we just changed it.
	var err := ProjectSettings.save()
	if err != OK:
		push_warning("[beckett] could not save project.godot after re-pointing the runtime autoload: %s" % error_string(err))
		return
	print("[beckett] runtime autoload re-pointed at the export-safe stub (%s)" % RUNTIME_SCRIPT)


## Resolve an [autoload] entry's value to a res:// path.
##
## Two things make a plain string compare wrong: the value carries a leading "*" when the
## autoload is exposed as a singleton, and since 4.4 the editor writes the target as a
## uid:// reference rather than a path, so the stored value for mcp_runtime.gd can read
## "*uid://dspgi2nxto4e8" with the path nowhere in sight.
static func _autoload_target(value: String) -> String:
	var p := value.trim_prefix("*")
	if not p.begins_with("uid://"):
		return p
	var id := ResourceUID.text_to_id(p)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return p
	return ResourceUID.get_id_path(id)


## The port we ask for at boot. Shared with the dock (MCPClientConfig.configured_port) so a
## manual Stop→Start can never bind a different port than this did.
func _port() -> int:
	return MCPClientConfig.configured_port()


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
