@tool
extends VBoxContainer

## In-editor dock (D5) — status, one-click Start/Stop, ZERO-click client setup, and a
## live activity feed of what the AI did. First impression for a paid product: connect
## with no JSON hand-editing — ideally with no click at all (plugin start auto-writes
## configs for the clients that exist on this machine; one button covers the rest).
##
## Design: native-feeling cards built from the editor theme (colors, icons, fonts,
## editor scale) so the dock looks at home in any Godot theme variant. No scene
## file — everything is code-built, so the panel ships as a single script.

const MCPClientConfig := preload("res://addons/beckett/core/client_config.gd")
const MCPEffortScript := preload("res://addons/beckett/core/effort.gd")

var server   # mcp_server node
var plugin   # EditorPlugin

const DEFAULT_PORT := 8770
const ACTIVITY_ROWS := 6
# TODO(W5.1): point at the live store page before the Lite listing ships.
const UPGRADE_URL := "https://beckettlabs.itch.io/beckett-godot-mcp"

var _es := 1.0  # editor display scale; multiply every px size by this

var _status_pill: PanelContainer
var _status_pill_label: Label
var _pill_on: StyleBoxFlat
var _pill_off: StyleBoxFlat
var _toggle_btn: Button
var _url_btn: Button
var _game_label: Label
var _client_label: Label
var _clients_list: VBoxContainer
var _clients_count: Label
var _clients_empty: Label
var _effort_slider: HSlider
var _tier_label: Label
var _tier_stats: Label
var _effort_desc: Label
var _activity_box: VBoxContainer
var _activity_empty: Label
var _activity_count: Label
var _feedback: Label
var _accum := 0.0
var _clients_accum := 999.0  # refresh client detection immediately on first tick
var _audit_sig := ""
var _feedback_left := 0.0
var _was_running := false


func _ready() -> void:
	name = "Beckett"
	if Engine.is_editor_hint():
		_es = EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(8 * _es))

	_build_header()
	_build_server_card()
	_build_clients_card()
	_build_effort_card()
	_build_activity_card()
	if _is_lite():
		_build_upgrade_button()

	_feedback = Label.new()
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.add_theme_font_size_override("font_size", int(12 * _es))
	_feedback.visible = false
	add_child(_feedback)

	set_process(true)
	_refresh()
	_refresh_effort()


# ---------------------------------------------------------------- header

func _build_header() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(6 * _es))
	add_child(row)

	var title := Label.new()
	title.text = "Beckett"
	title.add_theme_font_size_override("font_size", int(16 * _es))
	if has_theme_font("bold", "EditorFonts"):
		title.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	row.add_child(title)

	var tagline := Label.new()
	var ver := _plugin_version()
	tagline.text = "MCP for Godot" + (" · v" + ver if ver != "" else "")
	tagline.add_theme_font_size_override("font_size", int(11 * _es))
	tagline.add_theme_color_override("font_color", _dim())
	tagline.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(tagline)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	if _is_lite():
		row.add_child(_make_pill("LITE", _color("warning_color", Color(0.9, 0.7, 0.2))))
	else:
		row.add_child(_make_pill("FULL", _color("accent_color", Color(0.4, 0.6, 1.0))))

	# Live server pill — green when running, neutral when stopped.
	_pill_on = _pill_style(_color("success_color", Color(0.3, 0.8, 0.4)))
	_pill_off = _pill_style(_dim())
	_status_pill = PanelContainer.new()
	_status_pill_label = Label.new()
	_status_pill_label.add_theme_font_size_override("font_size", int(11 * _es))
	_status_pill.add_child(_status_pill_label)
	row.add_child(_status_pill)


# ---------------------------------------------------------------- server card

