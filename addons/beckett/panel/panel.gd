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

var _status_dot: Panel
var _status_text: Label
var _toggle_btn: Button
var _url_btn: Button
var _game_label: Label
var _client_label: Label
var _client_dot: Panel
var _client_row: HBoxContainer
var _clients_list: VBoxContainer
var _clients_count: Label
var _clients_empty: Label
var _effort_slider: HSlider
var _tier_label: Label
var _tier_stats: Label
var _effort_desc: Label
var _activity_box: VBoxContainer
var _activity_scroll: ScrollContainer  # bounds the feed's height; scrolls when it overflows
var _activity_empty: Label
var _activity_count: Button  # footer toggle: "View all N calls" / "Show recent"
var _feedback: Label
var _accum := 0.0
var _clients_accum := 999.0  # refresh client detection immediately on first tick
var _audit_sig := ""
var _expanded := {}  # audit-row key -> bool; keeps an opened row open across rebuilds
var _show_all := false  # activity feed: newest ACTIVITY_ROWS (false) vs the whole ring (true)
var _feedback_left := 0.0
var _was_running := false
var _wait_phase := 0  # cycles the "waiting…" ellipsis so it reads as actively pending


func _ready() -> void:
	name = "Beckett"
	if Engine.is_editor_hint():
		_es = EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(8 * _es))

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


# ------------------------------------------------------------- masthead + server

func _build_server_card() -> void:
	var mono: Font = get_theme_font("source", "EditorFonts") if has_theme_font("source", "EditorFonts") else null

	# The top card is also the masthead, so build it directly — no "SERVER" section label.
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color("dark_color_1", Color(0, 0, 0, 0.2))
	sb.set_corner_radius_all(int(5 * _es))
	sb.set_content_margin_all(10 * _es)
	pc.add_theme_stylebox_override("panel", sb)
	add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(7 * _es))
	pc.add_child(box)

	# Masthead: Beckett · MCP for Godot · v… with the edition pill riding the right.
	var brand := HBoxContainer.new()
	brand.add_theme_constant_override("separation", int(6 * _es))
	# HBox has no baseline align, so drop the smaller tagline by the ascent difference —
	# then "Beckett" and the tagline sit on exactly the same text baseline.
	var title_font: Font = get_theme_font("bold", "EditorFonts") if has_theme_font("bold", "EditorFonts") else get_theme_font("font", "Label")
	var tag_font: Font = get_theme_font("font", "Label")
	var baseline_drop := 0
	if title_font != null and tag_font != null:
		baseline_drop = maxi(0, int(title_font.get_ascent(int(16 * _es)) - tag_font.get_ascent(int(11 * _es))))

	var title := Label.new()
	title.text = "Beckett"
	title.add_theme_font_size_override("font_size", int(16 * _es))
	title.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if has_theme_font("bold", "EditorFonts"):
		title.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	brand.add_child(title)

	var tagwrap := MarginContainer.new()  # margin_top pushes the tagline onto the baseline
	tagwrap.add_theme_constant_override("margin_top", baseline_drop)
	tagwrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var tagline := Label.new()
	var ver := _plugin_version()
	tagline.text = "MCP for Godot" + (" · v" + ver if ver != "" else "")
	tagline.add_theme_font_size_override("font_size", int(11 * _es))
	tagline.add_theme_color_override("font_color", _dim())
	tagwrap.add_child(tagline)
	brand.add_child(tagwrap)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.add_child(sp)
	var pill := _make_pill("LITE", _color("warning_color", Color(0.9, 0.7, 0.2))) if _is_lite() else _make_pill("FULL", _color("accent_color", Color(0.4, 0.6, 1.0)))
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brand.add_child(pill)
	box.add_child(brand)

	box.add_child(HSeparator.new())

	# Status line: a colour-coded dot + state (· port when running).
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", int(5 * _es))
	_status_dot = _make_dot()
	status_row.add_child(_status_dot)
	_status_text = Label.new()
	_status_text.add_theme_font_size_override("font_size", int(13 * _es))
	_status_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_text)
	box.add_child(status_row)

	# Primary control.
	_toggle_btn = Button.new()
	_toggle_btn.custom_minimum_size = Vector2(0, 30 * _es)
	_toggle_btn.pressed.connect(_on_toggle_server)
	box.add_child(_toggle_btn)

	# Endpoint as a code block (matches the activity args look); the whole strip copies,
	# the trailing icon is the affordance.
	_url_btn = Button.new()
	_url_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_url_btn.clip_text = true
	_url_btn.icon = _eicon("ActionCopy")
	_url_btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_url_btn.focus_mode = Control.FOCUS_NONE
	_url_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_url_btn.add_theme_font_size_override("font_size", int(11 * _es))
	_url_btn.add_theme_color_override("font_color", _color("font_color", Color(0.9, 0.9, 0.9)))
	_url_btn.add_theme_color_override("icon_normal_color", _dim())
	_url_btn.add_theme_stylebox_override("normal", _code_style())
	_url_btn.add_theme_stylebox_override("hover", _code_style(true))
	_url_btn.add_theme_stylebox_override("pressed", _code_style(true))
	if mono != null:
		_url_btn.add_theme_font_override("font", mono)
	_url_btn.tooltip_text = "Click to copy the MCP endpoint URL"
	_url_btn.pressed.connect(_on_copy_url)
	box.add_child(_url_btn)

	# Live connection: a dot + who's talking (green) or a pending "waiting…" (amber). The
	# authoritative state from the initialize handshake — distinct from "config written".
	_client_row = HBoxContainer.new()
	_client_row.add_theme_constant_override("separation", int(5 * _es))
	_client_row.tooltip_text = "The connected MCP client, from its initialize handshake.\nThe model is chosen inside that client — MCP does not report it to the server."
	_client_dot = _make_dot()
	_client_row.add_child(_client_dot)
	_client_label = Label.new()
	_client_label.add_theme_font_size_override("font_size", int(11 * _es))
	_client_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_client_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_client_row.add_child(_client_label)
	_client_row.visible = false
	box.add_child(_client_row)

	# Shown only while a played game has the runtime channel open (noise-free idle).
	_game_label = Label.new()
	_game_label.text = "● game runtime connected"
	_game_label.add_theme_font_size_override("font_size", int(11 * _es))
	_game_label.add_theme_color_override("font_color", _color("success_color", Color(0.3, 0.8, 0.4)))
	_game_label.tooltip_text = "Live link to the running game — playtest tools use this"
	_game_label.visible = false
	box.add_child(_game_label)


