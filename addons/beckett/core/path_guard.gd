extends RefCounted

## One answer to "may a tool touch the file at this caller-supplied path?", in both directions.
## Everything that writes to a path an agent names (or that a saved suite file names, which can come
## from a cloned repo) asks write_path_error; everything that reads one asks check_read. The rule
## lives here instead of drifting across write_file, write_script, read_file, list_dir and the rest.
##
## WRITES: res:// or user:// only, no "..", no control characters, and no link on the way that
## leaves the project. The ".." check is a boundary because Godot does not sandbox a res:// path:
## "res://../../x.png" resolves to a folder OUTSIDE the project, and a bare scheme check would let it
## through. A link is the same escape without any "..": a junction or symlink inside the project is
## followed by the OS, so res://link/x.txt can land anywhere the link points (a cloned repository can
## ship one).
##
## READS: res:// and user://, plus an absolute path that resolves inside the project folder or the
## project's user:// folder. Anything else is refused: another folder, a relative path (it could mean
## any folder), a ".." path, a link that leaves the project. The owner can opt out for READS only, with
## the project setting beckett/allow_outside_reads or BECKETT_ALLOW_OUTSIDE_READS=1 (the environment
## wins, and "0" forces the confinement back on over a committed project setting). A write never
## consults the opt-out. The setting is the OWNER's: set_project_setting refuses to turn it on
## (setting_write_error), so the confined party cannot lift the confinement with a call.
##
## Links: before a path is judged, every folder on the way below the project (or user://) root is
## looked at, and a symlink or junction counts as inside only when what it resolves to is inside the
## project folder or the user:// folder. The roots themselves are not checked, because a project
## that lives behind a link, a mapped drive or /tmp -> /private/tmp is ordinary. Windows compares
## case-insensitively and treats both slashes as separators; a Windows spelling that names a drive's
## current folder ("C:foo") is a relative path.
##
## HARD CONSTRAINT on this file: no editor classes and no state. The headless playtest runner
## preloads it too, and it must parse inside a plain engine run.

const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # a project setting can hold the text "true"

const SETTING_OUTSIDE_READS := "beckett/allow_outside_reads"
const ENV_OUTSIDE_READS := "BECKETT_ALLOW_OUTSIDE_READS"

## A chain of links longer than this is called a loop (Linux stops at 40 as well).
const MAX_LINK_HOPS := 40
## A Unix link's text, in bytes, from which it may have been cut short (see _resolve).
const LINK_TEXT_MAX := 255
## The most of a path, or of text read off the filesystem, that a refusal echoes back.
const SHOWN_MAX := 160


# ---------------------------------------------------------------- writes

## "" when `path` is somewhere a tool may write, else the reason in plain words. `memo` is optional
## scratch a caller can reuse across many calls (an archive extraction checks thousands of paths):
## it holds the two roots, which are the same every time.
static func write_path_error(path: String, memo: Dictionary = {}) -> String:
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return "path must be res:// or user://"
	if path.contains(".."):
		return "path must not contain '..'"
	for i in path.length():
		var c := path.unicode_at(i)
		if c < 32 or c == 127:
			return "path must not contain control characters"
	return link_escape_error(path, memo)


## The link half of the write rule on its own, for a tool that accepts other paths as well (the
## screenshot's save_to takes an absolute path on purpose, but a res:// or user:// one still must not
## go through a link that leaves the project). "" when the path is fine or no link is in the way.
static func link_escape_error(path: String, memo: Dictionary = {}) -> String:
	var a := _assess(path, memo)
	match str(a["where"]):
		"link":
			return "path goes through %s, a link to %s, which is outside the project and user://. Beckett never writes through a link that leaves them (the file would land outside); write to a real folder inside the project" % [_shown(str(a["link"])), _shown(str(a["real"]))]
		"loop":
			return "path goes through %s, %s, so Beckett cannot tell where a write would land and does not write through a link it cannot follow" % [_shown(str(a["link"])), str(a["why"])]
	return ""


# ---------------------------------------------------------------- reads

## May a tool READ `path`? Returns {} when it is inside the project or user:// (the common case);
## {"note": text} when it is outside but the owner switched outside reads on (the reply must carry
## the note, see noted); {"error": text} when it is refused: the error names the path, says reads
## are confined to the project and user://, and says how to opt out, so it can be returned as is.
## An empty path has nothing to confine, so it passes and the tool's own "no file" answer follows.
## `uid://` is judged by the res:// path it names (it can only name a resource in this project).
static func check_read(path: String, memo: Dictionary = {}) -> Dictionary:
	if path.is_empty():
		return {}
	var a := _assess(path, memo)
	var where := str(a["where"])
	if where == "inside":
		return {}
	if where == "control":
		return {"error": "Refused to read %s: a path must not contain control characters." % _shown(path)}
	if outside_reads_allowed():
		return {"note": "NOTE: %s is not inside the project or user://. This read went ahead because outside reads are switched on (%s)." % [_shown(path), outside_reads_source()]}
	return {"error": _read_refusal(path, a)}


