@tool
extends RefCounted

## .NET SDK preflight for C# projects (v1.16), shared by build_csharp and doctor.
##
## Why it exists: Godot 4.8 raised GodotSharp's minimum target framework to net10.0
## (godotengine/godot#123738), so a 4.8 C# project can only build with the .NET 10 SDK. Before
## this, a missing or too-old SDK surfaced as raw NETSDK1045 / NU1202 lines in the middle of a
## build log, and an agent that does not know that code reads it as "my C# is broken".
##
## Shape: the rules are PURE (parse_sdk_list, parse_csproj, check take text or dictionaries
## and return dictionaries, so the unit suite runs them with no dotnet installed) and the
## process half is a thin shell around them: find `dotnet`, run `dotnet --list-sdks` once per
## editor session, read the project's .csproj, hand all three to check().
##
## Requirement by engine, as today: nothing is enforced below Godot 4.8 beyond the plain
## fact that an SDK cannot build a project that targets a newer .NET than the SDK itself (SDK 9
## builds net9.0 and below). From 4.8 on, the floor is net10.0 and so SDK 10.

## Godot 4.8 and later build against GodotSharp for this .NET.
const GODOT_48_DOTNET := 10
## The MSBuild codes that mean "this SDK cannot target what the project asks for", the ones a
## failed build is mapped back to the same plain-words problem the preflight gives. NETSDK1045:
## "The current .NET SDK does not support targeting .NET 10.0".
const SDK_TARGET_CODES := ["NETSDK1045"]

static var _dotnet: String = ""      # resolved `dotnet`; a miss is never cached (the human may install it)
static var _sdks: Array = []         # parsed `dotnet --list-sdks`, valid while _sdks_known
static var _sdks_known: bool = false


# ---------------------------------------------------------------- pure rules

## `dotnet --list-sdks` output -> [{version, major, minor, patch, preview, path}], in the order
## dotnet printed them (oldest first). Lines that are not an SDK entry (warnings, blanks) are
## skipped. `preview` is true for any prerelease suffix: "10.0.100-preview.7.25380.108",
## "10.0.100-rc.1.25451.107".
static func parse_sdk_list(text: String) -> Array:
	var rx := RegEx.create_from_string("^\\s*(\\d+)\\.(\\d+)\\.(\\d+)(-[0-9A-Za-z.\\-]+)?(?:\\+[0-9A-Za-z.\\-]+)?\\s+\\[(.*)\\]\\s*$")
	var out: Array = []
	for raw in text.split("\n", false):
		var m := rx.search(raw.strip_edges())
		if m == null:
			continue
		var pre := m.get_string(4)
		out.append({
			"version": "%s.%s.%s%s" % [m.get_string(1), m.get_string(2), m.get_string(3), pre],
			"major": m.get_string(1).to_int(),
			"minor": m.get_string(2).to_int(),
			"patch": m.get_string(3).to_int(),
			"preview": not pre.is_empty(),
			"path": m.get_string(5),
		})
	return out


