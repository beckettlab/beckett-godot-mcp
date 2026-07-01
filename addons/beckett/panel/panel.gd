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
const MCPReflectScript := preload("res://addons/beckett/core/reflection.gd")  # node-path resolver, shared with the tools

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
var _effort_bar: Control          # custom-drawn effort track (replaces the native HSlider)
var _effort_name: Label           # big tier name
var _effort_collapsed_name: Label # tier name on the header, shown only while the card is folded
var _effort_tag: Label            # short tier tagline
var _tier_stats: Label
var _effort_tick_row: HBoxContainer  # tier-name labels under the bar
var _effort_tools_head: Label        # collapsible "Active tools" header
var _effort_tools_count: Label       # "on/total" exposed count in the header
var _effort_tools_reset: Button      # re-enable every switched-off tool
var _effort_tools_arrow: TextureRect
var _effort_tools_body: VBoxContainer
var _effort_tools_panel: PanelContainer  # sunken dark bg behind the folded list
var _effort_tools_scroll: ScrollContainer  # caps the list height; scrolls when long
var _eff_name_tween: Tween       # fade+slide the tier name on level change
var _eff_name_anim_gen := 0      # supersedes in-flight name animations when the level changes again
# Effort-bar state. The Max-tier pixel shimmer is a Full-only module (effort_shimmer.gd),
# loaded lazily and absent in Lite — so its algorithm never ships in the free source.
const SHIMMER_MODULE := "res://addons/beckett/panel/effort_shimmer.gd"
var _eff_cur := 1
var _shimmer = null            # EffortShimmer instance (Full only); null in Lite (module trimmed)
var _activity_box: VBoxContainer
var _activity_scroll: ScrollContainer  # bounds the feed's height; scrolls when it overflows
var _activity_empty: Label
var _activity_count: Button  # footer toggle: "View all N calls" / "Show recent"
var _feedback: PanelContainer  # toast: animated action-feedback chip under the cards
var _fb_margin: MarginContainer  # animated top inset = the slide-in offset
var _fb_icon: Label
var _fb_label: Label
var _fb_total := 0.0  # total visible duration of the current flash (drives the fade curve)
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

	# Toast chip: an accent-tinted card with a ✓/✗ icon, animated by _animate_feedback.
	_feedback = PanelContainer.new()
	_feedback.visible = false
	_feedback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fb_margin = MarginContainer.new()  # only margin_top animates (the slide offset)
	_fb_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feedback.add_child(_fb_margin)
	var fb_row := HBoxContainer.new()
	fb_row.add_theme_constant_override("separation", int(7 * _es))
	fb_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fb_margin.add_child(fb_row)
	_fb_icon = Label.new()
	_fb_icon.add_theme_font_size_override("font_size", int(13 * _es))
	_fb_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fb_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fb_row.add_child(_fb_icon)
	_fb_label = Label.new()
	_fb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fb_label.add_theme_font_size_override("font_size", int(12 * _es))
	_fb_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fb_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fb_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fb_row.add_child(_fb_label)
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
	# The current tier name rides the header, shown only when the card is folded (the body
	# carries the big name when open) — a glanceable readout of the effort while collapsed.
	_effort_collapsed_name = Label.new()
	_effort_collapsed_name.add_theme_font_size_override("font_size", int(12 * _es))
	var box := _collapsible_card("AI Effort", _effort_collapsed_name, true)
	box.visibility_changed.connect(func() -> void:
		_effort_collapsed_name.visible = not box.visible)
	_effort_collapsed_name.visible = not box.visible
	var levels := _max_effort()

	# Header: big tier name + tagline (left), live tool/token cost (right).
	var head := HBoxContainer.new()
	box.add_child(head)
	var ncol := VBoxContainer.new()
	ncol.add_theme_constant_override("separation", int(1 * _es))
	ncol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(ncol)
	_effort_name = Label.new()
	_effort_name.add_theme_font_size_override("font_size", int(18 * _es))
	if has_theme_font("bold", "EditorFonts"):
		_effort_name.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	ncol.add_child(_effort_name)
	_effort_tag = Label.new()
	_effort_tag.add_theme_font_size_override("font_size", int(11 * _es))
	_effort_tag.add_theme_color_override("font_color", _dim())
	ncol.add_child(_effort_tag)
	_tier_stats = Label.new()
	_tier_stats.add_theme_font_size_override("font_size", int(11 * _es))
	_tier_stats.add_theme_color_override("font_color", _dim())
	_tier_stats.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_tier_stats)

	# Faster <-> Smarter rail labels.
	var ends := HBoxContainer.new()
	box.add_child(ends)
	var lf := Label.new()
	lf.text = "Faster"
	lf.add_theme_font_size_override("font_size", int(10 * _es))
	lf.add_theme_color_override("font_color", _dim())
	lf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(lf)
	var ls := Label.new()
	ls.text = "Smarter"
	ls.add_theme_font_size_override("font_size", int(10 * _es))
	ls.add_theme_color_override("font_color", _dim())
	ls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ends.add_child(ls)

	# Custom bar: a neutral track + flush thumb for lower tiers; the violet pixel shimmer
	# fires only at the absolute top (Full's Max). Drawn + driven by panel methods so the
	# dock stays a single script — no scene file, no inner class.
	_effort_bar = Control.new()
	_effort_bar.custom_minimum_size = Vector2(0, 18 * _es)
	_effort_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effort_bar.focus_mode = Control.FOCUS_ALL
	_effort_bar.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_effort_bar.tooltip_text = "Caps the tools the MCP client sees. Lower = cheaper model context, fewer capabilities. Applies live to clients that support tools/list_changed; others pick it up on reconnect."
	_effort_bar.draw.connect(_draw_effort_bar)
	_effort_bar.gui_input.connect(_on_effort_bar_input)
	_effort_bar.resized.connect(_on_effort_bar_resized)
	box.add_child(_effort_bar)
	# Full-only Max-tier shimmer; absent in Lite (module trimmed at pack time) -> stays null.
	if ResourceLoader.exists(SHIMMER_MODULE):
		_shimmer = load(SHIMMER_MODULE).new()

	# Tier names under the bar: L1 left-aligned, L<max> right-aligned; active one brightens.
	_effort_tick_row = HBoxContainer.new()
	box.add_child(_effort_tick_row)
	for lvl in range(1, levels + 1):
		var t := Label.new()
		t.text = str(MCPEffortScript.LEVELS.get(lvl, {}).get("name", "L%d" % lvl))
		t.add_theme_font_size_override("font_size", int(10 * _es))
		t.add_theme_color_override("font_color", _dim())
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if lvl == 1:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		elif lvl == levels:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		else:
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_effort_tick_row.add_child(t)

	# Collapsible: the tools active at this tier (folded by default, like the Clients card).
	var thead := HBoxContainer.new()
	thead.mouse_filter = Control.MOUSE_FILTER_STOP
	thead.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	thead.add_theme_constant_override("separation", int(5 * _es))
	_effort_tools_head = Label.new()
	_effort_tools_head.text = "Active tools"
	_effort_tools_head.add_theme_font_size_override("font_size", int(11 * _es))
	_effort_tools_head.add_theme_color_override("font_color", _dim())
	_effort_tools_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effort_tools_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thead.add_child(_effort_tools_head)
	# "on / total" exposed count — shows at a glance when some tools are switched off.
	_effort_tools_count = Label.new()
	_effort_tools_count.add_theme_font_size_override("font_size", int(10 * _es))
	_effort_tools_count.add_theme_color_override("font_color", _dim())
	_effort_tools_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thead.add_child(_effort_tools_count)
	# Reset re-enables every tool; only shown while something is off. STOP filter so its click
	# fires the button instead of bubbling up and toggling the fold.
	_effort_tools_reset = Button.new()
	_effort_tools_reset.flat = true
	_effort_tools_reset.text = "Reset"
	_effort_tools_reset.focus_mode = Control.FOCUS_NONE
	_effort_tools_reset.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_effort_tools_reset.add_theme_font_size_override("font_size", int(10 * _es))
	_effort_tools_reset.tooltip_text = "Switch every tool back on"
	_effort_tools_reset.visible = false
	_effort_tools_reset.pressed.connect(_on_tools_reset)
	thead.add_child(_effort_tools_reset)
	_effort_tools_arrow = TextureRect.new()
	_effort_tools_arrow.texture = _disc_icon(false)
	_effort_tools_arrow.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_effort_tools_arrow.custom_minimum_size = Vector2(12 * _es, 0)
	_effort_tools_arrow.modulate = _dim()
	_effort_tools_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thead.add_child(_effort_tools_arrow)
	box.add_child(thead)
	# The folded list sits in a sunken, darker panel so it reads as grouped under the header;
	# inside, a height-capped scroll keeps a long tier (Max lists every tool) from shoving the
	# rest of the dock off-screen.
	_effort_tools_panel = PanelContainer.new()
	_effort_tools_panel.add_theme_stylebox_override("panel", _code_style())
	_effort_tools_panel.visible = false
	_effort_tools_scroll = ScrollContainer.new()
	_effort_tools_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_effort_tools_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effort_tools_body = VBoxContainer.new()
	_effort_tools_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effort_tools_body.mouse_filter = Control.MOUSE_FILTER_PASS  # let the wheel bubble to the scroll
	_effort_tools_body.add_theme_constant_override("separation", int(2 * _es))
	_effort_tools_body.minimum_size_changed.connect(_fit_effort_tools_scroll)
	_effort_tools_scroll.add_child(_effort_tools_body)
	_effort_tools_panel.add_child(_effort_tools_scroll)
	box.add_child(_effort_tools_panel)
	thead.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_effort_tools_panel.visible = not _effort_tools_panel.visible
			_effort_tools_arrow.texture = _disc_icon(_effort_tools_panel.visible))


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

		# Right cluster: ms · reveal · fold-arrow, kept compact together at the row's end. The
		# reveal's external icon stays distinct from the chevron fold arrow beside it.
		var right := HBoxContainer.new()
		right.add_theme_constant_override("separation", int(3 * _es))
		right.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var meta := Label.new()
		meta.text = "%dms" % int(e.get("ms", 0))
		meta.add_theme_font_size_override("font_size", int(10 * _es))
		meta.add_theme_color_override("font_color", _dim())
		meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if mono != null:
			meta.add_theme_font_override("font", mono)
		right.add_child(meta)

		if e.has("focus"):
			var focus: Dictionary = e["focus"]
			var loc := Button.new()
			loc.flat = true
			loc.icon = _locate_icon()
			loc.add_theme_constant_override("icon_max_width", int(13 * _es))
			loc.focus_mode = Control.FOCUS_NONE
			loc.modulate.a = 0.8
			loc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			loc.tooltip_text = _focus_tip(focus)
			loc.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			loc.add_theme_stylebox_override("normal", StyleBoxEmpty.new())  # no padding → compact
			loc.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
			loc.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
			if loc.icon == null:
				loc.text = "↗"
				loc.add_theme_font_size_override("font_size", int(11 * _es))
			loc.pressed.connect(func() -> void: _focus(focus))
			right.add_child(loc)

		# Editor tree arrows are guaranteed in the theme (a glyph like ▸ renders blank in
		# the mono font); right = folded, down = open.
		var arrow := TextureRect.new()
		arrow.texture = _disc_icon(expanded)
		arrow.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		arrow.custom_minimum_size = Vector2(12 * _es, 0)
		arrow.modulate = _dim()
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		right.add_child(arrow)
		head.add_child(right)
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
		4: return Color(0.93, 0.70, 0.36)  # See — amber
		5: return Color(0.72, 0.52, 0.92)  # Drive — violet
		6: return Color(0.95, 0.45, 0.68)  # Max — magenta
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


