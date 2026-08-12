## Visual marker placed after the final rendered dialogue line.
##
## The marker lives outside RichTextLabel's tag stack so it never changes the
## dialogue text, character count, wrapping input, or backlog content.
class_name DialogueAdvanceIndicator
extends Control

const ANIMATION_NONE := "none"
const ANIMATION_PULSE := "pulse"
const ANIMATION_BOB := "bob"

const _ANIMATION_HALF_CYCLE := 0.45
const _PULSE_ALPHA_FACTOR := 0.45
const _BOB_DISTANCE := 4.0


## A no-op text effect used as an engine-supported geometry probe. Godot feeds
## RichTextEffect the final glyph transform from RichTextLabel._draw_line(),
## after paragraph alignment, list/indent margins, BiDi shaping and scrollbar
## reservation have all been applied. Wrapping the label's manual tag stack in
## this effect therefore observes the exact renderer-owned endpoint without
## duplicating Godot's BBCode parser or text shaping rules.
class EndpointProbeEffect:
	extends RichTextEffect

	var _frame := -1
	var _samples: Array[Dictionary] = []
	var _isolated_range := Vector2i(-1, -1)
	var _isolated_is_rtl := false
	var _isolated_is_embedded := false
	var _isolation_shift_x := 0.0
	var _is_isolating := false


	func reset() -> void:
		_frame = -1
		_samples.clear()
		_isolated_range = Vector2i(-1, -1)
		_isolated_is_rtl = false
		_isolated_is_embedded = false
		_isolation_shift_x = 0.0
		_is_isolating = false


	func _process_custom_fx(char_fx: CharFXTransform) -> bool:
		# Outline/shadow passes repeat every glyph at the same layout position.
		# Keep only the main text pass and only the most recent process frame so a
		# scroll or resize cannot reuse coordinates from an earlier draw.
		if char_fx.outline:
			if _is_isolating:
				char_fx.visible = false
			return true
		var authored_visible := char_fx.visible
		if _is_isolating:
			var is_target := char_fx.range == _isolated_range
			char_fx.visible = authored_visible and is_target
			if char_fx.visible and not _isolated_is_embedded \
				and not is_zero_approx(_isolation_shift_x):
				var shifted_transform := char_fx.transform
				shifted_transform.origin.x += _isolation_shift_x
				char_fx.transform = shifted_transform
		var process_frame := int(Engine.get_process_frames())
		if process_frame != _frame:
			_frame = process_frame
			_samples.clear()
		var flags := int(char_fx.glyph_flags)
		_samples.append({
			"range": char_fx.range,
			"origin": char_fx.transform.origin,
			"flags": flags,
			"glyph_index": char_fx.glyph_index,
			# Embedded objects are drawn by RichTextLabel before text effects are
			# evaluated, so CharFX visibility cannot suppress their actual pixels.
			"visible": (
				authored_visible
				or bool(flags & TextServer.GRAPHEME_IS_EMBEDDED_OBJECT)
			),
		})
		return true


	## Selects the final real grapheme in a shaped line. A second transparent
	## draw can then expose just that grapheme through visible_content_rect.
	## Godot 4.6 does not report the virtual trailing-caret glyphs added in 4.7,
	## so this renderer-owned rectangle is the compatibility fallback.
	func isolate_endpoint_for_line(
		line_range: Vector2i,
		visible_rect: Rect2i,
		default_rtl: bool,
	) -> bool:
		var target := _target_for_line(line_range)
		if target.is_empty():
			return false
		_isolated_range = target["range"]
		var flags := int(target["flags"])
		_isolated_is_embedded = bool(
			flags & TextServer.GRAPHEME_IS_EMBEDDED_OBJECT)
		_isolated_is_rtl = bool(flags & TextServer.GRAPHEME_IS_RTL)
		if _isolated_is_embedded and not _isolated_is_rtl:
			_isolated_is_rtl = _embedded_target_is_rtl(target, default_rtl)
		# RichTextLabel merges embedded-object rectangles before custom text
		# effects, so hiding non-target CharFX entries cannot remove an earlier
		# inline image from visible_content_rect. Move a text target beyond the
		# full content span for one transparent draw, read its uncontaminated outer
		# edge, then subtract this shift from the published endpoint.
		if not _isolated_is_embedded and visible_rect.size.x > 0:
			var isolation_distance := float(visible_rect.size.x) + 2.0
			_isolation_shift_x = (
				-isolation_distance if _isolated_is_rtl else isolation_distance)
		_is_isolating = true
		return true


	## Returns the logical trailing caret for the final drawable grapheme in a
	## shaped line, or null when that line was not part of the latest draw.
	func endpoint_for_line(line_range: Vector2i) -> Variant:
		var target := _target_for_line(line_range)
		if target.is_empty():
			return null

		var target_range: Vector2i = target["range"]
		var target_origin: Vector2 = target["origin"]
		var target_is_rtl := (
			_isolated_is_rtl
			if _is_isolating and target_range == _isolated_range
			else bool(int(target["flags"]) & TextServer.GRAPHEME_IS_RTL)
		)
		var endpoint_x := INF if target_is_rtl else -INF
		var found_boundary := false
		for sample_value in _samples:
			var sample: Dictionary = sample_value
			if not (int(sample["flags"]) & TextServer.GRAPHEME_IS_VIRTUAL):
				continue
			if (sample["range"] as Vector2i) != target_range:
				continue
			var origin: Vector2 = sample["origin"]
			if not is_equal_approx(origin.y, target_origin.y):
				continue
			found_boundary = true
			endpoint_x = (
				minf(endpoint_x, origin.x)
				if target_is_rtl
				else maxf(endpoint_x, origin.x)
			)
		if not found_boundary:
			return null
		return Vector2(endpoint_x - _isolation_shift_x, target_origin.y)


	## Returns the isolated grapheme's renderer-owned edge. Rect2i is pixel
	## aligned, so 4.7 keeps using its sub-pixel virtual caret when available;
	## this path exists for 4.6, where no such callback is emitted.
	func fallback_endpoint_for_line(
		line_range: Vector2i,
		visible_rect: Rect2i,
	) -> Variant:
		if not _is_isolating:
			return null
		var target := _target_for_line(line_range)
		if target.is_empty() or target["range"] != _isolated_range:
			return null
		var target_origin: Vector2 = target["origin"]
		if visible_rect.size.x <= 0:
			return Vector2(
				target_origin.x - _isolation_shift_x, target_origin.y)
		var target_is_rtl := _isolated_is_rtl
		return Vector2(
			float(visible_rect.position.x if target_is_rtl else visible_rect.end.x)
				- _isolation_shift_x,
			target_origin.y,
		)


	## Embedded glyph callbacks do not expose their resolved BiDi direction.
	## Prefer the renderer's trailing boundary when Godot reports one (4.7), then
	## infer the resolved direction from the nearest preceding logical grapheme
	## (4.6). The label direction is only needed for an object-only paragraph.
	func _embedded_target_is_rtl(target: Dictionary, default_rtl: bool) -> bool:
		var target_range: Vector2i = target["range"]
		var target_origin: Vector2 = target["origin"]
		var following_boundary: Dictionary = {}
		var previous: Dictionary = {}
		for sample_value in _samples:
			var sample: Dictionary = sample_value
			if not bool(sample.get("visible", true)):
				continue
			var glyph_range: Vector2i = sample["range"]
			var origin: Vector2 = sample["origin"]
			if not is_equal_approx(origin.y, target_origin.y):
				continue
			var flags := int(sample["flags"])
			if glyph_range.x >= target_range.y \
				and int(sample["glyph_index"]) == 0 \
				and flags & TextServer.GRAPHEME_IS_SPACE:
				if following_boundary.is_empty() \
					or glyph_range.x < (following_boundary["range"] as Vector2i).x:
					following_boundary = sample
				continue
			if flags & TextServer.GRAPHEME_IS_VIRTUAL \
				or flags & TextServer.GRAPHEME_IS_EMBEDDED_OBJECT:
				continue
			if glyph_range.y > target_range.x:
				continue
			if int(sample["glyph_index"]) == 0 \
				and flags & TextServer.GRAPHEME_IS_SPACE:
				continue
			if previous.is_empty() \
				or glyph_range.y > (previous["range"] as Vector2i).y \
				or (glyph_range.y == (previous["range"] as Vector2i).y \
					and glyph_range.x > (previous["range"] as Vector2i).x):
				previous = sample
		if not following_boundary.is_empty():
			return bool(
				int(following_boundary["flags"]) & TextServer.GRAPHEME_IS_RTL)
		if not previous.is_empty():
			var previous_origin: Vector2 = previous["origin"]
			if not is_equal_approx(previous_origin.x, target_origin.x):
				return target_origin.x < previous_origin.x
		return default_rtl


	func _target_for_line(line_range: Vector2i) -> Dictionary:
		var target: Dictionary = {}
		for sample_value in _samples:
			var sample: Dictionary = sample_value
			if not bool(sample.get("visible", true)):
				continue
			var glyph_range: Vector2i = sample["range"]
			if glyph_range.y <= line_range.x or glyph_range.x >= line_range.y:
				continue
			var flags := int(sample["flags"])
			if flags & TextServer.GRAPHEME_IS_VIRTUAL:
				continue
			# RichTextLabel represents paragraph/list line breaks as zero-glyph
			# whitespace records. They are layout controls, not rendered endpoints.
			if int(sample["glyph_index"]) == 0 \
				and flags & TextServer.GRAPHEME_IS_SPACE:
				continue
			if target.is_empty() \
				or glyph_range.y > (target["range"] as Vector2i).y \
				or (glyph_range.y == (target["range"] as Vector2i).y \
					and glyph_range.x > (target["range"] as Vector2i).x):
				target = sample
		return target

