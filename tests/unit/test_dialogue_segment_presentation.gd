extends GutTest
## Per-segment visual changes for voiced @combine dialogue.

var _game_scene: Node
var _dialogue: Control
var _original_backgrounds_path: String
var _original_characters_path: String
var _original_voice_path: String
var _original_skip_active: bool
var _original_auto_active: bool
var _original_character_voice_enabled: Dictionary
var _original_auto_wait_voice: bool
var _original_auto_delay: float


func before_each():
	_original_backgrounds_path = StellaRuntime.backgrounds_path
	_original_characters_path = StellaRuntime.characters_path
	_original_voice_path = StellaRuntime.voice_path
	_original_skip_active = StellaRuntime.skip_controller.is_active
	_original_auto_active = StellaRuntime.auto_play.is_active
	var enabled_setting = StellaRuntime.get_setting("character_voice_enabled")
	_original_character_voice_enabled = (
		enabled_setting.duplicate(true)
		if enabled_setting is Dictionary
		else {}
	)
	_original_auto_wait_voice = bool(
		StellaRuntime.get_setting("auto_play_wait_voice")
	)
	_original_auto_delay = float(StellaRuntime.get_setting("auto_play_delay"))
	StellaRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	StellaRuntime.characters_path = "res://examples/demo/art/characters/"
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.set_setting("character_voice_enabled", {})

	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	_dialogue._current_voice_character = "sakura"
	_dialogue._current_mode = "adv"
	_dialogue._playback_is_dialogue = false


func after_each():
	StellaRuntime.backgrounds_path = _original_backgrounds_path
	StellaRuntime.characters_path = _original_characters_path
	StellaRuntime.voice_path = _original_voice_path
	StellaRuntime.skip_controller.is_active = _original_skip_active
	StellaRuntime.auto_play.is_active = _original_auto_active
	StellaRuntime.set_setting(
		"character_voice_enabled",
		_original_character_voice_enabled,
	)
	StellaRuntime.set_setting("auto_play_wait_voice", _original_auto_wait_voice)
	StellaRuntime.set_setting("auto_play_delay", _original_auto_delay)


func _segment(
	text: String,
	voice: String,
	stage: String = "",
	avatar: String = "",
	transition: String = "cut",
	duration_ms: float = 0.0,
	expression: String = "",
) -> Dictionary:
	return {
		"text": text,
		"voice": voice,
		"stage": stage,
		"avatar": avatar,
		"transition": transition,
		"duration_ms": duration_ms,
		"expression": expression,
	}


func _prepare_queue(segment_count: int) -> void:
	_dialogue._playback_segment_durations.clear()
	for _index in range(segment_count):
		_dialogue._playback_segment_durations.append(1.0)
	_dialogue._playback_total_duration = float(segment_count)
	_dialogue._playback_played_duration = 0.0
	_dialogue._playback_aborted = false


func test_segment_presentation_applies_stage_avatar_and_expression():
	var backgrounds: Array = []
	var expressions: Array = []
	var bg_callback = func(asset, transition, duration):
		backgrounds.append([asset, transition, duration])
	var expr_callback = func(character, expression):
		expressions.append([character, expression])
	SignalBus.bg_changed.connect(bg_callback)
	SignalBus.char_expression_changed.connect(expr_callback)

	_dialogue._apply_segment_presentation(
		"sakura",
		_segment(
			"第二段",
			"clip_002",
			"bg_cafe",
			"sakura/happy",
			"fade",
			300.0,
			"happy",
		),
		false,
	)

	assert_eq(backgrounds.size(), 1)
	assert_eq(backgrounds[0][0], "bg_cafe")
	assert_eq(backgrounds[0][1], "fade")
	assert_almost_eq(float(backgrounds[0][2]), 0.3, 0.001)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")
	assert_true(
		_dialogue._avatar_texture.texture.resource_path.ends_with(
			"sakura/happy.png"
		),
	)
	assert_eq(expressions, [["sakura", "happy"]])

	SignalBus.bg_changed.disconnect(bg_callback)
	SignalBus.char_expression_changed.disconnect(expr_callback)


