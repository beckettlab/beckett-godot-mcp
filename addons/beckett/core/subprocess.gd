@tool
extends RefCounted

## Starting a child process, and judging what OS.execute says about one, in one place, so the Windows
## answers and the Linux/macOS answers cannot drift apart (the git check and the warning probe had each
## been written against Windows alone).
##
## Two facts about Godot's process API are encoded here.
##  * OS.execute says "the program could not be started" as -1 on Windows. On Linux and macOS the engine
##    runs the program through a shell, so a missing program is that shell's own answer: exit code 127,
##    and a line like "sh: 1: git: not found" that the caller only sees when it reads stderr (the engine
##    discards stderr otherwise). 126 is a program that exists and cannot be run.
##  * OS.create_process hands the child this process's own stdout and stderr on Linux and macOS. What
##    the child prints (the engine's SCRIPT ERROR text for a script it was asked to check, its own
##    startup lines) lands in the terminal the editor was started from, or in the output of the unit
##    suite that started it. On Windows the child gets no console and nothing leaks.

## The shell that quiet_command wraps a child in. Present on every Linux, macOS and BSD.
const SHELL := "/bin/sh"
## `exec` makes the program take over the shell's process, so the pid OS.create_process returns IS the
## program's and OS.kill and OS.is_process_running keep working on it. "$0" and "$@" carry the program
## and its arguments as separate words, so no path or argument needs quoting, whatever it holds.
const QUIET_SCRIPT := "exec \"$0\" \"$@\" >/dev/null 2>&1 </dev/null"
## What a shell's own complaint starts with, by shell: git's and dotnet's messages never do.
const SHELL_VOICES := ["sh:", "/bin/sh:", "bash:", "dash:", "zsh:", "env:"]


## True when an OS.execute result says the program never ran, as opposed to "it ran and failed" (git's
## 128 for a fatal error, its 129 for a usage error, a build's 1). -1 is Windows (and an engine that
## could not start anything); 127 and 126 are the shell on Linux and macOS. `ran`, when the caller
## knows every exit code the program uses itself (git: 0, 128, 129), turns any other number into "never
## ran" too, whatever the engine called it. Without it, any other number is read by the sentence the
## shell printed, when the call captured stderr: an engine that handed back the raw wait status
## (127 << 8) would still come with "sh: 1: git: not found". `text` is what the call captured and
## `program` the name that was run; both only sharpen the answer.
static func not_started(rc: int, text: String = "", program: String = "", ran: Array = []) -> bool:
	if rc == -1 or rc == 126 or rc == 127:
		return true
	if not ran.is_empty() and not ran.has(rc):
		return true
	if rc == 0 or text.is_empty():
		return false
	var first := ""
	for line in text.split("\n"):
		first = String(line).strip_edges().to_lower()
		if not first.is_empty():
			break
	var shell_said := false
	for voice in SHELL_VOICES:
		if first.begins_with(voice):
			shell_said = true
			break
	if not shell_said or not (first.contains("not found") or first.contains("no such file")):
		return false
	return program.is_empty() or first.contains(program.get_file().to_lower())


## The program and the arguments that start `exe` + `args` with its output out of this process's own.
## Windows needs no wrapper (see the header). Elsewhere the child runs under `sh -c 'exec ...'` with
## stdout, stderr and stdin pointed at /dev/null, which also means it can never block on a full pipe.
## Pure, so the unit suite pins it for every OS name.
static func quiet_command(exe: String, args: PackedStringArray, os_name: String, shell_exists: bool = true) -> Dictionary:
	if os_name == "Windows" or not shell_exists:
		return {"path": exe, "args": args}
	var wrapped := PackedStringArray(["-c", QUIET_SCRIPT, exe])
	wrapped.append_array(args)
	return {"path": SHELL, "args": wrapped}


## OS.create_process with the child's output kept out of this process's own (see the header). Returns
## the pid, or what the engine call returns when it cannot start the child. A child that cannot be
## executed on Linux or macOS still has a pid: it is the shell, which has already exited.
static func spawn_quiet(exe: String, args: PackedStringArray) -> int:
	var cmd := quiet_command(exe, args, OS.get_name(), FileAccess.file_exists(SHELL))
	var argv: PackedStringArray = cmd["args"]
	return OS.create_process(str(cmd["path"]), argv)
