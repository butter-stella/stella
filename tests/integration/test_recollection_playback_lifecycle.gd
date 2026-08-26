extends GutTest
## Runtime-owned recollection return lifecycle contract for issue #171.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://synthetic/recollection_lifecycle.stla"
const NORMAL_REENTRY_PATH := \
	"res://tests/fixtures/scenarios/dialogue/presentation_profile.stla"
const RECOLLECTION_REENTRY_PATH := \
	"res://examples/demo/scenarios/recollection_playback.stla"
const CONFIGURED_TITLE_PROBE := "res://addons/stella/scenes/game.tscn"
const SAVE_DIR := "user://tests/recollection_playback/"
const SAVE_SLOT := 171


class ReturnTarget extends Node:
	var runtime: Node
	var calls: Array[String]
	var normal_reentry_path := ""
	var recollection_reentry_path := ""
	var recollection_return: Callable
	var title_reentry := false

	func _init(owner: Node, call_sink: Array[String]) -> void:
		runtime = owner
		calls = call_sink

	func return_to_gallery() -> void:
		calls.append("returned")
		if title_reentry:
			runtime.return_to_title()
		elif not recollection_reentry_path.is_empty():
			runtime.start_recollection(
				recollection_reentry_path,
				recollection_return,
				"res://addons/stella/scenes/game.tscn",
			)
		elif not normal_reentry_path.is_empty():
			runtime.start_scenario(normal_reentry_path)

	func invalid_return(_value: Variant) -> void:
		pass


var _runtime: Node
var _owned_targets: Array[Node] = []
var _original_title_scene_path := ""


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.save_manager.save_dir = SAVE_DIR
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	_runtime._navigation_scene_change_override = Callable()
	_original_title_scene_path = _runtime.title_scene_path
	_owned_targets.clear()


func after_each() -> void:
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	if _runtime._navigation_scene_slot_active_serial > 0:
		_runtime._settle_navigation_scene_slot(
			_runtime._navigation_scene_slot_active_serial, false)
		await get_tree().process_frame
	_runtime._navigation_scene_change_override = Callable()
	_runtime.title_scene_path = _original_title_scene_path
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	for target: Node in _owned_targets:
		if is_instance_valid(target):
			target.free()
	_owned_targets.clear()


func _target(calls: Array[String]) -> ReturnTarget:
	var target := ReturnTarget.new(_runtime, calls)
	_owned_targets.append(target)
	return target


func _command(type: String, line: int, params: Dictionary = {}) -> CommandData:
	var command := CommandData.new()
	command.type = type
	command.params = params
	command.declared_line = line
	return command


func _scenario(
	commands: Array[CommandData],
	scenario_id: String = "recollection_lifecycle",
) -> ScenarioData:
	var data := ScenarioData.new()
	data.id = scenario_id
	data.source_path = SOURCE_PATH
	data.source_identity = ScenarioData.make_source_identity(SOURCE_PATH)
	var chapter := ChapterData.new()
	chapter.id = "memory"
	chapter.display_name = "Memory"
	chapter.scene_ids = ["start"]
	data.chapters = [chapter]
	var scene := SceneData.new()
	scene.id = "start"
	scene.chapter_id = "memory"
	scene.commands.assign(commands)
	data.scenes = [scene]
	return data


func _install_recollection(
	data: ScenarioData,
	return_continuation: Callable,
) -> Dictionary:
	var playback := ScenarioPlaybackContext.recollection(return_continuation)
	assert_true(playback.is_valid_for_entry())
	assert_true(_runtime.presentation_clip_audio_choice_authority.start_fresh_run())
	_runtime._install_scenario(data, SOURCE_PATH, playback)
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	_runtime.game_state.previous_state = GameStateMachine.State.TITLE
	_runtime.read_flags.mark_read("issue171", "memory", 171)
	_runtime.unlock_manager.unlock("scene", "issue171-memory")
	return {
		"context": _runtime.engine.context,
		"playback": playback,
	}


func _dirty_runtime_projection() -> void:
	_runtime.presentation_state.current_bg = "dirty_bg"
	_runtime.presentation_state.stage_layers["dirty"] = (
		StageLayerState.normalize_full({"asset": "stage:dirty"}))
	_runtime.presentation_state.current_bgm = {
		"asset": "dirty_bgm",
		"cue": "",
		"loop": true,
		"position": 0.0,
		"status": "playing",
		"stem_mix": {},
		"volume": 1.0,
	}
	_runtime.presentation_state.loop_se_channels = {
		"ambience": {
			"asset": "dirty_loop",
			"loop": true,
			"position": 0.0,
			"volume": 1.0,
		}
	}
	_runtime.backlog_manager.add_entry("dirty", [{"text": "dirty"}], 1)
	_runtime.choice_history_manager.record(2, func() -> Dictionary: return {})
	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true