func test_voice_queue_applies_each_visual_before_its_voice_clip():
	var events: Array = []
	var bg_callback = func(asset, _transition, _duration):
		events.append("stage:%s" % asset)
	var voice_callback = func(asset, _character):
		events.append("voice:%s" % asset)
	SignalBus.bg_changed.connect(bg_callback)
	SignalBus.voice_play.connect(voice_callback)

	var segments := [
		_segment(
			"第一段，",
			"sakura_013",
			"bg_school_gate",
			"sakura/smile",
		),
		_segment(
			"第二段。",
			"sakura_018",
			"bg_cafe",
			"sakura/happy",
			"fade",
			300.0,
		),
	]
	_prepare_queue(segments.size())
	_dialogue._run_voice_queue(
		"sakura",
		segments,
		_dialogue._dialogue_gen,
		true,
	)

	assert_eq(events, ["stage:bg_school_gate", "voice:sakura_013"])
	assert_eq(_dialogue._current_avatar_asset, "sakura/smile")

	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	assert_eq(
		events,
		[
			"stage:bg_school_gate",
			"voice:sakura_013",
			"stage:bg_cafe",
			"voice:sakura_018",
		],
	)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	SignalBus.bg_changed.disconnect(bg_callback)
	SignalBus.voice_play.disconnect(voice_callback)


func test_old_combine_without_new_metadata_still_sequences_voice_and_expression():
	var voices: Array = []
	var expressions: Array = []
	var voice_callback = func(asset, _character): voices.append(asset)
	var expr_callback = func(_character, expression):
		expressions.append(expression)
	SignalBus.voice_play.connect(voice_callback)
	SignalBus.char_expression_changed.connect(expr_callback)

	var legacy_segments := [
		{"text": "第一段", "voice": "sakura_013", "expression": "sad"},
		{"text": "第二段", "voice": "sakura_018", "expression": "happy"},
	]
	_prepare_queue(legacy_segments.size())
	_dialogue._run_voice_queue(
		"sakura",
		legacy_segments,
		_dialogue._dialogue_gen,
		true,
	)
	assert_eq(voices, ["sakura_013"])
	assert_eq(expressions, ["sad"])

	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	assert_eq(voices, ["sakura_013", "sakura_018"])
	assert_eq(expressions, ["sad", "happy"])

	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	SignalBus.voice_play.disconnect(voice_callback)
	SignalBus.char_expression_changed.disconnect(expr_callback)


func test_click_or_skip_snaps_to_final_independent_visual_values():
	var backgrounds: Array = []
	var expressions: Array = []
	var bg_callback = func(asset, transition, duration):
		backgrounds.append([asset, transition, duration])
	var expr_callback = func(_character, expression):
		expressions.append(expression)
	SignalBus.bg_changed.connect(bg_callback)
	SignalBus.char_expression_changed.connect(expr_callback)

	var segments := [
		_segment(
			"第一段，",
			"v1",
			"bg_school_gate",
			"sakura/smile",
			"fade",
			300.0,
			"sad",
		),
		_segment("第二段，", "v2", "", "sakura/sad"),
		_segment(
			"第三段，",
			"v3",
			"bg_cafe",
			"",
			"fade",
			500.0,
			"happy",
		),
		_segment("第四段。", "v4", "", "sakura/happy"),
	]
	_dialogue._finalize_dialogue("sakura", segments)

	assert_eq(backgrounds.size(), 1, "intermediate stages must not flash")
	assert_eq(backgrounds[0][0], "bg_cafe")
	assert_eq(backgrounds[0][1], "cut", "forced completion is instantaneous")
	assert_almost_eq(float(backgrounds[0][2]), 0.0, 0.001)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")
	assert_eq(expressions, ["happy"])

	SignalBus.bg_changed.disconnect(bg_callback)
	SignalBus.char_expression_changed.disconnect(expr_callback)


