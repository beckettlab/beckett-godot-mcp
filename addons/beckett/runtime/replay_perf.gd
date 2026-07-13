extends RefCounted
## Replay-window perf capture (v1.9.1, extracted from mcp_runtime as part of the B7 split).
## Real Performance monitors sampled once per UNPAUSED tick — frame_ms = last process
## frame's cost (the thing you optimize), fps = the engine's own frames-per-second read
## (what the player experiences, vsync-capped; the engine refreshes it ~1/s so short
## windows repeat values). Memory/orphan baselines snapshot at begin(). summary() is FLAT
## so playtest perf asserts and baseline diffs address each metric by one stable name.
## Measured, never modeled — no samples means an EMPTY summary, not fabricated zeros.
## Mirrored (deliberately, self-contained) by playtest_runner._perf_summary — extend both.

const CAP := 36000  # ~10 min @ 60 ticks/s — bound a runaway window's capture

var _ms := PackedFloat64Array()
var _fps := PackedFloat64Array()
var _mem0 := 0.0
var _orphan0 := 0.0


## Reset the capture and snapshot the delta baselines. Call when the replay window opens.
func begin() -> void:
	_ms = PackedFloat64Array()
	_fps = PackedFloat64Array()
	_mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
	_orphan0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)


## Sample once — call per unpaused replay tick.
func tick() -> void:
	if _ms.size() >= CAP:
		return
	_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_fps.append(Performance.get_monitor(Performance.TIME_FPS))


## Flat numeric summary ({} until something was sampled): frames, frame_ms_min/avg/p95/max,
## fps_min/avg, memory_static_end, memory_delta, orphan_delta, draw_calls_end.
func summary() -> Dictionary:
	if _ms.is_empty():
		return {}
	var by_ms := _ms.duplicate()
	by_ms.sort()
	var n := by_ms.size()
	var total := 0.0
	for v in by_ms:
		total += v
	var fps_total := 0.0
	var fps_min := 0.0
	for i in _fps.size():
		fps_total += _fps[i]
		if i == 0 or _fps[i] < fps_min:
			fps_min = _fps[i]
	return {
		"frames": n,
		"frame_ms_min": by_ms[0],
		"frame_ms_avg": total / float(n),
		"frame_ms_p95": by_ms[clampi(int(ceil(float(n) * 0.95)) - 1, 0, n - 1)],
		"frame_ms_max": by_ms[n - 1],
		"fps_min": fps_min,
		"fps_avg": fps_total / float(maxi(1, _fps.size())),
		"memory_static_end": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_delta": Performance.get_monitor(Performance.MEMORY_STATIC) - _mem0,
		"orphan_delta": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _orphan0,
		"draw_calls_end": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}