var _content: CanvasItem
var _animation_tween: Tween
var _base_position := Vector2.ZERO

var _source: Resource
var _animation := ANIMATION_NONE
var _base_modulate := Color.WHITE
var _base_process_mode := Node.PROCESS_MODE_INHERIT
var _position_valid := false
var _endpoint_probe := EndpointProbeEffect.new()
var _probed_label: RichTextLabel
var _probe_mirror: RichTextLabel
var _lifecycle_revision := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	clip_contents = false
	visible = false


func _exit_tree() -> void:
	hide_indicator()


## Replaces the current texture or scene. Returns an empty string on success,
## otherwise a diagnostic; failed configuration always leaves the helper empty.
func configure(source: Resource, animation: String) -> String:
	_lifecycle_revision += 1
	var revision := _lifecycle_revision
	var normalized_animation := animation.strip_edges().to_lower()
	if normalized_animation.is_empty():
		normalized_animation = ANIMATION_NONE
	if normalized_animation not in [ANIMATION_NONE, ANIMATION_PULSE, ANIMATION_BOB]:
		if not _clear_source_for_revision(revision):
			return ""
		return (
			"advance indicator animation must be one of 'none', 'pulse', or 'bob'; got '%s'"
			% animation
		)
	if source == null:
		clear_source()
		return ""
	# ResourceLoader returns cached Resource instances by default. Keep a custom
	# scene alive across entries when its source and wrapper animation are
	# unchanged; lifecycle transitions still call hide_indicator() first.
	if _source == source \
		and _animation == normalized_animation \
		and is_instance_valid(_content):
		_hide_indicator_for_revision(revision)
		return ""

	if not _clear_source_for_revision(revision):
		return ""

	var content: CanvasItem
	if source is Texture2D:
		content = _make_texture_content(source as Texture2D)
	elif source is PackedScene:
		var scene := source as PackedScene
		if not scene.can_instantiate():
			return "advance indicator scene cannot be instantiated"
		var instance := scene.instantiate()
		if not instance is CanvasItem:
			instance.free()
			return "advance indicator scene root must inherit CanvasItem"
		content = instance as CanvasItem
		# top_level detaches any CanvasItem subtype from the holder transform.
		# Custom scenes author visuals around their root, but the engine owns the
		# final endpoint transform.
		content.top_level = false
		if content is Control and not _uses_top_left_anchors(content as Control):
			instance.free()
			return (
				"advance indicator scene Control root must use top-left anchors "
				+ "and author its size with offsets or minimum size"
			)
	else:
		return (
			"advance indicator source must be a Texture2D or PackedScene; got %s"
			% source.get_class()
		)

	_source = source
	_animation = normalized_animation
	_content = content
	add_child(_content)
	_disable_mouse_input(_content)

	_base_position = _initial_content_position(_content)
	_set_content_position(_base_position)
	_base_modulate = _content.modulate
	_base_process_mode = _content.process_mode
	if not _set_content_ready(false, revision, _content):
		return ""
	_content.process_mode = Node.PROCESS_MODE_DISABLED
	visible = false
	return ""