## .csproj text -> {godot_sdk, targets}. godot_sdk is the Godot.NET.Sdk version the project
## names ("4.8.0"), "" when it names none (the version can also live in global.json). targets
## are the target frameworks a plain build uses, the way MSBuild resolves them: elements and
## property groups carrying a Condition are skipped (Godot's own template adds net9.0 for
## android and ios that way, and a desktop build ignores them), a later <TargetFramework>
## wins over an earlier one, and <TargetFrameworks> (multi-targeting) wins over both.
## Comments are not parsed as elements, a UTF-8 BOM is dropped, malformed XML keeps whatever
## was read before the break.
static func parse_csproj(text: String) -> Dictionary:
	var out := {"godot_sdk": "", "targets": []}
	var data := text.trim_prefix("\ufeff").to_utf8_buffer()
	if data.is_empty():  # open_buffer on nothing prints an engine error, which doctor would echo
		return out
	var xml := XMLParser.new()
	if xml.open_buffer(data) != OK:
		return out
	var single := ""
	var multi: Array = []
	var group_conditional := false
	var current := ""        # the TargetFramework(s) element whose text we are inside
	var current_conditional := false
	while xml.read() == OK:
		match xml.get_node_type():
			XMLParser.NODE_ELEMENT:
				var nm := xml.get_node_name()
				if nm == "Project" and xml.has_attribute("Sdk"):
					for part in xml.get_named_attribute_value("Sdk").split(";", false):
						var v := _godot_sdk_version(part)
						if not v.is_empty():
							out["godot_sdk"] = v
				elif nm == "Sdk" and xml.has_attribute("Name") and xml.has_attribute("Version") \
						and xml.get_named_attribute_value("Name") == "Godot.NET.Sdk":
					out["godot_sdk"] = xml.get_named_attribute_value("Version")
				elif nm == "PropertyGroup":
					group_conditional = xml.has_attribute("Condition")
				elif nm == "TargetFramework" or nm == "TargetFrameworks":
					current = "" if xml.is_empty() else nm
					current_conditional = group_conditional or xml.has_attribute("Condition")
			XMLParser.NODE_TEXT:
				if current != "" and not current_conditional:
					var val := xml.get_node_data().strip_edges()
					if not val.is_empty():
						if current == "TargetFramework":
							single = val
						else:
							multi = Array(val.split(";", false))
			XMLParser.NODE_ELEMENT_END:
				var en := xml.get_node_name()
				if en == "PropertyGroup":
					group_conditional = false
				if en == current:
					current = ""
	if not multi.is_empty():
		out["targets"] = multi
	elif not single.is_empty():
		out["targets"] = [single]
	return out


## "Godot.NET.Sdk/4.8.0" -> "4.8.0"; "" for any other SDK reference or one with no version.
static func _godot_sdk_version(ref: String) -> String:
	var s := ref.strip_edges()
	if not s.begins_with("Godot.NET.Sdk/"):
		return ""
	return s.get_slice("/", 1).strip_edges()


## The .NET major a target framework names: "net10.0" -> 10, "net8.0-windows10.0.19041" -> 8.
## 0 for everything that is not modern .NET (net48, netstandard2.1, netcoreapp3.1) and for an
## MSBuild property reference such as "$(Tfm)", which cannot be judged from the text.
static func target_major(tfm: String) -> int:
	var m := RegEx.create_from_string("^net(\\d+)\\.\\d+").search(tfm.strip_edges().to_lower())
	return m.get_string(1).to_int() if m != null else 0


## "4.8.0" / "4.8.0-dev.7" -> [4, 8]; [] when it is not a version.
static func _major_minor(version: String) -> Array:
	var m := RegEx.create_from_string("^(\\d+)\\.(\\d+)").search(version.strip_edges())
	return [m.get_string(1).to_int(), m.get_string(2).to_int()] if m != null else []


## The .NET major (SDK and target framework) Godot `major.minor` builds C# against. 0 means
## Beckett enforces no floor of its own for that engine.
static func required_major(godot_major: int, godot_minor: int) -> int:
	if godot_major > 4 or (godot_major == 4 and godot_minor >= 8):
		return GODOT_48_DOTNET
	return 0


## "4.8-dev7", "4.7.2", "4.4.1" for a get_version_info() dictionary.
static func version_label(info: Dictionary) -> String:
	var s := "%d.%d" % [int(info.get("major", 0)), int(info.get("minor", 0))]
	if int(info.get("patch", 0)) > 0:
		s += ".%d" % int(info.get("patch", 0))
	var status := str(info.get("status", ""))
	if not status.is_empty() and status != "stable":
		s += "-" + status
	return s