func _build_server_card() -> void:
	var box := _card("Server")

	_toggle_btn = Button.new()
	_toggle_btn.custom_minimum_size = Vector2(0, 30 * _es)
	_toggle_btn.pressed.connect(_on_toggle_server)
	box.add_child(_toggle_btn)

	# Endpoint — the whole row is a flat click-to-copy button.
	_url_btn = Button.new()
	_url_btn.flat = true
	_url_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_url_btn.clip_text = true
	_url_btn.icon = _eicon("ActionCopy")
	_url_btn.add_theme_font_size_override("font_size", int(12 * _es))
	_url_btn.tooltip_text = "Click to copy the MCP endpoint URL"
	_url_btn.pressed.connect(_on_copy_url)
	box.add_child(_url_btn)

	# Shown only while a played game has the runtime channel open (noise-free idle).
	_game_label = Label.new()
	_game_label.text = "● game runtime connected"
	_game_label.add_theme_font_size_override("font_size", int(11 * _es))
	_game_label.add_theme_color_override("font_color", _color("success_color", Color(0.3, 0.8, 0.4)))
	_game_label.tooltip_text = "Live link to the running game — playtest tools use this"
	_game_label.visible = false
	box.add_child(_game_label)

	# Who's actually connected (from the client's initialize handshake) + when it last
	# called. This is the real connection state — distinct from "config written" in the
	# Clients card. The model is intentionally not shown: MCP never reports it.
	_client_label = Label.new()
	_client_label.add_theme_font_size_override("font_size", int(11 * _es))
	_client_label.add_theme_color_override("font_color", _dim())
	_client_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_client_label.tooltip_text = "The connected MCP client, reported by its initialize handshake.\nThe model is chosen inside that client — MCP does not report the model to the server."
	_client_label.visible = false
	box.add_child(_client_label)


# ---------------------------------------------------------------- clients card

func _build_clients_card() -> void:
	# Which clients exist here, and which are already wired up. Configs for installed
	# clients are written automatically when the plugin starts — usually this already
	# reads all-✓ and the user never clicks anything. The count ("3 / 5 configured")
	# rides the card header line, right-aligned.
	_clients_count = Label.new()
	_clients_count.add_theme_font_size_override("font_size", int(10 * _es))
	_clients_count.add_theme_color_override("font_color", _dim())
	var box := _card("Clients", _clients_count)

	# One row per installed client — name + a ✓ once its config is written. Installed-only,
	# rebuilt each detection tick by _refresh_clients, so a clean machine reads tidy.
	_clients_list = VBoxContainer.new()
	_clients_list.add_theme_constant_override("separation", int(3 * _es))
	_clients_list.tooltip_text = "Installed MCP clients on this machine. ✓ = config written; ○ = detected but not configured yet.\nConfigs are written automatically on plugin start; the live-connected client shows under Server."
	box.add_child(_clients_list)

	# Shown instead of the strip when no MCP client is detected on this machine.
	_clients_empty = Label.new()
	_clients_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_clients_empty.add_theme_font_size_override("font_size", int(12 * _es))
	_clients_empty.add_theme_color_override("font_color", _dim())
	_clients_empty.visible = false
	box.add_child(_clients_empty)

	var connect_btn := Button.new()
	connect_btn.text = "Connect Detected Clients"
	connect_btn.custom_minimum_size = Vector2(0, 26 * _es)
	connect_btn.tooltip_text = "Write/merge the MCP config for every client found on this machine (never clobbers other servers). Claude Desktop gets an npx mcp-remote bridge entry (needs Node.js)."
	connect_btn.pressed.connect(_on_connect_clients)
	box.add_child(connect_btn)

	var copy_btn := Button.new()
	copy_btn.text = "Copy config JSON (other clients)"
	copy_btn.flat = true
	copy_btn.icon = _eicon("ActionCopy")
	copy_btn.add_theme_font_size_override("font_size", int(11 * _es))
	copy_btn.tooltip_text = "Copy a generic MCP client config — for Windsurf, Cline, or anything not auto-detected"
	copy_btn.pressed.connect(_on_copy)
	box.add_child(copy_btn)


# ---------------------------------------------------------------- effort card