## Removes and frees the configured source immediately.
func clear_source() -> void:
	_lifecycle_revision += 1
	_clear_source_for_revision(_lifecycle_revision)


func _clear_source_for_revision(revision: int) -> bool:
	if not _hide_indicator_for_revision(revision):
		return false
	if is_instance_valid(_content):
		var old_content := _content
		_content = null
		if old_content.get_parent() == self:
			remove_child(old_content)
		old_content.free()
	else:
		_content = null
	_source = null
	_animation = ANIMATION_NONE
	_base_position = Vector2.ZERO
	_base_modulate = Color.WHITE
	_base_process_mode = Node.PROCESS_MODE_INHERIT
	_position_valid = false
	_clear_layout_probe()
	return revision == _lifecycle_revision


## Creates a transparent, non-interactive RichTextLabel child with the same
## shaping inputs and a no-op outer effect. The live label is never cleared or
## edited: its public text, tag stack, selection, visible-character state and
## scroll state all remain untouched.
func prepare_layout_probe(label: RichTextLabel) -> void:
	_clear_layout_probe()
	if label == null or not is_instance_valid(label) or not is_instance_valid(_content):
		return
	var mirror := RichTextLabel.new()
	mirror.name = &"__StellaEndpointProbe"
	_copy_layout_properties(label, mirror)
	# Text effects run during draw on the main thread. Synchronous shaping keeps
	# the temporary probe deterministic even when the live label shapes threaded.
	mirror.threaded = false
	mirror.visible_characters = -1
	mirror.visible_ratio = 1.0
	mirror.scroll_following = false
	mirror.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mirror.focus_mode = Control.FOCUS_NONE
	mirror.self_modulate = Color(1.0, 1.0, 1.0, 0.0)
	label.add_child(mirror)
	mirror.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	mirror.position = Vector2.ZERO
	mirror.size = label.size

	var source := label.text
	mirror.clear()
	mirror.push_customfx(_endpoint_probe, {})
	if mirror.bbcode_enabled:
		mirror.append_text(source)
	else:
		mirror.add_text(source)
	# Source may intentionally contain mismatched or unclosed tags. Godot keeps
	# only its actual top-of-stack close semantics; close every remaining manual
	# item after parsing so no authored tag or the probe leaks into later appends.
	mirror.pop_all()
	_probe_mirror = mirror
	_probed_label = label


