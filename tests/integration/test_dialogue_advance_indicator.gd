extends GutTest
## Black-box integration contract for issue #154's end-of-text advance marker.
##
## These tests intentionally configure the marker only through the same profile
## Dictionary that DialogueHandler passes synchronously through SignalBus. They
## do not call implementation helpers: a configured presenter lazily owns one
## CanvasItem named AdvanceIndicator, while an unconfigured presenter owns none.

const FIXTURE := preload("res://tests/integration/fixtures/dialogue_presentation_profile.tscn")
const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const AUDIO_PRESENTER_SCRIPT := preload(
	"res://addons/stella/presentation/audio/audio_presenter.gd")
const INDICATOR_TEXTURE_PATH := \
	"res://tests/integration/fixtures/advance_indicator_4x4.svg"
const INDICATOR_SCENE_PATH := \
	"res://tests/integration/fixtures/advance_indicator_scene.tscn"
const INDICATOR_SCENE_SCRIPT := preload(
	"res://tests/integration/fixtures/advance_indicator_scene.gd")
const VOICE_PROGRESS_BAR_SCRIPT := preload(
	"res://examples/demo/scripts/voice_progress_bar.gd")
const SIGNAL_BUS_SCRIPT := preload(
	"res://addons/stella/autoload/signal_bus.gd")
const INVALID_INDICATOR_SCENE_PATH := \
	"res://tests/integration/fixtures/advance_indicator_invalid_root.tscn"
const INDICATOR_OFFSET := Vector2(7.0, 5.0)


class SyntheticCustomEffect:
	extends RichTextEffect

	var bbcode := "custom"


	func _process_custom_fx(_char_fx: CharFXTransform) -> bool:
		return true

var _presenter: Control
var _original_auto_play_delay: float
var _original_auto_play_wait_voice: bool
var _original_skip_interval: int
var _original_skip_only_read: bool
var _original_voice_path: String
var _original_characters_path: String
var _original_voice_continue_on_advance: bool


func before_each() -> void:
	_original_auto_play_delay = float(StellaRuntime.get_setting("auto_play_delay"))
	_original_auto_play_wait_voice = bool(
		StellaRuntime.get_setting("auto_play_wait_voice"))
	_original_skip_interval = int(StellaRuntime.get_setting("skip_interval"))
	_original_skip_only_read = bool(StellaRuntime.get_setting("skip_only_read"))
	_original_voice_path = StellaRuntime.voice_path
	_original_characters_path = StellaRuntime.characters_path
	_original_voice_continue_on_advance = bool(
		StellaRuntime.get_setting("voice_continue_on_advance"))
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	StellaRuntime.game_state.previous_state = GameStateMachine.State.PLAYING


func after_each() -> void:
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	SignalBus.hide_dialogue.emit()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.set_setting("auto_play_delay", _original_auto_play_delay)
	StellaRuntime.set_setting(
		"auto_play_wait_voice", _original_auto_play_wait_voice)
	StellaRuntime.set_setting("skip_interval", _original_skip_interval)
	StellaRuntime.set_setting("skip_only_read", _original_skip_only_read)
	StellaRuntime.voice_path = _original_voice_path
	StellaRuntime.characters_path = _original_characters_path
	StellaRuntime.set_setting(
		"voice_continue_on_advance", _original_voice_continue_on_advance)
	StellaRuntime.game_state.current_state = GameStateMachine.State.TITLE
	StellaRuntime.game_state.previous_state = GameStateMachine.State.TITLE
	await get_tree().process_frame


func test_unconfigured_presenter_never_creates_an_indicator() -> void:
	SignalBus.emit_show_dialogue(
		"", [_segment("Legacy dialogue")], "adv")
	if not await _wait_for_typing_to_finish(_presenter):
		return

	assert_null(_presenter.get_node_or_null("AdvanceIndicator"),
		"legacy projects must not allocate an indicator node")
	assert_eq(_indicator_nodes(_presenter).size(), 0)
	assert_eq(_text_label(_presenter).text, "Legacy dialogue")


func test_resource_fallback_cannot_author_an_advance_indicator() -> void:
	var mode_profile := DialogueModeProfile.new()
	mode_profile.override_panel_modulate = true
	mode_profile.panel_modulate = Color(0.2, 0.3, 0.4, 1.0)
	var profile := DialoguePresentationProfile.new()
	profile.adv = mode_profile
	_presenter.set_presentation_profile(profile)

	SignalBus.show_dialogue.emit(
		"", [_segment("Resource fallback")], "adv")
	if not await _wait_for_typing_to_finish(_presenter):
		return

	assert_eq(_text_label(_presenter).text, "Resource fallback")
	assert_eq(_presenter.modulate, Color(0.2, 0.3, 0.4, 1.0),
		"legacy Resource layout remains supported")
	assert_null(_presenter.get_node_or_null("AdvanceIndicator"),
		"new indicator authoring has one canonical .stla schema")


func test_stla_profile_is_canonical_when_resource_layout_is_also_configured() -> void:
	var layout_mode := DialogueModeProfile.new()
	layout_mode.override_panel_modulate = true
	layout_mode.panel_modulate = Color(0.3, 0.4, 0.5, 1.0)
	var layout_profile := DialoguePresentationProfile.new()
	layout_profile.adv = layout_mode
	_presenter.set_presentation_profile(layout_profile)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "STLA indicator remains canonical", "adv", _scene_profile())
	if indicator == null:
		return
	assert_eq(_presenter.modulate, Color(0.9, 0.8, 0.7, 0.95),
		"the canonical STLA profile replaces the fallback Resource as one unit")
	assert_not_null(indicator.get_node_or_null("SyntheticAdvanceIndicator"))
	assert_true(indicator.visible)


func test_wrapped_adv_indicator_tracks_the_last_rendered_line() -> void:
	var wrapped_text := "WWWW WWWW WWWW WWWW WWWW WWWW"
	var indicator := await _show_and_wait_for_indicator(
		_presenter, wrapped_text, "adv", _texture_profile())
	if indicator == null:
		return

	var label := _text_label(_presenter)
	assert_gt(label.get_line_count(), 1,
		"the synthetic ADV fixture must exercise RichTextLabel wrapping")
	_assert_indicator_at_last_line(label, indicator, INDICATOR_OFFSET)
	assert_eq(label.text, wrapped_text,
		"the indicator must stay outside RichTextLabel.text")


func test_bbcode_paragraph_alignment_moves_the_rendered_endpoint() -> void:
	var label := _text_label(_presenter)
	label.bbcode_enabled = true
	label.offset_right = 260.0
	var cases: Array[Dictionary] = [
		{
			"text": "[p align=center]CENTER[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_CENTER,
			"outer_alignment": HORIZONTAL_ALIGNMENT_LEFT,
		},
		{
			"text": "[p align=right]RIGHT[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_RIGHT,
			"outer_alignment": HORIZONTAL_ALIGNMENT_LEFT,
		},
		{
			"text": "[p align=r]SHORT RIGHT[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_RIGHT,
			"outer_alignment": HORIZONTAL_ALIGNMENT_LEFT,
		},
		{
			"text": "[p align=RIGHT]CASE-SENSITIVE LEFT[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_LEFT,
			"outer_alignment": HORIZONTAL_ALIGNMENT_RIGHT,
		},
		{
			"text": "[p align=bogus]INVALID FALLBACK LEFT[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_LEFT,
			"outer_alignment": HORIZONTAL_ALIGNMENT_RIGHT,
		},
		{
			"text": "[p align=left align=right]LAST ALIGN WINS[/p]",
			"alignment": HORIZONTAL_ALIGNMENT_RIGHT,
			"outer_alignment": HORIZONTAL_ALIGNMENT_LEFT,
		},
	]
	for case_value in cases:
		var case: Dictionary = case_value
		var profile := _texture_profile()
		profile["horizontal_alignment"] = int(case["outer_alignment"])
		var indicator := await _show_and_wait_for_indicator(
			_presenter, String(case["text"]), "adv", profile)
		if indicator == null:
			return
		var expected_x := _expected_aligned_endpoint_x(
			label, int(case["alignment"]), INDICATOR_OFFSET.x)
		assert_almost_eq(
			_canvas_global_position(indicator).x,
			expected_x,
			2.0,
			"the marker follows the final paragraph's BBCode alignment",
		)


func test_clipped_endpoint_hides_until_the_last_line_is_scrolled_into_view() -> void:
	var label := _text_label(_presenter)
	label.threaded = true
	label.clip_contents = true
	label.scroll_active = true
	label.scroll_following = false
	label.offset_bottom = 76.0
	var long_text := (
		"One wrapped line after another keeps the final rendered endpoint "
		+ "well below this deliberately short RichTextLabel viewport."
	)
	var profile := _texture_profile()
	profile["clip_contents"] = true
	profile["scroll_active"] = true
	profile["scroll_following"] = false
	SignalBus.emit_show_dialogue(
		"", [_segment(long_text)], "adv", profile, true)
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var scroll_bar := label.get_v_scroll_bar()
	scroll_bar.value = 0.0
	for _frame in range(3):
		await get_tree().process_frame
	var indicator := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_not_null(indicator)
	if indicator == null:
		return
	assert_gt(label.get_line_count(), 2,
		"the clipping regression needs content below the visible viewport")
	assert_false(indicator.visible,
		"an endpoint outside the visible RichTextLabel viewport must stay hidden")

	assert_true(scroll_bar.visible)
	scroll_bar.value = scroll_bar.max_value
	var appeared: bool = await wait_until(
		func(): return indicator.visible and indicator.is_visible_in_tree(),
		1.0,
		"scrolling the final line into view repositions the marker",
	)
	assert_true(appeared,
		"the marker becomes ready once its rendered endpoint is visible")


func test_vertical_overflow_hides_even_when_control_clipping_is_disabled() -> void:
	var label := _text_label(_presenter)
	label.clip_contents = false
	label.scroll_active = false
	label.offset_bottom = 76.0
	SignalBus.emit_show_dialogue(
		"",
		[_segment(
			"A fixed short label cannot draw this many wrapped lines even when "
			+ "Control clipping is disabled, so its endpoint is not visible.")],
		"adv",
		_texture_profile(),
		true,
	)
	if not await _wait_for_typing_to_finish(_presenter):
		return
	for _frame in range(3):
		await get_tree().process_frame
	var indicator := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_not_null(indicator)
	if indicator != null:
		assert_false(indicator.visible,
			"RichTextLabel vertically culls overflow independently of clip_contents")