## A handler's reply, carrying the note check_read returned (nothing to do when there is none): a JSON
## reply gets an "outside_read" key, a text reply gets a second block of {"outside_read": note} so the
## file text itself stays exactly what was read.
static func noted(reply: Dictionary, guard: Dictionary) -> Dictionary:
	var note := str(guard.get("note", ""))
	if note.is_empty() or reply.has("error"):
		return reply
	var j: Variant = reply.get("json")
	if j is Dictionary:
		(j as Dictionary)["outside_read"] = note
	elif j == null:
		reply["json"] = {"outside_read": note}
	else:  # a JSON array has no place for a key, and the note must never replace the data
		reply["text"] = (str(reply["text"]) + "\n" if reply.has("text") else "") + note
	return reply


## Are reads outside the project switched on? The environment decides when it says yes or no
## (BECKETT_ALLOW_OUTSIDE_READS=1 / =0), else the project setting does.
static func outside_reads_allowed() -> bool:
	var env := _env_state()
	if env >= 0:
		return env == 1
	return ProjectSettings.has_setting(SETTING_OUTSIDE_READS) and CallArgs.to_bool(ProjectSettings.get_setting(SETTING_OUTSIDE_READS, false))


## What switched outside reads on, for a note or for doctor: "" when they are off.
static func outside_reads_source() -> String:
	var env := _env_state()
	if env == 1:
		return "%s=1" % ENV_OUTSIDE_READS
	if env == 0 or not outside_reads_allowed():
		return ""
	return "the project setting %s" % SETTING_OUTSIDE_READS


## "" when a tool may store `value` in the project setting `setting`, else why not. The one setting a tool may
## not turn ON is the opt-out above: it belongs to the person who owns the project, and an agent that could set
## it with one call would not be confined by it. Turning it off is always fine, and so is every other setting.
static func setting_write_error(setting: String, value: Variant) -> String:
	if setting == SETTING_OUTSIDE_READS and CallArgs.to_bool(value):
		return "%s is the owner's switch for reading files outside the project, so it is not set through a tool. Ask the user to set it themselves: add allow_outside_reads=true under [beckett] in project.godot and reopen the project, or start the editor with %s=1." % [SETTING_OUTSIDE_READS, ENV_OUTSIDE_READS]
	return ""


## 1 = the environment says yes, 0 = it says no, -1 = it says nothing.
static func _env_state() -> int:
	match OS.get_environment(ENV_OUTSIDE_READS).strip_edges().to_lower():
		"1", "true", "yes", "on":
			return 1
		"0", "false", "no", "off":
			return 0
	return -1


static func _read_refusal(path: String, a: Dictionary) -> String:
	var tail := " To read outside the project on purpose, the user sets the project setting %s=true (under [beckett] in project.godot) or starts the editor with %s=1; a tool cannot set it." % [SETTING_OUTSIDE_READS, ENV_OUTSIDE_READS]
	var confined := "Beckett reads are confined to the project folder (res://) and the project's user:// folder."
	match str(a["where"]):
		"relative":
			return "Refused to read %s: a relative path could mean any folder. %s Use %s, or an absolute path inside the project.%s" % [_shown(path), confined, _shown("res://" + path.trim_prefix("./")), tail]
		"dotdot":
			return "Refused to read %s: the path contains '..'. %s Write it without ../ steps (res://, user://, or an absolute path inside the project).%s" % [_shown(path), confined, tail]
		"link":
			return "Refused to read %s: it goes through %s, a link to %s, which is outside the project. %s A link out of them does not count as inside.%s" % [_shown(path), _shown(str(a["link"])), _shown(str(a["real"])), confined, tail]
		"loop":
			return "Refused to read %s: it goes through %s, %s, so Beckett cannot tell where it leads. %s%s" % [_shown(path), _shown(str(a["link"])), str(a["why"]), confined, tail]
	return "Refused to read %s: it is outside this project. %s%s" % [_shown(path), confined, tail]


# ---------------------------------------------------------------- directory walkers

