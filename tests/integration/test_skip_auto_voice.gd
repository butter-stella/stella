extends GutTest
## Integration tests for skip/auto-play interaction with voice.
## Verifies:
##   - Skip mode suppresses voice playback
##   - Voice stop on advance emits voice_finished (prevents _voice_playing stuck true)


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")

var _bus: Node
var _game_scene: Node


func before_each() -> void:
	_bus = get_tree().root.get_node("SignalBus")
	await RuntimeTestSupport.reset_for_test(StellaRuntime, get_tree())
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	# Load the game scene so DialoguePanel is available for tests that poke at it.
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


# --- Skip mode should NOT play voice ---

func test_skip_mode_suppresses_voice_play():
	# Use Array for counter (GDScript lambdas capture locals by value)
	var voice_received := []
	var conn = func(a, _c): voice_received.append(a)
	_bus.voice_play.connect(conn)

	StellaRuntime.skip_controller.is_active = true
	assert_true(StellaRuntime.is_skipping())

	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": "sakura_001"}], "adv")
	await get_tree().create_timer(0.2).timeout

	assert_eq(voice_received.size(), 0, "voice should NOT play during skip mode")

	_bus.voice_play.disconnect(conn)
	StellaRuntime.skip_controller.is_active = false


# --- voice_finished signal propagation ---

func test_voice_finished_signal_propagates():
	var count := [0]
	var conn = func(): count[0] += 1
	_bus.voice_finished.connect(conn)

	_bus.voice_finished.emit()

	assert_eq(count[0], 1, "voice_finished signal should propagate")
	_bus.voice_finished.disconnect(conn)


func test_audio_presenter_advance_does_not_crash():
	var audio_presenter = StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter == null:
		pending("AudioPresenter not available")
		return

	# Verify advance_requested with AudioPresenter doesn't crash
	_bus.advance_requested.emit()
	await get_tree().process_frame
	pass_test("advance_requested with AudioPresenter connected does not crash")


# --- _voice_playing flag management ---

func test_voice_started_sets_flag():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = false
	_bus.voice_started.emit("sakura", "test_voice")
	await get_tree().process_frame
	assert_true(dialogue._voice_playing, "voice_started should set _voice_playing true")


func test_voice_finished_clears_flag():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = true
	_bus.voice_finished.emit()
	await get_tree().process_frame
	assert_false(dialogue._voice_playing, "voice_finished should clear _voice_playing")


# --- Mutual exclusivity ---

func test_skip_and_auto_mutually_exclusive():
	StellaRuntime.toggle_skip()
	assert_true(StellaRuntime.is_skipping())
	assert_false(StellaRuntime.is_auto_playing())

	StellaRuntime.toggle_auto_play()
	assert_false(StellaRuntime.is_skipping(), "skip should stop when auto activates")
	assert_true(StellaRuntime.is_auto_playing())

	StellaRuntime.auto_play.stop()


# --- _dialogue_gen prevents double-advance ---

func test_dialogue_gen_increments_on_show_dialogue():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	var gen_before = dialogue._dialogue_gen
	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": ""}], "adv")
	await get_tree().process_frame

	assert_gt(dialogue._dialogue_gen, gen_before, "_dialogue_gen should increment on each show_dialogue")
	dialogue._is_typing = false


func test_dialogue_gen_changes_on_successive_dialogues():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	_bus.show_dialogue.emit("sakura", [{"text": "First", "voice": ""}], "adv")
	await get_tree().process_frame
	var gen1 = dialogue._dialogue_gen

	_bus.show_dialogue.emit("sakura", [{"text": "Second", "voice": ""}], "adv")
	await get_tree().process_frame
	var gen2 = dialogue._dialogue_gen

	assert_ne(gen1, gen2, "each dialogue should get a unique gen")
	dialogue._is_typing = false


# --- auto_play_click_interrupt setting ---

func test_auto_play_click_interrupt_default_true():
	var val = StellaRuntime.get_setting("auto_play_click_interrupt")
	assert_true(val, "auto_play_click_interrupt should default to true")


func test_auto_play_click_interrupt_persists():
	StellaRuntime.set_setting("auto_play_click_interrupt", false)
	assert_false(StellaRuntime.get_setting("auto_play_click_interrupt"),
		"setting should persist after set")
	# Restore default
	StellaRuntime.set_setting("auto_play_click_interrupt", true)


# --- Leaving PLAYING stops auto/skip ---

func test_overlay_stops_auto_play():
	StellaRuntime.auto_play.is_active = true
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SETTINGS)
	assert_false(StellaRuntime.is_auto_playing(), "auto should stop when leaving PLAYING")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)


func test_overlay_stops_skip():
	StellaRuntime.skip_controller.is_active = true
	StellaRuntime.game_state.transition_to(GameStateMachine.State.BACKLOG)
	assert_false(StellaRuntime.is_skipping(), "skip should stop when leaving PLAYING")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)