func _build_effort_card() -> void:
	var box := _card("AI Effort")

	var head := HBoxContainer.new()
	box.add_child(head)
	_tier_label = Label.new()
	_tier_label.add_theme_font_size_override("font_size", int(14 * _es))
	_tier_label.add_theme_color_override("font_color", _color("accent_color", Color(0.4, 0.6, 1.0)))
	if has_theme_font("bold", "EditorFonts"):
		_tier_label.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	head.add_child(_tier_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_tier_stats = Label.new()
	_tier_stats.add_theme_font_size_override("font_size", int(11 * _es))
	_tier_stats.add_theme_color_override("font_color", _dim())
	_tier_stats.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(_tier_stats)

	var maxv := _max_effort()
	_effort_slider = HSlider.new()
	_effort_slider.min_value = 1
	_effort_slider.max_value = maxv
	_effort_slider.step = 1
	_effort_slider.tick_count = maxv
	_effort_slider.ticks_on_borders = true
	_effort_slider.scrollable = true
	_effort_slider.custom_minimum_size = Vector2(0, 18 * _es)
	_effort_slider.tooltip_text = "Caps the tools the MCP client sees. Lower = cheaper model context, fewer capabilities. Applies live to connected clients that support tools/list_changed; others pick it up on reconnect."
	_effort_slider.value = float(_cur_effort())  # set before connecting so it doesn't self-fire
	_effort_slider.value_changed.connect(_on_effort_changed)
	box.add_child(_effort_slider)

	# Tier names under the ticks: L1 left-aligned, L<max> right-aligned.
	var ticks := HBoxContainer.new()
	box.add_child(ticks)
	for lvl in range(1, maxv + 1):
		var t := Label.new()
		t.text = str(MCPEffortScript.LEVELS.get(lvl, {}).get("name", "L%d" % lvl))
		t.add_theme_font_size_override("font_size", int(10 * _es))
		t.add_theme_color_override("font_color", _dim())
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if lvl == 1:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		elif lvl == maxv:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		else:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ticks.add_child(t)

	_effort_desc = Label.new()
	_effort_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effort_desc.add_theme_font_size_override("font_size", int(11 * _es))
	_effort_desc.add_theme_color_override("font_color", _dim())
	box.add_child(_effort_desc)


# ---------------------------------------------------------------- activity card

func _build_activity_card() -> void:
	var box := _card("Activity")

	_activity_empty = Label.new()
	_activity_empty.text = "No calls yet — ask your AI assistant something."
	_activity_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_activity_empty.add_theme_font_size_override("font_size", int(11 * _es))
	_activity_empty.add_theme_color_override("font_color", _dim())
	box.add_child(_activity_empty)

	_activity_box = VBoxContainer.new()
	_activity_box.add_theme_constant_override("separation", int(2 * _es))
	box.add_child(_activity_box)

	_activity_count = Label.new()
	_activity_count.add_theme_font_size_override("font_size", int(10 * _es))
	_activity_count.add_theme_color_override("font_color", _dim())
	_activity_count.tooltip_text = "Full history: resources/read audit://recent"
	_activity_count.visible = false
	box.add_child(_activity_count)


## Rebuild the activity rows only when the audit ring actually changed.
func _refresh_activity() -> void:
	if server == null or not server.has_method("audit_log"):
		return
	var audit: Array = server.audit_log()
	var sig := ""
	if not audit.is_empty():
		var last: Dictionary = audit[audit.size() - 1]
		sig = "%d|%s|%s" % [audit.size(), str(last.get("t", "")), str(last.get("tool", ""))]
	if sig == _audit_sig:
		return
	_audit_sig = sig

	for c in _activity_box.get_children():
		c.queue_free()
	_activity_empty.visible = audit.is_empty()
	_activity_count.visible = audit.size() > ACTIVITY_ROWS
	_activity_count.text = "… %d calls this session" % audit.size()

	var mono: Font = get_theme_font("source", "EditorFonts") if has_theme_font("source", "EditorFonts") else null
	var n: int = mini(ACTIVITY_ROWS, audit.size())
	for i in n:
		var e: Dictionary = audit[audit.size() - 1 - i]  # newest first
		var ok := bool(e.get("ok", true))
		var tool_name := str(e.get("tool", "?"))
		var tier: int = MCPEffortScript.tier_of(tool_name)
		# A failure always reads red; otherwise tint by the tool's effort tier.
		var col := _color("error_color", Color(0.9, 0.3, 0.3)) if not ok else _tier_color(tier)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(5 * _es))
		var tier_name := str(MCPEffortScript.LEVELS.get(tier, {}).get("name", "L%d" % tier))
		var tip := "%s — L%d %s\n%s · %dms · %s" % [tool_name, tier, tier_name,
			str(e.get("t", "")), int(e.get("ms", 0)), "ok" if ok else "FAILED"]
		var args_s := str(e.get("args", ""))
		if args_s != "":
			tip += "\n%s" % args_s
		if not ok:
			tip += "\n%s" % str(e.get("error", ""))
		row.tooltip_text = tip

		# ✓/✗ + tool name share the tier colour; the timing rides a quiet right column.
		var mark := Label.new()
		mark.text = "✓" if ok else "✗"
		mark.add_theme_font_size_override("font_size", int(11 * _es))
		mark.add_theme_color_override("font_color", col)
		if mono != null:
			mark.add_theme_font_override("font", mono)
		row.add_child(mark)

		var name_lbl := Label.new()
		name_lbl.text = tool_name
		name_lbl.clip_text = true
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", int(11 * _es))
		name_lbl.add_theme_color_override("font_color", col)
		if mono != null:
			name_lbl.add_theme_font_override("font", mono)
		row.add_child(name_lbl)

		var meta := Label.new()
		meta.text = "%dms" % int(e.get("ms", 0))
		meta.add_theme_font_size_override("font_size", int(11 * _es))
		meta.add_theme_color_override("font_color", _dim())
		if mono != null:
			meta.add_theme_font_override("font", mono)
		row.add_child(meta)

		_activity_box.add_child(row)