func test_partially_visible_final_line_keeps_its_endpoint_marker() -> void:
	var label := _text_label(_presenter)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "A wrapped final line remains partially visible", "adv",
		_texture_profile())
	if indicator == null:
		return
	var endpoint_y := (
		_canvas_global_position(indicator).y
		- label.global_position.y
		- INDICATOR_OFFSET.y
	)
	var normal_style := label.get_theme_stylebox(&"normal")
	label.clip_contents = true
	label.offset_bottom = (
		label.offset_top
		+ endpoint_y
		+ normal_style.get_margin(SIDE_BOTTOM)
		+ 1.0
	)
	var repositioned: bool = await wait_until(
		func(): return indicator.visible,
		1.0,
		"a partially visible final line retains its marker",
	)
	assert_true(repositioned)
	var last_line := label.get_line_count() - 1
	var line_bottom := (
		normal_style.get_offset().y
		+ label.get_line_offset(last_line)
		+ label.get_line_height(last_line)
	)
	var draw_bottom := label.size.y - normal_style.get_margin(SIDE_BOTTOM)
	assert_gt(line_bottom, draw_bottom,
		"the regression must actually clip part of the final line")


func test_accumulated_nvl_moves_one_indicator_to_the_newest_endpoint() -> void:
	var profile := _texture_profile()
	profile["entry_separator"] = "\n"
	var first := await _show_and_wait_for_indicator(
		_presenter, "First NVL entry", "nvl", profile, "indicator-page:1")
	if first == null:
		return
	var label := _text_label(_presenter)
	var first_position := _canvas_global_position(first)
	var first_line_count := label.get_line_count()
	var first_probe_mirror: RichTextLabel = _presenter._advance_indicator._probe_mirror
	assert_not_null(first_probe_mirror,
		"plain NVL keeps one transparent layout mirror for later appends")
	_assert_indicator_at_last_line(label, first, INDICATOR_OFFSET)

	_presenter._char_interval = 0.05
	SignalBus.emit_show_dialogue(
		"",
		[_segment("Second NVL entry")],
		"nvl",
		profile,
		true,
		"indicator-page:1",
	)
	assert_false(first.visible,
		"the previous NVL endpoint must hide synchronously for the new entry")
	await get_tree().process_frame
	_presenter._is_typing = false
	label.visible_characters = -1
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var second := await _wait_for_indicator(_presenter)
	if second == null:
		return

	assert_eq(_indicator_nodes(_presenter).size(), 1,
		"NVL accumulation must move one node rather than append marker nodes")
	assert_gt(label.get_line_count(), first_line_count)
	assert_gt(_canvas_global_position(second).y, first_position.y,
		"the endpoint must move down to the newest accumulated NVL entry")
	assert_same(
		_presenter._advance_indicator._probe_mirror,
		first_probe_mirror,
		"plain NVL appends must reuse the existing shaped mirror",
	)
	_assert_indicator_at_last_line(label, second, INDICATOR_OFFSET)
	assert_eq(
		label.text,
		"First NVL entry\nSecond NVL entry",
	)


func test_new_typing_and_advance_hide_the_ready_indicator_synchronously() -> void:
	var profile := _texture_profile()
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready", "adv", profile)
	if indicator == null:
		return

	_presenter._char_interval = 0.1
	SignalBus.emit_show_dialogue(
		"", [_segment("A deliberately slow replacement")], "adv", profile, true)
	assert_false(indicator.visible,
		"a valid SHOW must hide the old ready marker before its first await")

	SignalBus.advance_requested.emit()
	assert_false(indicator.visible,
		"advance must keep the marker hidden even without a following dialogue")
	await get_tree().create_timer(0.15).timeout
	assert_false(indicator.visible,
		"the replaced typewriter must not resurrect the advanced marker")


func test_double_click_style_advance_invalidates_pending_completion() -> void:
	var profile := _texture_profile()
	_presenter._char_interval = 0.05
	SignalBus.emit_show_dialogue(
		"", [_segment("Pending completion")], "adv", profile, true)
	await get_tree().process_frame
	_presenter._is_typing = false
	_text_label(_presenter).visible_characters = -1
	# Models the second click arriving before the old typewriter coroutine has
	# resumed and committed its ready-to-advance state.
	SignalBus.advance_requested.emit()
	await get_tree().create_timer(0.15).timeout

	var indicator := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_true(indicator == null or not indicator.visible,
		"an advanced generation must not become ready from stale completion work")


func test_input_immediately_after_show_completes_without_advancing() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.1
	var advance_count := [0]
	var voice_finished_count := [0]
	var on_advance := func(): advance_count[0] += 1
	var on_voice_finished := func(): voice_finished_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.dialogue_voice_finished.connect(on_voice_finished)
	var input_handler: Node = game.get_node("InputHandler")

	# Do not cross a process-frame boundary after SHOW. The accepted line must
	# already be active/not-ready when a second mouse event arrives.
	SignalBus.emit_show_dialogue(
		"", [_segment("Immediate mouse completion")], "adv",
		_texture_profile(), true)
	assert_true(_presenter._is_typing,
		"SHOW establishes its active state before yielding its first frame")
	_presenter._current_scenario_id = "issue_154_input"
	_presenter._current_scene_id = "start"
	_presenter._current_command_index = 15401
	_presenter._playback_total_duration = 1.0
	_presenter._playback_is_dialogue = true
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	input_handler._input(left_click)
	assert_eq(advance_count[0], 0,
		"a zero-frame completion click must not skip the accepted line")
	assert_false(_presenter._is_typing)
	assert_eq(_text_label(_presenter).visible_characters, -1)
	assert_true(StellaRuntime.read_flags.is_read(
		"issue_154_input", "start", 15401),
		"zero-frame completion still marks the accepted line as read")
	assert_eq(voice_finished_count[0], 1,
		"zero-frame completion still closes dialogue voice presentation")

	# The keyboard path has the same no-frame contract.
	SignalBus.emit_show_dialogue(
		"", [_segment("Immediate keyboard completion")], "adv",
		_texture_profile(), true)
	assert_true(_presenter._is_typing)
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	input_handler._unhandled_input(space)
	assert_eq(advance_count[0], 0,
		"Space immediately after SHOW must complete, not advance")
	assert_false(_presenter._is_typing)
	assert_eq(_text_label(_presenter).visible_characters, -1)

	# Ctrl uses a held-state contract instead of click-to-complete. A same-frame
	# press/release may neither advance nor leave a delayed skip owner behind.
	SignalBus.emit_show_dialogue(
		"", [_segment("Immediate Ctrl remains on this line")], "adv",
		_texture_profile(), true)
	var ctrl_press := InputEventKey.new()
	ctrl_press.keycode = KEY_CTRL
	ctrl_press.pressed = true
	input_handler._unhandled_input(ctrl_press)
	assert_eq(advance_count[0], 0,
		"Ctrl immediately after SHOW must not advance an active line")
	assert_true(_presenter._is_typing)
	var ctrl_release := InputEventKey.new()
	ctrl_release.keycode = KEY_CTRL
	ctrl_release.pressed = false
	input_handler._unhandled_input(ctrl_release)
	assert_false(_presenter._ctrl_held)
	assert_eq(_presenter._skip_pending_dialogue_gen, -1)
	await get_tree().create_timer(0.05).timeout
	assert_eq(advance_count[0], 0,
		"same-frame Ctrl release must not create a skip timer")

	SignalBus.advance_requested.disconnect(on_advance)
	SignalBus.dialogue_voice_finished.disconnect(on_voice_finished)


func test_real_click_to_finish_shows_ready_then_next_click_hides() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	SignalBus.emit_show_dialogue(
		"", [_segment("Click-to-finish remains one dialogue")], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"the real input path receives an in-flight typewriter",
	)
	assert_true(typing_started)
	if not typing_started:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	var input_handler: Node = game.get_node("InputHandler")
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	input_handler._input(left_click)
	assert_false(_presenter._is_typing)
	assert_eq(advance_count[0], 0,
		"the completion click must not also advance the dialogue")

	var indicator := await _wait_for_indicator(_presenter)
	if indicator == null:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_true(indicator.visible)
	input_handler._input(left_click)
	assert_eq(advance_count[0], 1)
	assert_false(indicator.visible,
		"the following click must synchronously retire the ready marker")
	SignalBus.advance_requested.disconnect(on_advance)


func test_click_to_finish_cancels_a_long_inline_wait_immediately() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	SignalBus.emit_show_dialogue(
		"", [_segment("A{wait:1500}")], "adv", _texture_profile(), true)
	var waiting: bool = await wait_until(
		func():
			return (
				_presenter._is_typing
				and _text_label(_presenter).visible_characters >= 1
			),
		1.0,
		"the real typewriter reaches the authored wait",
	)
	assert_true(waiting)
	if not waiting:
		SignalBus.advance_requested.disconnect(on_advance)
		return

	var input_handler: Node = game.get_node("InputHandler")
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	input_handler._input(left_click)
	assert_eq(advance_count[0], 0,
		"the completion click must not advance through an authored wait")
	var appeared_promptly: bool = await wait_until(
		func():
			var node := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
			return node != null and node.visible and node.is_visible_in_tree(),
		0.3,
		"click completion bypasses the remaining authored wait",
	)
	assert_true(appeared_promptly,
		"ready feedback must not wait for a cancelled inline timer")
	if appeared_promptly:
		var indicator := _presenter.get_node("AdvanceIndicator") as CanvasItem
		input_handler._input(left_click)
		assert_eq(advance_count[0], 1)
		assert_false(indicator.visible)
	SignalBus.advance_requested.disconnect(on_advance)


func test_auto_keyboard_completion_resumes_the_auto_advance_tail() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	StellaRuntime.set_setting("auto_play_delay", 0.15)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	StellaRuntime.auto_play.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	SignalBus.emit_show_dialogue(
		"", [_segment("A{wait:1500}uto keyboard completion")], "adv",
		_texture_profile(), true)
	var waiting: bool = await wait_until(
		func():
			return (
				_presenter._is_typing
				and _text_label(_presenter).visible_characters >= 1
			),
		1.0,
		"auto dialogue reaches its authored wait",
	)
	assert_true(waiting)
	if not waiting:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	(game.get_node("InputHandler") as Node)._unhandled_input(space)
	assert_false(_presenter._is_typing)
	assert_true(StellaRuntime.is_auto_playing(),
		"keyboard completion does not disable auto mode")
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"keyboard completion continues into auto-play's delayed advance",
	)
	assert_true(advanced)
	assert_eq(advance_count[0], 1)
	SignalBus.advance_requested.disconnect(on_advance)


func test_active_skip_never_exposes_a_ready_indicator() -> void:
	StellaRuntime.set_setting("skip_interval", 5)
	StellaRuntime.set_setting("skip_only_read", false)
	StellaRuntime.skip_controller.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	SignalBus.emit_show_dialogue(
		"", [_segment("Skipped endpoint")], "adv", _texture_profile(), true)
	var saw_visible := false
	for _frame in range(60):
		await get_tree().process_frame
		var indicator := (
			_presenter.get_node_or_null("AdvanceIndicator") as CanvasItem)
		if indicator != null and indicator.visible:
			saw_visible = true
		if advance_count[0] > 0:
			break

	assert_eq(advance_count[0], 1,
		"active skip must continue through the dialogue exactly once")
	assert_false(saw_visible,
		"a skipped line must never flash a ready-to-advance marker")
	var indicator := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_true(indicator == null or not indicator.visible)
	SignalBus.advance_requested.disconnect(on_advance)