## A short tooltip for the row's "reveal" jump button, by focus kind.
func _focus_tip(f: Dictionary) -> String:
	match str(f.get("kind", "")):
		"node": return "Reveal the node — selects it and opens its 2D/3D view"
		"script": return "Open in the Script editor"
		"resource": return "Open in the Inspector"
		"scene": return "Open this scene"
		"file": return "Reveal in the FileSystem dock"
		"screen": return "Switch to the %s screen" % str(f.get("name", ""))
	return "Reveal in editor"


## Jump the editor to a row's subject — select a node, open a script/resource/scene, or
## switch the main screen. Resolved live, so a deleted/renamed target fails with a flash.
func _focus(f: Dictionary) -> void:
	match str(f.get("kind", "")):
		"node":
			await _focus_node(f)
		"script":
			var p := str(f.get("path", ""))
			if ResourceLoader.exists(p):
				var s: Variant = load(p)
				if s is Script:
					EditorInterface.edit_script(s, int(f.get("line", 0)), 0, true)
					EditorInterface.set_main_screen_editor("Script")
					return
			_flash("Couldn't open script: %s" % p, false)
		"resource":
			var p := str(f.get("path", ""))
			if ResourceLoader.exists(p):
				var r: Variant = load(p)
				if r is Resource:
					EditorInterface.edit_resource(r)
					return
			_flash("Couldn't open resource: %s" % p, false)
		"scene":
			var p := str(f.get("path", ""))
			if ResourceLoader.exists(p):
				EditorInterface.open_scene_from_path(p)
			else:
				_flash("Scene not found: %s" % p, false)
		"file":
			EditorInterface.select_file(str(f.get("path", "")))
		"screen":
			var nm := str(f.get("name", "2D"))
			if nm == "Game" and not EditorInterface.is_playing_scene():
				_flash("Game isn't running — press Play to see it", false)
				return
			EditorInterface.set_main_screen_editor(nm)