# ---------------------------------------------------------------- upgrade (Lite)

func _build_upgrade_button() -> void:
	var btn := Button.new()
	btn.text = "★ Get Full — the AI plays & tests your game"
	btn.custom_minimum_size = Vector2(0, 30 * _es)
	btn.add_theme_color_override("font_color", _color("accent_color", Color(0.4, 0.6, 1.0)))
	btn.tooltip_text = "$15 one-time, lifetime updates. Unlocks L4 Playtest (screenshots, input, asserts, tests, animation) + L5 Ship (export jobs, asset library) + 32 skill packs. Opens the store page."
	btn.pressed.connect(_on_buy_full)
	add_child(btn)


func _on_buy_full() -> void:
	OS.shell_open(UPGRADE_URL)


# ---------------------------------------------------------------- ui helpers

## A subtle rounded card with an uppercase section header, themed from the editor.
func _card(header: String, header_right: Control = null) -> VBoxContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color("dark_color_1", Color(0, 0, 0, 0.2))
	sb.set_corner_radius_all(int(5 * _es))
	sb.set_content_margin_all(10 * _es)
	pc.add_theme_stylebox_override("panel", sb)
	add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(6 * _es))
	pc.add_child(box)
	var h := Label.new()
	h.text = header.to_upper()
	h.add_theme_font_size_override("font_size", int(10 * _es))
	h.add_theme_color_override("font_color", _dim())
	# Optional right-aligned widget riding the header line (e.g. the Clients count).
	if header_right == null:
		box.add_child(h)
	else:
		var hrow := HBoxContainer.new()
		hrow.add_child(h)
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hrow.add_child(sp)
		header_right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hrow.add_child(header_right)
		box.add_child(hrow)
	return box


func _pill_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c.r, c.g, c.b, 0.16)
	sb.set_corner_radius_all(int(9 * _es))
	sb.content_margin_left = 8 * _es
	sb.content_margin_right = 8 * _es
	sb.content_margin_top = 2 * _es
	sb.content_margin_bottom = 2 * _es
	return sb


func _make_pill(text: String, c: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _pill_style(c))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", int(11 * _es))
	l.add_theme_color_override("font_color", c)
	pc.add_child(l)
	return pc


func _color(cname: String, fallback: Color) -> Color:
	return get_theme_color(cname, "Editor") if has_theme_color(cname, "Editor") else fallback


func _dim() -> Color:
	var c := _color("font_color", Color(0.9, 0.9, 0.9))
	c.a = 0.55
	return c


## Muted per-tier tint for an activity row — the tool's effort bucket (the same
## Inspect/Author/Run/Playtest/Ship groups as the slider). Inspect (read-only) stays
## neutral; the rest get a hue blended toward the editor text colour, so it reads as a
## gentle accent rather than a loud highlight, and adapts to light/dark editor themes.
func _tier_color(tier: int) -> Color:
	var base: Color
	match tier:
		2: base = Color(0.36, 0.62, 0.92)  # Author — blue
		3: base = Color(0.38, 0.78, 0.46)  # Run — green
		4: base = Color(0.93, 0.70, 0.36)  # Playtest — amber
		5: base = Color(0.72, 0.52, 0.92)  # Ship — violet
		_: return _dim()                   # Inspect / unmapped — quiet, like a read
	return base.lerp(_color("font_color", Color(0.86, 0.87, 0.9)), 0.3)