func test_activating_toolbar_skip_from_ready_hides_synchronously() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before toolbar skip", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	if not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_true(StellaRuntime.is_skipping())
	assert_eq(advance_count[0], 1,
		"toolbar skip advances a dialogue that was already fully shown")
	assert_false(indicator.visible,
		"activating skip must retire the existing ready marker synchronously")
	SignalBus.advance_requested.disconnect(on_advance)


func test_stella_action_skip_from_ready_matches_toolbar() -> void:
	StellaRuntime.set_setting("skip_only_read", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before public skip", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	var button := Button.new()
	var action := StellaAction.new()
	action.action = StellaAction.Action.TOGGLE_SKIP
	button.add_child(action)
	add_child_autoqfree(button)
	await get_tree().process_frame

	button.pressed.emit()
	assert_true(StellaRuntime.is_skipping())
	assert_eq(advance_count[0], 1,
		"public ready-line skip must advance exactly like the built-in toolbar")
	assert_false(indicator.visible,
		"public ready-line skip retires the waiting marker synchronously")
	SignalBus.advance_requested.disconnect(on_advance)


func test_queued_for_deletion_presenter_cannot_advance_from_public_skip() -> void:
	StellaRuntime.set_setting("skip_only_read", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before presenter replacement", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	_presenter.queue_free()
	StellaRuntime.skip_controller.is_active = true
	assert_eq(advance_count[0], 0,
		"a presenter awaiting deletion cannot advance the replacement scene")
	SignalBus.advance_requested.disconnect(on_advance)


func test_toolbar_skip_mid_typing_never_flashes_and_advances_once() -> void:
	StellaRuntime.set_setting("skip_interval", 5)
	StellaRuntime.set_setting("skip_only_read", false)
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("Toolbar skip interrupts this typewriter")], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"toolbar skip receives an in-flight typewriter",
	)
	assert_true(typing_started)
	if not typing_started:
		SignalBus.advance_requested.disconnect(on_advance)
		return

	if not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_false(_presenter._is_typing)
	assert_eq(_text_label(_presenter).visible_characters, -1)
	var saw_visible := false
	for _frame in range(60):
		await get_tree().process_frame
		var indicator := (
			_presenter.get_node_or_null("AdvanceIndicator") as CanvasItem)
		if indicator != null and indicator.visible:
			saw_visible = true
		if advance_count[0] > 0:
			break

	assert_eq(advance_count[0], 1,
		"mid-typewriter toolbar skip must schedule exactly one advance")
	assert_false(saw_visible,
		"snap-to-end in skip mode must not enter the normal ready-marker state")
	SignalBus.advance_requested.disconnect(on_advance)


func test_toolbar_skip_checks_unread_gate_before_finalizing_typewriter() -> void:
	StellaRuntime.set_setting("skip_interval", 5)
	StellaRuntime.set_setting("skip_only_read", true)
	_presenter._char_interval = 0.0
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("U{wait:1500}nread gate stays active")], "adv",
		_texture_profile(), true)
	var waiting: bool = await wait_until(
		func():
			return (
				_presenter._is_typing
				and _text_label(_presenter).visible_characters >= 1
			),
		1.0,
		"unread toolbar gate receives an in-flight typewriter",
	)
	assert_true(waiting)
	if not waiting:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	_presenter._current_scenario_id = "issue_154_skip_gate"
	_presenter._current_scene_id = "start"
	_presenter._current_command_index = 15402
	assert_false(StellaRuntime.read_flags.is_read(
		"issue_154_skip_gate", "start", 15402))

	if not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_false(StellaRuntime.is_skipping(),
		"toolbar skip stops at an unread line before completing it")
	assert_true(_presenter._is_typing,
		"the blocked toolbar action leaves the unread typewriter active")
	assert_ne(_text_label(_presenter).visible_characters, -1)
	assert_false(StellaRuntime.read_flags.is_read(
		"issue_154_skip_gate", "start", 15402),
		"the unread gate must run before finalize marks the line read")
	await get_tree().create_timer(0.05).timeout
	assert_eq(advance_count[0], 0,
		"a blocked unread toolbar skip must not leave an advance timer")
	assert_false(StellaRuntime.read_flags.is_read(
		"issue_154_skip_gate", "start", 15402))
	SignalBus.advance_requested.disconnect(on_advance)


func test_stella_action_skip_applies_unread_gate_during_typewriter() -> void:
	StellaRuntime.set_setting("skip_only_read", true)
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("Public StellaAction skip cannot read its own completion")],
		"adv", _texture_profile(), true)
	var typing_started: bool = await wait_until(
		func():
			return (
				_presenter._is_typing
				and _text_label(_presenter).visible_characters >= 1
			),
		1.0,
		"public skip regression reaches an in-flight typewriter",
	)
	assert_true(typing_started)
	if not typing_started:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	_presenter._current_scenario_id = "issue_154_public_skip_gate"
	_presenter._current_scene_id = "start"
	_presenter._current_command_index = 15403

	var button := Button.new()
	var action := StellaAction.new()
	action.action = StellaAction.Action.TOGGLE_SKIP
	button.add_child(action)
	add_child_autoqfree(button)
	await get_tree().process_frame
	button.pressed.emit()
	assert_false(StellaRuntime.is_skipping(),
		"Presenter applies the unread gate synchronously to public skip activation")
	assert_true(_presenter._is_typing,
		"blocked public skip leaves the unread typewriter running")
	assert_false(StellaRuntime.read_flags.is_read(
		"issue_154_public_skip_gate", "start", 15403))
	assert_eq(advance_count[0], 0)
	SignalBus.advance_requested.disconnect(on_advance)


func test_cancelling_toolbar_skip_during_its_delay_restores_ready_state() -> void:
	StellaRuntime.set_setting("skip_interval", 250)
	StellaRuntime.set_setting("skip_only_read", false)
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("Cancel skip before its delayed advance")], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"toolbar skip cancellation starts from an in-flight typewriter",
	)
	assert_true(typing_started)
	if not typing_started or not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_true(StellaRuntime.is_skipping())
	if not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_false(StellaRuntime.is_skipping())

	var indicator := await _wait_for_indicator(_presenter)
	if indicator == null:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	await get_tree().create_timer(0.35).timeout
	assert_eq(advance_count[0], 0,
		"stopping skip must cancel its already scheduled advance")
	assert_true(indicator.visible,
		"the completed current line becomes normally advanceable again")
	SignalBus.advance_requested.disconnect(on_advance)


func test_public_auto_toggle_takes_over_a_pending_skip_delay() -> void:
	StellaRuntime.set_setting("skip_interval", 250)
	StellaRuntime.set_setting("skip_only_read", false)
	StellaRuntime.set_setting("auto_play_delay", 0.05)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("Auto takes over this pending skip")], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"public auto takeover starts from an in-flight typewriter",
	)
	assert_true(typing_started)
	if not typing_started or not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_true(StellaRuntime.is_skipping())

	# This is the documented facade path used by external UIs/StellaAction,
	# rather than DialoguePresenter's toolbar callback.
	StellaRuntime.toggle_auto_play()
	assert_true(StellaRuntime.is_auto_playing())
	assert_false(StellaRuntime.is_skipping())
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.8,
		"auto-play resumes after taking ownership from the skip timer",
	)
	assert_true(advanced)
	assert_eq(advance_count[0], 1,
		"skip-to-auto handoff must own exactly one delayed advance")
	SignalBus.advance_requested.disconnect(on_advance)


func test_an_early_advance_retires_the_pending_skip_timer() -> void:
	StellaRuntime.set_setting("skip_interval", 250)
	StellaRuntime.set_setting("skip_only_read", false)
	_presenter._char_interval = 0.05
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	SignalBus.emit_show_dialogue(
		"", [_segment("Do not let the old skip timer advance twice")], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"pending-skip cancellation starts while typing",
	)
	assert_true(typing_started)
	if not typing_started or not _press_toolbar_skip(_presenter):
		SignalBus.advance_requested.disconnect(on_advance)
		return
	SignalBus.advance_requested.emit()
	assert_eq(advance_count[0], 1)
	await get_tree().create_timer(0.35).timeout
	assert_eq(advance_count[0], 1,
		"an unrelated advance must retire the old line's skip timer")
	SignalBus.advance_requested.disconnect(on_advance)


func test_ctrl_release_cancels_pending_skip_and_restores_ready_immediately() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	StellaRuntime.set_setting("skip_interval", 500)
	StellaRuntime.set_setting("skip_only_read", false)
	_presenter._ctrl_held = true
	SignalBus.emit_show_dialogue(
		"", [_segment("Ctrl release restores this completed line")], "adv",
		_texture_profile(), true)
	var pending: bool = await wait_until(
		func():
			return (
				_presenter._skip_pending_dialogue_gen
				== _presenter._dialogue_gen
			),
		1.0,
		"Ctrl skipping reaches its configured delay",
	)
	assert_true(pending)
	if not pending:
		return
	var release := InputEventKey.new()
	release.keycode = KEY_CTRL
	release.pressed = false
	(game.get_node("InputHandler") as Node)._unhandled_input(release)
	assert_false(_presenter._ctrl_held)
	assert_eq(_presenter._skip_pending_dialogue_gen, -1)
	var indicator := await _wait_for_indicator(_presenter)
	if indicator != null:
		assert_true(indicator.visible,
			"releasing Ctrl restores ready feedback without waiting 500 ms")


func test_auto_play_shows_during_wait_then_advance_hides_it() -> void:
	StellaRuntime.set_setting("auto_play_delay", 0.25)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	StellaRuntime.auto_play.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Auto-play endpoint", "adv", _texture_profile())
	if indicator == null:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	assert_true(indicator.visible,
		"auto-play keeps the marker visible during its configured wait")
	assert_eq(advance_count[0], 0)
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		1.0,
		"auto-play emits its delayed advance",
	)
	assert_true(advanced)
	assert_false(indicator.visible,
		"auto-play's advance must synchronously hide the marker")
	SignalBus.advance_requested.disconnect(on_advance)


func test_reenabling_auto_does_not_revive_the_retired_delay() -> void:
	StellaRuntime.set_setting("auto_play_delay", 0.4)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Auto attempt ownership", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	StellaRuntime.auto_play.is_active = true
	await get_tree().create_timer(0.25).timeout
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.auto_play.is_active = true
	await get_tree().create_timer(0.22).timeout

	assert_eq(advance_count[0], 0,
		"re-enabling Auto starts a fresh delay instead of reviving the old timer")
	assert_true(indicator.visible)
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.35,
		"the replacement Auto attempt advances after its own full delay",
	)
	assert_true(advanced)
	assert_eq(advance_count[0], 1)
	SignalBus.advance_requested.disconnect(on_advance)