## Reveal a node: reopen its scene first if it lived in another one, then resolve the
## path (shared resolver) and select it in the Scene dock + Inspector.
func _focus_node(f: Dictionary) -> void:
	var want := str(f.get("scene", ""))
	var root := EditorInterface.get_edited_scene_root()
	var cur := root.scene_file_path if root != null else ""
	if want != "" and want != cur and ResourceLoader.exists(want):
		EditorInterface.open_scene_from_path(want)
		await get_tree().process_frame  # let the freshly opened scene become the edited one
		await get_tree().process_frame
	var obj: Object = MCPReflectScript.resolve(str(f.get("target", "")))
	if obj is Node:
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(obj)
		EditorInterface.edit_node(obj)
		# Selecting alone keeps the current screen (e.g. Script); show the node's viewport.
		EditorInterface.set_main_screen_editor("3D" if obj is Node3D else "2D")
	elif obj is Resource:
		# A node-path into a sub-resource (e.g. "Sprite2D/texture") resolves to a Resource.
		EditorInterface.edit_resource(obj)
	else:
		_flash("Node not found — renamed or deleted?", false)


# ---------------------------------------------------------------- upgrade (Lite)

func _build_upgrade_button() -> void:
	var btn := Button.new()
	btn.text = "★ Get Full — the AI playtests your game"
	btn.custom_minimum_size = Vector2(0, 30 * _es)
	btn.add_theme_color_override("font_color", _color("accent_color", Color(0.4, 0.6, 1.0)))
	btn.tooltip_text = "$15 one-time, lifetime updates. Lite already SEES the running game (screenshots, live tree, runtime reads). Full unlocks L5 Drive (input, UI/3D clicks, drag/scroll, asserts, tests, animation) + L6 Max (export jobs, asset library) + the skill packs. Opens the store page."
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