## The verdict. `engine` is Engine.get_version_info(), `sdks` is parse_sdk_list(), `proj` is
## parse_csproj() (+ an optional "file": the .csproj's file name, for the messages; {} when
## there is no project). Returns
##   {ok, need, have, problems: [{kind, message, suggestion}]}
## need = the .NET major the build needs, have = the newest installed SDK major (0 = none).
## What the project is built against is the Godot.NET.Sdk version its .csproj names, because
## that is the GodotSharp the build restores; it falls back to the running editor when the
## .csproj names none. A project that pins an older Godot.NET.Sdk is therefore not held to the
## 4.8 floor just because the editor is newer.
static func check(engine: Dictionary, sdks: Array, proj: Dictionary) -> Dictionary:
	var named := _major_minor(str(proj.get("godot_sdk", "")))
	var built_against: Array = named if not named.is_empty() else [int(engine.get("major", 0)), int(engine.get("minor", 0))]
	var floor_net := required_major(int(built_against[0]), int(built_against[1]))
	var tfm := 0
	for t in proj.get("targets", []):
		tfm = maxi(tfm, target_major(str(t)))
	var need := maxi(floor_net, tfm)
	var have := _newest_major(sdks)
	var file := str(proj.get("file", "")) if not str(proj.get("file", "")).is_empty() else "the .csproj"
	var godot := version_label(engine)
	var who := _who(engine, proj)
	var problems: Array = []
	# A project that names Godot.NET.Sdk 4.8+ but still targets an older .NET: GodotSharp for 4.8
	# is net10.0 only, so the restore fails. Only judged when the .csproj states the version.
	if not named.is_empty() and floor_net > 0 and tfm > 0 and tfm < floor_net:
		problems.append({"kind": "target_too_old",
			"message": "%s targets net%d.0, but %s builds against GodotSharp for net%d.0 only." % [file, tfm, who, floor_net],
			"suggestion": "Change <TargetFramework> in %s to net%d.0 and its Godot.NET.Sdk version to match this editor (%s). That also needs the .NET %d SDK." % [file, floor_net, godot, floor_net]})
	if have == 0:
		var want := maxi(need, 8)
		problems.append({"kind": "no_sdk",
			"message": "No .NET SDK was found (dotnet is missing, or `dotnet --list-sdks` lists none).",
			"suggestion": "Install the .NET %d SDK (%s), then call build_csharp again." % [want, sdk_url(want)]})
	elif have < need:
		problems.append(sdk_too_old(need, sdks, floor_net, tfm, file, who))
	return {"ok": problems.is_empty(), "need": need, "have": have, "problems": problems}


## Who the net floor belongs to, for the messages: the Godot.NET.Sdk the .csproj names when it
## names one (that is the GodotSharp the build restores), else the running editor.
static func _who(engine: Dictionary, proj: Dictionary) -> String:
	var sdk := str(proj.get("godot_sdk", ""))
	if not _major_minor(sdk).is_empty():
		return "Godot.NET.Sdk %s" % sdk
	return "Godot %s" % version_label(engine)


## The newest installed SDK's major (0 = none).
static func _newest_major(sdks: Array) -> int:
	var have := 0
	for s in sdks:
		have = maxi(have, int((s as Dictionary).get("major", 0)))
	return have


## The "SDK older than the target" problem, one wording for the preflight and for a build that
## failed with NETSDK1045. `floor_net` is what Godot itself needs, `tfm` what the project
## targets: when the project asks for MORE than Godot does, lowering <TargetFramework> is a real
## way out and the suggestion says so; when Godot is what needs it, it is not.
static func sdk_too_old(need: int, sdks: Array, floor_net: int, tfm: int, file: String, who: String) -> Dictionary:
	var have := _newest_major(sdks)
	var list := _versions_text(sdks)
	var why: String
	var sug := "Install the .NET %d SDK (%s), then call build_csharp again." % [need, sdk_url(need)]
	if tfm > floor_net:
		why = "%s targets net%d.0" % [file, tfm]
		if have >= 1:
			sug += " Or, if the project does not need net%d.0, lower <TargetFramework> in %s to net%d.0 or older." % [need, file, have]
	else:
		why = "%s builds C# against GodotSharp for net%d.0" % [who, floor_net]
	var top := "top out at .NET %d" % have if have > 0 else "could not be listed"
	return {"kind": "sdk_too_old",
		"message": "%s, which needs the .NET %d SDK, but the SDKs installed here %s (installed: %s). An SDK can only build up to its own version." % [why, need, top, list],
		"suggestion": sug}