# ---------------------------------------------------------------- clients card

func _build_clients_card() -> void:
	# Which clients exist here, and which are already wired up. Configs for installed
	# clients are written automatically when the plugin starts — usually this already
	# reads all-✓ and the user never clicks anything. The count ("3 / 5 configured")
	# rides the card header line, right-aligned.
	_clients_count = Label.new()
	_clients_count.add_theme_font_size_override("font_size", int(10 * _es))
	_clients_count.add_theme_color_override("font_color", _dim())
	# Collapsible + folded by default: this is usually all-✓ and rarely touched, so it
	# stays out of the way. The "n / m configured" count rides the header for a glance.
	var box := _collapsible_card("Clients", _clients_count, false)

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
	# A copy-the-whole-log button rides the header line, right-aligned.
	var copy_all := Button.new()
	copy_all.flat = true
	copy_all.icon = _eicon("ActionCopy")
	copy_all.add_theme_constant_override("icon_max_width", int(13 * _es))
	copy_all.focus_mode = Control.FOCUS_NONE
	copy_all.modulate.a = 0.7
	copy_all.tooltip_text = "Copy the whole activity log"
	copy_all.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	copy_all.pressed.connect(_on_copy_all)
	var box := _card("Activity", copy_all)

	_activity_empty = Label.new()
	_activity_empty.text = "No calls yet — ask your AI assistant something."
	_activity_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_activity_empty.add_theme_font_size_override("font_size", int(11 * _es))
	_activity_empty.add_theme_color_override("font_color", _dim())
	box.add_child(_activity_empty)

	# The feed lives in a height-bounded scroll, so a long log scrolls instead of
	# pushing the rest of the dock off-screen.
	_activity_scroll = ScrollContainer.new()
	_activity_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_activity_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_activity_box = VBoxContainer.new()
	_activity_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_activity_box.add_theme_constant_override("separation", int(4 * _es))
	_activity_box.minimum_size_changed.connect(_fit_activity_scroll)
	_activity_scroll.add_child(_activity_box)
	box.add_child(_activity_scroll)

	# Footer: toggles the recent feed ⇄ the whole ring; also carries the call count.
	_activity_count = Button.new()
	_activity_count.flat = true
	_activity_count.focus_mode = Control.FOCUS_NONE
	_activity_count.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_activity_count.add_theme_font_size_override("font_size", int(10 * _es))
	_activity_count.add_theme_color_override("font_color", _dim())
	_activity_count.add_theme_color_override("font_hover_color", _color("font_color", Color(0.9, 0.9, 0.9)))
	_activity_count.tooltip_text = "Show every call this session, or just the recent few. The header ⧉ copies the whole log."
	_activity_count.visible = false
	_activity_count.pressed.connect(_toggle_show_all)
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
	var kept := audit.size()
	var total: int = server.audit_total() if server.has_method("audit_total") else kept
	_activity_empty.visible = audit.is_empty()
	_activity_count.visible = total > ACTIVITY_ROWS
	if _show_all:
		_activity_count.text = "Show recent"
	elif total > kept:
		_activity_count.text = "View all · last %d of %d" % [kept, total]  # ring rotated
	else:
		_activity_count.text = "View all %d calls" % total

	var mono: Font = get_theme_font("source", "EditorFonts") if has_theme_font("source", "EditorFonts") else null
	var bright: Color = _color("font_color", Color(0.9, 0.9, 0.9))
	var n: int = audit.size() if _show_all else mini(ACTIVITY_ROWS, audit.size())
	var live := {}  # rebuilt expand state — implicitly drops keys that scrolled off
	for i in n:
		var e: Dictionary = audit[audit.size() - 1 - i]  # newest first
		var ok := bool(e.get("ok", true))
		var tool_name := str(e.get("tool", "?"))
		var tier: int = MCPEffortScript.tier_of(tool_name)
		var tier_name := str(MCPEffortScript.LEVELS.get(tier, {}).get("name", "L%d" % tier))
		# One accent tints the whole card — red on failure, else the tool's effort tier.
		var accent := _row_accent(ok, tier)
		var tip := "%s — L%d %s\n%s · %dms · %s" % [tool_name, tier, tier_name,
			str(e.get("t", "")), int(e.get("ms", 0)), "ok" if ok else "FAILED"]

		# A stable-ish key (time+tool+args) keeps an opened row open as newer calls arrive.
		var key := "%s|%s|%s" % [str(e.get("t", "")), tool_name, str(e.get("args", ""))]
		var expanded: bool = _expanded.get(key, false)
		live[key] = expanded

		# The whole row is a tinted, rounded card; clicking anywhere on it folds the detail.
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _row_card_style(accent, false))
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		card.tooltip_text = tip

		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", int(3 * _es))
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(body)

		# ── header: ✓ tool …………… 12ms ▸ — the disclosure arrow trails on the right.
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", int(5 * _es))
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var mark := Label.new()
		mark.text = "✓" if ok else "✗"
		mark.add_theme_font_size_override("font_size", int(11 * _es))
		mark.add_theme_color_override("font_color", accent)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if mono != null:
			mark.add_theme_font_override("font", mono)
		head.add_child(mark)

		var name_lbl := Label.new()
		name_lbl.text = tool_name
		name_lbl.clip_text = true
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", int(11 * _es))
		name_lbl.add_theme_color_override("font_color", bright)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if mono != null:
			name_lbl.add_theme_font_override("font", mono)
		head.add_child(name_lbl)

		var meta := Label.new()
		meta.text = "%dms" % int(e.get("ms", 0))
		meta.add_theme_font_size_override("font_size", int(10 * _es))
		meta.add_theme_color_override("font_color", _dim())
		meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if mono != null:
			meta.add_theme_font_override("font", mono)
		head.add_child(meta)

		# Editor tree arrows are guaranteed in the theme (a glyph like ▸ renders blank in
		# the mono font); right = folded, down = open.
		var arrow := TextureRect.new()
		arrow.texture = _disc_icon(expanded)
		arrow.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		arrow.custom_minimum_size = Vector2(12 * _es, 0)
		arrow.modulate = _dim()
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(arrow)
		body.add_child(head)

		# ── detail (folds away): a divider, then when it ran · its tier, the args it
		# carried, and the error if it failed — with a one-click copy of the whole call.
		var args_s := str(e.get("args", ""))
		var detail := VBoxContainer.new()
		detail.add_theme_constant_override("separation", int(2 * _es))
		detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		detail.visible = expanded

		var sep := HSeparator.new()
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		detail.add_child(sep)

		# meta line (when · tier) shares its row with a trailing copy button.
		var meta_row := HBoxContainer.new()
		meta_row.add_theme_constant_override("separation", int(4 * _es))
		meta_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var meta_line := _detail_line("%s · L%d %s" % [str(e.get("t", "")), tier, tier_name], _dim(), mono)
		meta_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		meta_row.add_child(meta_line)

		var summary := _call_summary(tool_name, tier, tier_name, e, ok, args_s)
		var copy_btn := Button.new()
		copy_btn.flat = true
		copy_btn.icon = _eicon("ActionCopy")
		copy_btn.add_theme_constant_override("icon_max_width", int(13 * _es))
		copy_btn.focus_mode = Control.FOCUS_NONE
		copy_btn.modulate.a = 0.7
		copy_btn.tooltip_text = "Copy this call's details"
		copy_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		copy_btn.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(summary)
			_flash("Call details copied ✓"))
		meta_row.add_child(copy_btn)
		detail.add_child(meta_row)

		if args_s != "" and args_s != "{}":
			detail.add_child(_code_block(args_s, mono))
		var result_s := str(e.get("result", ""))
		if result_s != "":
			detail.add_child(_detail_line(result_s, bright, mono))
		if not ok:
			detail.add_child(_detail_line("⚠ %s" % str(e.get("error", "")), accent, mono))
		body.add_child(detail)

		_activity_box.add_child(card)

		# Brighten on hover (affordance) and toggle the fold on click — both on the card.
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", _row_card_style(accent, true)))
		card.mouse_exited.connect(func() -> void:
			card.add_theme_stylebox_override("panel", _row_card_style(accent, false)))
		card.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				var now := not detail.visible
				detail.visible = now
				arrow.texture = _disc_icon(now)
				_expanded[key] = now)

	_expanded = live
	call_deferred("_fit_activity_scroll")