func _assert_return_cleanup() -> void:
	assert_null(_runtime.engine.context)
	assert_null(_runtime._active_recollection_context)
	assert_null(_runtime._active_recollection_playback)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PAUSED)
	assert_false(_runtime.auto_play.is_active)
	assert_false(_runtime.skip_controller.is_active)
	assert_eq(_runtime.backlog_manager.get_entries(), [])
	assert_eq(_runtime.choice_history_manager.size(), 0)
	assert_true(_runtime.read_flags.is_read("issue171", "memory", 171),
		"return does not roll back monotonic read progress")
	assert_true(_runtime.unlock_manager.is_unlocked(
		"scene", "issue171-memory"),
		"return does not roll back explicit gallery unlock progress")
	assert_eq(_runtime.presentation_state.current_bg, "")
	assert_eq(_runtime.presentation_state.stage_layers, {})
	assert_eq(_runtime.presentation_state.current_bgm, {})
	assert_eq(_runtime.presentation_state.loop_se_channels, {})
	assert_false(bool(
		_runtime.presentation_clip_audio_choice_authority.capture_snapshot()
			.get("initialized", true)))
	assert_eq(_runtime._navigation_kind, "")


func _wait_until(predicate: Callable, max_frames: int = 120) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func test_dsl_exit_claims_cleanup_and_return_exactly_once() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var data := DslParser.parse(
		DslLexer.tokenize("""@chapter memory "Memory"
@scene start
@set entered = true
@recollection_exit
@set leaked = true
"""),
		"recollection_dsl_exit",
		SOURCE_PATH,
	)
	assert_eq(data.diagnostics, [])
	var installed := _install_recollection(
		data, Callable(target, "return_to_gallery"))
	var playback: ScenarioPlaybackContext = installed["playback"]
	var context: ScenarioContext = installed["context"]
	_dirty_runtime_projection()

	await _runtime.engine.run()

	assert_eq(calls, ["returned"])
	assert_eq(context.variable_store.get_var("entered"), "true")
	assert_false(context.variable_store.get_var("leaked", false))
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	_assert_return_cleanup()
	assert_false(_runtime.return_from_recollection())
	assert_eq(calls, ["returned"])


func test_public_entry_rejects_nonzero_argument_continuation_without_mutation() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var initial_navigation: int = _runtime._navigation_generation

	var entered: bool = _runtime.start_recollection(
		RECOLLECTION_REENTRY_PATH,
		Callable(target, "invalid_return"),
	)

	assert_push_error(RECOLLECTION_REENTRY_PATH + ":entry")
	assert_false(entered)
	assert_null(_runtime.engine.context)
	assert_null(_runtime._active_recollection_context)
	assert_eq(_runtime._navigation_generation, initial_navigation,
		"validation failure cannot claim navigation ownership")
	assert_eq(calls, [])


func test_natural_end_uses_the_same_return_claim() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var installed := _install_recollection(
		_scenario([_command("set", 12, {
			"var": "natural_end",
			"op": "=",
			"value": true,
		})]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]
	var context: ScenarioContext = installed["context"]

	await _runtime.engine.run()

	assert_true(context.variable_store.get_var("natural_end", false))
	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	_assert_return_cleanup()


func test_public_return_uses_the_same_claim_before_natural_end() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var installed := _install_recollection(
		_scenario([_command("set", 22, {
			"variable": "must_not_run",
			"op": "=",
			"value": true,
		})]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]
	var context: ScenarioContext = installed["context"]
	_dirty_runtime_projection()

	assert_true(_runtime.return_from_recollection())

	assert_false(context.variable_store.get_var("must_not_run", false))
	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	_assert_return_cleanup()


func test_lost_continuation_still_cleans_then_fails_source_located() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var installed := _install_recollection(
		_scenario([_command("set", 37)]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]
	_owned_targets.erase(target)
	target.free()
	_dirty_runtime_projection()

	assert_false(_runtime.return_from_recollection())

	assert_push_error(SOURCE_PATH + ":37")
	assert_eq(calls, [])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.CANCELLED)
	_assert_return_cleanup()


func test_return_callback_can_start_normal_owner_without_old_cleanup_tail() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	target.normal_reentry_path = NORMAL_REENTRY_PATH
	var installed := _install_recollection(
		_scenario([_command("set", 44)]),
		Callable(target, "return_to_gallery"),
	)
	var old_context: ScenarioContext = installed["context"]

	assert_true(_runtime.return_from_recollection())
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != null
				and _runtime.engine.context != old_context
				and _runtime.engine.context.scenario_data.id
					== "presentation_profile"
			)))

	assert_eq(calls, ["returned"])
	assert_false(_runtime.engine.context.is_recollection_playback())
	assert_eq(_runtime._navigation_kind, "",
		"the callback's completed normal entry owns the final navigation state")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)