func test_input_completion_applies_final_visuals_in_same_call():
	var backgrounds: Array = []
	var bg_callback = func(asset, _transition, _duration):
		backgrounds.append(asset)
	SignalBus.bg_changed.connect(bg_callback)

	_dialogue._dialogue_voice_character = "sakura"
	_dialogue._dialogue_segments = [
		_segment("第一段，", "v1", "bg_school_gate", "sakura/sad"),
		_segment("第二段。", "v2", "bg_cafe", "sakura/happy"),
	]
	_dialogue._is_typing = true
	_dialogue.text_label.visible_characters = 2

	_dialogue.complete_current_dialogue()

	assert_false(_dialogue._is_typing)
	assert_eq(_dialogue.text_label.visible_characters, -1)
	assert_eq(backgrounds, ["bg_cafe"])
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.bg_changed.disconnect(bg_callback)


func test_advance_after_typewriter_completion_preserves_final_visual_state():
	var backgrounds: Array = []
	var bg_callback = func(asset, _transition, _duration):
		backgrounds.append(asset)
	SignalBus.bg_changed.connect(bg_callback)

	_dialogue._dialogue_voice_character = "sakura"
	_dialogue._dialogue_segments = [
		_segment("第一段，", "v1", "bg_school_gate", "sakura/sad"),
		_segment("第二段。", "v2", "bg_cafe", "sakura/happy"),
	]
	_dialogue._is_typing = false
	_dialogue._segment_presentation_complete = false

	_dialogue.finalize_current_dialogue_for_advance()

	assert_eq(backgrounds, ["bg_cafe"])
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	backgrounds.clear()
	_dialogue.finalize_current_dialogue_for_advance()
	assert_eq(backgrounds, [], "an already-finalized dialogue must not flash again")

	SignalBus.bg_changed.disconnect(bg_callback)


func test_advance_commits_final_stage_while_its_transition_may_still_run():
	var backgrounds: Array = []
	var bg_callback = func(asset, transition, duration):
		backgrounds.append([asset, transition, duration])
	SignalBus.bg_changed.connect(bg_callback)

	var segments := [
		_segment("第一段，", "", "bg_school_gate", "sakura/sad"),
		_segment(
			"第二段。",
			"",
			"bg_cafe",
			"sakura/happy",
			"fade",
			1000.0,
		),
	]
	_dialogue._dialogue_voice_character = "sakura"
	_dialogue._dialogue_segments = segments
	_prepare_queue(segments.size())
	# Missing/disabled voice makes the queue apply both segments immediately,
	# while the final background transition itself remains asynchronous.
	_dialogue._playback_segment_durations.fill(0.0)
	_dialogue._playback_total_duration = 0.0
	_dialogue._run_voice_queue(
		"sakura",
		segments,
		_dialogue._dialogue_gen,
		true,
	)

	assert_eq(backgrounds.size(), 2)
	assert_eq(backgrounds[1], ["bg_cafe", "fade", 1.0])
	assert_false(
		_dialogue._segment_presentation_complete,
		"starting the final tween must not mark its endpoint committed",
	)

	_dialogue.finalize_current_dialogue_for_advance()

	assert_eq(backgrounds.size(), 3)
	assert_eq(
		backgrounds[2],
		["bg_cafe", "cut", 0.0],
		"advance must commit the final stage synchronously",
	)
	assert_true(_dialogue._segment_presentation_complete)

	SignalBus.bg_changed.disconnect(bg_callback)


func test_skip_queue_does_not_flash_intermediate_visuals():
	var backgrounds: Array = []
	var bg_callback = func(asset, _transition, _duration):
		backgrounds.append(asset)
	SignalBus.bg_changed.connect(bg_callback)

	var segments := [
		_segment("第一段，", "v1", "bg_school_gate", "sakura/sad"),
		_segment("第二段。", "v2", "bg_cafe", "sakura/happy"),
	]
	StellaRuntime.skip_controller.is_active = true
	_prepare_queue(segments.size())
	_dialogue._run_voice_queue(
		"sakura",
		segments,
		_dialogue._dialogue_gen,
		true,
	)
	assert_eq(backgrounds, [], "skip queue must not play intermediate visuals")

	_dialogue._finalize_dialogue("sakura", segments)
	assert_eq(backgrounds, ["bg_cafe"])
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.bg_changed.disconnect(bg_callback)


