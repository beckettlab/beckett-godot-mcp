@tool
extends EditorExportPlugin

## Keeps Beckett out of your shipped game.
##
## Beckett is an editor tool, but two things pull it into exports anyway: the
## plugin registers a project autoload (baked into project.godot, and therefore
## into every preset), and Godot's default export filter is "all resources in the
## project", which sweeps up all of addons/. Left alone that ships ~475 KB of
## compiled editor-only GDScript (the dock panel, the MCP server, every tool
## module) that a game can never load.
##
## This runs at export time and skip()s every Beckett file except the autoload
## stub, which has to stay because project.binary names it. The stub is inert
## outside the editor (see runtime/beckett_autoload.gd), so the net effect is a
## pack with no Beckett in it.
##
## It also skip()s Beckett's private per-project files: the MCP client configs it
## writes (their URL carries the auth token) and res://.beckett/ (the token itself).
## The default "all resources" filter never picks those up, but an include_filter
## such as *.json does, and that shipped the token inside a game (field report
## 2026-09-29). Those are skipped even with the opt-out below: that setting keeps the
## addon's code in the pack, it was never a reason to ship a credential.
##
## Doing it here rather than by writing exclude_filter into the user's
## export_presets.cfg means it needs no setup, covers every preset including ones
## added later, works the same in CI, and never edits a file we do not own.
##
## Opt out with project setting beckett/strip_from_exports = false.

const MCPClientConfigScript := preload("res://addons/beckett/core/client_config.gd")

const ADDON_PREFIX := "res://addons/beckett/"
const SETTING := "beckett/strip_from_exports"

## Beckett's own runtime state (token, live port). Mirrors mcp_server.gd AUTH_TOKEN_FILE's
## directory; the unit suite checks the two agree.
const STATE_DIR := "res://.beckett/"

## The one file that must survive: project.binary's autoload/BeckettRuntime points
## at it, and an autoload whose script is missing from the pack is a hard error on
## every boot, which is precisely the noise this plugin exists to remove.
const KEEP := "res://addons/beckett/runtime/beckett_autoload.gd"

var _skipped := 0
var _bytes := 0
var _private := 0


## A file that may carry the auth token (or other servers' settings): never game content. That is
## each client config AND the siblings its writer leaves beside it (client_config.gd): the
## `.invalid-<stamp>.bak` copy of a config it could not parse, and the `.beckett-tmp` / `.beckett-old`
## files of an interrupted replace, each of which holds a whole config, token included.
static func is_private_file(path: String) -> bool:
	if path.begins_with(STATE_DIR):
		return true
	for cfg in MCPClientConfigScript.PROJECT_CONFIG_FILES:
		if path == cfg or path.begins_with(str(cfg) + "."):
			return true
	return false


func _get_name() -> String:
	return "Beckett"


func _export_begin(_features, _is_debug, _path, _flags) -> void:
	_skipped = 0
	_bytes = 0
	_private = 0


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if is_private_file(path):
		_private += 1
		skip()
		return
	if path == KEEP or not path.begins_with(ADDON_PREFIX):
		return
	if not bool(ProjectSettings.get_setting(SETTING, true)):
		return
	# Measured before skip() so the report can say what the user actually saved.
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		_bytes += f.get_length()
		f.close()
	_skipped += 1
	skip()


func _export_end() -> void:
	if _skipped > 0:
		print("[beckett] kept %d editor-only file(s) (%s) out of the export; only the inert runtime autoload ships"
			% [_skipped, String.humanize_size(_bytes)])
	if _private > 0:
		print("[beckett] kept %d private file(s) out of the export: MCP client configs and res://.beckett/ carry the auth token"
			% _private)
