@tool
extends RefCounted

## Beckett's own version number, read from addons/beckett/plugin.cfg and nowhere else (v1.16).
##
## Why it exists: through v1.15.2 the initialize reply said "version": "1.0.0", a literal in
## mcp_server.gd that had not changed since v1.2.0, so no client ever saw the real release number.
## doctor, the dock and the playtest reports each kept a private plugin.cfg reader, and the asset
## tools sent a User-Agent with a literal 0.1. plugin.cfg is the file `release.ps1 -Bump` stamps, so
## a number read from it cannot drift from the release. Everything that names the version asks here:
## current() is read once and kept, from_cfg() is the reader behind it.
##
## When plugin.cfg cannot be read (a partial install, a stripped export) or declares no version, the
## answer is UNKNOWN: a plain word, never an empty string and never a crash.

const PLUGIN_CFG := "res://addons/beckett/plugin.cfg"
## What a caller gets when there is no version to report.
const UNKNOWN := "unknown"

## Where current() reads. A var only so the unit suite can aim it at a missing or a scratch file; nothing else assigns it.
static var cfg_path: String = PLUGIN_CFG
static var _cached: String = ""  # set by the first read that finds a version; a failed read is not kept, so the next call tries again


## The version a plugin.cfg declares under [plugin], or UNKNOWN when the file cannot be read or declares none.
## Not cached: this is the reader, and current() is what everything else calls.
static func from_cfg(path: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return UNKNOWN
	var v := str(cfg.get_value("plugin", "version", "")).strip_edges()
	return v if not v.is_empty() else UNKNOWN


## Beckett's version, read from plugin.cfg once and then served from memory. UNKNOWN when it cannot be read.
static func current() -> String:
	if _cached.is_empty():
		var v := from_cfg(cfg_path)
		if v == UNKNOWN:
			return UNKNOWN
		_cached = v
	return _cached