## Scrolls the mirror to its own final viewport after its first layout. The
## endpoint's horizontal transform is independent of vertical scroll, while
## drawing the last viewport guarantees the final glyph is sampled even when
## the temporary outer effect introduces an empty leading paragraph before a
## block-level BBCode tag. The live label remains authoritative for vertical
## position and visibility.
func sync_layout_probe_scroll() -> void:
	if not is_instance_valid(_probe_mirror) or not is_instance_valid(_probed_label):
		return
	var mirror_bar := _probe_mirror.get_v_scroll_bar()
	if mirror_bar == null:
		return
	mirror_bar.value = mirror_bar.max_value
	_probe_mirror.queue_redraw()


## Isolates the final real grapheme after the mirror has drawn its target
## viewport. The following draw publishes a renderer-owned fallback rectangle
## on Godot 4.6, while 4.7 can continue using its sub-pixel virtual caret.
func isolate_layout_probe_endpoint() -> bool:
	if not is_instance_valid(_probe_mirror) \
		or not is_instance_valid(_probed_label):
		return false
	var line_count := _probed_label.get_line_count()
	var last_line := _find_last_rendered_line(_probed_label, line_count)
	if last_line < 0 or not _endpoint_probe.isolate_endpoint_for_line(
		_probed_label.get_line_range(last_line),
		_probe_mirror.get_visible_content_rect(),
		_probe_mirror.text_direction == Control.TEXT_DIRECTION_RTL \
			or _probe_mirror.is_layout_rtl(),
	):
		_position_valid = false
		_clear_layout_probe()
		return false
	_probe_mirror.queue_redraw()
	return true