func _eicon(iname: String) -> Texture2D:
	return get_theme_icon(iname, "EditorIcons") if has_theme_icon(iname, "EditorIcons") else null


## One client row: the client's name with a ✓ once its config has been written (○ while it
## is only detected). Installed-only, so the list stays short on a typical machine.
func _make_client_row(client_name: String, configured: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(6 * _es))
	row.tooltip_text = "%s — %s" % [client_name, "configured" if configured else "detected, not configured yet"]

	var mark := Label.new()
	mark.text = "✓" if configured else "○"
	mark.add_theme_font_size_override("font_size", int(12 * _es))
	mark.add_theme_color_override("font_color",
		_color("success_color", Color(0.3, 0.8, 0.4)) if configured else _dim())
	mark.custom_minimum_size = Vector2(13 * _es, 0)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(mark)

	var nm := Label.new()
	nm.text = client_name
	nm.add_theme_font_size_override("font_size", int(12 * _es))
	if not configured:
		nm.add_theme_color_override("font_color", _dim())
	row.add_child(nm)
	return row


## Transient action feedback under the cards — never overwritten by the
## 0.5 s status refresh (the old single status label lost "copied ✓" instantly).
func _flash(msg: String, ok := true) -> void:
	_feedback.text = msg
	_feedback.add_theme_color_override("font_color",
		_color("success_color", Color(0.3, 0.8, 0.4)) if ok else _color("error_color", Color(0.9, 0.3, 0.3)))
	_feedback.visible = true
	_feedback_left = 3.5


# ---------------------------------------------------------------- refresh loop

func _process(delta: float) -> void:
	if _feedback_left > 0.0:
		_feedback_left -= delta
		if _feedback_left <= 0.0:
			_feedback.visible = false
	_accum += delta
	_clients_accum += delta
	if _accum >= 0.5:
		_accum = 0.0
		_refresh()


func _refresh() -> void:
	var running: bool = server != null and server.is_running()

	_status_pill_label.text = "Running" if running else "Stopped"
	_status_pill_label.add_theme_color_override("font_color",
		_color("success_color", Color(0.3, 0.8, 0.4)) if running else _dim())
	_status_pill.add_theme_stylebox_override("panel", _pill_on if running else _pill_off)

	_toggle_btn.text = "Stop Server" if running else "Start Server"
	_toggle_btn.icon = _eicon("Stop") if running else _eicon("Play")

	_url_btn.text = "http://127.0.0.1:%d/mcp" % _port()
	_url_btn.modulate.a = 1.0 if running else 0.6

	_game_label.visible = server != null and server.bridge != null and server.bridge.is_game_connected()
	_refresh_client_line(running)

	_refresh_activity()
	if _clients_accum >= 2.0:  # detection reads small files — no need every tick
		_clients_accum = 0.0
		_refresh_clients()

	# Tool stats depend on the registry, which may finish loading after _ready.
	if running != _was_running:
		_was_running = running
		_refresh_effort()


## A compact icon strip of installed clients (✓ badge = configured). Rebuilt only here,
## on the 2 s detection tick — installed clients only, so a clean machine reads tidy.
func _refresh_clients() -> void:
	if _clients_list == null:
		return
	for ch in _clients_list.get_children():
		ch.queue_free()
	var installed := 0
	var configured := 0
	for c in MCPClientConfig.detect():
		if not bool(c.get("installed", false)):
			continue
		installed += 1
		var is_conf := bool(c.get("configured", false))
		if is_conf:
			configured += 1
		_clients_list.add_child(_make_client_row(str(c.get("name", "?")), is_conf))
	_clients_list.visible = installed > 0
	_clients_count.visible = installed > 0
	_clients_count.text = "%d / %d configured" % [configured, installed]
	_clients_empty.visible = installed == 0
	_clients_empty.text = "No MCP clients detected (Claude Code, Cursor, VS Code, Claude Desktop)"


## The live connection line under Server: which client is actually talking and when it
## last called. Authoritative (from initialize), unlike the Clients card's "configured".
func _refresh_client_line(running: bool) -> void:
	if _client_label == null:
		return
	if not running:
		_client_label.visible = false
		return
	var cs: Dictionary = server.client_status() if server != null and server.has_method("client_status") else {}
	var idle: int = int(cs.get("idle_ms", -1))
	_client_label.visible = true
	if idle < 0:
		_client_label.text = "↳ waiting for a client to connect…"
		return
	var who := str(cs.get("name", ""))
	if who.is_empty():
		who = str(cs.get("ua", ""))
	if who.is_empty():
		who = "unknown client"
	var ver := str(cs.get("version", ""))
	_client_label.text = "↳ %s%s · %s" % [who, (" " + ver) if ver != "" else "", _ago(idle)]