func test_return_callback_can_start_new_recollection_without_old_cleanup_tail() -> void:
	var first_calls: Array[String] = []
	var second_calls: Array[String] = []
	var first_target := _target(first_calls)
	var second_target := _target(second_calls)
	first_target.recollection_reentry_path = RECOLLECTION_REENTRY_PATH
	first_target.recollection_return = Callable(
		second_target, "return_to_gallery")
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	var installed := _install_recollection(
		_scenario([_command("set", 48)]),
		Callable(first_target, "return_to_gallery"),
	)
	var first_playback: ScenarioPlaybackContext = installed["playback"]
	var first_context: ScenarioContext = installed["context"]

	assert_true(_runtime.return_from_recollection())
	assert_true(await _wait_until(
		func() -> bool:
			return _runtime._navigation_scene_slot_active_serial > 0))
	var scene_serial: int = _runtime._navigation_scene_slot_active_serial
	assert_eq(first_calls, ["returned"])
	assert_eq(first_playback.get_status(),
		ScenarioPlaybackContext.Status.RETURNED)
	_runtime._settle_navigation_scene_slot(scene_serial, true)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != null
				and _runtime.engine.context != first_context
				and _runtime.engine.context.is_recollection_playback()
				and _runtime._active_recollection_context
					== _runtime.engine.context
			)))

	assert_eq(second_calls, [])
	assert_not_same(_runtime._active_recollection_playback, first_playback)
	assert_eq(_runtime._active_recollection_playback.get_status(),
		ScenarioPlaybackContext.Status.ACTIVE)
	assert_eq(_runtime._navigation_kind, "")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)


func test_rejected_title_replacement_preserves_active_return_contract() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var installed := _install_recollection(
		_scenario([_command("wait", 49, {"mode": "click"})]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]
	var retained_context: ScenarioContext = installed["context"]
	_runtime.engine.run()
	await get_tree().process_frame
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return ERR_CANT_CREATE

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime._navigation_kind.is_empty()
				and not _runtime._return_to_title_pending
				and retained_context.is_runtime_owner_current()
			)
	))

	assert_push_warning(
		"auto save is unavailable during recollection playback")
	assert_push_error("failed to request the configured title scene")
	assert_push_error(
		"failed to enter the configured title scene; falling back")
	assert_push_error("failed to request the built-in title scene")
	assert_push_error("failed to enter the built-in title scene")
	assert_same(_runtime.engine.context, retained_context)
	assert_false(retained_context.is_finished)
	assert_true(retained_context.is_recollection_playback())
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.ACTIVE)
	assert_same(_runtime._active_recollection_context, retained_context)
	assert_same(_runtime._active_recollection_playback, playback)
	assert_eq(calls, [])

	assert_true(_runtime.return_from_recollection(),
		"the restored recollection retains its exact caller settlement")
	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	_assert_return_cleanup()
	assert_false(_runtime.return_from_recollection())
	assert_eq(calls, ["returned"])


func test_return_callback_can_start_title_without_old_cleanup_tail() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	target.title_reentry = true
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	var installed := _install_recollection(
		_scenario([_command("set", 50)]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]

	assert_true(_runtime.return_from_recollection())
	assert_true(await _wait_until(
		func() -> bool:
			return _runtime._navigation_scene_slot_active_serial > 0))
	var scene_serial: int = _runtime._navigation_scene_slot_active_serial
	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	assert_null(_runtime._active_recollection_context)
	assert_null(_runtime._active_recollection_playback)
	_runtime._settle_navigation_scene_slot(scene_serial, true)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.game_state.current_state
					== GameStateMachine.State.TITLE
				and _runtime._navigation_kind.is_empty()
				and not _runtime._return_to_title_pending
			)
	))

	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	assert_null(_runtime.engine.context)


func test_normal_replacement_cancels_caller_without_return() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	var installed := _install_recollection(
		_scenario([_command("set", 51)]),
		Callable(target, "return_to_gallery"),
	)
	var playback: ScenarioPlaybackContext = installed["playback"]
	var old_context: ScenarioContext = installed["context"]

	_runtime.start_scenario(NORMAL_REENTRY_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != null
				and _runtime.engine.context != old_context
				and _runtime.engine.context.scenario_data.id
					== "presentation_profile"
			)))

	assert_eq(calls, [])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.CANCELLED)
	assert_null(_runtime._active_recollection_context)
	assert_null(_runtime._active_recollection_playback)


func test_save_and_rollback_mutation_fail_closed_during_recollection() -> void:
	var calls: Array[String] = []
	var target := _target(calls)
	_install_recollection(
		_scenario([_command("set", 60)]),
		Callable(target, "return_to_gallery"),
	)

	_runtime.quick_save()
	_runtime.auto_save()
	_runtime.save(SAVE_SLOT)
	assert_push_warning("quick save is unavailable during recollection playback")
	assert_push_warning("auto save is unavailable during recollection playback")
	assert_push_warning("manual save is unavailable during recollection playback")
	assert_false(_runtime.has_quick_save())
	assert_false(_runtime.has_auto_save())
	assert_false(_runtime.has_save(SAVE_SLOT))
	assert_false(_runtime.jump_from_backlog(0))
	assert_false(_runtime.can_jump_to_previous_choice())
	assert_false(_runtime.jump_to_previous_choice())
	assert_false(_runtime.jump_from_flowchart("memory"))