## Positions this holder at the final non-empty rendered line's advance point.
## The offset is expressed in label-local coordinates. Call only after the
## label has completed its layout/draw boundary.
func position_after(label: RichTextLabel, offset: Vector2) -> bool:
	if label == null or not is_instance_valid(label) or not is_instance_valid(_content):
		_position_valid = false
		_clear_layout_probe()
		hide_indicator()
		return false

	var line_count := label.get_line_count()
	var last_line := _find_last_rendered_line(label, line_count)
	if last_line < 0:
		_position_valid = false
		_clear_layout_probe()
		hide_indicator()
		return false

	var normal_style := label.get_theme_stylebox(&"normal")
	var text_origin := normal_style.get_offset()
	var minimum_size := normal_style.get_minimum_size()
	var text_size := Vector2(
		maxf(0.0, label.size.x - minimum_size.x),
		maxf(0.0, label.size.y - minimum_size.y),
	)

	var scroll_bar := label.get_v_scroll_bar()
	var scroll_value := 0.0
	if scroll_bar != null:
		scroll_value = scroll_bar.value
	if _probed_label != label:
		_position_valid = false
		_clear_layout_probe()
		hide_indicator()
		return false
	var line_range := label.get_line_range(last_line)
	var probed_endpoint: Variant = _endpoint_probe.endpoint_for_line(line_range)
	if probed_endpoint == null and is_instance_valid(_probe_mirror):
		probed_endpoint = _endpoint_probe.fallback_endpoint_for_line(
			line_range, _probe_mirror.get_visible_content_rect())
	if probed_endpoint == null:
		_position_valid = false
		_clear_layout_probe()
		hide_indicator()
		return false
	var endpoint_x := (probed_endpoint as Vector2).x
	_clear_layout_probe()

	var vertical_begin := 0.0
	var vertical_separation := 0.0
	if label.vertical_alignment != VERTICAL_ALIGNMENT_TOP:
		var content_height := float(label.get_content_height())
		if text_size.y > content_height:
			match label.vertical_alignment:
				VERTICAL_ALIGNMENT_CENTER:
					vertical_begin = (text_size.y - content_height) / 2.0
				VERTICAL_ALIGNMENT_BOTTOM:
					vertical_begin = text_size.y - content_height
				VERTICAL_ALIGNMENT_FILL:
					if line_count > 1:
						vertical_separation = (
							(text_size.y - content_height) / float(line_count - 1)
						)

	var line_separation := label.get_theme_constant(&"line_separation")
	var line_height := maxf(
		0.0,
		float(label.get_line_height(last_line) - line_separation),
	)
	var endpoint_y := (
		text_origin.y
		+ vertical_begin
		+ label.get_line_offset(last_line)
		+ float(last_line) * vertical_separation
		- scroll_value
		+ line_height / 2.0
	)
	if not _endpoint_is_visible(
		label, normal_style, Vector2(endpoint_x, endpoint_y)):
		_position_valid = false
		hide_indicator()
		return false
	var label_point := Vector2(endpoint_x, endpoint_y) + offset
	var canvas_point := label.get_global_transform_with_canvas() * label_point
	var parent_item := get_parent() as CanvasItem
	position = (
		parent_item.get_global_transform_with_canvas().affine_inverse() * canvas_point
		if parent_item != null
		else canvas_point
	)
	_position_valid = true
	return true


