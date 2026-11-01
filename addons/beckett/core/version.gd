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
##
## The BUILD (1.17): a version number alone could not tell a copy of the 1.16.0 addon carrying two
## draft skill files from the 1.16.0 release, or from the monorepo with a long unreleased list: all
## three said 1.16.0. display() adds the first 8 hex digits of a fingerprint of the addon's own text
## files, "1.17.0-dev+3f9a2c1d", which serverInfo.version, doctor and the dock's tooltip show. The
## fingerprint normalizes what a checkout changes and the content does not (a UTF-8 BOM, CRLF), so a
## Windows checkout and a Linux one of the same commit agree, and dev/addon-fingerprint.ps1 is its
## PowerShell twin (pack.ps1 stamps addons/beckett/build.cfg with it; the unit suite pins both to the
## same known answers). current() stays the plain version: the asset tools' User-Agent and the
## playtest suite stamps keep it, so a suite users commit does not churn with every edit.

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # is_link_path: a linked folder is not walked into

const PLUGIN_CFG := "res://addons/beckett/plugin.cfg"
## What a caller gets when there is no version to report.
const UNKNOWN := "unknown"
## The tree the fingerprint covers, and the stamp pack.ps1 writes into every package (never part of it).
const ADDON_DIR := "res://addons/beckett"
const BUILD_STAMP := "build.cfg"
## Text files only: .uid and .import are written by the editor (4.4+ adds a .uid beside any script lacking
## one, 4.2 and 4.3 do not), so counting them would give one copy a different figure per engine.
const FINGERPRINT_EXTS := ["gd", "md", "cfg", "tscn", "tres", "json", "gdshader"]
## How many hex digits of the fingerprint the build string carries.
const FINGERPRINT_SHOWN := 8

## Where current() reads. A var only so the unit suite can aim it at a missing or a scratch file; nothing else assigns it.
static var cfg_path: String = PLUGIN_CFG
static var _cached: String = ""  # set by the first read that finds a version; a failed read is not kept, so the next call tries again
## The addon's fingerprint, computed on first use and then kept for the process (an edit under a running editor shows
## after a restart, as the version already does). _fp_files 0 = nothing could be read.
static var _fp_hash: String = ""
static var _fp_files: int = -1
static var _fp_usec: int = 0


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


# ---------------------------------------------------------------- the build

## The exact build: the plugin.cfg version, then "+" and the first 8 hex digits of the addon's fingerprint
## ("." instead when the version already carries a "+", which keeps it valid semver). UNKNOWN when there is
## no version, and the bare version when no addon file could be read.
static func display() -> String:
	var v := current()
	if v == UNKNOWN:
		return UNKNOWN
	var fp := fingerprint()
	if fp.is_empty():
		return v
	return v + ("." if v.contains("+") else "+") + fp.left(FINGERPRINT_SHOWN)


## The addon's fingerprint, 64 hex digits, computed once per process; "" when no addon file could be read.
static func fingerprint() -> String:
	if _fp_files < 0:
		var t0 := Time.get_ticks_usec()
		var fp := fingerprint_of(ADDON_DIR)
		_fp_usec = Time.get_ticks_usec() - t0
		_fp_files = int(fp["files"])
		_fp_hash = str(fp["hash"]) if _fp_files > 0 else ""
	return _fp_hash


## How many files the kept fingerprint covers, and how long it took (the unit suite prints both).
static func fingerprint_files() -> int:
	fingerprint()
	return maxi(_fp_files, 0)


static func fingerprint_usec() -> int:
	fingerprint()
	return _fp_usec


## {hash, files} for the tree at `root`: the SHA-256 (lowercase hex) of the sorted per-file digests joined
## with LF. Pure apart from the reads, so the unit suite runs it on a scratch tree with known answers.
static func fingerprint_of(root: String) -> Dictionary:
	var digests: Array = []
	_collect(root, "", digests)
	digests.sort()
	return {"hash": "\n".join(PackedStringArray(digests)).sha256_text(), "files": digests.size()}


