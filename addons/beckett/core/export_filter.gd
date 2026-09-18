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
## Doing it here rather than by writing exclude_filter into the user's
## export_presets.cfg means it needs no setup, covers every preset including ones
## added later, works the same in CI, and never edits a file we do not own.
##
## Opt out with project setting beckett/strip_from_exports = false.

const ADDON_PREFIX := "res://addons/beckett/"
const SETTING := "beckett/strip_from_exports"

## The one file that must survive: project.binary's autoload/BeckettRuntime points
## at it, and an autoload whose script is missing from the pack is a hard error on
## every boot, which is precisely the noise this plugin exists to remove.
const KEEP := "res://addons/beckett/runtime/beckett_autoload.gd"

var _skipped := 0
var _bytes := 0


func _get_name() -> String:
	return "Beckett"


func _export_begin(_features, _is_debug, _path, _flags) -> void:
	_skipped = 0
	_bytes = 0


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
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