## For a tool that walks res:// on its own (search_files, the analysis tools): should the entry at
## `full` (a res:// or user:// path) be left out? True for a link that leads outside the project and
## user://, unless outside reads are on. The usual entry costs one is_link probe.
static func walk_skip(full: String, memo: Dictionary = {}) -> bool:
	if outside_reads_allowed():
		return false
	var da := _da(memo)
	if da == null or not _link_at(da, ProjectSettings.globalize_path(full)):
		return false
	return str(_assess(full, memo)["where"]) != "inside"


## The fields a walker adds to its JSON reply for what walk_skip left out, {} when it left nothing out:
## say so instead of reporting a smaller project as if it were the whole one.
static func skipped_note(skipped: Array) -> Dictionary:
	var once: Array = []  # a tool that walks twice reports each entry once
	for s in skipped:
		if not once.has(s):
			once.append(s)
	if once.is_empty():
		return {}
	var listed: Array = []  # names a cloned repository chose: short, plain data, never a free-standing sentence
	for s in once.slice(0, 10):
		listed.append(_plain(str(s)))
	return {
		"skipped_links": listed,
		"skipped_note": "%d linked folder(s) or file(s) that lead outside the project were left out (first %d are in skipped_links). To include them, the user sets the project setting %s=true or starts the editor with %s=1." % [
			once.size(), mini(once.size(), 10), SETTING_OUTSIDE_READS, ENV_OUTSIDE_READS],
	}


# ---------------------------------------------------------------- links

## Is `os_path` (an OS path) a symbolic link, a directory junction or another reparse point? Reached
## by name (has_method / call): DirAccess.is_link only exists from Godot 4.3, and this script is loaded
## on every engine the addon supports, 4.2 included, where naming it would be a parse error that stops
## the whole plugin. An engine without it reports no link at all, which is what the writers did
## before links were looked at. client_config.gd asks here too, so the trick lives in one place.
static func is_link_path(os_path: String) -> bool:
	var da := DirAccess.open("res://")
	return da != null and _link_at(da, os_path)


static func _link_at(da: Object, os_path: String) -> bool:
	return da.has_method("is_link") and da.call("is_link", os_path) == true


## Where a link points, exactly as the engine reports it: Windows gives the final absolute path with
## every link on the way already followed (forward slashes, no prefix), Unix gives the link's own text
## (possibly relative to its folder). When Windows cannot open the link at all (a dangling one) it hands
## back the input instead, backslashes and a \\?\ prefix kept, which no success ever looks like.
static func _link_target(da: Object, os_path: String) -> String:
	if not da.has_method("read_link"):
		return ""
	return str(da.call("read_link", os_path))


## Walk `tail` below the existing real folder prefix + base, replacing every link met on the way by what
## it points at (a relative target is read from the folder that holds the link, ".." in one included),
## and return where that lands: {ok, prefix, segs, link} where `link` is the first link met ("" if none).
## A folder that does not exist yet is just a name (a file about to be created cannot be a link). {ok:
## false, link, why} for a link that cannot be followed: a loop, or one whose target cannot be read.
static func _resolve(prefix: String, base: Array, tail: Array, da: Object) -> Dictionary:
	var cur_prefix := prefix
	var cur: Array = base.duplicate()
	var queue: Array = tail.duplicate()
	var first_link := ""
	var hops := 0
	while not queue.is_empty():
		var seg := str(queue.pop_front())
		if seg == "" or seg == ".":
			continue
		if seg == "..":
			if not cur.is_empty():
				cur.pop_back()
			continue
		var cand := _join(cur_prefix, cur + [seg])
		if not _link_at(da, cand):
			cur.append(seg)
			continue
		var raw := _link_target(da, cand)
		if raw.is_empty() or raw.begins_with("\\\\?\\"):
			# A dangling link, or one the engine could not open: it will not say where it points, and a
			# write through it would create that target. (FileAccess.file_exists is no help here: it
			# says true for a dangling file symlink on Windows.)
			return {"ok": false, "link": cand, "why": "a link whose target cannot be read"}
		if not _win() and raw.to_utf8_buffer().size() >= LINK_TEXT_MAX:
			# The engine reads a Unix link into a 256-byte buffer, so a target this long may have been cut
			# short, and what is left of it could look inside the project while the rest climbs out.
			return {"ok": false, "link": cand, "why": "a link whose target is too long to read in full"}
		var target := _norm(raw)
		if _key(target) == _key(cand):
			# A reparse point that redirects nothing (a OneDrive placeholder, say) opens fine and names
			# itself: the name is the place.
			cur.append(seg)
			continue
		if _win() and da is DirAccess and not bool(_parts(target)["abs"]):
			# The engine on Windows answers with a full path, a drive or a share, whenever it can read the link
			# at all. A target that is neither is not a place this walk can follow: a link to a network share
			# comes back as "UNC/server/share/..." (measured on 4.6.2), and reading that as relative to the
			# link's folder would call the share inside the project. (The unit suite's made-up machine hands in
			# Unix-shaped relative targets on any OS, which is why this asks for the engine's own DirAccess.)
			return {"ok": false, "link": cand, "why": "a link whose target cannot be read"}
		hops += 1
		if hops > MAX_LINK_HOPS:
			return {"ok": false, "link": cand, "why": "a chain of links that never ends"}
		if first_link.is_empty():
			first_link = cand
		var t := _parts(target)
		if bool(t["abs"]):
			cur_prefix = str(t["prefix"])
			cur = []
		queue = (t["segs"] as Array) + queue
	return {"ok": true, "prefix": cur_prefix, "segs": cur, "link": first_link}