func test_stella_action_auto_from_ready_enters_the_auto_tail() -> void:
	StellaRuntime.set_setting("auto_play_delay", 0.05)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before public auto", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	var button := Button.new()
	var action := StellaAction.new()
	action.action = StellaAction.Action.TOGGLE_AUTO_PLAY
	button.add_child(action)
	add_child_autoqfree(button)
	await get_tree().process_frame

	button.pressed.emit()
	assert_true(StellaRuntime.is_auto_playing())
	assert_true(indicator.visible,
		"the ready marker remains visible during the configured auto delay")
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"public ready-line auto enters the normal delayed advance tail",
	)
	assert_true(advanced)
	assert_eq(advance_count[0], 1)
	assert_false(indicator.visible)
	SignalBus.advance_requested.disconnect(on_advance)


func test_public_auto_cannot_advance_a_ready_line_behind_system_overlay() -> void:
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready under system overlay", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	StellaRuntime.game_state.transition_to(GameStateMachine.State.BACKLOG)

	StellaRuntime.auto_play.is_active = true
	await get_tree().create_timer(0.05).timeout
	assert_true(StellaRuntime.is_auto_playing(),
		"a system overlay must not rewrite the public Auto controller state")
	assert_eq(advance_count[0], 0,
		"an Auto tail cannot advance dialogue behind a system overlay")
	assert_true(indicator.visible,
		"the covered ready dialogue keeps its waiting marker")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	assert_true(await wait_until(
		func(): return advance_count[0] == 1,
		0.5,
		"the preserved Auto state takes effect only after PLAYING resumes",
	))
	SignalBus.advance_requested.disconnect(on_advance)


func test_queued_for_deletion_presenter_cannot_start_public_auto_tail() -> void:
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before auto scene replacement", "adv", _texture_profile())
	if indicator == null:
		return
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	_presenter.queue_free()
	StellaRuntime.auto_play.is_active = true
	await get_tree().create_timer(0.05).timeout
	assert_eq(advance_count[0], 0,
		"a presenter awaiting deletion cannot schedule an auto advance")
	SignalBus.advance_requested.disconnect(on_advance)


func test_hard_hide_cancels_typing_and_stops_bob_animation() -> void:
	var profile := _texture_profile("bob")
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Animated ready marker", "adv", profile)
	if indicator == null:
		return
	var content := _first_canvas_child(indicator)

	_presenter._ctrl_held = true
	SignalBus.hide_dialogue.emit()
	assert_false(_presenter._ctrl_held,
		"hard hide clears held Ctrl even when no release event follows")
	assert_false(indicator.visible)
	var hidden_position := _canvas_global_position(indicator)
	var hidden_modulate := indicator.modulate
	var hidden_content_position := _canvas_local_position(content)
	var hidden_content_modulate := content.modulate
	await get_tree().create_timer(0.2).timeout
	assert_false(indicator.visible)
	assert_eq(_canvas_global_position(indicator), hidden_position,
		"hard hide must stop a bob animation rather than leave it processing")
	assert_eq(indicator.modulate, hidden_modulate)
	assert_eq(_canvas_local_position(content), hidden_content_position,
		"hard hide must kill and reset the animated custom/texture content")
	assert_eq(content.modulate, hidden_content_modulate)

	_presenter._char_interval = 0.05
	SignalBus.emit_show_dialogue(
		"", [_segment("Hide while typing")], "adv", profile, true)
	SignalBus.hide_dialogue.emit()
	await get_tree().create_timer(0.15).timeout
	var active := _presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_true(active == null or not active.visible,
		"hard hide must invalidate pending typewriter/layout continuations")


func test_scene_and_scenario_lifecycle_events_hide_without_duplicate_nodes() -> void:
	var profile := _texture_profile("pulse")
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Before scene change", "adv", profile)
	if indicator == null:
		return

	SignalBus.scene_changed_event.emit("synthetic-next-scene")
	assert_false(indicator.visible,
		"scenario scene replacement must hide the previous endpoint")

	indicator = await _show_and_wait_for_indicator(
		_presenter, "Before scenario restart", "adv", profile)
	if indicator == null:
		return
	SignalBus.scenario_started_event.emit("replacement-scenario")
	assert_false(indicator.visible)

	indicator = await _show_and_wait_for_indicator(
		_presenter, "Before scenario end", "adv", profile)
	if indicator == null:
		return
	SignalBus.scenario_ended_event.emit("replacement-scenario")
	assert_false(indicator.visible,
		"scenario end must explicitly stop and hide the indicator child")
	assert_eq(_indicator_nodes(_presenter).size(), 1)


func test_soft_hide_round_trip_preserves_the_ready_indicator() -> void:
	# Exercise the real InputHandler path rather than directly toggling the two
	# presenter fields used for a view-only hide.
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Soft hide ready", "adv", _texture_profile())
	if indicator == null:
		return

	var input_handler: Node = game.get_node("InputHandler")
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	input_handler._input(right_click)
	assert_true(_presenter._ui_hidden)
	assert_false(indicator.is_visible_in_tree())

	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SETTINGS)
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	input_handler._input(left_click)
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	input_handler._unhandled_input(space)
	assert_true(_presenter._ui_hidden,
		"system-overlay input cannot restore the soft-hidden dialogue below it")
	assert_false(_presenter.visible)
	assert_eq(advance_count[0], 0)

	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	input_handler._input(left_click)
	assert_false(_presenter._ui_hidden)
	assert_true(indicator.visible)
	assert_true(indicator.is_visible_in_tree(),
		"restoring a soft hide must restore the same ready marker")
	assert_eq(_indicator_nodes(_presenter).size(), 1)
	assert_eq(advance_count[0], 0,
		"the restoring click is consumed instead of advancing the dialogue")
	SignalBus.advance_requested.disconnect(on_advance)


func test_ctrl_input_in_system_overlay_preserves_ready_and_typing_lines() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	var input_handler: Node = game.get_node("InputHandler")
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)

	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready beneath system overlay", "adv", _texture_profile())
	if indicator == null:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	StellaRuntime.game_state.current_state = GameStateMachine.State.BACKLOG
	var ctrl_press := InputEventKey.new()
	ctrl_press.keycode = KEY_CTRL
	ctrl_press.pressed = true
	input_handler._unhandled_input(ctrl_press)
	assert_false(_presenter._ctrl_held)
	assert_eq(advance_count[0], 0,
		"Ctrl in a system overlay must not advance the ready dialogue below it")
	assert_true(indicator.visible,
		"the overlay preserves the same ready indicator")

	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	SignalBus.emit_show_dialogue(
		"", [_segment("T{wait:1500}yping beneath system overlay")], "adv",
		_texture_profile(), true)
	var waiting: bool = await wait_until(
		func():
			return (
				_presenter._is_typing
				and _text_label(_presenter).visible_characters >= 1
			),
		1.0,
		"system-overlay Ctrl regression reaches an authored wait",
	)
	assert_true(waiting)
	if not waiting:
		SignalBus.advance_requested.disconnect(on_advance)
		return
	var visible_before := _text_label(_presenter).visible_characters
	StellaRuntime.game_state.current_state = GameStateMachine.State.SETTINGS
	input_handler._unhandled_input(ctrl_press)
	assert_false(_presenter._ctrl_held,
		"Ctrl in a system overlay must not enable fast-forward below it")
	assert_true(_presenter._is_typing)
	assert_eq(_text_label(_presenter).visible_characters, visible_before)
	assert_eq(advance_count[0], 0)

	_presenter._ctrl_held = true
	var ctrl_release := InputEventKey.new()
	ctrl_release.keycode = KEY_CTRL
	ctrl_release.pressed = false
	input_handler._unhandled_input(ctrl_release)
	assert_false(_presenter._ctrl_held,
		"Ctrl release remains unconditional in a system overlay")
	SignalBus.advance_requested.disconnect(on_advance)


func test_leaving_playing_retires_held_ctrl_and_pending_skip() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	StellaRuntime.set_setting("skip_interval", 250)
	StellaRuntime.set_setting("skip_only_read", false)
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	SignalBus.advance_requested.connect(on_advance)
	_presenter._ctrl_held = true
	SignalBus.emit_show_dialogue(
		"", [_segment("Ctrl timer must stop beneath Settings")], "adv",
		_texture_profile(), true)
	var pending: bool = await wait_until(
		func():
			return (
				_presenter._skip_pending_dialogue_gen
				== _presenter._dialogue_gen
			),
		1.0,
		"held Ctrl reaches its delayed advance",
	)
	assert_true(pending)
	if not pending:
		SignalBus.advance_requested.disconnect(on_advance)
		return

	StellaRuntime.game_state.transition_to(GameStateMachine.State.SETTINGS)
	assert_false(_presenter._ctrl_held,
		"leaving PLAYING synchronously clears held Ctrl")
	assert_eq(_presenter._skip_pending_dialogue_gen, -1,
		"leaving PLAYING retires the completed line's skip timer")
	await get_tree().create_timer(0.35).timeout
	assert_eq(advance_count[0], 0,
		"a Ctrl timer cannot advance the scenario beneath a system overlay")
	SignalBus.advance_requested.disconnect(on_advance)


func test_overlay_marker_hides_on_advance_without_a_following_show() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Overlay endpoint", "overlay", _texture_profile())
	if indicator == null:
		return

	SignalBus.advance_requested.emit()
	assert_false(indicator.visible,
		"@overlay off has no presenter event, so advance must close its marker")
	await get_tree().process_frame
	assert_false(indicator.visible)


func test_indicator_does_not_mutate_text_segments_or_backlog() -> void:
	var segments := [{
		"text": "Original source text",
		"voice": "",
		"expression": "",
	}]
	var original_segments := segments.duplicate(true)
	SignalBus.emit_show_dialogue(
		"Narrator", segments, "adv", _texture_profile(), true)
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var indicator := await _wait_for_indicator(_presenter)
	if indicator == null:
		return

	assert_eq(_text_label(_presenter).text, "Original source text")
	assert_eq(segments, original_segments,
		"presentation must not append marker metadata to dialogue segments")
	var backlog := BacklogManager.new()
	backlog.add_entry("Narrator", segments)
	assert_eq(backlog.get_entry(0)["text"], "Original source text")
	assert_false(backlog.get_entry(0)["text"].contains("AdvanceIndicator"))


func test_pulse_and_bob_reuse_a_single_named_canvas_item() -> void:
	for animation in ["pulse", "bob", "pulse"]:
		var indicator := await _show_and_wait_for_indicator(
			_presenter, "Animation %s" % animation, "adv",
			_texture_profile(animation))
		if indicator == null:
			return
		assert_eq(indicator.name, "AdvanceIndicator")
		assert_eq(_indicator_nodes(_presenter).size(), 1,
			"animation replacement must not leak or duplicate marker nodes")


