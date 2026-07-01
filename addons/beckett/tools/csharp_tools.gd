@tool
extends RefCounted
class_name BeckettCSharpTools

## C#/.NET dev-loop for Godot Mono/.NET projects. GDScript's compile-gate
## (write_script validates in-process via GDScript.reload) has NO C# equivalent: C#
## compiles out-of-process through `dotnet build` (Roslyn/MSBuild). This tool orchestrates
## the .NET SDK the user ALREADY has (it's a hard prerequisite of C#-in-Godot) — so C#
## support adds ZERO new dependency, and the build runs as a transient subprocess (like
## export_project), so the zero-sidecar promise holds (no persistent relay).
##
## Design (each point verified live 2026-07-01):
##  * Builds to a SCRATCH output dir (-o) so it NEVER writes the assembly the editor has
##    loaded (`.godot/mono/temp/bin`). On Windows the editor's collectible AssemblyLoadContext
##    can fail to unload and keep that DLL locked; building elsewhere sidesteps the lock and
##    never perturbs the editor's assembly state. (obj/ intermediates are not the loaded file.)
##  * This is a compile-CHECK: it returns diagnostics; it does NOT make the editor reload new
##    C# types — that needs Godot's own Build (hammer) or simply happens on play (Godot builds
##    before running). Kept isolated on purpose.
##  * `--tl:off` is REQUIRED: .NET 8+ Terminal Logger reformats output and breaks the parser.

var server  # mcp_server node

var _dotnet := ""  # cached resolved dotnet path (probe once)


func _register(registry) -> void:
	registry.register({
		"name": "build_csharp",
		"description": "Compile-check a C#/.NET Godot project with `dotnet build`, returning structured diagnostics (errors/warnings with file:line:col + CS-code). Isolated build (scratch output) — never touches the editor's loaded assembly, so it's safe while the editor is open. Auto-detects the .csproj if omitted. Needs the .NET SDK (already installed for any C# Godot project). First build restores packages (slower); incremental ~1-3s. Use after editing .cs — the GDScript compile-gate (write_script) does NOT cover C#.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"csproj": {"type": "string", "description": "res:// or absolute path to the .csproj; auto-detected from the project if omitted"},
			"configuration": {"type": "string", "description": "Debug (default) or Release"},
		}},
		"handler": Callable(self, "_build_csharp"),
	})


# ---------------------------------------------------------------- handler

func _build_csharp(args: Dictionary) -> Dictionary:
	var dotnet := _find_dotnet()
	if dotnet.is_empty():
		return {"error": "Could not find the .NET SDK (`dotnet`). It's required for C# in Godot — install from https://dotnet.microsoft.com or put dotnet on PATH.",
			"suggestion": "If it's installed, set DOTNET_ROOT or add its folder to PATH, then retry."}
	var csproj := _resolve_csproj(str(args.get("csproj", "")))
	if csproj.is_empty():
		return _csproj_error()
	# Godot's FileAccess and dotnet both take forward slashes; a caller may pass a native
	# Windows path with backslashes, which FileAccess.file_exists would miss.
	csproj = csproj.replace("\\", "/")
	if not FileAccess.file_exists(csproj):
		return {"error": "No .csproj at: %s" % _to_res(csproj)}
	var config := str(args.get("configuration", "Debug"))
	if config != "Debug" and config != "Release":
		config = "Debug"
	# Build to a scratch dir so we never fight the editor for the loaded DLL.
	var build_args := ["build", csproj, "-c", config, "-o", _scratch_dir(),
		"--tl:off", "-clp:NoSummary", "-v:m", "-nologo"]
	var output: Array = []
	var code := OS.execute(dotnet, build_args, output, true)  # read_stderr=true
	if code == -1:
		return {"error": "Failed to launch `dotnet build` (%s). Is the .NET SDK healthy?" % dotnet}
	var text := ""
	for chunk in output:
		text += str(chunk) + "\n"
	var diags := _parse_diagnostics(text)
	var errs := 0
	var warns := 0
	for d in diags:
		if d["severity"] == "error":
			errs += 1
		else:
			warns += 1
	var ok := code == 0
	# NOTE: return ONLY "json" — the server's result serializer is if/elif, so a top-level
	# "text" key would shadow the "json" branch and drop structuredContent. Summary goes inside.
	return {"json": {
		"ok": ok,
		"summary": ("C# build OK — compiles (%d warning(s))." % warns) if ok \
			else ("C# build FAILED — %d error(s), %d warning(s)." % [errs, warns]),
		"exit_code": code,
		"csproj": _to_res(csproj),
		"configuration": config,
		"errors": errs,
		"warnings": warns,
		"diagnostics": diags,
	}}