## Icon for a row's "reveal in editor" button — an external/open-there glyph (it sits in
## the row header, after the tool name). First editor icon that exists wins.
func _locate_icon() -> Texture2D:
	for n in ["ExternalLink", "Edit", "Tools"]:
		if has_theme_icon(n, "EditorIcons"):
			return get_theme_icon(n, "EditorIcons")
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


## Transient action feedback under the cards — an accent-tinted toast that fades/slides in,
## holds, then fades out (see _animate_feedback). Outlives the 0.5 s status refresh.
func _flash(msg: String, ok := true) -> void:
	var accent := _color("success_color", Color(0.3, 0.8, 0.4)) if ok else _color("error_color", Color(0.9, 0.3, 0.3))
	_fb_label.text = msg
	_fb_label.add_theme_color_override("font_color", _color("font_color", Color(0.9, 0.9, 0.9)))
	_fb_icon.text = "✓" if ok else "✗"
	_fb_icon.add_theme_color_override("font_color", accent)
	_feedback.add_theme_stylebox_override("panel", _toast_style(accent))
	_feedback.visible = true
	_fb_total = 3.6 if ok else 4.4  # errors linger a touch longer
	_feedback_left = _fb_total
	_animate_feedback()  # seed the opening frame so it starts hidden, not popped


## Drive the toast's fade + slide from the time left: ramp in (0.16 s), hold, ramp out
## (0.5 s), smoothstep-eased. Per-frame from _process — no Tween (dependable in-editor).
func _animate_feedback() -> void:
	var in_dur := 0.16
	var out_dur := 0.5
	var elapsed := _fb_total - _feedback_left
	var a := 1.0
	if elapsed < in_dur:
		a = elapsed / in_dur
	elif _feedback_left < out_dur:
		a = _feedback_left / out_dur
	a = clampf(a, 0.0, 1.0)
	a = a * a * (3.0 - 2.0 * a)  # smoothstep ease
	_feedback.modulate.a = a
	_fb_margin.add_theme_constant_override("margin_top", int(round(7.0 * _es * (1.0 - a))))


## The toast background: an accent-tinted fill with a solid left stripe and rounded
## corners — the same visual family as the activity row cards.
func _toast_style(accent: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent.r, accent.g, accent.b, 0.16)
	sb.set_corner_radius_all(int(5 * _es))
	sb.border_width_left = int(3 * _es)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	sb.content_margin_left = 9 * _es
	sb.content_margin_right = 9 * _es
	sb.content_margin_top = 6 * _es
	sb.content_margin_bottom = 6 * _es
	return sb


# ---------------------------------------------------------------- refresh loop

func _process(delta: float) -> void:
	if _shimmer != null and _effort_bar != null and _effort_bar.is_visible_in_tree():
		if _shimmer.tick(delta, _eff_cur == MCPEffortScript.MAX_LEVEL):
			_effort_bar.queue_redraw()
	if _feedback_left > 0.0:
		_feedback_left -= delta
		_animate_feedback()
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


func _level_name(lvl: int) -> String:
	return "L%d %s" % [lvl, str(MCPEffortScript.LEVELS.get(lvl, {}).get("name", ""))]


