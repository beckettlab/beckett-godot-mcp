extends RefCounted
## Replay-window perf capture (v1.9.1, extracted from mcp_runtime as part of the B7 split), timed frame by frame
## since 1.17. One implementation behind both measuring windows: the editor's replay window (runtime/mcp_runtime.gd)
## and the headless runner (runtime/playtest_runner.gd).
##
## frame_ms is the wall time from one frame to the next. The owner calls frame() at one fixed point of every process
## frame with Time.get_ticks_usec(), and each interval between two calls is one sample: physics steps, scripts,
## drawing and any vsync or max_fps wait included, which is what a frame budget means. Before 1.17 this read
## Performance.TIME_PROCESS on every physics tick, but Godot sets that monitor once a second, to the slowest frame of
## the second before (its process pass and drawing, physics left out), and it reads 0 in a game's first second
## (main.cpp Main::iteration, 4.2 to 4.7): a window of a few seconds repeated a handful of stale maxima. A field
## session on 2026-10-12 read 19 to 36 ms that way where its frames took 13.4 to 26.6 ms. fps_avg and fps_min come
## from the same intervals. Memory/orphan baselines snapshot at begin(). summary() is FLAT so playtest perf asserts and
## baseline diffs address each metric by one stable name. Measured, never modeled: no frame timed means an EMPTY
## summary, not fabricated zeros.

const CAP := 36000  # intervals kept: 10 min at 60 fps, about 4 at a headless game's pace (bounds a runaway window)
## What timed frame_ms: 1 = TIME_PROCESS read on every physics tick (before 1.17), 2 = this frame clock. The game's
## fingerprint carries it, so a perf baseline timed by the other clock is labelled not comparable.
const CLOCK := 2

var active := false
var _ms := PackedFloat64Array()
var _last_us := -1
var _mem0 := 0.0
var _orphan0 := 0.0


## Reset the capture, snapshot the delta baselines and start timing. Call when the window opens.
func begin() -> void:
	_ms = PackedFloat64Array()
	_last_us = -1
	active = true
	_mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
	_orphan0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)


## Stop timing and keep what was timed. Call when the window closes, or is dropped.
func end() -> void:
	active = false


## A frame reached the owner's fixed point at t_us (Time.get_ticks_usec()): call once per process frame, a no-op while
## no window is open. The first call after begin() only sets the start, so every sample is one whole frame.
func frame(t_us: int) -> void:
	if not active:
		return
	if _last_us >= 0 and t_us > _last_us and _ms.size() < CAP:
		_ms.append(float(t_us - _last_us) / 1000.0)
	_last_us = t_us


## Flat numeric summary ({} until a frame was timed): frames (the frame intervals timed), frame_ms_min/avg/p95/max (ms,
## to 0.01), fps_min/avg (to 0.1), memory_static_end, memory_delta, orphan_delta, draw_calls_end.
func summary() -> Dictionary:
	if _ms.is_empty():
		return {}
	var by_ms := _ms.duplicate()
	by_ms.sort()
	var n := by_ms.size()
	var total := 0.0
	for v in by_ms:
		total += v
	return {
		"frames": n,
		"frame_ms_min": snappedf(by_ms[0], 0.01),
		"frame_ms_avg": snappedf(total / float(n), 0.01),
		"frame_ms_p95": snappedf(by_ms[clampi(int(ceil(float(n) * 0.95)) - 1, 0, n - 1)], 0.01),
		"frame_ms_max": snappedf(by_ms[n - 1], 0.01),
		"fps_min": fps_min_of(_ms),
		"fps_avg": snappedf(1000.0 * float(n) / total, 0.1) if total > 0.0 else 0.0,
		"memory_static_end": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_delta": Performance.get_monitor(Performance.MEMORY_STATIC) - _mem0,
		"orphan_delta": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _orphan0,
		"draw_calls_end": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}


## The frame rate of the slowest stretch of about a second: from each frame, the run of frames that first reaches
## 1000 ms, at frames * 1000 / its length, and the lowest of those. A 300 ms hitch among 60 fps frames reads about 43
## (counting whole seconds would depend on where their edges fall), and one frame of 1200 ms reads 0.8. A window shorter
## than a second has no such run and reads its own rate. Two pointers, O(n). Pure.
static func fps_min_of(ms: PackedFloat64Array) -> float:
	var n := ms.size()
	var total := 0.0
	for v in ms:
		total += v
	if n == 0 or total <= 0.0:
		return 0.0
	if total < 1000.0:
		return snappedf(1000.0 * float(n) / total, 0.1)
	var worst := INF
	var k := 0
	var run := 0.0
	for j in n:
		while k < n and run < 1000.0:
			run += ms[k]
			k += 1
		if run < 1000.0:
			break
		worst = minf(worst, 1000.0 * float(k - j) / run)
		run -= ms[j]
	return snappedf(worst, 0.1)