# ---------------------------------------------------------------- the judgement

## Where `path` points, for both rules. {where, ...}, where is one of
##   inside    in the project or user://, and no link on the way leaves them (or there is no way to tell)
##   outside   an absolute path in neither folder
##   relative  no scheme and not absolute
##   dotdot    a ".." (or "...") segment
##   control   a control character
##   link      inside by name, but a link on the way resolves outside: {link, real}
##   loop      a link that cannot be followed: {link, why}
static func _assess(path: String, memo: Dictionary) -> Dictionary:
	for i in path.length():
		var c := path.unicode_at(i)
		if c < 32 or c == 127:
			return {"where": "control"}
	var p := path
	if p.begins_with("uid://"):
		p = _uid_path(p)
		if p.is_empty():
			return {"where": "inside"}  # no resource has that id: nothing to confine, the loader says so
	var scheme := ""
	if p.begins_with("res://"):
		scheme = "res://"
	elif p.begins_with("user://"):
		scheme = "user://"
	var rest := p.substr(scheme.length())
	if _has_dotdot(rest):
		return {"where": "dotdot"}
	if scheme.is_empty() and not bool(_parts(_norm(p))["abs"]):
		return {"where": "relative"}
	var os_parts: Dictionary
	if scheme.is_empty():
		os_parts = _parts(_norm(p))
	else:
		var base := _parts(_norm(ProjectSettings.globalize_path(scheme)))
		os_parts = {"abs": true, "prefix": base["prefix"], "segs": (base["segs"] as Array) + _segs(_norm(rest))}
	var da := _da(memo)
	var roots := _roots(da, memo)
	var loc := _locate(os_parts, roots)
	if loc.is_empty():
		return {"where": "outside"}
	if da == null:
		return {"where": "inside"}
	var walked := _resolve(str(loc["prefix"]), loc["segs"], loc["rel"], da)
	if not bool(walked["ok"]):
		return {"where": "loop", "link": _scheme_form(str(walked["link"]), roots), "why": str(walked["why"])}
	if not _locate({"abs": true, "prefix": walked["prefix"], "segs": walked["segs"]}, roots).is_empty():
		return {"where": "inside"}
	return {"where": "link", "link": _scheme_form(str(walked["link"]), roots), "real": _join(str(walked["prefix"]), walked["segs"])}


## The folders reads may reach: [{scheme, nominal, real}] for the project and for user://, each side as
## parts. `real` is the nominal path with every link in it resolved (the project behind a junction,
## macOS's /tmp), so a path given by either spelling is recognised, and a link inside the project that
## points back into it by its real spelling is not mistaken for an escape.
static func _roots(da: Object, memo: Dictionary) -> Array:
	if memo.has("roots"):
		return memo["roots"]
	var out: Array = []
	for scheme in ["res://", "user://"]:
		var nominal := _parts(_norm(ProjectSettings.globalize_path(scheme)))
		if not bool(nominal["abs"]):
			continue
		var real := nominal
		if da != null:
			var r := _resolve(str(nominal["prefix"]), [], nominal["segs"], da)
			if bool(r["ok"]):
				real = {"abs": true, "prefix": r["prefix"], "segs": r["segs"]}
		out.append({"scheme": scheme, "nominal": nominal, "real": real})
	memo["roots"] = out
	return out


## `os_path` as res:// or user:// when it lies under that root (by either spelling), else unchanged: what
## a refusal shows for a link inside the project.
static func _scheme_form(os_path: String, roots: Array) -> String:
	var p := _parts(_norm(os_path))
	for r in roots:
		for side in ["nominal", "real"]:
			var rem: Variant = _below(r[side], p)
			if rem != null:
				return str(r["scheme"]) + "/".join(PackedStringArray(rem))
	return os_path