## Commit a new effort level: tell the server, refresh the read-out, and — when stepping up
## into the top tier — restart the pixel spread so it plays from the thumb each time.
func _set_effort_level(lvl: int) -> void:
	lvl = clampi(lvl, 1, _max_effort())
	if lvl == _eff_cur:
		return
	var going_up := lvl > _eff_cur
	_eff_cur = lvl
	if _shimmer != null:
		_shimmer.set_top(lvl == MCPEffortScript.MAX_LEVEL)
	var notified := 0
	if server != null and server.has_method("set_effort"):
		notified = server.set_effort(lvl)
	_refresh_effort()
	_animate_effort_name(going_up)
	if _effort_bar != null:
		_effort_bar.queue_redraw()
	if notified > 0:
		_flash("Effort set to %s — applied live (%d client stream%s notified)" % [_level_name(lvl), notified, "s" if notified > 1 else ""])
	else:
		_flash("Effort set to %s — clients pick it up on next connect" % _level_name(lvl))


## Fade + slide the tier name on a level change: it rises into place when stepping up and
## drops in when stepping down. Deferred one frame so the VBox settles the new text at its
## resting spot first; we then animate from an offset the container won't re-sort mid-tween.
## A generation counter cancels a stale animation if the level moves again before it finishes.
func _animate_effort_name(going_up: bool) -> void:
	if _effort_name == null:
		return
	_eff_name_anim_gen += 1
	var gen := _eff_name_anim_gen
	if _eff_name_tween != null and _eff_name_tween.is_valid():
		_eff_name_tween.kill()
	await get_tree().process_frame
	if _effort_name == null or gen != _eff_name_anim_gen:
		return
	var base_y := _effort_name.position.y
	var dy := 9.0 * _es
	_effort_name.position.y = base_y + (dy if going_up else -dy)
	_effort_name.modulate.a = 0.0
	# Slower, longer travel; fade finishes before the slide so the name is visible while it's
	# still moving — that's what makes the up/down direction read.
	_eff_name_tween = create_tween().set_parallel(true)
	_eff_name_tween.tween_property(_effort_name, "position:y", base_y, 0.34).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_eff_name_tween.tween_property(_effort_name, "modulate:a", 1.0, 0.22)


func _on_effort_bar_resized() -> void:
	if _shimmer != null:
		_shimmer.invalidate()  # rebuild the pixel grid at the new width
	if _effort_bar != null:
		_effort_bar.queue_redraw()


