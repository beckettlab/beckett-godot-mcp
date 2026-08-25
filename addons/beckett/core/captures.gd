@tool
extends RefCounted
class_name BeckettCaptures

## Capture store (v1.14) — the backing file store for `capture://` MCP resources.
##
## Why it exists: a default 1280 px game frame is ~1.2 MB of PNG, which is ~1.6 MB once
## base64'd into a tool result, and the model re-reads that blob on every turn it keeps the
## message. A `resource_link` hands the client a URI instead, and the client fetches the
## bytes once, only if it wants them. v1.13.0 measured the cost; this is where we stop
## paying it by default.
##
## Security shape (this file is the only thing between a caller-supplied string and the
## filesystem, so it is deliberately paranoid):
##   * an id must match ID_PATTERN — 16 lowercase hex digits, a dot, a known extension;
##   * paths are built by CONCATENATION onto a fixed prefix, never by joining caller text,
##     so there is no path for `..` or a drive letter to survive the regex and still land
##     somewhere else;
##   * the store lives under user://, never res:// — captures are session scratch, not
##     project content, and must never end up in someone's version control.

const DIR := "user://beckett_captures"
const MAX_KEEP := 20  # newest N survive each write; a run of screenshots must not fill a disk
const ID_PATTERN := "^[0-9a-f]{16}\\.(png|jpg|webp)$"

const _MIME_BY_EXT := {
	"png": "image/png",
	"jpg": "image/jpeg",
	"webp": "image/webp",
}


## True if `id` is safe to concatenate onto DIR. Call this before ANY filesystem access.
static func is_valid_id(id: String) -> bool:
	var re := RegEx.new()
	re.compile(ID_PATTERN)
	return re.search(id) != null


## Extension -> MIME, defaulting to PNG. Accepts a full MIME string too, so callers can
## hand us whatever the runtime channel reported without a lookup of their own.
static func ext_for_mime(mime: String) -> String:
	var m := mime.to_lower()
	if m.contains("jpeg") or m.contains("jpg"):
		return "jpg"
	if m.contains("webp"):
		return "webp"
	return "png"


static func mime_for_id(id: String) -> String:
	return str(_MIME_BY_EXT.get(id.get_extension().to_lower(), "image/png"))


## Write base64 image data to the store. Returns {id, uri, path, bytes} or {error}.
## `path` is globalized and absolute on purpose: it is what rides in the text block, so a
## client that ignores resource_link can still open the picture with its own file tool.
static func store(data_base64: String, mime: String) -> Dictionary:
	var bytes := Marshalls.base64_to_raw(data_base64)
	if bytes.is_empty():
		return {"error": "capture data was empty or not valid base64"}
	if not DirAccess.dir_exists_absolute(DIR):
		var derr := DirAccess.make_dir_recursive_absolute(DIR)
		if derr != OK:
			return {"error": "could not create %s (%s)" % [DIR, error_string(derr)]}
	var id := _mint_id(ext_for_mime(mime))
	# Belt and braces: the id we just built is ours, but it goes through the same gate a
	# caller-supplied one does, so the invariant has exactly one enforcement point.
	if not is_valid_id(id):
		return {"error": "internal: generated capture id failed validation"}
	var path := DIR + "/" + id
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "could not write %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_buffer(bytes)
	f.close()
	_prune()
	return {
		"id": id,
		"uri": "capture://" + id,
		"path": ProjectSettings.globalize_path(path),
		"bytes": bytes.size(),
		"mime": mime_for_id(id),
	}


## Stored captures, newest first: [{id, uri, bytes, modified}].
static func list_entries() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if not is_valid_id(f):
			continue  # something else put a file here; it is not ours to serve
		var path := DIR + "/" + f
		out.append({
			"id": f,
			"uri": "capture://" + f,
			"bytes": _size_of(path),
			"modified": FileAccess.get_modified_time(path),
		})
	# Sort by ID, not by mtime. FileAccess.get_modified_time has SECOND granularity, so a
	# burst of captures — exactly what a playtest loop produces — all share a timestamp and
	# the "newest first" order collapses into directory order. The prune then evicted an
	# arbitrary five of twenty, which could include the frame a caller had just been handed a
	# link to. Ids are timestamp-prefixed (see _mint_id) so their lexicographic order IS
	# chronological order, at millisecond resolution, with no filesystem metadata involved.
	out.sort_custom(func(a, b): return str(a["id"]) > str(b["id"]))
	return out


## Read one capture. Returns {ok:true, mime, blob} (blob = base64, the shape MCP's
## resources/read wants for binary) or {ok:false, error}.
static func read_id(id: String) -> Dictionary:
	if not is_valid_id(id):
		return {"ok": false, "error": "not a capture id: %s" % id}
	var path := DIR + "/" + id
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "capture %s is gone (the store keeps only the newest %d)" % [id, MAX_KEEP]}
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"ok": false, "error": "capture %s could not be read" % id}
	return {"ok": true, "mime": mime_for_id(id), "blob": Marshalls.raw_to_base64(bytes)}


## Absolute on-disk path for an id, or "" when the id is invalid. For the text channel.
static func path_for(id: String) -> String:
	if not is_valid_id(id):
		return ""
	return ProjectSettings.globalize_path(DIR + "/" + id)


# ---------------------------------------------------------------- internals

## Monotonic ids, so ORDERING IS A PROPERTY OF THE NAME and neither list_entries nor _prune
## ever consults filesystem metadata. 16 hex digits exactly, so ID_PATTERN is unchanged:
##
##   11 digits  wall-clock millisecond (44 bits covers ~557 years from the epoch)
##    3 digits  a per-process sequence counter
##    2 digits  random
##
## The sequence counter is the load-bearing part and it was learned the hard way TWICE. The
## first version sorted on FileAccess.get_modified_time, which resolves to SECONDS. The second
## used a millisecond prefix plus random digits — which passed on a Windows dev box and failed
## on both macOS CI lanes, because a faster machine mints all 25 captures of the prune test
## inside ONE millisecond and the random tail put them in arbitrary order again. A counter is
## the only tail that is exact regardless of how fast the machine is; it wraps at 4096 per
## millisecond, which no real capture rate approaches, and the millisecond dominates across
## the wrap. The 2 random digits are what is left for collision resistance between two
## processes sharing one user:// dir; a collision there overwrites one scratch capture.
##
## Known limit, stated rather than hidden: if the system clock steps BACKWARDS, ordering for
## captures either side of the step is wrong. The cost is a mis-pruned scratch frame.
static var _seq: int = 0

static func _mint_id(ext: String) -> String:
	var ms := int(Time.get_unix_time_from_system() * 1000.0)
	_seq = (_seq + 1) & 0xFFF
	return "%011x%03x%02x.%s" % [ms & 0xFFFFFFFFFFF, _seq, randi() & 0xFF, ext]


static func _prune() -> void:
	var entries := list_entries()
	if entries.size() <= MAX_KEEP:
		return
	for i in range(MAX_KEEP, entries.size()):
		DirAccess.remove_absolute(DIR + "/" + str(entries[i]["id"]))


static func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)