## Size the feed's scroll to its content, capped — short logs sit at natural height,
## long ones (or many expanded rows) stop growing and scroll instead.
func _fit_activity_scroll() -> void:
	if _activity_scroll == null or _activity_box == null:
		return
	# max() guards a timing quirk: the measured size can lag a frame behind a rebuild, so
	# fall back to a per-row estimate. Capped only when showing all (then it scrolls).
	var rows := _activity_box.get_child_count()
	var h := maxf(_activity_box.get_combined_minimum_size().y, rows * 30.0 * _es)
	_activity_scroll.custom_minimum_size.y = minf(h, 300.0 * _es) if _show_all else h


## One wrapped, monospaced line inside an expanded row's detail block.
func _detail_line(text: String, col: Color, mono: Font) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", int(10 * _es))
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if mono != null:
		l.add_theme_font_override("font", mono)
	return l


## The call's args as a code block — monospace on a sunken, rounded panel so the literal
## payload reads as code, set apart from the prose lines around it.
func _code_block(text: String, mono: Font) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_theme_stylebox_override("panel", _code_style())
	pc.add_child(_detail_line(text, _color("font_color", Color(0.9, 0.9, 0.9)), mono))
	return pc


## The sunken, rounded background shared by the args and endpoint code blocks. `hot`
## brightens it for a button's hover/pressed states.
func _code_style(hot := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.34 if hot else 0.25)
	sb.set_corner_radius_all(int(3 * _es))
	sb.content_margin_left = 6 * _es
	sb.content_margin_right = 6 * _es
	sb.content_margin_top = 3 * _es
	sb.content_margin_bottom = 3 * _es
	return sb