## Click/drag anywhere to snap to the nearest tier; arrows step. Grabs focus so the keys land.
func _on_effort_bar_input(ev: InputEvent) -> void:
	if _effort_bar == null:
		return
	var levels := _max_effort()
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_effort_bar.grab_focus()
		_set_effort_level(_eff_level_at(ev.position.x, levels))
	elif ev is InputEventMouseMotion and (ev.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_set_effort_level(_eff_level_at(ev.position.x, levels))
	elif ev is InputEventKey and ev.pressed:
		if ev.keycode == KEY_RIGHT or ev.keycode == KEY_UP:
			_set_effort_level(mini(levels, _eff_cur + 1))
		elif ev.keycode == KEY_LEFT or ev.keycode == KEY_DOWN:
			_set_effort_level(maxi(1, _eff_cur - 1))


## The tier whose stop sits nearest the given x (stops are flush to both edges).
func _eff_level_at(x: float, levels: int) -> int:
	var w := _effort_bar.size.x
	if w <= 1.0 or levels <= 1:
		return 1
	var tw := 22.0 * _es
	var best := 1
	var bd := INF
	for i in levels:
		var cx := lerpf(tw * 0.5, w - tw * 0.5, float(i) / float(levels - 1))
		var d := absf(cx - x)
		if d < bd:
			bd = d
			best = i + 1
	return best


# ---------------------------------------------------------------- effort bar drawing

## A flat rounded fill — the building block for the track, neutral fill, and thumb.
func _eff_box(col: Color, radius: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(int(radius))
	return sb


## Draw the whole bar: sunken track, the neutral fill + ticks (full-width at the top tier),
## the violet pixel field layered over them (easing in/out around the top tier), then the
## flush thumb. Wired to the bar's `draw` signal.
func _draw_effort_bar() -> void:
	var bar := _effort_bar
	if bar == null:
		return
	var w := bar.size.x
	var h := bar.size.y
	if w <= 1.0:
		return
	var levels := _max_effort()
	var tw := 22.0 * _es
	var track_h := 10.0 * _es
	var track_y := (h - track_h) * 0.5
	var on_top := _eff_cur == MCPEffortScript.MAX_LEVEL

	var centers := PackedFloat32Array()
	for i in levels:
		var f := 0.0 if levels <= 1 else float(i) / float(levels - 1)
		centers.append(lerpf(tw * 0.5, w - tw * 0.5, f))
	var cur_x: float = centers[clampi(_eff_cur - 1, 0, levels - 1)]
	var fc := _color("font_color", Color(0.92, 0.92, 0.95))

	bar.draw_style_box(_eff_box(Color(0, 0, 0, 0.28), track_h * 0.5), Rect2(0, track_y, w, track_h))

	# Gray progress fill + per-tier dots: drawn at every level, max included (where the fill
	# runs the full width). The violet pixels layer over this; they no longer replace it.
	var fill_w := w if on_top else maxf(cur_x, track_h)
	bar.draw_style_box(_eff_box(Color(fc.r, fc.g, fc.b, 0.30), track_h * 0.5), Rect2(0, track_y, fill_w, track_h))
	for i in levels:
		if i == _eff_cur - 1:
			continue
		bar.draw_circle(Vector2(centers[i], h * 0.5), 1.5 * _es, Color(fc.r, fc.g, fc.b, 0.45))

	# Top-tier shimmer over the fill (Full only; _shimmer is null in Lite). Eases in on entry,
	# wipes toward the live thumb (cur_x) on exit — see effort_shimmer.gd.
	if _shimmer != null and _shimmer.needs_draw():
		_shimmer.draw(bar, w, track_y, track_h, cur_x, _es, on_top)

	var thumb := Rect2(cur_x - tw * 0.5, 0.0, tw, h)
	bar.draw_style_box(_eff_box(fc, 5.0 * _es), thumb)


## Live read-out: the tier name + tagline (violet at the absolute top), its real tool count
## and rough tools/list token cost, the active tick label, and the folded active-tools list.
func _refresh_effort() -> void:
	if _effort_name == null:
		return
	var lvl: int = _cur_effort()
	_eff_cur = clampi(lvl, 1, _max_effort())
	var info: Dictionary = MCPEffortScript.LEVELS.get(_eff_cur, {})
	var is_top := _eff_cur == MCPEffortScript.MAX_LEVEL
	var violet := Color(0.66, 0.52, 1.0)
	var accent := _color("accent_color", Color(0.4, 0.6, 1.0))

	_effort_name.text = str(info.get("name", "?"))
	_effort_name.add_theme_color_override("font_color", violet if is_top else accent)
	if _effort_collapsed_name != null:
		_effort_collapsed_name.text = str(info.get("name", "?"))
		_effort_collapsed_name.add_theme_color_override("font_color", violet if is_top else accent)
	_effort_tag.text = str(info.get("tag", ""))

	_update_tier_stats()

	if _effort_tick_row != null:
		var kids := _effort_tick_row.get_children()
		for i in kids.size():
			var lab := kids[i] as Label
			if lab == null:
				continue
			if (i + 1) == _eff_cur:
				lab.add_theme_color_override("font_color", violet if is_top else _color("font_color", Color(0.9, 0.9, 0.9)))
			else:
				lab.add_theme_color_override("font_color", _dim())

	_refresh_effort_tools(_eff_cur)
	if _effort_bar != null:
		_effort_bar.queue_redraw()


## Fill the folded list with the tool names ACTIVE at this tier — every tool from level 1
## up through `lvl` (cumulative), matching the "N tools" count on the tier-stats line.
## Each row is an EffortToolRow so hovering shows a rich tooltip: the tool name, its
## effort tier (colour-coded), and the full, wrapped description.
func _refresh_effort_tools(lvl: int) -> void:
	if _effort_tools_body == null:
		return
	for c in _effort_tools_body.get_children():
		c.queue_free()
	var mono: Font = get_theme_font("source", "EditorFonts") if has_theme_font("source", "EditorFonts") else null
	for tier in range(1, lvl + 1):
		var tools_at: Array = MCPEffortScript.adds_at(tier)
		# Lite trims some modules whose tools are still named in _DELTA (e.g. list_skills lives in
		# the Full-only skill_tools) — drop any the registry doesn't actually have, so the list and
		# its count match the real tool surface the AI sees.
		if server != null and server.registry != null:
			tools_at = tools_at.filter(func(t): return server.registry.has(str(t)))
		if tools_at.is_empty():
			continue
		var tier_name := str(MCPEffortScript.LEVELS.get(tier, {}).get("name", "L%d" % tier))
		var tcol := _row_accent(true, tier)

		# Effort-zone divider: the tier name (in its accent) + a rule, with a little air above.
		if _effort_tools_body.get_child_count() > 0:
			var gap := Control.new()
			gap.custom_minimum_size.y = 6 * _es
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_effort_tools_body.add_child(gap)
		_effort_tools_body.add_child(_tier_header(tier_name, tcol))

		for tn in tools_at:
			var tname := str(tn)
			var desc := _tool_desc(tname)
			var on: bool = server == null or server.is_tool_enabled(tname)

			var rowbox := HBoxContainer.new()
			rowbox.mouse_filter = Control.MOUSE_FILTER_PASS  # let the wheel bubble to the scroll
			rowbox.add_theme_constant_override("separation", int(6 * _es))

			# Per-tool on/off via a custom monochrome switch (fits the dock; the editor CheckBox
			# clashed). An off tool drops out of tools/list and is blocked at the gate.
			var sw := ToolSwitch.new()
			sw.on = on
			sw.es = _es
			sw.custom_minimum_size = Vector2(14 * _es, 14 * _es)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sw.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			sw.tooltip_text = "Show / hide this tool from the MCP client"
			rowbox.add_child(sw)

			var row := EffortToolRow.new()
			row.text = tname
			row.tool_name = tname
			row.tier_head = "%s · L%d" % [tier_name, tier]
			row.tier_color = tcol
			row.desc = desc
			row.es = _es
			row.mono = mono
			# tooltip_text must be non-empty for the hover to fire; it's also the plain-text
			# fallback if _make_custom_tooltip ever isn't used.
			row.tooltip_text = ("%s\n%s" % [row.tier_head, desc]) if desc != "" else row.tier_head
			row.mouse_filter = Control.MOUSE_FILTER_PASS  # PASS: hover shows the tooltip, wheel still scrolls
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_theme_font_size_override("font_size", int(10 * _es))
			if mono != null:
				row.add_theme_font_override("font", mono)
			row.set_enabled_look(on)
			rowbox.add_child(row)

			# Mutation-class badge on the right: Read / Write / Delete, colour-coded.
			var kind := _tool_kind(tname)
			if not kind.is_empty():
				rowbox.add_child(_type_badge(kind))

			sw.switched.connect(_on_tool_toggled.bind(tname, row))
			_effort_tools_body.add_child(rowbox)
	_update_tool_counts()
	call_deferred("_fit_effort_tools_scroll")


## The tool's full purpose line, straight from the registry (empty when the server isn't up yet).
func _tool_desc(tool_name: String) -> String:
	if server != null and server.registry != null:
		return str(server.registry.get_tool(tool_name).get("description", "")).strip_edges()
	return ""


## A divider that opens an effort zone in the tools list: the tier name (uppercase, in its
## accent colour) plus a rule across the rest of the row.
func _tier_header(tier_name: String, tcol: Color) -> Control:
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", int(6 * _es))
	var lab := Label.new()
	lab.text = tier_name
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.add_theme_font_size_override("font_size", int(9 * _es))
	lab.add_theme_color_override("font_color", tcol)
	hb.add_child(lab)
	var rule := HSeparator.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(rule)
	return hb


## The tool's mutation class for its row badge, straight from the registry annotation flags
## (the same readonly/destructive flags that drive the MCP hints + the destructive-confirm
## gate): Read-only, Destructive, or plain Write. Empty when the server isn't up.
func _tool_kind(tool_name: String) -> Dictionary:
	if server == null or server.registry == null:
		return {}
	var t: Dictionary = server.registry.get_tool(tool_name)
	if t.is_empty():
		return {}
	if bool(t.get("destructive", false)):
		return {"label": "Destructive", "color": Color(0.90, 0.42, 0.42)}  # red
	if bool(t.get("readonly", false)):
		return {"label": "Read-only", "color": Color(0.46, 0.77, 0.53)}    # green
	return {"label": "Write", "color": Color(0.93, 0.73, 0.40)}            # amber


## A small colour-coded tag for a tool's mutation class (sits at the row's right edge). Its own
## tight stylebox — the shared _pill_style is too padded/round and looks bulky around tiny text.
func _type_badge(kind: Dictionary) -> Control:
	var c: Color = kind["color"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c.r, c.g, c.b, 0.14)
	sb.set_corner_radius_all(int(3 * _es))
	sb.content_margin_left = 5 * _es
	sb.content_margin_right = 5 * _es
	sb.content_margin_top = 1 * _es
	sb.content_margin_bottom = 1 * _es
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = str(kind["label"])
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", int(8 * _es))
	l.add_theme_color_override("font_color", c)
	pc.add_child(l)
	return pc


## One tool switched on/off from its row checkbox. The server persists it and pushes
## tools/list_changed; here we just restyle that row and refresh the header/stats counts —
## no list rebuild, so the scroll position is kept.
func _on_tool_toggled(pressed: bool, tool_name: String, row: EffortToolRow) -> void:
	if server != null:
		server.set_tool_enabled(tool_name, pressed)
	row.set_enabled_look(pressed)
	_update_tool_counts()
	_update_tier_stats()


## The header "Reset": switch every tool back on, then rebuild the rows to clear their look.
func _on_tools_reset() -> void:
	if server != null:
		server.enable_all_tools()
	_refresh_effort_tools(_eff_cur)
	_update_tier_stats()


## Header "on / total" count + Reset visibility, recomputed from the live switch state. Shows
## the count only when something is off (an all-on list stays uncluttered).
func _update_tool_counts() -> void:
	if _effort_tools_count == null:
		return
	var total := 0
	var on := 0
	for tier in range(1, _eff_cur + 1):
		for tn in MCPEffortScript.adds_at(tier):
			if server != null and server.registry != null and not server.registry.has(str(tn)):
				continue  # not registered in this edition (e.g. Lite-trimmed) — don't count it
			total += 1
			if server == null or server.is_tool_enabled(str(tn)):
				on += 1
	_effort_tools_count.text = ("%d / %d on" % [on, total]) if on < total else ""
	if _effort_tools_reset != null:
		_effort_tools_reset.visible = on < total


## The tier-stats line: how many tools the agent actually sees now (effort tier minus the off
## switches) and a rough tools/list token cost. Shared by _refresh_effort and a toggle.
func _update_tier_stats() -> void:
	if _tier_stats == null:
		return
	var tools := 0
	var est_tokens := 0
	if server != null and server.registry != null:
		var specs: Array = server.effective_specs(_eff_cur)
		tools = specs.size()
		est_tokens = int(JSON.stringify(specs).length() / 4.0)
	_tier_stats.text = "%d tools · ~%s tok" % [tools, _fmt_k(est_tokens)]


## Cap the active-tools list height; it grows to fit a short tier and scrolls past the cap
## (the Max tier lists every tool, which would otherwise run off the dock).
func _fit_effort_tools_scroll() -> void:
	if _effort_tools_scroll == null or _effort_tools_body == null:
		return
	var h := _effort_tools_body.get_combined_minimum_size().y
	_effort_tools_scroll.custom_minimum_size.y = minf(h, 200.0 * _es)


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


## One row in the "Active tools" list. It supplies its OWN tooltip because the editor's default
## tooltip neither wraps a long description nor lets us colour the effort tier — Godot calls
## _make_custom_tooltip on hover (tooltip_text is set, so it fires) and shows the returned control
## inside the editor's themed tooltip panel. Fields are populated by _refresh_effort_tools.
## A compact, monochrome on/off switch for a tool row. Custom-drawn so it stays black-and-white
## and theme-neutral (the editor CheckBox clashed) and can be sized down. Emits `switched(on)`.
class ToolSwitch extends Control:
	signal switched(on: bool)
	var on := true
	var es := 1.0

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			on = not on
			queue_redraw()
			switched.emit(on)
			accept_event()

	func _draw() -> void:
		var s := minf(size.x, size.y)
		var r := Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s))
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(int(3 * es))
		if on:
			box.bg_color = Color(0.92, 0.92, 0.94, 0.90)  # filled white = exposed
			draw_style_box(box, r)
			var p := r.position
			var check := PackedVector2Array([
				p + Vector2(s * 0.26, s * 0.52),
				p + Vector2(s * 0.43, s * 0.70),
				p + Vector2(s * 0.74, s * 0.30),
			])
			draw_polyline(check, Color(0.12, 0.12, 0.14), maxf(1.6 * es, 1.0), true)
		else:
			box.bg_color = Color(1, 1, 1, 0.0)               # hollow outline = hidden
			box.border_color = Color(1, 1, 1, 0.32)
			box.set_border_width_all(int(maxf(1.0 * es, 1.0)))
			draw_style_box(box, r)


