## Flowchart overlay — visualizes the chapter-level scenario graph (issue #97).
##
## MVP layout: vertical list of chapters with status indicators + choice edge
## labels. Click a chapter node to jump via StellaRuntime.jump_from_flowchart.
## Visual graph layout with positioned nodes and drawn edges is deferred to v2.
extends PanelContainer


var _content: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	# Full-screen anchors
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var vbox = VBoxContainer.new()
	margin.add_child(vbox)

	# Header
	var header = HBoxContainer.new()
	vbox.add_child(header)
	var title_label = Label.new()
	title_label.text = "Flowchart"
	title_label.add_theme_font_size_override("font_size", 24)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_label)
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)

	# Scroll area
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(_content)

	_populate()


func _populate() -> void:
	var graph: ScenarioGraph = StellaRuntime.scenario_graph
	if graph == null:
		var lbl = Label.new()
		lbl.text = "(No scenario loaded)"
		_content.add_child(lbl)
		return

	var current_chapter_id = StellaRuntime.flowchart_state.get_current_chapter_id()

	for chapter in graph.chapters:
		_add_chapter_row(chapter, current_chapter_id, graph)


func _add_chapter_row(chapter: ChapterData, current_id: String, graph: ScenarioGraph) -> void:
	var is_current = chapter.id == current_id
	var is_visited = StellaRuntime.flowchart_visited.is_chapter_visited(chapter.id)
	var is_deadlocked = graph.is_deadlocked(chapter.id)

	# Chapter button
	var btn = Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

	# Status indicator + chapter name
	var status_icon: String
	if is_current:
		status_icon = ">> "
	elif is_visited:
		status_icon = "[v] "
	else:
		status_icon = "[ ] "

	var display_name = chapter.display_name if chapter.display_name != "" else chapter.id
	btn.text = "%s%s" % [status_icon, display_name]

	# Visual styling based on state
	if is_current:
		btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))  # gold
	elif is_visited:
		btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))  # bright
	else:
		btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))  # dimmed

	if is_deadlocked:
		btn.tooltip_text = "This chapter has no exits (deadlock)"

	var chapter_id = chapter.id
	btn.pressed.connect(func(): _on_chapter_clicked(chapter_id))
	_content.add_child(btn)

	# Outgoing edges (choice options get their own sub-labels)
	var outgoing = graph.get_outgoing_edges(chapter.id)
	for edge in outgoing:
		if edge.kind == ChapterEdge.KIND_TERMINAL:
			var lbl = _make_edge_label("  -- END --", edge)
			_content.add_child(lbl)
		elif edge.kind == ChapterEdge.KIND_CHOICE:
			var target_name = _chapter_display_name(edge.target_chapter_id, graph)
			var text = '  -> "%s" -> %s' % [edge.label, target_name]
			var lbl = _make_edge_label(text, edge)
			_content.add_child(lbl)
		elif edge.kind == ChapterEdge.KIND_JUMP:
			var target_name = _chapter_display_name(edge.target_chapter_id, graph)
			var lbl = _make_edge_label("  -> %s" % target_name, edge)
			_content.add_child(lbl)
		elif edge.kind == ChapterEdge.KIND_SEQUENTIAL:
			# Sequential edges are implicit — the next chapter button shows
			# the flow. Only show if it's not the "obvious" next chapter.
			pass
		elif edge.kind == ChapterEdge.KIND_CALL:
			var target_name = _chapter_display_name(edge.target_chapter_id, graph)
			var lbl = _make_edge_label("  [call] %s" % target_name, edge)
			_content.add_child(lbl)


func _make_edge_label(text: String, edge: ChapterEdge) -> Label:
	var lbl = Label.new()
	lbl.text = text
	if StellaRuntime.flowchart_visited.is_edge_visited(edge.get_edge_id()):
		lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))  # light blue
	else:
		lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))  # dim
	lbl.add_theme_font_size_override("font_size", 14)
	return lbl


func _chapter_display_name(chapter_id: String, graph: ScenarioGraph) -> String:
	var ch = graph.get_chapter(chapter_id)
	if ch == null:
		return chapter_id
	return ch.display_name if ch.display_name != "" else ch.id


func _on_chapter_clicked(chapter_id: String) -> void:
	var ok = StellaRuntime.jump_from_flowchart(chapter_id)
	if ok:
		# jump_from_flowchart already closes overlays and runs the engine.
		pass
	else:
		push_warning("FlowchartScreen: jump to chapter '%s' failed" % chapter_id)


func _close() -> void:
	StellaRuntime.close_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	if not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE or event.keycode == KEY_F9:
		_close()
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_close()
			get_viewport().set_input_as_handled()