func show_ready() -> void:
	_lifecycle_revision += 1
	var revision := _lifecycle_revision
	if not _position_valid or not is_instance_valid(_content):
		visible = false
		return
	var content := _content
	_stop_animation()
	content.process_mode = _base_process_mode
	visible = true
	if not _set_content_ready(true, revision, content):
		return
	_start_animation()


func hide_indicator() -> void:
	_lifecycle_revision += 1
	_hide_indicator_for_revision(_lifecycle_revision)


func _hide_indicator_for_revision(revision: int) -> bool:
	_clear_layout_probe()
	var content := _content
	if is_instance_valid(content):
		if not _set_content_ready(false, revision, content):
			return false
	if revision != _lifecycle_revision or _content != content:
		return false
	_stop_animation()
	if is_instance_valid(content):
		content.process_mode = Node.PROCESS_MODE_DISABLED
	visible = false
	return true


func cleanup() -> void:
	clear_source()


func _make_texture_content(texture: Texture2D) -> TextureRect:
	var texture_rect := TextureRect.new()
	texture_rect.name = "Texture"
	texture_rect.texture = texture
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.size = texture.get_size()
	texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_rect.focus_mode = Control.FOCUS_NONE
	return texture_rect


func _initial_content_position(content: CanvasItem) -> Vector2:
	if content is TextureRect:
		return Vector2(0.0, -(content as TextureRect).size.y / 2.0)
	# A custom scene authors its visuals around its root origin. The configured
	# offset belongs to the holder, not to an incidental root transform.
	return Vector2.ZERO


func _find_last_rendered_line(label: RichTextLabel, line_count: int) -> int:
	for line in range(line_count - 1, -1, -1):
		var line_range := label.get_line_range(line)
		if line_range.y > line_range.x and label.get_line_width(line) > 0:
			return line
	return -1


func _disable_mouse_input(node: Node) -> void:
	if node is Control:
		var control := node as Control
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_disable_mouse_input(child)


func _uses_top_left_anchors(control: Control) -> bool:
	return (
		is_zero_approx(control.anchor_left)
		and is_zero_approx(control.anchor_top)
		and is_zero_approx(control.anchor_right)
		and is_zero_approx(control.anchor_bottom)
	)