static func sdk_url(major: int) -> String:
	return "https://dotnet.microsoft.com/download/dotnet/%d.0" % major


## A failed build's diagnostics -> the same plain-words problem, or {} when none of them is an
## SDK-cannot-target code. `diags` is csharp_tools' parsed list ({code, message, ...}).
static func problem_from_diagnostics(diags: Array, engine: Dictionary, sdks: Array, proj: Dictionary) -> Dictionary:
	for d in diags:
		if not SDK_TARGET_CODES.has(str((d as Dictionary).get("code", ""))):
			continue
		var msg := str(d.get("message", ""))
		var m := RegEx.create_from_string("targeting \\.NET (\\d+)\\.").search(msg)
		var need := m.get_string(1).to_int() if m != null else _newest_major(sdks) + 1
		var file := str(proj.get("file", "")) if not str(proj.get("file", "")).is_empty() else "the .csproj"
		var seen := "MSBuild %s: %s" % [str(d.get("code", "")), msg.get_slice(".  ", 0).strip_edges().left(160)]
		if _newest_major(sdks) >= need:
			# An installed SDK CAN build it and dotnet used another one: a global.json that pins an
			# older SDK is the usual reason, and the newest-SDK wording would read as a contradiction.
			return {"kind": "sdk_pinned",
				"message": "%s targets net%d.0, but dotnet built it with an older SDK than the newest installed (%s), so the .NET %d SDK that could build it was not used (%s)." % [file, need, _versions_text(sdks), need, seen],
				"suggestion": "Look for a global.json at or above the project folder that pins an older SDK, raise or remove the pin, then call build_csharp again."}
		var named := _major_minor(str(proj.get("godot_sdk", "")))
		var built_against: Array = named if not named.is_empty() else [int(engine.get("major", 0)), int(engine.get("minor", 0))]
		var p := sdk_too_old(need, sdks, required_major(int(built_against[0]), int(built_against[1])), need, file, _who(engine, proj))
		p["message"] = "%s (%s)" % [p["message"], seen]
		return p
	return {}


## "9.0.314, 10.0.100", or "none found".
static func _versions_text(sdks: Array) -> String:
	var versions := PackedStringArray()
	for s in sdks:
		versions.append(str((s as Dictionary).get("version", "")))
	return ", ".join(versions) if not versions.is_empty() else "none found"


# ---------------------------------------------------------------- process half

## Locate the dotnet executable: PATH first, then DOTNET_ROOT / well-known install dirs.
## Validated with a bounded `--version` probe; a hit is cached for the session.
static func find_dotnet() -> String:
	if not _dotnet.is_empty():
		return _dotnet
	var cands: Array = ["dotnet"]
	if OS.has_environment("DOTNET_ROOT"):
		cands.append(OS.get_environment("DOTNET_ROOT").path_join("dotnet"))
	if OS.get_name() == "Windows":
		var pf := OS.get_environment("ProgramFiles")
		cands.append((pf if not pf.is_empty() else "C:/Program Files").path_join("dotnet/dotnet.exe"))
	else:
		# macOS installer, Linux apt/official, Homebrew-Intel, Homebrew-AppleSilicon, Linux snap.
		# These matter when the editor is GUI-launched (minimal PATH) so a bare `dotnet` misses.
		cands.append_array(["/usr/local/share/dotnet/dotnet", "/usr/bin/dotnet", "/usr/local/bin/dotnet",
			"/opt/homebrew/bin/dotnet", "/snap/bin/dotnet"])
		if OS.has_environment("HOME"):
			cands.append(OS.get_environment("HOME").path_join(".dotnet/dotnet"))
	for c in cands:
		var o: Array = []
		if OS.execute(c, ["--version"], o, false) == 0:
			_dotnet = c
			return c
	return ""