# ---------------------------------------------------------------- helpers

## Locate the dotnet executable: PATH first, then DOTNET_ROOT / well-known install dirs.
## Validated with a bounded `--version` probe; the result is cached for the session.
func _find_dotnet() -> String:
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


## Resolve the project's .csproj: explicit arg -> the dotnet/project setting -> a lone
## .csproj at res://. Empty string means "not found / ambiguous" (see _csproj_error).
func _resolve_csproj(arg: String) -> String:
	if not arg.is_empty():
		return ProjectSettings.globalize_path(arg) if arg.begins_with("res://") else arg
	if ProjectSettings.has_setting("dotnet/project/assembly_name"):
		var nm := str(ProjectSettings.get_setting("dotnet/project/assembly_name"))
		if not nm.is_empty():
			var p := ProjectSettings.globalize_path("res://%s.csproj" % nm)
			if FileAccess.file_exists(p):
				return p
	var found := _list_csproj()
	return found[0] if found.size() == 1 else ""


func _list_csproj() -> Array:
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


func _csproj_error() -> Dictionary:
	var found := _list_csproj()
	if found.size() > 1:
		var names := PackedStringArray()
		for p in found:
			names.append(_to_res(p))
		return {"error": "Multiple .csproj found — pass 'csproj' explicitly.",
			"suggestion": "One of: %s" % ", ".join(names)}
	return {"error": "No .csproj found — is this a C#/.NET Godot project?",
		"suggestion": "C# Godot projects have a <Name>.csproj at res:// (Godot writes it when you add a C# script). Pass 'csproj' if it lives elsewhere."}


func _scratch_dir() -> String:
	var dir := OS.get_cache_dir().path_join("beckett/csharp-build")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## Rewrite an absolute path back to res:// when it's inside the project (nicer for the agent).
func _to_res(abs_path: String) -> String:
	var root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	var a := abs_path.replace("\\", "/")
	return "res://" + a.substr(root.length()) if a.begins_with(root) else abs_path


## Parse MSBuild/Roslyn console diagnostics. Canonical line (with --tl:off):
##   <file>(<line>,<col>): <error|warning> <CODE>: <message> [<project>]
## Matched per-line with numbered groups; deduped (MSBuild can repeat a diagnostic).
func _parse_diagnostics(text: String) -> Array:
	var rx := RegEx.new()
	rx.compile("^(.+?)\\((\\d+),(\\d+)\\):\\s+(error|warning)\\s+([A-Za-z]{2,}[0-9]+):\\s+(.+?)\\s+\\[[^\\]]+\\]\\s*$")
	var seen := {}
	var out: Array = []
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		var m := rx.search(line)
		if m == null:
			continue
		var key := "%s|%s|%s|%s" % [m.get_string(1), m.get_string(2), m.get_string(3), m.get_string(5)]
		if seen.has(key):
			continue
		seen[key] = true
		out.append({
			"severity": m.get_string(4),
			"code": m.get_string(5),
			"file": _to_res(m.get_string(1)),
			"line": m.get_string(2).to_int(),
			"column": m.get_string(3).to_int(),
			"message": m.get_string(6),
		})
		if out.size() >= 100:
			break
	return out