func _copy_layout_properties(source: RichTextLabel, target: RichTextLabel) -> void:
	target.bbcode_enabled = source.bbcode_enabled
	target.fit_content = source.fit_content
	target.scroll_active = source.scroll_active
	target.autowrap_mode = source.autowrap_mode
	target.autowrap_trim_flags = source.autowrap_trim_flags
	target.horizontal_alignment = source.horizontal_alignment
	target.vertical_alignment = source.vertical_alignment
	target.tab_size = source.tab_size
	target.tab_stops = source.tab_stops
	target.text_direction = source.text_direction
	target.language = source.language
	target.structured_text_bidi_override = source.structured_text_bidi_override
	target.structured_text_bidi_override_options = (
		source.structured_text_bidi_override_options)
	target.justification_flags = source.justification_flags
	target.custom_effects = source.custom_effects
	target.layout_direction = source.layout_direction
	target.clip_contents = source.clip_contents
	target.theme = source.theme
	target.theme_type_variation = source.theme_type_variation

	for font_name in [
		&"normal_font", &"bold_font", &"italics_font", &"bold_italics_font",
		&"mono_font",
	]:
		target.add_theme_font_override(font_name, source.get_theme_font(font_name))
	for font_size_name in [
		&"normal_font_size", &"bold_font_size", &"italics_font_size",
		&"bold_italics_font_size", &"mono_font_size",
	]:
		target.add_theme_font_size_override(
			font_size_name, source.get_theme_font_size(font_size_name))
	for constant_name in [
		&"line_separation", &"paragraph_separation", &"table_h_separation",
		&"table_v_separation", &"outline_size", &"shadow_offset_x",
		&"shadow_offset_y", &"shadow_outline_size",
	]:
		target.add_theme_constant_override(
			constant_name, source.get_theme_constant(constant_name))
	target.add_theme_stylebox_override(
		&"normal", source.get_theme_stylebox(&"normal"))


func _clear_layout_probe() -> void:
	_endpoint_probe.reset()
	_probed_label = null
	if is_instance_valid(_probe_mirror):
		_probe_mirror.free()
	_probe_mirror = null


func _endpoint_is_visible(
	label: RichTextLabel,
	normal_style: StyleBox,
	endpoint: Vector2,
) -> bool:
	const EPSILON := 0.5
	# RichTextLabel always culls lines outside its vertical draw viewport, even
	# when clip_contents and scrolling are disabled. Anchor visibility (rather
	# than requiring the full line box) keeps a partially visible final line's
	# marker consistent with what the label actually draws.
	var draw_bottom := label.size.y - normal_style.get_margin(SIDE_BOTTOM)
	if endpoint.y < -EPSILON or endpoint.y > draw_bottom + EPSILON:
		return false
	# Horizontal overflow is visible when Control clipping is disabled.
	if label.clip_contents \
		and (endpoint.x < -EPSILON or endpoint.x > label.size.x + EPSILON):
		return false
	return true


func _set_content_ready(
	ready: bool,
	revision: int,
	content: CanvasItem,
) -> bool:
	if is_instance_valid(content) and content.has_method(&"set_advance_ready"):
		content.call(&"set_advance_ready", ready)
	return (
		revision == _lifecycle_revision
		and _content == content
		and (content == null or is_instance_valid(content))
	)


func _set_content_position(value: Vector2) -> void:
	if not is_instance_valid(_content):
		return
	if _content is Control:
		(_content as Control).position = value
	elif _content is Node2D:
		(_content as Node2D).position = value


func _stop_animation() -> void:
	if _animation_tween != null and _animation_tween.is_valid():
		_animation_tween.kill()
	_animation_tween = null
	if not is_instance_valid(_content):
		return
	match _animation:
		ANIMATION_PULSE:
			_content.modulate = _base_modulate
		ANIMATION_BOB:
			_set_content_position(_base_position)


func _start_animation() -> void:
	if not is_inside_tree() or not is_instance_valid(_content):
		return
	match _animation:
		ANIMATION_PULSE:
			_animation_tween = create_tween().set_loops()
			_animation_tween.tween_property(
				_content,
				"modulate:a",
				_base_modulate.a * _PULSE_ALPHA_FACTOR,
				_ANIMATION_HALF_CYCLE,
			).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_animation_tween.tween_property(
				_content,
				"modulate:a",
				_base_modulate.a,
				_ANIMATION_HALF_CYCLE,
			).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		ANIMATION_BOB:
			_animation_tween = create_tween().set_loops()
			_animation_tween.tween_property(
				_content,
				"position",
				_base_position + Vector2(0.0, _BOB_DISTANCE),
				_ANIMATION_HALF_CYCLE,
			).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_animation_tween.tween_property(
				_content,
				"position",
				_base_position,
				_ANIMATION_HALF_CYCLE,
			).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
