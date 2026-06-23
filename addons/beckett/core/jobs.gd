@tool
extends RefCounted
class_name BeckettJobs

## Background jobs (D6). Long-running work — today a full project export — runs as a
## detached OS subprocess so the editor (and the MCP request loop) never freezes.
## Handlers stay synchronous (the zero-sidecar constraint): spawn returns immediately
## with a job_id and the agent polls job_status; pipes are drained lazily on each poll.
##
## On Godot 4.4+ the subprocess is spawned with OS.execute_with_pipe (non-blocking)
## so stdout/stderr are captured. Older engines fall back to OS.create_process —
## the job still runs and completion/exit code still report, just without output.
##
## IMPORTANT: the owner must call tick() every frame. A chatty subprocess fills the
## OS pipe buffer (~64KB) and then BLOCKS on write — draining only on status polls
## would deadlock it between polls (observed live with Godot's import progress spam).

const _OUTPUT_CAP := 65536  # keep at most this much tail per job

# id -> {id, kind, pid, started, meta, output:String, stdio:FileAccess?, stderr:FileAccess?,
#        done:bool, exit_code:int}
var _jobs: Dictionary = {}
var _seq: int = 0


## Spawn `exe` with `arguments` as a background process. Returns {ok, job_id, pid}
## or {error}. `meta` is echoed back from status (e.g. preset/output_path).
func spawn(kind: String, exe: String, arguments: Array, meta: Dictionary = {}) -> Dictionary:
	_seq += 1
	var id := "%s-%d" % [kind, _seq]
	var args := PackedStringArray()
	for a in arguments:
		args.append(str(a))

	var job := {
		"id": id, "kind": kind, "pid": -1, "started": Time.get_datetime_string_from_system(),
		"meta": meta, "output": "", "stdio": null, "stderr": null,
		"done": false, "exit_code": -1,
	}

	if _has_pipe_spawn():
		# Dynamic call keeps this script parse-safe on engines without the method.
		var d: Variant = OS.call("execute_with_pipe", exe, args, false)
		if typeof(d) == TYPE_DICTIONARY and d.has("pid"):
			job["pid"] = int(d["pid"])
			job["stdio"] = d.get("stdio")
			job["stderr"] = d.get("stderr")
	if int(job["pid"]) < 0:
		var pid := OS.create_process(exe, args)
		if pid < 0:
			return {"error": "failed to spawn %s subprocess" % kind}
		job["pid"] = pid
		job["output"] = "(output capture needs Godot 4.4+; falling back to exit code + artifacts)"

	_jobs[id] = job
	return {"ok": true, "job_id": id, "pid": int(job["pid"])}


## Poll one job: drains its pipes, refreshes running/exit state.
## Returns {found:false} for an unknown id.
func status(id: String) -> Dictionary:
	if not _jobs.has(id):
		return {"found": false, "error": "unknown job_id '%s'" % id, "jobs": list()}
	var job: Dictionary = _jobs[id]
	_refresh(job)
	var out := {
		"found": true,
		"job_id": id,
		"kind": job["kind"],
		"running": not bool(job["done"]),
		"started": job["started"],
		"meta": job["meta"],
		"output_tail": _clean(_tail(str(job["output"]), 4000)),
	}
	if bool(job["done"]):
		out["exit_code"] = int(job["exit_code"])
	return out


## Kill a running job's process. Status stays queryable afterwards.
func cancel(id: String) -> Dictionary:
	if not _jobs.has(id):
		return {"found": false, "error": "unknown job_id '%s'" % id}
	var job: Dictionary = _jobs[id]
	_refresh(job)
	if bool(job["done"]):
		return {"found": true, "job_id": id, "cancelled": false, "note": "already finished"}
	var err := OS.kill(int(job["pid"]))
	return {"found": true, "job_id": id, "cancelled": err == OK}


## Per-frame upkeep: drain the pipes of every live job so the subprocess never
## stalls on a full pipe. Cheap when nothing is running.
func tick() -> void:
	for id in _jobs:
		var job: Dictionary = _jobs[id]
		if not bool(job["done"]):
			_drain(job)


## Compact summaries of every job this session (newest last).
func list() -> Array:
	var out: Array = []
	for id in _jobs:
		var job: Dictionary = _jobs[id]
		_refresh(job)
		out.append({
			"job_id": id, "kind": job["kind"], "running": not bool(job["done"]),
			"started": job["started"],
		})
	return out


# ---------------------------------------------------------------- internals

func _refresh(job: Dictionary) -> void:
	_drain(job)
	if bool(job["done"]):
		return
	var pid := int(job["pid"])
	if OS.is_process_running(pid):
		return
	job["done"] = true
	_drain(job)  # final drain after exit
	job["exit_code"] = _exit_code(pid)


func _drain(job: Dictionary) -> void:
	for key in ["stdio", "stderr"]:
		var fa: FileAccess = job[key]
		if fa == null:
			continue
		while true:
			var chunk := fa.get_buffer(4096)
			if chunk.size() == 0:
				break
			job["output"] = _tail(str(job["output"]) + chunk.get_string_from_utf8(), _OUTPUT_CAP)


func _exit_code(pid: int) -> int:
	# OS.get_process_exit_code is 4.3+; report -1 (unknown) on older engines.
	if OS.has_method("get_process_exit_code"):
		return int(OS.call("get_process_exit_code", pid))
	return -1


func _has_pipe_spawn() -> bool:
	# execute_with_pipe exists from 4.3 but its non-blocking flag arrived in 4.4.
	var v := Engine.get_version_info()
	return int(v.get("major", 4)) > 4 \
		or (int(v.get("major", 4)) == 4 and int(v.get("minor", 0)) >= 4)


static func _tail(s: String, n: int) -> String:
	return s if s.length() <= n else "…" + s.substr(s.length() - n)


## Strip ANSI escape sequences + raw control bytes from captured subprocess output.
## Godot's JSON.stringify leaves control chars (e.g. the ESC 0x1B in a colored export log)
## RAW inside JSON strings; a strict MCP client then rejects the whole response as malformed
## — surfacing as "session expired" on the next job_status. Drop ANSI colour codes and lone
## control bytes; keep tab / newline / carriage-return.
static func _clean(s: String) -> String:
	if s.is_empty():
		return s
	var ansi := RegEx.create_from_string("\\x1b\\[[0-9;?]*[ -/]*[@-~]")
	if ansi != null:
		s = ansi.sub(s, "", true)
	var ctrl := RegEx.create_from_string("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f]")
	if ctrl != null:
		s = ctrl.sub(s, "", true)
	return s