## {prefix, segs, rel} for a path that lies under one of the roots (by either spelling): the real root
## to start the link walk from, and the segments below it. {} when it lies under none.
static func _locate(p: Dictionary, roots: Array) -> Dictionary:
	for r in roots:
		for side in ["nominal", "real"]:
			var rem: Variant = _below(r[side], p)
			if rem != null:
				var real: Dictionary = r["real"]
				return {"prefix": real["prefix"], "segs": real["segs"], "rel": rem}
	return {}


## The segments of `p` below `root`, or null when `p` is not under it. Whole segments only, so
## /proj-evil is not under /proj.
static func _below(root: Dictionary, p: Dictionary) -> Variant:
	if _key(str(root["prefix"])) != _key(str(p["prefix"])):
		return null
	var rs: Array = root["segs"]
	var ps: Array = p["segs"]
	if ps.size() < rs.size():
		return null
	for i in rs.size():
		if _key(str(rs[i])) != _key(str(ps[i])):
			return null
	return ps.slice(rs.size())


## The res:// path a uid:// names, or "" when none does.
static func _uid_path(uid: String) -> String:
	var id: int = ResourceUID.text_to_id(uid)
	if id == -1 or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)


# ---------------------------------------------------------------- path text

static func _da(memo: Dictionary) -> Object:
	if not memo.has("da"):
		memo["da"] = DirAccess.open("res://")
	return memo["da"]


static func _win() -> bool:
	return OS.get_name() == "Windows"


## Case-folded on Windows, where C:/Proj and c:/proj are one folder; exact elsewhere.
static func _key(s: String) -> String:
	return s.to_lower() if _win() else s


## Forward slashes, runs of slashes collapsed (a Windows UNC start kept) and no trailing slash. A
## backslash separates only on Windows: elsewhere it is an ordinary character in a file name.
static func _norm(p: String) -> String:
	var s := p.replace("\\", "/") if _win() else p
	var unc := _win() and s.begins_with("//")
	while s.contains("//"):
		s = s.replace("//", "/")
	if unc:
		s = "/" + s
	if s.length() > 1 and s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	return s


## A normalized path as {abs, prefix, segs}: the drive ("C:"), the UNC share ("//host/share") or "" for a
## rooted Unix path, then the segments. abs is false for a path with no root at all.
static func _parts(p: String) -> Dictionary:
	if _win():
		if p.length() >= 2 and p[1] == ":" and p.unicode_at(0) < 128 and p[0].to_upper() != p[0].to_lower():
			if p.length() > 2 and p[2] != "/":
				# "C:foo" is relative to the CURRENT folder of drive C, not to its root: it names a
				# place nobody can tell from the text, which is what the relative rule is for.
				return {"abs": false, "prefix": "", "segs": _segs(p)}
			return {"abs": true, "prefix": p.substr(0, 2), "segs": _segs(p.substr(2))}
		if p.begins_with("//"):
			var rest := _segs(p.substr(2))
			if rest.size() >= 2:
				return {"abs": true, "prefix": "//%s/%s" % [rest[0], rest[1]], "segs": rest.slice(2)}
			return {"abs": true, "prefix": "//" + "/".join(PackedStringArray(rest)), "segs": []}
	if p.begins_with("/"):
		return {"abs": true, "prefix": "", "segs": _segs(p)}
	return {"abs": false, "prefix": "", "segs": _segs(p)}


static func _segs(s: String) -> Array:
	return Array(s.split("/", false))


static func _join(prefix: String, segs: Array) -> String:
	return prefix + "/" + "/".join(PackedStringArray(segs))


## A ".." segment, or a run of three or more dots (Windows reads a trailing dot as nothing, so these
## are not worth telling apart). Either slash splits, on every OS.
static func _has_dotdot(s: String) -> bool:
	for seg in s.replace("\\", "/").split("/", false):
		var t := seg.strip_edges()
		if t.length() >= 2 and t.replace(".", "").is_empty():
			return true
	return false


## Text from the caller or off the filesystem, as it goes into a refusal: control characters become
## "?" and a long one is cut. A link's name and target are written by whoever made the link (a cloned
## repository can), so they are quoted and short, never a free-standing sentence.
static func _shown(s: String) -> String:
	return "\"%s\"" % _plain(s)


## The same text without the quotes, for an entry of a list (a JSON string is quoted already).
static func _plain(s: String) -> String:
	var out := ""
	for i in mini(s.length(), SHOWN_MAX):
		var c := s.unicode_at(i)
		out += "?" if (c < 32 or c == 127) else s[i]
	return out + ("..." if s.length() > SHOWN_MAX else "")