## A copy-paste-friendly one-block summary of a single audit entry — the same fields the
## expanded row shows, flattened for pasting into a bug report or message.
func _call_summary(tool_name: String, tier: int, tier_name: String, e: Dictionary, ok: bool, args_s: String) -> String:
	var s := "%s · L%d %s · %s · %dms · %s" % [tool_name, tier, tier_name,
		str(e.get("t", "")), int(e.get("ms", 0)), "ok" if ok else "FAILED"]
	if args_s != "" and args_s != "{}":
		s += "\nargs: %s" % args_s
	var res := str(e.get("result", ""))
	if res != "":
		s += "\nresult: %s" % res
	if not ok:
		s += "\nerror: %s" % str(e.get("error", ""))
	return s


## The single colour that themes one activity card — red on failure, otherwise the
## tool's effort tier (Inspect stays a neutral grey so reads don't shout).
func _row_accent(ok: bool, tier: int) -> Color:
	if not ok:
		return _color("error_color", Color(0.9, 0.3, 0.3))
	match tier:
		2: return Color(0.36, 0.62, 0.92)  # Author — blue
		3: return Color(0.38, 0.78, 0.46)  # Run — green
		4: return Color(0.93, 0.70, 0.36)  # Playtest — amber
		5: return Color(0.72, 0.52, 0.92)  # Ship — violet
	return _color("font_color", Color(0.86, 0.87, 0.9))  # Inspect / unmapped — neutral