## The installed SDKs, from `dotnet --list-sdks`, run ONCE per editor session. A failed run
## (no dotnet, non-zero exit) is not cached, so installing the SDK and retrying works without
## restarting the editor. `force` re-probes.
static func installed_sdks(force: bool = false) -> Array:
	if _sdks_known and not force:
		return _sdks
	var dotnet := find_dotnet()
	if dotnet.is_empty():
		return []
	var out: Array = []
	if OS.execute(dotnet, ["--list-sdks"], out, true) != 0:
		return []
	var text := ""
	for chunk in out:
		text += str(chunk) + "\n"
	_sdks = parse_sdk_list(text)
	_sdks_known = true
	return _sdks


## Drop what installed_sdks cached (tests, and a human who just installed an SDK).
static func forget() -> void:
	_sdks = []
	_sdks_known = false
	_dotnet = ""


## Is this a C# PROJECT: a .csproj at res://, or the assembly name the editor records when it makes
## the C# solution. A .NET build of the editor opened on a GDScript-only project is not one: there is
## no C# to build, and judging the machine's SDKs for it would raise "C#:" warnings (flipping doctor's
## ok) about a language the project does not use. doctor skips the whole block (and its two process
## spawns) for a plain GDScript project.
static func applies() -> bool:
	if not list_csproj().is_empty():
		return true
	return ProjectSettings.has_setting("dotnet/project/assembly_name") and not str(ProjectSettings.get_setting("dotnet/project/assembly_name")).is_empty()


## The project's .csproj: the explicit path, else the dotnet/project setting, else a lone
## .csproj at res://. "" means not found or ambiguous.
static func resolve_csproj(arg: String) -> String:
	if not arg.is_empty():
		return ProjectSettings.globalize_path(arg) if arg.begins_with("res://") else arg
	if ProjectSettings.has_setting("dotnet/project/assembly_name"):
		var nm := str(ProjectSettings.get_setting("dotnet/project/assembly_name"))
		if not nm.is_empty():
			var p := ProjectSettings.globalize_path("res://%s.csproj" % nm)
			if FileAccess.file_exists(p):
				return p
	var found := list_csproj()
	return found[0] if found.size() == 1 else ""


static func list_csproj() -> Array:
	var root := ProjectSettings.globalize_path("res://")
	var out: Array = []
	var d := DirAccess.open(root)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.get_extension() == "csproj":
			out.append(root.path_join(f))
		f = d.get_next()
	d.list_dir_end()
	return out


## Everything the preflight knows, gathered live: {dotnet, sdks, proj, check}. `csproj` is the
## absolute path to judge ("" = the project's own, when it has exactly one). A failing verdict is
## never sticky: the SDKs are re-listed once before it is believed, because the likeliest
## reason for a failure is that the human has just installed the SDK this very message asks for.
static func inspect(csproj: String, engine: Dictionary) -> Dictionary:
	var path := resolve_csproj(csproj).replace("\\", "/")
	var proj: Dictionary = {}
	if not path.is_empty() and FileAccess.file_exists(path):
		proj = parse_csproj(FileAccess.get_file_as_string(path))
		proj["file"] = path.get_file()
	var sdks := installed_sdks()
	var verdict := check(engine, sdks, proj)
	if not bool(verdict["ok"]):
		sdks = installed_sdks(true)
		verdict = check(engine, sdks, proj)
	return {"dotnet": find_dotnet(), "sdks": sdks, "proj": proj, "csproj": path, "check": verdict}