static func _collect(root: String, rel_dir: String, out: Array) -> void:
	var path := root if rel_dir.is_empty() else root.path_join(rel_dir)
	var da := DirAccess.open(path)
	if da == null:
		return
	# A file the OS marks hidden is walked like any other (PowerShell's Directory.GetFiles returns it too);
	# dotfiles are left out by name on both sides instead.
	da.include_hidden = true
	for f in da.get_files():
		var rel: String = f if rel_dir.is_empty() else rel_dir + "/" + f
		if fingerprint_includes(rel):
			out.append(file_digest(rel, FileAccess.get_file_as_string(path.path_join(f))))
	for d in da.get_directories():
		if d.begins_with("."):
			continue
		var sub := path.path_join(d)
		# A linked folder is not the addon's own content (4.3+ can tell; 4.2 has no is_link and follows it).
		if PathGuard.is_link_path(ProjectSettings.globalize_path(sub)):
			continue
		_collect(root, d if rel_dir.is_empty() else rel_dir + "/" + d, out)


## One file's digest: SHA-256 (lowercase hex) of its path below the addon, LF, and its text with every
## leading U+FEFF dropped and CRLF turned into LF. Godot drops a UTF-8 BOM when it decodes a file and .NET
## keeps it, so both sides drop it themselves rather than lean on either decoder. The BOM is compared by
## code point, never as a literal: an invisible character a paste or an editor can drop would leave
## begins_with(""), which is always true, and the loop would never end.
static func file_digest(rel: String, text: String) -> String:
	var t := text
	while not t.is_empty() and t.unicode_at(0) == 0xFEFF:
		t = t.substr(1)
	return (rel + "\n" + t.replace("\r\n", "\n")).sha256_text()


## Does the file at `rel` (a path below the addon, "/" separated) count toward the fingerprint? Not a
## dotfile, not the build stamp, not an extension outside FINGERPRINT_EXTS (so no .uid, .import, image or
## LICENSE), and not an .md at the addon root (README.md and INSTALL.md are the package's docs).
static func fingerprint_includes(rel: String) -> bool:
	var file := rel.get_file()
	if file.begins_with(".") or rel == BUILD_STAMP:
		return false
	var ext := file.get_extension().to_lower()
	if not FINGERPRINT_EXTS.has(ext):
		return false
	return not (ext == "md" and not rel.contains("/"))


## Where this tree came from, for doctor's `build` block: {fingerprint, files, tree, note[, package]}.
## tree is "source" when there is no build.cfg (a checkout, or a copy of one), "pristine" when the stamp
## names this version and this fingerprint, "modified" otherwise; package is the stamp's own fields.
static func provenance() -> Dictionary:
	return provenance_of(ADDON_DIR, current(), fingerprint(), fingerprint_files())


static func provenance_of(root: String, version: String, fp: String, files: int) -> Dictionary:
	var out := {"fingerprint": fp, "files": files}
	var cfg := ConfigFile.new()
	if cfg.load(root.path_join(BUILD_STAMP)) != OK:
		out["tree"] = "source"
		out["note"] = "No %s/%s: a source checkout or a copy of one, not a package as it was packed." % [root.get_file(), BUILD_STAMP]
		return out
	var stamp := {}
	for k in ["version", "edition", "commit", "fingerprint", "files"]:
		stamp[k] = cfg.get_value("build", k, "")
	out["package"] = stamp
	if str(stamp["version"]) != version:
		out["tree"] = "modified"
		out["note"] = "%s was written for %s but plugin.cfg says %s: another version's files were copied over this package." % [BUILD_STAMP, str(stamp["version"]), version]
	elif str(stamp["fingerprint"]) == fp:
		out["tree"] = "pristine"
		out["note"] = "Matches the package it came from (%s %s, commit %s)." % [str(stamp["edition"]), str(stamp["version"]), str(stamp["commit"])]
	else:
		out["tree"] = "modified"
		out["note"] = "Differs from the package it came from (%s %s, commit %s): files were changed, added or removed since (%d now, %s when packed)." % [
			str(stamp["edition"]), str(stamp["version"]), str(stamp["commit"]), files, str(stamp["files"])]
	return out


## The dock tagline's tooltip: the exact build and where it came from.
static func describe() -> String:
	var b := display()
	if b == UNKNOWN:
		return "Beckett version unknown: plugin.cfg could not be read."
	return "Beckett %s\n%s" % [b, str(provenance()["note"])]