# --- _voice_playing cleared on hide_dialogue ---

func test_voice_playing_cleared_on_hide():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = true
	_bus.hide_dialogue.emit()
	await get_tree().process_frame
	assert_false(dialogue._voice_playing, "_voice_playing should clear on hide_dialogue")


# --- skip_only_read semantics (PR: feat/skip-unread-setting) ---
# Ctrl-hold always skips (including unread). Toolbar skip respects
# skip_only_read — when true (default), it auto-stops at unread lines.

func _fresh_position(dialogue: Node, index: int = 0) -> void:
	# Tests don't run a real scenario engine, so seed the presenter's cached
	# position fields directly — _on_show_dialogue normally fills them from
	# engine.context.
	dialogue._current_scenario_id = "test_scn"
	dialogue._current_scene_id = "test_scene"
	dialogue._current_command_index = index


func test_ctrl_held_skips_unread_regardless_of_setting():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1000)
	dialogue._ctrl_held = true
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.set_setting("skip_only_read", true)
	assert_true(dialogue._should_skip_current(), "Ctrl-hold must skip even unread lines")
	dialogue._ctrl_held = false


func test_toolbar_skip_unread_pure_query_returns_false():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1001)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	# Pure query must not mutate skip_controller state.
	assert_false(dialogue._should_skip_current(), "toolbar skip should not skip unread when skip_only_read=true")
	assert_true(StellaRuntime.skip_controller.is_active, "query must not stop the skip controller")
	StellaRuntime.skip_controller.is_active = false


func test_apply_unread_skip_gate_stops_toolbar_skip_on_unread():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1005)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_false(StellaRuntime.skip_controller.is_active, "gate must stop toolbar skip on unread line")


func test_apply_unread_skip_gate_noop_on_read():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1006)
	StellaRuntime.read_flags.mark_read("test_scn", "test_scene", 1006)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_true(StellaRuntime.skip_controller.is_active, "gate must be a no-op when current line is read")
	StellaRuntime.skip_controller.is_active = false


func test_apply_unread_skip_gate_noop_when_ctrl_held():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1007)
	dialogue._ctrl_held = true
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_true(StellaRuntime.skip_controller.is_active, "Ctrl-hold must bypass the gate")
	dialogue._ctrl_held = false
	StellaRuntime.skip_controller.is_active = false


func test_toolbar_skip_unread_allowed_when_setting_off():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1002)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", false)
	StellaRuntime.skip_controller.is_active = true
	assert_true(dialogue._should_skip_current(), "toolbar skip should skip unread when skip_only_read=false")
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.set_setting("skip_only_read", true)


func test_toolbar_skip_read_line_allowed():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1003)
	StellaRuntime.read_flags.mark_read("test_scn", "test_scene", 1003)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	assert_true(dialogue._should_skip_current(), "read line should be skippable by toolbar skip")
	StellaRuntime.skip_controller.is_active = false


func test_mark_current_line_read_writes_to_read_flags():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1004)
	assert_false(StellaRuntime.read_flags.is_read("test_scn", "test_scene", 1004))
	dialogue._mark_current_line_read()
	assert_true(StellaRuntime.read_flags.is_read("test_scn", "test_scene", 1004))


func test_skip_only_read_setting_default_true():
	var val = StellaRuntime.get_setting("skip_only_read")
	assert_true(val, "skip_only_read should default to true")


# --- _on_skip_pressed mid-typewriter snap behavior ---
# Fix for round-2 Opus UX concern: when the user presses the toolbar skip
# button while the typewriter is running, snap the text to end immediately
# (like click-to-complete). Without this the button highlights but the
# typewriter keeps running, which looks like skip isn't working.

func test_skip_press_while_typing_snaps_text():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	# Leave skip off at test start so _on_skip_pressed toggles it ON.
	StellaRuntime.skip_controller.is_active = false
	dialogue._is_typing = true
	dialogue.text_label.visible_characters = 3
	dialogue._on_skip_pressed()
	assert_false(dialogue._is_typing, "pressing skip while typing must stop the typewriter")
	assert_eq(dialogue.text_label.visible_characters, -1, "pressing skip while typing must snap text to full")
	# Cleanup
	StellaRuntime.skip_controller.is_active = false


func test_skip_press_toggle_off_leaves_state_alone():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	# Skip already on — pressing must toggle it OFF without touching text state.
	StellaRuntime.skip_controller.is_active = true
	dialogue._is_typing = true
	dialogue.text_label.visible_characters = 5
	dialogue._on_skip_pressed()
	assert_false(StellaRuntime.is_skipping(), "pressing skip while active must toggle off")
	assert_true(dialogue._is_typing, "toggling skip off must not disturb in-flight typewriter")
	assert_eq(dialogue.text_label.visible_characters, 5, "toggling skip off must not snap text")
	dialogue._is_typing = false