func test_packed_scene_configuration_uses_the_same_node_contract() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Scene-backed indicator", "adv", _scene_profile("bob"))
	if indicator == null:
		return

	assert_eq(indicator.name, "AdvanceIndicator")
	assert_eq(_indicator_nodes(_presenter).size(), 1)
	assert_true(indicator is CanvasItem)


func test_stla_scene_diagnostics_distinguish_profile_path_and_declaration_line() -> void:
	var source := ("""@dialogue_profile alpha advance_indicator_scene=\"%s\"
@dialogue_profile beta advance_indicator_scene=\"%s\"
@chapter test
@scene start
@adv profile=alpha
「Alpha」
@adv profile=beta
「Beta」""") % [
		INVALID_INDICATOR_SCENE_PATH,
		INVALID_INDICATOR_SCENE_PATH,
	]
	var stla_path := \
		"res://tests/fixtures/scenarios/dialogue/indicator_provenance.stla"
	var data := DslParser.parse(
		DslLexer.tokenize(source), "indicator_provenance", stla_path)
	assert_eq(data.diagnostics, [])

	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 2)
	var context := ScenarioContext.new(data)
	for index in commands.size():
		var command: CommandData = commands[index]
		var expected_name := "alpha" if index == 0 else "beta"
		var expected_line := index + 1
		context.apply_dialogue_mode_events(command.dialogue_mode_events_before)
		SignalBus.advance_requested.emit.call_deferred()
		await DialogueHandler.new().execute(command, context)
		assert_push_warning((
			"DialoguePresenter advance indicator [STLA profile '%s'; "
			+ "STLA source '%s'; advance_indicator_scene declared at line %d; "
			+ "indicator source '%s']: advance indicator scene root must inherit "
			+ "CanvasItem. Fix: Set the PackedScene root to Control, Node2D, or "
			+ "another CanvasItem, then re-save the scene."
		) % [
			expected_name,
			stla_path,
			expected_line,
			INVALID_INDICATOR_SCENE_PATH,
		])


func test_full_rect_control_scene_is_rejected_without_orphan_content() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK)
	root.free()
	var indicator := DialogueAdvanceIndicator.new()
	add_child_autoqfree(indicator)
	var error := indicator.configure(packed, "none")
	assert_string_contains(error, "must use top-left anchors")
	assert_eq(indicator.get_child_count(), 0,
		"a rejected scene must not leave instantiated marker content behind")


func test_top_level_control_scene_is_attached_to_the_endpoint_holder() -> void:
	var root := Control.new()
	root.top_level = true
	root.offset_right = 4.0
	root.offset_bottom = 4.0
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK)
	root.free()
	var indicator := DialogueAdvanceIndicator.new()
	add_child_autoqfree(indicator)
	assert_eq(indicator.configure(packed, "none"), "")
	var content := _first_canvas_child(indicator)
	assert_false(content.top_level,
		"custom CanvasItem roots must inherit the holder's endpoint transform")


func test_custom_scene_ready_hook_tracks_show_and_advance() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready hook", "adv", _scene_profile())
	if indicator == null:
		return
	var content := indicator.get_node_or_null("SyntheticAdvanceIndicator")
	assert_not_null(content)
	if content == null:
		return
	assert_true(bool(content.get("advance_ready")))
	assert_eq(
		content.get("advance_ready_history"),
		[false, true],
		"custom scenes are initialized hidden before receiving ready=true",
	)

	SignalBus.advance_requested.emit()
	assert_false(bool(content.get("advance_ready")))
	assert_eq(
		content.get("advance_ready_history"),
		[false, true, false],
		"advance synchronously informs custom scenes before the next command",
	)


func test_freeing_presenter_destroys_indicator_and_its_animation() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Scene replacement", "adv", _texture_profile("bob"))
	if indicator == null:
		return
	var old_indicator_ref: WeakRef = weakref(indicator)

	_presenter.queue_free()
	await get_tree().process_frame
	assert_null(old_indicator_ref.get_ref(),
		"the scene-owned indicator must be destroyed with its presenter")

	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var replacement := await _show_and_wait_for_indicator(
		_presenter, "Replacement scene", "adv", _texture_profile())
	if replacement == null:
		return
	assert_eq(_indicator_nodes(_presenter).size(), 1,
		"a replacement presenter must not retain the old scene's marker")


func test_advance_dispatch_does_not_invalidate_a_synchronously_shown_replacement() -> void:
	var first := await _show_and_wait_for_indicator(
		_presenter, "Before reordered listeners", "adv", _texture_profile())
	if first == null:
		return
	var did_show := [false]
	var serial_seen := [-1]
	var earlier_listener := func():
		if did_show[0]:
			return
		did_show[0] = true
		serial_seen[0] = SignalBus.current_advance_dispatch_serial()
		SignalBus.emit_show_dialogue(
			"", [_segment("Replacement during advance")], "adv",
			_texture_profile(), true)
	SignalBus.advance_requested.connect(earlier_listener)

	# Direct signal emission is part of the public compatibility surface and
	# must receive the same pre-dispatch ordering guarantee as the wrapper.
	SignalBus.advance_requested.emit()
	SignalBus.advance_requested.disconnect(earlier_listener)
	assert_true(did_show[0])
	assert_gt(serial_seen[0], 0,
		"SignalBus publishes the transition before ordinary advance listeners")
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var replacement := await _wait_for_indicator(_presenter)
	if replacement == null:
		return
	assert_eq(_text_label(_presenter).text, "Replacement during advance")
	assert_true(replacement.visible,
		"the old transition must not retire a synchronously shown generation")


func test_finalize_signal_cannot_retire_a_synchronously_shown_replacement() -> void:
	_presenter._char_interval = 0.05
	SignalBus.emit_show_dialogue(
		"speaker", [{
			"text": "Typing before reentrant finalization[expr:retired-expression]",
			"voice": "",
			"expression": "",
		}], "adv",
		_texture_profile(), true)
	var typing_started: bool = await wait_until(
		func(): return _presenter._is_typing,
		1.0,
		"reentrant finalization starts from an active typewriter",
	)
	assert_true(typing_started)
	if not typing_started:
		return

	var did_show := [false]
	var on_voice_finished := func():
		if did_show[0]:
			return
		did_show[0] = true
		SignalBus.emit_show_dialogue(
			"", [_segment("Replacement from finalize signal")], "adv",
			_texture_profile(), true)
	SignalBus.dialogue_voice_finished.connect(on_voice_finished)
	# Exercise the public completion signal without requiring a private audio
	# fixture. This is the same state set by a loaded dialogue voice.
	_presenter._playback_total_duration = 1.0
	_presenter._playback_is_dialogue = true
	SignalBus.advance_requested.emit()
	SignalBus.dialogue_voice_finished.disconnect(on_voice_finished)
	assert_true(did_show[0])
	assert_eq(_text_label(_presenter).text,
		"Replacement from finalize signal")
	assert_ne(_presenter._avatar_expressions.get("speaker", ""),
		"retired-expression",
		"finalization stops applying retired avatar state after replacement")
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var replacement := await _wait_for_indicator(_presenter)
	if replacement == null:
		return
	assert_true(replacement.visible,
		"the retired outer generation cannot invalidate the reentrant SHOW")


func test_input_advance_is_atomic_when_finalize_signal_shows_replacement() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	_presenter = game.get_node("UILayer/DialoguePanel")
	_presenter._char_interval = 0.0
	SignalBus.emit_show_dialogue(
		"speaker", [{
			"text": "Ready before input finalization[expr:retired-expression]",
			"voice": "",
			"expression": "",
		}], "adv",
		_texture_profile(), true)
	if not await _wait_for_typing_to_finish(_presenter):
		return
	# Model an active logical dialogue voice so the atomic advance prehook emits
	# FINISHED. A listener that SHOWs a replacement there must not be followed by
	# a second, input-layer finalization of that replacement.
	_presenter._playback_total_duration = 1.0
	_presenter._playback_is_dialogue = true
	_presenter._playback_dialogue_finished_emitted = false
	_presenter._segment_presentation_complete = true
	var did_show := [false]
	var on_voice_finished := func():
		if did_show[0]:
			return
		did_show[0] = true
		SignalBus.emit_show_dialogue(
			"", [_segment("Replacement from real input advance")], "adv",
			_texture_profile(), true)
	SignalBus.dialogue_voice_finished.connect(on_voice_finished)
	var input_handler: Node = game.get_node("InputHandler")
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	input_handler._input(left_click)
	SignalBus.dialogue_voice_finished.disconnect(on_voice_finished)

	assert_true(did_show[0])
	assert_eq(_text_label(_presenter).text,
		"Replacement from real input advance")
	assert_true(_presenter._is_typing,
		"the input layer must not retire the replacement after the bus prehook")