## A tinted card background for one activity row: a faint fill plus a solid left stripe
## in the row's accent. `hot` brightens both for hover feedback.
func _row_card_style(accent: Color, hot: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent.r, accent.g, accent.b, 0.18 if hot else 0.10)
	sb.set_corner_radius_all(int(4 * _es))
	sb.border_width_left = int(3 * _es)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.9 if hot else 0.6)
	sb.content_margin_left = 8 * _es
	sb.content_margin_right = 7 * _es
	sb.content_margin_top = 4 * _es
	sb.content_margin_bottom = 4 * _es
	return sb


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


## Like _card, but the header is a click target that folds a body away (trailing arrow,
## same as the activity rows). Returns the body VBox to add content to; `open` is the
## initial state. The header (title + optional right widget + arrow) is always visible.
func _collapsible_card(header: String, header_right: Control, open: bool) -> VBoxContainer:
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

	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", int(5 * _es))
	hrow.mouse_filter = Control.MOUSE_FILTER_STOP
	hrow.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var h := Label.new()
	h.text = header.to_upper()
	h.add_theme_font_size_override("font_size", int(10 * _es))
	h.add_theme_color_override("font_color", _dim())
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hrow.add_child(h)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hrow.add_child(sp)
	if header_right != null:
		header_right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		header_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hrow.add_child(header_right)
	var arrow := TextureRect.new()
	arrow.texture = _disc_icon(open)
	arrow.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	arrow.custom_minimum_size = Vector2(12 * _es, 0)
	arrow.modulate = _dim()
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hrow.add_child(arrow)
	box.add_child(hrow)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", int(6 * _es))
	body.visible = open
	box.add_child(body)

	hrow.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			body.visible = not body.visible
			arrow.texture = _disc_icon(body.visible))
	return body


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


## A small round status dot — an exact-size circle (vs a ● glyph, whose side bearing
## left an uneven gap to the label). _paint_dot sets its colour and filled/hollow state.
func _make_dot() -> Panel:
	var p := Panel.new()
	var d := int(7 * _es)
	p.custom_minimum_size = Vector2(d, d)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _paint_dot(p: Panel, col: Color, filled: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(4 * _es))  # ≥ half the 7px box → fully round
	if filled:
		sb.bg_color = col
	else:
		sb.bg_color = Color(col.r, col.g, col.b, 0.0)  # hollow ring = pending
		sb.border_color = col
		sb.set_border_width_all(maxi(1, int(1.5 * _es)))
	p.add_theme_stylebox_override("panel", sb)


func _color(cname: String, fallback: Color) -> Color:
	return get_theme_color(cname, "Editor") if has_theme_color(cname, "Editor") else fallback


