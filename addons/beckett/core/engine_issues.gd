extends RefCounted

## Known ENGINE bugs that matter to an agent driving the editor, reported by doctor for the
## Godot build that is actually running (v1.16). Table-driven on purpose: a new entry is data,
## not code. The selector is pure (a version dictionary in, a list out), so the unit suite
## pins it for every status string an engine reports ("stable", "rc1", "dev7") without
## needing that engine installed.
##
## An entry applies to a build when since <= build < before. Both bounds are version strings
## (see key_of_string): "4.7.1" is the LOWEST build of 4.7.1 (its dev and rc builds count as
## 4.7.1), "4.8-dev8" is the first snapshot after a fix. No `since` = from the beginning; no
## `before` = not fixed yet. These are Godot's bugs, not Beckett state: doctor lists them
## next to its own warnings and never lets one flip `ok`, because most users sit on an
## affected engine and "not ok forever" would stop meaning anything.

## id: stable slug. issue: the godotengine/godot number (also named in `text`, which is the
## whole message: one or two sentences, what happens and what to do about it).
const ISSUES := [
	{
		"id": "debugger-getter-freeze",
		"issue": 123042,
		"since": "4.7.1",
		"before": "4.7.3",
		"text": "Debugger freeze (godotengine/godot#123042): breaking execution inside a property getter can hang the editor, and because Beckett's server shares the editor's main thread the MCP endpoint hangs with it. Fixed on master by #123156 for Godot 4.8 and not backported to 4.7.x so far, so keep breakpoints out of getters on this version.",
	},
	{
		"id": "ignore-external-changes",
		"issue": 117489,
		# The faulty code is EditorNode::_resave_externally_modified_scenes, which saves the current
		# tab into every listed file. It first appears in 4.5-stable (and is in 4.6 and 4.7): checked
		# against editor_node.cpp at 4.4.1, 4.5, 4.6 and 4.7, where 4.4.1 and older instead call
		# save_all_scenes() and put each open scene back into its own file, so they are not affected.
		"since": "4.5",
		# #124048 merged on master 2026-10-01, 85 minutes AFTER 4.8-dev7 was published, so that
		# snapshot and every older one still carry the bug; the first build after the fix is
		# either dev8 or beta1, and both sort at or above the bound below.
		"before": "4.8-dev8",
		"text": "Scene overwrite (godotengine/godot#117489): choosing 'Ignore External Changes' in the files-modified-outside-Godot dialog can save the current tab's scene over the other listed files, replacing a base scene with the scene that inherits from it. Fixed on master by #124048 for Godot 4.8, so after agent edits pick 'Reload from disk'.",
	},
]


## The entries that apply to this build, as [{id, issue, text}] in table order. `info` is
## Engine.get_version_info(); anything unparseable (a custom build with an odd status) gets
## no entries rather than a guess.
static func for_version(info: Dictionary) -> Array:
	var key := key_of_info(info)
	var out: Array = []
	if key.is_empty():
		return out
	for e in ISSUES:
		var since: String = str(e.get("since", ""))
		var before: String = str(e.get("before", ""))
		if not since.is_empty() and compare(key, key_of_string(since)) < 0:
			continue
		if not before.is_empty() and compare(key, key_of_string(before)) >= 0:
			continue
		out.append({"id": e["id"], "issue": e["issue"], "text": e["text"]})
	return out


## Sort key [major, minor, patch, rank, n] for a get_version_info() dictionary; [] when the
## status is one we cannot place. A missing or empty status reads as "stable".
static func key_of_info(info: Dictionary) -> Array:
	if not (info.get("major") is int and info.get("minor") is int):
		return []
	var status := str(info.get("status", "stable"))
	return _key(int(info["major"]), int(info["minor"]), int(info.get("patch", 0)), status if not status.is_empty() else "stable")


## The same key for a bound written as "4.7.1", "4.8-dev8" or "4.7.1-rc1". No status means the
## lowest build of that triple (rank -1), so "4.7.1" admits 4.7.1-dev3 and rejects 4.7.0.
static func key_of_string(s: String) -> Array:
	var parts := s.strip_edges().split("-", false, 1)
	if parts.is_empty():
		return []
	var nums := parts[0].split(".")
	if nums.size() < 2 or not nums[0].is_valid_int() or not nums[1].is_valid_int():
		return []
	var patch := int(nums[2]) if nums.size() > 2 and nums[2].is_valid_int() else 0
	return _key(int(nums[0]), int(nums[1]), patch, parts[1] if parts.size() > 1 else "")


## -1, 0 or 1. Lexicographic over the key, which is exactly dev < beta < rc < stable inside
## one version triple and numeric inside one status.
static func compare(a: Array, b: Array) -> int:
	for i in range(mini(a.size(), b.size())):
		if int(a[i]) != int(b[i]):
			return -1 if int(a[i]) < int(b[i]) else 1
	return 0


## status "" -> rank -1 (the bound form), "stable" -> 3, rcN -> 2, betaN -> 1, devN -> 0. A bare
## "dev" is a build off master between two snapshots and sorts above every numbered one. Anything
## else returns [] (see key_of_info).
static func _key(major: int, minor: int, patch: int, status: String) -> Array:
	if status.is_empty():
		return [major, minor, patch, -1, 0]
	if status == "stable":
		return [major, minor, patch, 3, 0]
	for pair in [["rc", 2], ["beta", 1], ["dev", 0]]:
		var tag: String = pair[0]
		if status.begins_with(tag):
			var tail := status.substr(tag.length())
			if tail.is_empty():
				return [major, minor, patch, int(pair[1]), 1000000]
			if tail.is_valid_int():
				return [major, minor, patch, int(pair[1]), int(tail)]
	return []