func test_toolbar_and_backlog_replay_never_apply_visual_metadata():
	var backgrounds: Array = []
	var bg_callback = func(asset, _transition, _duration):
		backgrounds.append(asset)
	SignalBus.bg_changed.connect(bg_callback)

	_dialogue._current_avatar_asset = "sakura/smile"
	_dialogue._dialogue_segments = [
		_segment("", "", "bg_cafe", "sakura/happy"),
	]
	_dialogue._segment_presentation_complete = false
	_dialogue._on_voice_replay_pressed()
	assert_eq(backgrounds, [])
	assert_eq(_dialogue._current_avatar_asset, "sakura/smile")

	# Replay may replace an unfinished initial queue, but advancing must still
	# preserve the authored final visual state even though replay itself is audio-only.
	_dialogue.finalize_current_dialogue_for_advance()
	assert_eq(backgrounds, ["bg_cafe"])
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	backgrounds.clear()
	_dialogue._current_avatar_asset = "sakura/smile"
	_dialogue._segment_presentation_complete = false
	_dialogue._on_dialogue_voice_replay_requested([""], "sakura")
	assert_eq(backgrounds, [])
	assert_eq(_dialogue._current_avatar_asset, "sakura/smile")

	SignalBus.bg_changed.disconnect(bg_callback)


func test_missing_voice_assets_do_not_stall_segment_queue():
	var voices: Array = []
	var voice_callback = func(asset, _character): voices.append(asset)
	SignalBus.voice_play.connect(voice_callback)

	var segments := [
		_segment("第一段，", "__missing_clip_1", "", "sakura/sad"),
		_segment("第二段。", "__missing_clip_2", "", "sakura/happy"),
	]
	_dialogue._start_voice_playback("sakura", segments, false, true)

	assert_false(_dialogue._playback_queue_active)
	assert_almost_eq(_dialogue._playback_total_duration, 0.0, 0.001)
	assert_eq(voices, [])
	assert_true(_dialogue._segment_presentation_complete)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.voice_play.disconnect(voice_callback)


func test_muted_character_voice_does_not_stall_segment_queue():
	var voices: Array = []
	var voice_callback = func(asset, _character): voices.append(asset)
	SignalBus.voice_play.connect(voice_callback)
	StellaRuntime.set_setting("character_voice_enabled", {"sakura": false})

	var segments := [
		_segment("第一段，", "sakura_013", "", "sakura/sad"),
		_segment("第二段。", "sakura_018", "", "sakura/happy"),
	]
	_dialogue._start_voice_playback("sakura", segments, false, true)

	assert_false(_dialogue._playback_queue_active)
	assert_almost_eq(_dialogue._playback_total_duration, 0.0, 0.001)
	assert_eq(voices, [])
	assert_true(_dialogue._segment_presentation_complete)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.voice_play.disconnect(voice_callback)


func test_auto_without_voice_wait_finalizes_before_advance():
	var events: Array = []
	var bg_callback = func(asset, _transition, _duration):
		events.append("stage:%s" % asset)
	var advance_callback = func(): events.append("advance")
	SignalBus.bg_changed.connect(bg_callback)
	SignalBus.advance_requested.connect(advance_callback)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	StellaRuntime.set_setting("auto_play_delay", 0.0)
	StellaRuntime.auto_play.is_active = true

	SignalBus.show_dialogue.emit("sakura", [
		_segment(
			"一",
			"sakura_013",
			"bg_school_gate",
			"sakura/sad",
		),
		_segment(
			"二",
			"sakura_018",
			"bg_cafe",
			"sakura/happy",
		),
	], "adv")

	await get_tree().create_timer(0.3).timeout
	assert_eq(
		events,
		["stage:bg_school_gate", "stage:bg_cafe", "advance"],
		"auto advance must snap final visuals before stopping the current clip",
	)
	assert_true(_dialogue._playback_aborted)
	assert_true(_dialogue._segment_presentation_complete)
	assert_eq(_dialogue._current_avatar_asset, "sakura/happy")

	SignalBus.bg_changed.disconnect(bg_callback)
	SignalBus.advance_requested.disconnect(advance_callback)