func _dim() -> Color:
	var c := _color("font_color", Color(0.9, 0.9, 0.9))
	c.a = 0.55
	return c


func _eicon(iname: String) -> Texture2D:
	return get_theme_icon(iname, "EditorIcons") if has_theme_icon(iname, "EditorIcons") else null


## Disclosure triangle for an activity row. The Gui* icon names vary across editor
## versions, so fall back to the Tree control's own expand arrows, which always exist.
func _disc_icon(open: bool) -> Texture2D:
	var ei := "GuiTreeArrowDown" if open else "GuiTreeArrowRight"
	if has_theme_icon(ei, "EditorIcons"):
		return get_theme_icon(ei, "EditorIcons")
	var tn := "arrow" if open else "arrow_collapsed"
	if has_theme_icon(tn, "Tree"):
		return get_theme_icon(tn, "Tree")
	return null


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

	var sc := _color("success_color", Color(0.3, 0.8, 0.4)) if running else _dim()
	_paint_dot(_status_dot, sc, true)
	_status_text.text = "Running · port %d" % _port() if running else "Stopped"
	_status_text.add_theme_color_override("font_color",
		_color("font_color", Color(0.9, 0.9, 0.9)) if running else _dim())

	_toggle_btn.text = "Stop Server" if running else "Start Server"
	_toggle_btn.icon = _eicon("Stop") if running else _eicon("Play")

	_url_btn.text = "http://127.0.0.1:%d/mcp" % _port()
	_url_btn.modulate.a = 1.0 if running else 0.5

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
	if _client_row == null:
		return
	if not running:
		_client_row.visible = false
		return
	_client_row.visible = true
	var cs: Dictionary = server.client_status() if server != null and server.has_method("client_status") else {}
	var idle: int = int(cs.get("idle_ms", -1))
	if idle < 0:
		# Waiting: a hollow amber dot + a gently cycling ellipsis so it reads as pending.
		_wait_phase = (_wait_phase + 1) % 3
		_paint_dot(_client_dot, _color("warning_color", Color(0.9, 0.7, 0.2)), false)  # hollow = pending
		_client_label.add_theme_color_override("font_color", _dim())
		_client_label.text = "waiting for a client to connect" + ".".repeat(_wait_phase + 1)
		return
	# Connected: a filled green dot + who's talking and when it last called.
	var who := str(cs.get("name", ""))
	if who.is_empty():
		who = str(cs.get("ua", ""))
	if who.is_empty():
		who = "unknown client"
	var ver := str(cs.get("version", ""))
	_paint_dot(_client_dot, _color("success_color", Color(0.3, 0.8, 0.4)), true)
	_client_label.add_theme_color_override("font_color", _color("font_color", Color(0.9, 0.9, 0.9)))
	_client_label.text = "%s%s · %s" % [who, (" " + ver) if ver != "" else "", _ago(idle)]


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


## Toggle the activity feed between the recent few and the whole ring (forces a rebuild).
func _toggle_show_all() -> void:
	_show_all = not _show_all
	_audit_sig = ""
	_refresh_activity()


## Copy every call in the audit ring (newest first) as one paste-friendly block.
func _on_copy_all() -> void:
	var txt := _all_calls_text()
	if txt == "":
		_flash("No calls to copy", false)
		return
	DisplayServer.clipboard_set(txt)
	var n: int = server.audit_log().size() if server != null and server.has_method("audit_log") else 0
	_flash("Copied %d call%s ✓" % [n, "s" if n != 1 else ""])


func _all_calls_text() -> String:
	if server == null or not server.has_method("audit_log"):
		return ""
	var audit: Array = server.audit_log()
	var lines := PackedStringArray()
	for i in range(audit.size() - 1, -1, -1):  # newest first, same order as the feed
		var e: Dictionary = audit[i]
		var tool_name := str(e.get("tool", "?"))
		var tier: int = MCPEffortScript.tier_of(tool_name)
		var tier_name := str(MCPEffortScript.LEVELS.get(tier, {}).get("name", "L%d" % tier))
		lines.append(_call_summary(tool_name, tier, tier_name, e, bool(e.get("ok", true)), str(e.get("args", ""))))
	return "\n\n".join(lines)


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