## Humanize a milliseconds-since-last-call into a short phrase.
func _ago(ms: int) -> String:
	if ms < 1500:
		return "active now"
	var s := int(ms / 1000.0)
	if s < 60:
		return "last call %ds ago" % s
	var m := int(s / 60.0)
	if m < 60:
		return "last call %dm ago" % m
	return "last call %dh ago" % int(m / 60.0)


# ---------------------------------------------------------------- actions

func _on_toggle_server() -> void:
	if server == null:
		return
	if server.is_running():
		server.stop_server()
		_flash("Server stopped")
	else:
		server.start_server(DEFAULT_PORT)
		_flash("Server running on port %d" % _port())
	_refresh()


func _on_copy_url() -> void:
	DisplayServer.clipboard_set("http://127.0.0.1:%d/mcp" % _port())
	_flash("Endpoint URL copied ✓")


func _on_copy() -> void:
	DisplayServer.clipboard_set(MCPClientConfig.config_json(_port()))
	_flash("Client config copied ✓")


## One button, every detected client: project configs + Claude Desktop's global file.
func _on_connect_clients() -> void:
	var results: Array = MCPClientConfig.ensure_all(_port())
	if results.is_empty():
		_flash("No MCP clients detected on this machine", false)
		return
	var parts: Array = []
	var all_ok := true
	for r in results:
		var ok := bool(r.get("ok", false))
		all_ok = all_ok and ok
		parts.append("%s %s" % [str(r.get("name", "?")), str(r.get("action", "")) if ok else "FAILED"])
	_clients_accum = 999.0  # re-detect on the next tick
	_flash(" · ".join(parts) + (" ✓" if all_ok else ""), all_ok)


# ---------------------------------------------------------------- effort

func _cur_effort() -> int:
	if server != null and server.has_method("get_effort"):
		return server.get_effort()
	return MCPEffortScript.DEFAULT_LEVEL


func _max_effort() -> int:
	if server != null and server.has_method("max_effort"):
		return server.max_effort()
	return MCPEffortScript.MAX_LEVEL


func _is_lite() -> bool:
	return server != null and server.has_method("is_lite") and server.is_lite()


func _on_effort_changed(value: float) -> void:
	var notified := 0
	if server != null and server.has_method("set_effort"):
		notified = server.set_effort(int(value))
	_refresh_effort()
	if notified > 0:
		_flash("Effort set to L%d — applied live (%d client stream%s notified)" % [int(value), notified, "s" if notified > 1 else ""])
	else:
		_flash("Effort set to L%d — clients pick it up on next connect" % int(value))


## Live read-out: tier name + what it unlocks, the real tool count at that tier,
## and a rough token cost of the tools/list payload (~chars/4).
func _refresh_effort() -> void:
	if _tier_label == null:
		return
	var lvl: int = _cur_effort()
	var info: Dictionary = MCPEffortScript.LEVELS.get(lvl, {})
	_tier_label.text = "L%d · %s" % [lvl, str(info.get("name", "?"))]
	var tools := 0
	var est_tokens := 0
	if server != null and server.registry != null:
		var specs: Array = server.registry.list_specs(lvl)
		tools = specs.size()
		est_tokens = int(JSON.stringify(specs).length() / 4.0)
	_tier_stats.text = "%d tools · ~%s tok" % [tools, _fmt_k(est_tokens)]
	var txt := str(info.get("adds", ""))
	if _is_lite():
		txt += "\n🔒 Full edition: the AI plays, sees & tests your game itself — L4 Playtest · L5 Ship"
	_effort_desc.text = txt


func _fmt_k(n: int) -> String:
	return ("%.1fk" % (n / 1000.0)) if n >= 1000 else str(n)


func _plugin_version() -> String:
	var cf := ConfigFile.new()
	if cf.load("res://addons/beckett/plugin.cfg") == OK:
		return str(cf.get_value("plugin", "version", ""))
	return ""


func _port() -> int:
	if server != null and server.is_running():
		return server.http.port
	return DEFAULT_PORT