func test_advance_tail_cannot_stop_voice_started_by_finalize_replacement() -> void:
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	StellaRuntime.set_setting("voice_continue_on_advance", false)
	_presenter._char_interval = 0.05
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(audio_presenter)
	if audio_presenter == null:
		return
	var did_replace := [false]
	var on_dialogue_voice_finished := func():
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue("replacement", [{
			"text": "Replacement voice survives the retired advance",
			"voice": "narration_002",
			"expression": "",
		}], "adv", _texture_profile(), true)
	SignalBus.dialogue_voice_finished.connect(on_dialogue_voice_finished)
	SignalBus.emit_show_dialogue("retired", [{
		"text": "Typing voice retired by a defensive advance",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	assert_true(audio_presenter._voice_player.playing)

	SignalBus.emit_advance_requested()
	SignalBus.dialogue_voice_finished.disconnect(on_dialogue_voice_finished)
	assert_true(did_replace[0])
	assert_eq(_text_label(_presenter).text,
		"Replacement voice survives the retired advance")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(audio_presenter._voice_player.stream.resource_path.ends_with(
			"narration_002.wav"))
	assert_true(audio_presenter._voice_player.playing,
		"the ordinary tail of the retired advance must not stop replacement audio")
	assert_true(_presenter._playback_queue_active,
		"replacement playback must still own its live queue")
	audio_presenter._voice_player.stop()
	SignalBus.voice_finished.emit()


func test_voice_progress_consumer_rejects_retired_finished_tail() -> void:
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	_presenter._char_interval = 0.05
	var did_replace := [false]
	var on_dialogue_voice_finished := func():
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue("replacement", [{
			"text": "Replacement keeps its progress visible",
			"voice": "narration_002",
			"expression": "",
		}], "adv", _texture_profile(), true)
	# Connect the reentrant extension before the real demo consumer so the native
	# outer signal tail reaches that consumer after the nested replacement START.
	SignalBus.dialogue_voice_finished.connect(on_dialogue_voice_finished)
	var progress_bar := ProgressBar.new()
	progress_bar.set_script(VOICE_PROGRESS_BAR_SCRIPT)
	add_child_autoqfree(progress_bar)
	await get_tree().process_frame
	SignalBus.emit_show_dialogue("retired", [{
		"text": "Retired line closes its logical voice",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	assert_true(progress_bar.visible)

	assert_true(_presenter.complete_typewriter())
	SignalBus.dialogue_voice_finished.disconnect(on_dialogue_voice_finished)
	assert_true(did_replace[0])
	assert_eq(_text_label(_presenter).text,
		"Replacement keeps its progress visible")
	assert_true(progress_bar.visible,
		"the retired FINISHED tail must not hide replacement voice progress")
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter != null:
		audio_presenter._voice_player.stop()
	SignalBus.voice_finished.emit()


func test_owned_dialogue_voice_started_tail_rejects_replacement() -> void:
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_replace := [false]
	var accepted_totals: Array[float] = []
	var on_started_early := func(_total_duration: float):
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue("replacement", [{
			"text": "Replacement owns logical voice start",
			"voice": "narration_002",
			"expression": "",
		}], "adv", _texture_profile(), true)
	var on_started_late := func(total_duration: float):
		if SignalBus.dialogue_voice_started_event_is_current(total_duration):
			accepted_totals.append(total_duration)
	SignalBus.dialogue_voice_started.connect(on_started_early)
	SignalBus.dialogue_voice_started.connect(on_started_late)

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Retired logical voice start",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _scene_profile(), true)
	SignalBus.dialogue_voice_started.disconnect(on_started_early)
	SignalBus.dialogue_voice_started.disconnect(on_started_late)

	assert_true(did_replace[0])
	assert_eq(_text_label(_presenter).text,
		"Replacement owns logical voice start")
	assert_eq(accepted_totals.size(), 1,
		"a stateful late consumer must reject the retired STARTED tail")
	if not accepted_totals.is_empty():
		assert_almost_eq(
			accepted_totals[0], _presenter._playback_total_duration, 0.001,
			"the one accepted event belongs to replacement playback",
		)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter != null:
		audio_presenter._voice_player.stop()
	SignalBus.voice_finished.emit()


func test_typed_voice_progress_rejects_a_replaced_playback_owner() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_replace := [false]
	var on_progress_early := func(event: VoicePlaybackEvent):
		if event.kind != VoicePlaybackEvent.Kind.PROGRESS:
			return
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue("replacement", [{
			"text": "Replacement progress owner",
			"voice": "narration_002",
			"expression": "",
		}], "adv", _texture_profile(), true)
	# This extension must precede the scene-local Presenter on the public signal.
	SignalBus.voice_playback_event.connect(on_progress_early)
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	SignalBus.emit_show_dialogue(
		"retired", [_segment("Original progress owner")], "adv",
		_texture_profile(), true)
	var owner_gen: int = _presenter._dialogue_gen
	var queue_gen: int = _presenter._playback_queue_gen
	_presenter._playback_total_duration = 3.0
	_presenter._playback_played_duration = 1.0
	_presenter._playback_voice_token = 701
	var accepted_low_progress: Array = []
	var accepted_dialogue_progress: Array = []
	var on_progress_late := func(event: VoicePlaybackEvent):
		if event.kind == VoicePlaybackEvent.Kind.PROGRESS and event.is_current():
			accepted_low_progress.append([event.position, event.duration])
	var on_dialogue_progress := func(position: float, duration: float):
		accepted_dialogue_progress.append([position, duration])
	SignalBus.voice_playback_event.connect(on_progress_late)
	SignalBus.dialogue_voice_progress.connect(on_dialogue_progress)

	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.progress(
		0.25, 1.0, 701,
		_presenter._voice_queue_event_owner_is_current.bind(owner_gen, queue_gen),
	))
	SignalBus.voice_playback_event.disconnect(on_progress_early)
	SignalBus.voice_playback_event.disconnect(on_progress_late)
	SignalBus.dialogue_voice_progress.disconnect(on_dialogue_progress)

	assert_true(did_replace[0])
	assert_eq(accepted_low_progress.size(), 0,
		"a late low-level consumer rejects the retired playback tail")
	assert_eq(accepted_dialogue_progress.size(), 0,
		"a typed event retired by an earlier listener cannot reach the dialogue relay")
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter != null:
		audio_presenter._voice_player.stop()
	SignalBus.voice_finished.emit()


func test_high_level_voice_progress_tail_rejects_replacement() -> void:
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	SignalBus.emit_show_dialogue(
		"retired", [_segment("Retired high progress")], "adv",
		_texture_profile(), true)
	var owner_gen: int = _presenter._dialogue_gen
	var queue_gen: int = _presenter._playback_queue_gen
	_presenter._playback_total_duration = 3.0
	_presenter._playback_played_duration = 1.0
	_presenter._playback_voice_token = 702
	var did_replace := [false]
	var on_progress_early := func(_position: float, _duration: float):
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue("replacement", [{
			"text": "Replacement owns the progress bar",
			"voice": "narration_002",
			"expression": "",
		}], "adv", _texture_profile(), true)
	SignalBus.dialogue_voice_progress.connect(on_progress_early)
	var progress_bar := ProgressBar.new()
	progress_bar.set_script(VOICE_PROGRESS_BAR_SCRIPT)
	add_child_autoqfree(progress_bar)
	await get_tree().process_frame

	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.progress(
		0.25, 1.0, 702,
		_presenter._voice_queue_event_owner_is_current.bind(owner_gen, queue_gen),
	))
	SignalBus.dialogue_voice_progress.disconnect(on_progress_early)
	assert_true(did_replace[0])
	assert_true(progress_bar.visible)
	assert_almost_eq(float(progress_bar.value), 0.0, 0.001,
		"the retired high-level PROGRESS tail cannot overwrite replacement START")
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter != null:
		audio_presenter._voice_player.stop()
	SignalBus.voice_finished.emit()


func test_voice_kickoff_cannot_overwrite_a_synchronously_shown_replacement() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var replacement_segments: Array = [{
		"text": "Replacement owns the voice generation",
		"voice": "narration_002",
		"expression": "replacement-expression",
	}]
	var did_replace := [false]
	var replacement_gen := [-1]
	var replacement_queue_gen := [-1]
	var voice_plays: Array = []
	var on_voice_started := func(_duration: float):
		if did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue(
			"replacement", replacement_segments, "adv", _scene_profile(), true)
		replacement_gen[0] = _presenter._dialogue_gen
		replacement_queue_gen[0] = _presenter._playback_queue_gen
	var on_voice_play := func(asset: String, character: String):
		voice_plays.append([asset, character])
	# Connect the reentrant observer before Presenter exists. This reproduces an
	# extension whose synchronous signal hook precedes every scene-local listener.
	SignalBus.dialogue_voice_started.connect(on_voice_started)
	SignalBus.voice_play.connect(on_voice_play)
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Retired voice kickoff must stop here",
		"voice": "narration_001",
		"expression": "retired-expression",
	}], "adv", _texture_profile(), true)
	var completed := await _wait_for_typing_to_finish(_presenter)
	var indicator: CanvasItem = null
	if completed:
		indicator = await _wait_for_indicator(_presenter)

	assert_true(did_replace[0])
	assert_eq(_presenter._dialogue_gen, replacement_gen[0])
	assert_eq(_presenter._playback_queue_gen, replacement_queue_gen[0],
		"retired kickoff cannot steal the replacement voice queue generation")
	assert_eq(_presenter._dialogue_segments, replacement_segments)
	assert_eq(_presenter._dialogue_voice_character, "replacement")
	assert_eq(_presenter._current_voice, "narration_002")
	assert_eq(_text_label(_presenter).text,
		"Replacement owns the voice generation")
	assert_not_null(_presenter._active_stla_mode_profile)
	if _presenter._active_stla_mode_profile != null:
		assert_not_null(
			_presenter._active_stla_mode_profile.resolve_advance_indicator_scene())
	assert_eq(voice_plays, [["narration_002", "replacement"]],
		"only the replacement generation may reach public voice_play")
	assert_not_null(indicator)
	if indicator != null:
		assert_not_null(
			indicator.get_node_or_null("SyntheticAdvanceIndicator"))

	SignalBus.dialogue_voice_started.disconnect(on_voice_started)
	SignalBus.voice_play.disconnect(on_voice_play)
	SignalBus.emit_advance_requested()


func test_indicator_ready_hook_cannot_overwrite_reentrant_show() -> void:
	var did_replace := [false]
	var replacement_segments := [_segment("Replacement from ready hook")]
	INDICATOR_SCENE_SCRIPT.ready_callback = func(ready: bool):
		if ready or did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue(
			"", replacement_segments, "adv", _texture_profile(), true)
	var retired_profile := _scene_profile()
	retired_profile["advance_indicator_offset"] = Vector2(41.0, 42.0)

	SignalBus.emit_show_dialogue(
		"", [_segment("Retired ready hook configuration")], "adv",
		retired_profile, true)
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	assert_true(did_replace[0])
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var indicator := await _wait_for_indicator(_presenter)
	if indicator == null:
		return
	assert_eq(_text_label(_presenter).text, "Replacement from ready hook")
	assert_eq(_presenter._dialogue_segments, replacement_segments)
	assert_eq(_presenter._advance_indicator_offset, INDICATOR_OFFSET,
		"retired configure cannot publish its offset after a custom hook reenters")
	assert_null(indicator.get_node_or_null("SyntheticAdvanceIndicator"),
		"replacement texture source must survive the retired custom configure")


func test_hard_hide_hook_cannot_clear_reentrant_show() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Before reentrant hard hide", "adv", _scene_profile())
	if indicator == null:
		return
	var did_replace := [false]
	var replacement_segments := [_segment("Replacement during hard hide")]
	INDICATOR_SCENE_SCRIPT.ready_callback = func(ready: bool):
		if ready or did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue(
			"", replacement_segments, "adv", _texture_profile(), true)

	_presenter._ctrl_held = true
	SignalBus.hide_dialogue.emit()
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	assert_true(did_replace[0])
	assert_false(_presenter._ctrl_held)
	assert_true(_presenter.visible,
		"the replacement SHOW wins over the retired hard-hide callback")
	assert_eq(_presenter._dialogue_segments, replacement_segments)
	assert_eq(_text_label(_presenter).text, "Replacement during hard hide")
	if not await _wait_for_typing_to_finish(_presenter):
		return
	var replacement := await _wait_for_indicator(_presenter)
	if replacement != null:
		assert_true(replacement.visible)


func test_advance_during_owned_voice_emit_blocks_retired_audio_tail() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_advance := [false]
	var on_voice_play := func(asset: String, _character: String):
		if did_advance[0] or asset != "narration_001":
			return
		did_advance[0] = true
		SignalBus.emit_advance_requested()
	SignalBus.voice_play.connect(on_voice_play)
	var late_audio: Node = AUDIO_PRESENTER_SCRIPT.new()
	add_child_autoqfree(late_audio)
	await get_tree().process_frame
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Advance retires this voice before later consumers",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	SignalBus.voice_play.disconnect(on_voice_play)

	assert_true(did_advance[0])
	assert_false(_presenter._playback_queue_active)
	assert_null(late_audio._voice_player.stream,
		"AudioPresenter connected after the advance listener rejects retired audio")


func test_owned_voice_tail_cannot_restart_retired_audio() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var replacement_segments: Array = [{
		"text": "Replacement audio remains authoritative",
		"voice": "narration_002",
		"expression": "",
	}]
	var did_replace := [false]
	var on_voice_play := func(asset: String, _character: String):
		if did_replace[0] or asset != "narration_001":
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue(
			"replacement", replacement_segments, "adv",
			_texture_profile(), true)
	SignalBus.voice_play.connect(on_voice_play)
	var audio_presenter := StellaRuntime.get_node("AudioPresenter")
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Retired audio must not restart after replacement",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _scene_profile(), true)
	SignalBus.voice_play.disconnect(on_voice_play)

	assert_true(did_replace[0])
	assert_eq(_presenter._dialogue_segments, replacement_segments)
	assert_eq(audio_presenter._current_voice_character, "replacement")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(
			audio_presenter._voice_player.stream.resource_path.ends_with(
				"narration_002.wav"),
			"the canonical AudioPresenter retains replacement audio",
		)
	SignalBus.emit_advance_requested()


func test_same_dialogue_replay_retires_the_previous_voice_tail() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_replay := [false]
	var on_voice_play := func(asset: String, _character: String):
		if did_replay[0] or asset != "narration_001":
			return
		did_replay[0] = true
		SignalBus.dialogue_voice_replay_requested.emit(
			["narration_002"], "replay")
	SignalBus.voice_play.connect(on_voice_play)
	var audio_presenter := StellaRuntime.get_node("AudioPresenter")
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Replay takes ownership without changing the dialogue",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	SignalBus.voice_play.disconnect(on_voice_play)

	assert_true(did_replay[0])
	assert_eq(_presenter._dialogue_gen,
		_presenter._playback_owner_dialogue_gen)
	assert_eq(audio_presenter._current_voice_character, "replay")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(
			audio_presenter._voice_player.stream.resource_path.ends_with(
				"narration_002.wav"),
			"same-line replay queue must suppress the retired voice signal tail",
		)
	SignalBus.emit_advance_requested()


func test_hide_during_compat_voice_notification_retires_dialogue_queue() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_hide := [false]
	var on_voice_play := func(asset: String, _character: String):
		if did_hide[0] or asset != "narration_001":
			return
		did_hide[0] = true
		SignalBus.hide_dialogue.emit()
	SignalBus.voice_play.connect(on_voice_play)
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Hide retires this voice before later consumers",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	SignalBus.voice_play.disconnect(on_voice_play)

	assert_true(did_hide[0])
	assert_false(_presenter.visible)
	assert_false(_presenter._playback_queue_active)
	SignalBus.emit_advance_requested()


func test_direct_raw_voice_remains_legacy_compatible() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var audio_presenter := StellaRuntime.get_node("AudioPresenter")

	# Public raw voice requests outside a Presenter-owned frame retain their
	# established behavior for extensions and command handlers.
	SignalBus.voice_play.emit("narration_001", "raw")

	assert_eq(audio_presenter._current_voice_character, "raw")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(audio_presenter._voice_player.stream.resource_path.ends_with(
			"narration_001.wav"))
	SignalBus.emit_advance_requested()


func test_nested_raw_different_voice_remains_legacy_compatible() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var did_emit_raw := [false]
	var on_voice_play := func(asset: String, _character: String):
		if did_emit_raw[0] or asset != "narration_001":
			return
		did_emit_raw[0] = true
		SignalBus.voice_play.emit("narration_002", "raw")
		SignalBus.hide_dialogue.emit()
	SignalBus.voice_play.connect(on_voice_play)
	var audio_presenter := StellaRuntime.get_node("AudioPresenter")
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue("retired", [{
		"text": "Nested raw voice remains public",
		"voice": "narration_001",
		"expression": "",
	}], "adv", _texture_profile(), true)
	SignalBus.voice_play.disconnect(on_voice_play)

	assert_true(did_emit_raw[0])
	assert_eq(audio_presenter._current_voice_character, "raw")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(audio_presenter._voice_player.stream.resource_path.ends_with(
			"narration_002.wav"))
	SignalBus.emit_advance_requested()


func test_empty_raw_show_does_not_retire_the_active_owned_queue() -> void:
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var voice_plays: Array[String] = []
	var on_voice_play := func(asset: String, _character: String):
		voice_plays.append(asset)
	SignalBus.voice_play.connect(on_voice_play)
	var segments: Array = [
		{
			"text": "First segment. ",
			"voice": "narration_001",
			"expression": "",
		},
		{
			"text": "Second segment.",
			"voice": "narration_002",
			"expression": "",
		},
	]
	SignalBus.emit_show_dialogue(
		"sakura", segments, "adv", _texture_profile(), true)
	var owner_gen: int = _presenter._dialogue_gen
	var queue_gen: int = _presenter._playback_queue_gen
	assert_eq(voice_plays, ["narration_001"])

	# Empty SHOW remains the established no-op. It may pass through the public
	# signal hook, but cannot invalidate the presenter's accepted line owner.
	SignalBus.show_dialogue.emit("", [], "adv")
	assert_eq(_presenter._dialogue_gen, owner_gen)
	assert_eq(_presenter._playback_queue_gen, queue_gen)
	assert_true(_presenter._playback_queue_active)

	# An unrelated raw FINISH cannot complete an accepted typed playback.
	SignalBus.voice_finished.emit()
	assert_eq(voice_plays, ["narration_001"])
	var audio_presenter := StellaRuntime.get_node("AudioPresenter")
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	assert_eq(voice_plays, ["narration_001", "narration_002"])
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	assert_false(_presenter._playback_queue_active)
	assert_true(await _wait_for_typing_to_finish(_presenter),
		"the accepted line still reaches its natural ready boundary")
	SignalBus.voice_play.disconnect(on_voice_play)
	SignalBus.emit_advance_requested()


func test_profile_ready_hook_cannot_overwrite_reentrant_show() -> void:
	var indicator := await _show_and_wait_for_indicator(
		_presenter, "Ready before fallback replacement", "adv", _scene_profile())
	if indicator == null:
		return
	var did_replace := [false]
	var replacement_gen := [-1]
	var replacement_segments := [_segment("Replacement during fallback swap")]
	INDICATOR_SCENE_SCRIPT.ready_callback = func(ready: bool):
		if ready or did_replace[0]:
			return
		did_replace[0] = true
		SignalBus.emit_show_dialogue(
			"", replacement_segments, "adv", _texture_profile(), true)
		replacement_gen[0] = _presenter._dialogue_gen
	var fallback_mode := DialogueModeProfile.new()
	fallback_mode.override_panel_modulate = true
	fallback_mode.panel_modulate = Color(0.2, 0.3, 0.4, 1.0)
	var fallback_profile := DialoguePresentationProfile.new()
	fallback_profile.adv = fallback_mode

	_presenter.set_presentation_profile(fallback_profile)
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	assert_true(did_replace[0])
	assert_eq(_presenter._dialogue_gen, replacement_gen[0])
	assert_eq(_presenter._dialogue_segments, replacement_segments)
	assert_eq(_text_label(_presenter).text, "Replacement during fallback swap")
	assert_eq(_presenter._indicator_candidate_dialogue_gen, replacement_gen[0])
	assert_null(_presenter.presentation_profile,
		"the retired fallback setter must not commit after reentrant SHOW")
	assert_not_null(_presenter._active_stla_mode_profile)
	if _presenter._active_stla_mode_profile != null:
		assert_not_null(
			_presenter._active_stla_mode_profile.resolve_advance_indicator_texture())
	assert_eq(_presenter._advance_indicator_offset, INDICATOR_OFFSET)
	assert_null(indicator.get_node_or_null("SyntheticAdvanceIndicator"),
		"the replacement texture source survives the retired fallback setter")


func test_same_generation_resource_layout_swap_keeps_stla_indicator_config() -> void:
	var replacement_mode := DialogueModeProfile.new()
	replacement_mode.override_panel_modulate = true
	replacement_mode.panel_modulate = Color(0.3, 0.4, 0.5, 1.0)
	var replacement_profile := DialoguePresentationProfile.new()
	replacement_profile.adv = replacement_mode
	var did_swap := [false]
	INDICATOR_SCENE_SCRIPT.ready_callback = func(ready: bool):
		if ready or did_swap[0]:
			return
		did_swap[0] = true
		_presenter.set_presentation_profile(replacement_profile)

	SignalBus.emit_show_dialogue(
		"", [_segment("Same-generation resource layout swap")], "adv",
		_scene_profile(), true)
	INDICATOR_SCENE_SCRIPT.ready_callback = Callable()
	assert_true(did_swap[0])
	assert_same(_presenter.presentation_profile, replacement_profile)
	assert_eq(_presenter._advance_indicator_offset, INDICATOR_OFFSET)
	assert_not_null(_presenter._advance_indicator)
	if _presenter._advance_indicator != null:
		assert_true(_presenter._advance_indicator._source is PackedScene,
			"Resource layout cannot replace the canonical STLA source")
	var completed := await _wait_for_typing_to_finish(_presenter)
	if completed:
		assert_not_null(await _wait_for_indicator(_presenter))


func test_first_indicator_add_child_keeps_stla_source_during_layout_swap() -> void:
	var replacement_mode := DialogueModeProfile.new()
	replacement_mode.override_panel_modulate = true
	replacement_mode.panel_modulate = Color(0.3, 0.4, 0.5, 1.0)
	var replacement_profile := DialoguePresentationProfile.new()
	replacement_profile.adv = replacement_mode
	var did_swap := [false]
	var on_child_entered := func(child: Node):
		if did_swap[0] or child.name != "AdvanceIndicator":
			return
		did_swap[0] = true
		_presenter.set_presentation_profile(replacement_profile)
	_presenter.child_entered_tree.connect(on_child_entered)

	SignalBus.emit_show_dialogue(
		"", [_segment("First holder reentrant layout swap")], "adv",
		_scene_profile(), true)
	_presenter.child_entered_tree.disconnect(on_child_entered)
	assert_true(did_swap[0])
	assert_same(_presenter.presentation_profile, replacement_profile)
	assert_eq(_presenter._advance_indicator_offset, INDICATOR_OFFSET)
	assert_not_null(_presenter._advance_indicator)
	if _presenter._advance_indicator != null:
		assert_true(_presenter._advance_indicator._source is PackedScene,
			"add_child reentrancy keeps the STLA indicator source")


func test_nested_same_payload_raw_high_voice_events_keep_raw_identity() -> void:
	var bus: Node = SIGNAL_BUS_SCRIPT.new()
	var start_owner := [true]
	var start_reentered := [false]
	var start_currentness: Array[bool] = []
	bus.dialogue_voice_started.connect(func(duration: float):
		if start_reentered[0]:
			return
		start_reentered[0] = true
		start_owner[0] = false
		bus.dialogue_voice_started.emit(duration))
	bus.dialogue_voice_started.connect(func(duration: float):
		start_currentness.append(
			bus.dialogue_voice_started_event_is_current(duration, 7201)))
	bus.emit_owned_dialogue_voice_started(
		2.5, func(): return start_owner[0])
	assert_eq(start_currentness, [true, false],
		"nested raw high-level START stays current; retired outer does not")

	var finish_owner := [true]
	var finish_reentered := [false]
	var finish_currentness: Array[bool] = []
	bus.dialogue_voice_finished.connect(func():
		if finish_reentered[0]:
			return
		finish_reentered[0] = true
		finish_owner[0] = false
		bus.dialogue_voice_finished.emit())
	bus.dialogue_voice_finished.connect(func():
		finish_currentness.append(
			bus.dialogue_voice_finished_event_is_current(7202)))
	bus.emit_owned_dialogue_voice_finished(func(): return finish_owner[0])
	assert_eq(finish_currentness, [true, false],
		"no-argument high-level FINISH also restores the outer identity")
	bus.free()


func test_nested_same_payload_raw_voice_is_a_distinct_typed_request() -> void:
	var bus: Node = SIGNAL_BUS_SCRIPT.new()
	var reentered := [false]
	var ownership: Array[bool] = []
	bus.voice_playback_requested.connect(func(request: VoicePlaybackRequest):
		ownership.append(request.owner_validator.is_valid()))
	bus.voice_play.connect(func(asset: String, character: String):
		if reentered[0]:
			return
		reentered[0] = true
		bus.voice_play.emit(asset, character))

	bus.request_voice_playback(
		"same_asset", "sakura", func(): return true)
	assert_eq(ownership, [true, false],
		"the raw adapter creates a separate unowned typed request")
	bus.free()


func test_ready_toolbar_reflects_already_active_public_controllers() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	StellaRuntime.auto_play.is_active = true
	StellaRuntime.skip_controller.is_active = true
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame

	assert_not_null(_presenter._auto_btn)
	assert_not_null(_presenter._skip_btn)
	if _presenter._auto_btn != null:
		assert_eq(_presenter._auto_btn.modulate, Color.YELLOW)
	if _presenter._skip_btn != null:
		assert_eq(_presenter._skip_btn.modulate, Color.YELLOW)


func test_scene_custom_effect_tags_share_visual_and_backlog_scanning() -> void:
	if is_instance_valid(_presenter):
		_presenter.queue_free()
		await get_tree().process_frame
	_presenter = FIXTURE.instantiate()
	_configure_fixed_text_layout(_presenter)
	var label := _text_label(_presenter)
	label.bbcode_enabled = true
	label.custom_effects = [SyntheticCustomEffect.new()]
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	StellaRuntime.backlog_manager.clear()
	var source := "[custom]A[/custom][custom=2]B[/custom]"

	SignalBus.show_dialogue.emit("sakura", [_segment(source)], "adv")
	assert_true(await _wait_for_typing_to_finish(_presenter))
	assert_eq(_presenter._avatar_expressions.get("sakura", "default"), "default",
		"bare and valued custom effect tags are not expression markers")
	assert_eq(label.get_parsed_text(), "A[custom=2]B[/custom]",
		"Godot applies bare custom BBCode and displays its invalid main-value form")
	# Exercise BacklogManager's explicit per-request effect registry directly.
	StellaRuntime.backlog_manager.clear()
	StellaRuntime.backlog_manager.add_entry(
		"sakura", [_segment(source)], 154001, Callable(), ["custom"])
	var entries: Array = StellaRuntime.backlog_manager.get_entries()
	assert_eq(entries.size(), 1)
	if entries.size() == 1:
		assert_eq(entries[0].get("text"), "A[custom=2]B[/custom]",
			"Backlog mirrors RichTextLabel's custom-effect parsing")


func _texture_profile(animation: String = "none") -> Dictionary:
	return {
		"advance_indicator_texture": INDICATOR_TEXTURE_PATH,
		"advance_indicator_scene": "",
		"advance_indicator_offset": INDICATOR_OFFSET,
		"advance_indicator_animation": animation,
	}


func _scene_profile(animation: String = "none") -> Dictionary:
	return {
		"advance_indicator_texture": "",
		"advance_indicator_scene": INDICATOR_SCENE_PATH,
		"advance_indicator_offset": INDICATOR_OFFSET,
		"advance_indicator_animation": animation,
	}


func _segment(text: String) -> Dictionary:
	return {"text": text, "voice": "", "expression": ""}


func _show_and_wait_for_indicator(
	presenter: Control,
	text: String,
	mode: String,
	profile: Dictionary,
	nvl_page_key: String = "",
) -> CanvasItem:
	SignalBus.emit_show_dialogue(
		"", [_segment(text)], mode, profile, true, nvl_page_key)
	if not await _wait_for_typing_to_finish(presenter):
		return null
	return await _wait_for_indicator(presenter)


func _wait_for_typing_to_finish(presenter: Control) -> bool:
	# Cross the presenter's first layout/typewriter boundary before polling. SHOW
	# itself already establishes active/not-ready synchronously.
	await get_tree().process_frame
	var completed: bool = await wait_until(
		func():
			return (
				is_instance_valid(presenter)
				and not presenter._is_typing
				and _text_label(presenter).visible_characters == -1
			),
		2.0,
		"dialogue typewriter reaches its ready boundary",
	)
	assert_true(completed, "dialogue typewriter reaches its ready boundary")
	return completed


func _wait_for_indicator(presenter: Control) -> CanvasItem:
	# Endpoint placement is layout-driven and may wait for RichTextLabel.draw.
	var appeared: bool = await wait_until(
		func():
			var node := presenter.get_node_or_null("AdvanceIndicator") as CanvasItem
			return node != null and node.visible and node.is_visible_in_tree(),
		1.0,
		"configured advance indicator becomes visible",
	)
	assert_true(appeared,
		"a configured profile must create and show AdvanceIndicator")
	if not appeared:
		return null
	return presenter.get_node("AdvanceIndicator") as CanvasItem


func _indicator_nodes(presenter: Control) -> Array[Node]:
	var result: Array[Node] = []
	for node in presenter.find_children("AdvanceIndicator", "CanvasItem", true, false):
		result.append(node)
	return result


func _text_label(presenter: Control) -> RichTextLabel:
	return presenter.get_node("%TextLabel") as RichTextLabel


func _canvas_global_position(item: CanvasItem) -> Vector2:
	if item is Control:
		return (item as Control).global_position
	if item is Node2D:
		return (item as Node2D).global_position
	return Vector2(INF, INF)


func _canvas_local_position(item: CanvasItem) -> Vector2:
	if item is Control:
		return (item as Control).position
	if item is Node2D:
		return (item as Node2D).position
	return Vector2(INF, INF)


func _first_canvas_child(item: CanvasItem) -> CanvasItem:
	for child in item.get_children():
		if child is CanvasItem:
			return child as CanvasItem
	return item


func _press_toolbar_skip(presenter: Control) -> bool:
	var toolbar_node := presenter.get_node("%Toolbar")
	for child in toolbar_node.get_children():
		if child is Button and (child as Button).text == "快进":
			(child as Button).pressed.emit()
			return true
	assert_true(false, "synthetic presenter exposes its toolbar skip button")
	return false


func _assert_indicator_at_last_line(
	label: RichTextLabel,
	indicator: CanvasItem,
	offset: Vector2,
) -> void:
	var last_line := label.get_line_count() - 1
	assert_gte(last_line, 0)
	if last_line < 0:
		return
	var marker_position := _canvas_global_position(indicator)
	var expected_x := (
		label.global_position.x + label.get_line_width(last_line) + offset.x)
	var line_top := (
		label.global_position.y + label.get_line_offset(last_line) + offset.y)
	var line_bottom := line_top + label.get_line_height(last_line)
	assert_almost_eq(marker_position.x, expected_x, 2.0,
		"marker x follows the rendered width of the final RichTextLabel line")
	assert_true(
		marker_position.y >= line_top - 2.0
		and marker_position.y <= line_bottom + 2.0,
		"marker y stays on the final rendered line using RichTextLabel metrics",
	)


func _expected_aligned_endpoint_x(
	label: RichTextLabel,
	alignment: int,
	offset_x: float,
) -> float:
	var normal_style := label.get_theme_stylebox(&"normal")
	var paragraph_width := label.size.x - normal_style.get_minimum_size().x
	var scroll_bar := label.get_v_scroll_bar()
	if scroll_bar.visible:
		paragraph_width -= scroll_bar.get_combined_minimum_size().x
	var line_width := float(label.get_line_width(label.get_line_count() - 1))
	var local_x := normal_style.get_offset().x + line_width
	if alignment == HORIZONTAL_ALIGNMENT_CENTER:
		local_x += floorf((paragraph_width - line_width) / 2.0)
	elif alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		local_x = normal_style.get_offset().x + paragraph_width
	return label.global_position.x + local_x + offset_x


func _configure_fixed_text_layout(presenter: Control) -> void:
	# Exact font pixels are intentionally not asserted, but a fixed narrow label
	# makes wrapping and relative line movement deterministic in headless runs.
	presenter.anchor_left = 0.0
	presenter.anchor_top = 0.0
	presenter.anchor_right = 0.0
	presenter.anchor_bottom = 0.0
	presenter.offset_left = 0.0
	presenter.offset_top = 0.0
	presenter.offset_right = 320.0
	presenter.offset_bottom = 220.0
	var region := presenter.get_node("TextRegion") as Control
	region.anchor_left = 0.0
	region.anchor_top = 0.0
	region.anchor_right = 0.0
	region.anchor_bottom = 0.0
	region.offset_left = 20.0
	region.offset_top = 10.0
	region.offset_right = 180.0
	region.offset_bottom = 200.0
	var label := region.get_node("TextLabel") as RichTextLabel
	label.anchor_left = 0.0
	label.anchor_top = 0.0
	label.anchor_right = 0.0
	label.anchor_bottom = 0.0
	label.offset_left = 0.0
	label.offset_top = 30.0
	label.offset_right = 96.0
	label.offset_bottom = 170.0
	label.custom_minimum_size = Vector2.ZERO
	label.fit_content = false
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	label.add_theme_font_size_override("normal_font_size", 16)