class EffortToolRow extends Label:
	var tool_name := ""
	var tier_head := ""          # e.g. "Inspect · L1"
	var tier_color := Color.WHITE
	var desc := ""
	var es := 1.0
	var mono: Font
	var enabled := true

	## Dim the name when the tool is switched off, so the list reads on/off at a glance.
	func set_enabled_look(on: bool) -> void:
		enabled = on
		var base := Color(0.84, 0.85, 0.90)
		add_theme_color_override("font_color", base if on else Color(base.r, base.g, base.b, 0.38))

	func _make_custom_tooltip(_for_text: String) -> Object:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", int(5 * es))

		# Header line: the tool name (bright, mono) with its effort tier (colour-coded) to the right.
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", int(14 * es))
		col.add_child(header)
		var name_lbl := Label.new()
		name_lbl.text = tool_name
		name_lbl.add_theme_font_size_override("font_size", int(12 * es))
		name_lbl.add_theme_color_override("font_color", Color(0.96, 0.96, 0.98))
		if mono != null:
			name_lbl.add_theme_font_override("font", mono)
		header.add_child(name_lbl)
		var tier_lbl := Label.new()
		tier_lbl.text = tier_head
		tier_lbl.add_theme_font_size_override("font_size", int(10 * es))
		tier_lbl.add_theme_color_override("font_color", tier_color)
		tier_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tier_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tier_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		header.add_child(tier_lbl)

		# The full description, wrapped at a comfortable tooltip width — no truncation.
		if desc != "":
			var body := Label.new()
			body.text = desc
			body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body.custom_minimum_size.x = 340.0 * es
			body.add_theme_font_size_override("font_size", int(11 * es))
			body.add_theme_color_override("font_color", Color(0.80, 0.82, 0.88))
			col.add_child(body)
		return col
