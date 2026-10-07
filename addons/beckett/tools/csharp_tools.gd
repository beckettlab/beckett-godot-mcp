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
##  * The .NET SDK is checked BEFORE the build (core/dotnet_check.gd, shared with doctor): Godot
##    4.8 needs the .NET 10 SDK, and a missing one used to surface as raw NETSDK1045 lines.

const DotnetCheck := preload("res://addons/beckett/core/dotnet_check.gd")
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the read rule for a .csproj the caller names (dotnet build runs whatever that project says)
const Subprocess := preload("res://addons/beckett/core/subprocess.gd")  # was dotnet started at all: -1 on Windows, 127 on Linux and macOS

var server  # mcp_server node


func _register(registry) -> void:
	registry.register({
		"name": "build_csharp",
		"description": "Compile-check a C#/.NET Godot project with `dotnet build`, returning structured diagnostics (errors/warnings with file:line:col + CS-code). Isolated build (scratch output) — never touches the editor's loaded assembly, so it's safe while the editor is open. Auto-detects the .csproj if omitted. Needs the .NET SDK, checked first (Godot 4.8 needs SDK 10): a missing or too-old one comes back as a plain error saying what to install, not as build noise. First build restores packages (slower); incremental ~1-3s. Use after editing .cs — the GDScript compile-gate (write_script) does NOT cover C#.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"csproj": {"type": "string", "description": "res:// or absolute path to the .csproj; auto-detected from the project if omitted"},
			"configuration": {"type": "string", "description": "Debug (default) or Release"},
		}},
		"handler": Callable(self, "_build_csharp"),
	})


# ---------------------------------------------------------------- handler

func _build_csharp(args: Dictionary) -> Dictionary:
	# First, before anything is looked up or run: a project's own .csproj is auto-detected, and one the
	# caller names stays inside the project (dotnet build runs whatever that project says).
	var csproj_arg := str(args.get("csproj", ""))
	var guard: Dictionary = PathGuard.check_read(csproj_arg)
	if guard.has("error"):
		return guard
	var dotnet := _find_dotnet()
	if dotnet.is_empty():
		return {"error": "Could not find the .NET SDK (`dotnet`). It's required for C# in Godot — install from https://dotnet.microsoft.com or put dotnet on PATH.",
			"suggestion": "If it's installed, set DOTNET_ROOT or add its folder to PATH, then retry."}
	var csproj := _resolve_csproj(csproj_arg)
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
	# Preflight: does an installed SDK satisfy this project and this engine? A build that cannot
	# work is not started; the answer is a plain error naming what to install.
	var engine := Engine.get_version_info()
	var insp := DotnetCheck.inspect(csproj, engine)
	var verdict: Dictionary = insp["check"]
	if not bool(verdict["ok"]):
		return _problem_error("C# build not started", verdict["problems"])
	# Build to a scratch dir so we never fight the editor for the loaded DLL.
	var build_args := ["build", csproj, "-c", config, "-o", _scratch_dir(),
		"--tl:off", "-clp:NoSummary", "-v:m", "-nologo"]
	var output: Array = []
	var code := OS.execute(dotnet, build_args, output, true)  # read_stderr=true
	var text := ""
	for chunk in output:
		text += str(chunk) + "\n"
	if Subprocess.not_started(code, text, dotnet):
		return {"error": "Failed to launch `dotnet build` (%s). Is the .NET SDK healthy?" % dotnet}
	var diags := _parse_diagnostics(text)
	var errs := 0
	var warns := 0
	for d in diags:
		if d["severity"] == "error":
			errs += 1
		else:
			warns += 1
	var ok := code == 0
	# The preflight cannot see everything (a csproj that builds its target framework from a
	# property, say), so a build that still dies on an SDK-cannot-target code gets the same
	# plain words instead of the raw MSBuild line.
	if not ok:
		var mapped := DotnetCheck.problem_from_diagnostics(diags, engine, insp["sdks"], insp["proj"])
		if not mapped.is_empty():
			return _problem_error("C# build failed", [mapped])
	# NOTE: return ONLY "json" — the server's result serializer is if/elif, so a top-level
	# "text" key would shadow the "json" branch and drop structuredContent. Summary goes inside.
	return PathGuard.noted({"json": {
		"ok": ok,
		"summary": ("C# build OK — compiles (%d warning(s))." % warns) if ok \
			else ("C# build FAILED — %d error(s), %d warning(s)." % [errs, warns]),
		"exit_code": code,
		"csproj": _to_res(csproj),
		"configuration": config,
		"errors": errs,
		"warnings": warns,
		"diagnostics": diags,
	}}, guard)


# ---------------------------------------------------------------- helpers

## The dotnet probing, .csproj lookup and SDK rules live in core/dotnet_check.gd (doctor needs
## them too); these three are the names this file has always used.
func _find_dotnet() -> String:
	return DotnetCheck.find_dotnet()


func _resolve_csproj(arg: String) -> String:
	return DotnetCheck.resolve_csproj(arg)


func _list_csproj() -> Array:
	return DotnetCheck.list_csproj()


## The preflight's (or the mapped build failure's) problems as one tool error: what is wrong, in
## plain words, and the next step.
func _problem_error(lead: String, problems: Array) -> Dictionary:
	var what := PackedStringArray()
	var next := PackedStringArray()
	for p in problems:
		what.append(str((p as Dictionary).get("message", "")))
		next.append(str((p as Dictionary).get("suggestion", "")))
	return {"error": "%s: %s" % [lead, " ".join(what)], "suggestion": " ".join(next)}


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
## Restore and project-level errors (NU1202, MSB4025, ...) carry no position and often no
## trailing [project]: `Game.csproj : error NU1202: ...`; they parse with line/column 0, so a
## build that failed before compiling never reads as "FAILED, 0 errors".
## Matched per-line with numbered groups; deduped (MSBuild can repeat a diagnostic).
func _parse_diagnostics(text: String) -> Array:
	var rx := RegEx.new()
	rx.compile("^(.+?)(?:\\((\\d+),(\\d+)\\))?\\s*:\\s+(error|warning)\\s+([A-Za-z]{2,}[0-9]+):\\s+(.+?)(?:\\s+\\[[^\\]]+\\])?\\s*$")
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
