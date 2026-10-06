@tool
extends EditorDebuggerPlugin

## Is the played game parked inside the editor's debugger? (v1.16)
##
## Why it exists: a GDScript runtime error in a game the editor launched (it carries --remote-debug) makes
## the engine break into the debugger. The game's main thread then sits inside RemoteDebugger::debug() until
## someone presses Continue, so the runtime autoload's _process never runs, the runtime channel gets no
## answer, and every runtime tool times out - while get_play_state still says connected and playing, and the
## embedded timeout text used to blame the Suspend button. An agent that read that gave up on the runtime
## tools and redid the work by running the game headless outside the editor.
##
## So this asks the debugger instead of the game. An EditorDebuggerSession is the editor's own view of one
## run (4.2+: is_active, is_breaked, is_debuggable), and asking it cannot hang. It is read live on every
## question and never mirrored from the breaked/continued signals: a mirror that missed one signal would
## wedge every runtime tool for good, and this one can only ever be as wrong as the editor itself.
##
## What it cannot see: the editor learns that a game broke when it next processes the debugger's messages,
## a frame after the fact, and a tool call that is blocking the main thread (every handler does) has no frame
## in between. A call that is already waiting on the game when it breaks therefore still times out; the NEXT
## call sees the break and answers at once (runtime_bridge.gd words both cases).
##
## Not instantiable outside the editor (the engine refuses), so everything worth testing is static and takes
## the sessions as an argument: the unit suite passes fakes. plugin.gd registers one instance and hands it to
## the runtime bridge; null there means "no editor", and the bridge then behaves as it always did.


## One debugger session per run instance, so a project that runs several instances has several. A game
## counts as broken when ANY active session is, and as breakpoint-style when any broken one can be debugged.
func break_state() -> Dictionary:
	return state_of(get_sessions())


## {} when no active session is in a break, else
## {broken: true, sessions: active sessions, broken_sessions: how many are in a break, can_debug: bool}.
## can_debug is false for a script error (the engine breaks with nothing to step through) and true for a
## breakpoint or the Pause button, which is what lets the message name the right one. `sessions` is
## duck-typed (anything with is_active/is_breaked/is_debuggable), so the unit suite can pass fakes.
static func state_of(sessions: Array) -> Dictionary:
	var active := 0
	var broken := 0
	var can_debug := false
	for s in sessions:
		# is_instance_valid first: it is false for null, for a freed object and for anything that is not an object at
		# all, and `s is Object` on a freed instance is itself a script error.
		if not is_instance_valid(s):
			continue
		if not (s.has_method("is_active") and s.has_method("is_breaked")):
			continue
		if not s.is_active():
			continue
		active += 1
		if s.is_breaked():
			broken += 1
			if s.has_method("is_debuggable") and s.is_debuggable():
				can_debug = true
	if broken == 0:
		return {}
	return {"broken": true, "sessions": active, "broken_sessions": broken, "can_debug": can_debug}
