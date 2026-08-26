extends GutTest
## Tests ScreenEffects presenter — shake composition, defensive parameter
## validation, cancellation, and configurable flash rendering.

const SCREEN_EFFECTS_SCRIPT = preload("res://addons/stella/presentation/effects/screen_effects.gd")

var _parent: Node2D
var _bg_layer: CanvasLayer
var _stage_layer: CanvasLayer
var _ui_layer: CanvasLayer
var _bg_shake_root: Node2D
var _stage_shake_root: Node2D
var _effects: Node
var _original_effect_enabled: bool


func before_each() -> void:
	_original_effect_enabled = bool(StellaRuntime.get_setting("effect_enabled"))
	StellaRuntime.set_setting("effect_enabled", true)
	# Mirror the real game scene: camera/pan offsets live on CanvasLayers while
	# ScreenEffects owns dedicated Node2D roots below the two stage layers.
	_parent = Node2D.new()
	_parent.name = "Game"
	add_child_autoqfree(_parent)

	_bg_layer = CanvasLayer.new()
	_bg_layer.name = "BackgroundLayer"
	_bg_layer.layer = 0
	_parent.add_child(_bg_layer)
	_bg_shake_root = Node2D.new()
	_bg_shake_root.name = "ShakeRoot"
	_bg_layer.add_child(_bg_shake_root)

	_stage_layer = CanvasLayer.new()
	_stage_layer.name = "StageLayer"
	_stage_layer.layer = 1
	_parent.add_child(_stage_layer)
	_stage_shake_root = Node2D.new()
	_stage_shake_root.name = "ShakeRoot"
	_stage_layer.add_child(_stage_shake_root)

	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "UILayer"
	_ui_layer.layer = 3
	_parent.add_child(_ui_layer)

	_effects = Node.new()
	_effects.name = "ScreenEffects"
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ShakeRoot"),
		NodePath("../StageLayer/ShakeRoot"),
	]
	_effects.shake_target_paths = target_paths
	_parent.add_child(_effects)
	await get_tree().process_frame


func after_each() -> void:
	if is_instance_valid(_effects):
		_effects._clear_effects()
		# Disconnect to avoid cross-test signal bleed.
		if SignalBus.effect_requested.is_connected(_effects._on_effect):
			SignalBus.effect_requested.disconnect(_effects._on_effect)
		if SignalBus.engine_abort_requested.is_connected(_effects._clear_effects):
			SignalBus.engine_abort_requested.disconnect(_effects._clear_effects)
	StellaRuntime.set_setting("effect_enabled", _original_effect_enabled)


# --- Settings policy: admission, active cleanup, and generation safety ---

func test_disabled_policy_drops_builtins_without_mutation_or_later_replay() -> void:
	var bg_baseline := Vector2(7.0, -3.0)
	var stage_baseline := Vector2(-5.0, 11.0)
	_bg_shake_root.position = bg_baseline
	_stage_shake_root.position = stage_baseline

	StellaRuntime.set_setting("effect_enabled", false)
	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 5.0})

	_assert_effects_neutral(bg_baseline, stage_baseline)
	StellaRuntime.set_setting("effect_enabled", true)
	_assert_effects_neutral(bg_baseline, stage_baseline)

	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 5.0})
	assert_not_null(_effects._shake_tween,
		"re-enabling admits only a newly requested shake")
	assert_not_null(_effects._flash_tween,
		"re-enabling admits only a newly requested flash")
	assert_not_null(_effects._flash_overlay)


func test_disabling_active_effects_restores_visuals_and_retires_old_callbacks() -> void:
	var target := Control.new()
	target.name = "PolicyCoverageTarget"
	target.position = Vector2(13.0, -9.0)
	target.size = Vector2(320.0, 180.0)
	target.scale = Vector2.ONE
	target.pivot_offset = Vector2(4.0, 6.0)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/PolicyCoverageTarget"),
	]
	_effects.shake_target_paths = target_paths
	_effects.shake_coverage_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 5.0})
	var retired_shake: Tween = _effects._shake_tween
	var retired_flash: Tween = _effects._flash_tween
	var retired_overlay: ColorRect = _effects._flash_overlay
	assert_not_null(retired_shake)
	assert_not_null(retired_flash)
	assert_not_null(retired_overlay)
	assert_ne(target.position, Vector2(13.0, -9.0))
	assert_ne(target.scale, Vector2.ONE)

	StellaRuntime.set_setting("effect_enabled", false)

	assert_null(_effects._shake_tween)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_eq(target.position, Vector2(13.0, -9.0))
	assert_eq(target.scale, Vector2.ONE)
	assert_eq(target.pivot_offset, Vector2(4.0, 6.0))
	assert_false(_effects.is_processing())
	assert_false(retired_overlay.visible)

	StellaRuntime.set_setting("effect_enabled", true)
	SignalBus.effect_requested.emit("shake", {"intensity": 8.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 5.0})
	var replacement_shake: Tween = _effects._shake_tween
	var replacement_flash: Tween = _effects._flash_tween
	var replacement_overlay: ColorRect = _effects._flash_overlay
	assert_not_same(replacement_shake, retired_shake)
	assert_not_same(replacement_flash, retired_flash)

	_effects._finish_shake(retired_shake)
	_effects._finish_flash(retired_flash)
	assert_same(_effects._shake_tween, replacement_shake,
		"a disabled generation's late shake callback cannot clear the replacement")
	assert_same(_effects._flash_tween, replacement_flash,
		"a disabled generation's late flash callback cannot clear the replacement")
	assert_same(_effects._flash_overlay, replacement_overlay)

	StellaRuntime.set_setting("effect_enabled", false)
	SignalBus.effect_requested.emit("off", {})
	assert_null(_effects._shake_tween, "off remains an unconditional neutralizer")
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)


func test_reentrant_reenable_during_disable_keeps_only_fresh_effects() -> void:
	var target := Control.new()
	target.name = "ReentrantPolicyTarget"
	target.position = Vector2(13.0, -9.0)
	target.size = Vector2(320.0, 180.0)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ReentrantPolicyTarget"),
	]
	_effects.shake_target_paths = target_paths
	_effects.shake_coverage_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 5.0})
	var retired_shake: Tween = _effects._shake_tween
	var retired_flash: Tween = _effects._flash_tween
	_effects._apply_shake_offset(retired_shake, Vector2(4.0, -6.0))
	var reentry := {"requested": false}
	target.item_rect_changed.connect(func() -> void:
		if reentry["requested"]:
			return
		reentry["requested"] = true
		StellaRuntime.set_setting("effect_enabled", true)
		SignalBus.effect_requested.emit(
			"shake", {"intensity": 8.0, "duration": 5.0})
		SignalBus.effect_requested.emit(
			"flash", {"color": "blue", "duration": 5.0})
	)

	StellaRuntime.set_setting("effect_enabled", false)

	assert_true(reentry["requested"],
		"restoring the retired Control must exercise synchronous policy reentry")
	assert_true(bool(StellaRuntime.get_setting("effect_enabled")))
	assert_not_null(_effects._shake_tween)
	assert_not_null(_effects._flash_tween)
	assert_not_same(_effects._shake_tween, retired_shake,
		"the false generation cannot remain the active shake owner")
	assert_not_same(_effects._flash_tween, retired_flash,
		"the false generation cannot remain the active flash owner")
	assert_eq(_effects._flash_overlay.color, Color.BLUE)

	StellaRuntime.set_setting("effect_enabled", false)
	_assert_effects_neutral(Vector2.ZERO, Vector2.ZERO)
	assert_eq(target.position, Vector2(13.0, -9.0))
	assert_eq(target.scale, Vector2.ONE)
	assert_eq(target.pivot_offset, Vector2.ZERO)


func test_disable_during_fallback_resolution_rolls_back_stale_canvas() -> void:
	_parent.remove_child(_effects)
	_effects.free()
	_effects = null
	StellaRuntime.set_setting("effect_enabled", false)

	_effects = Node.new()
	_effects.name = "ScreenEffects"
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ShakeRoot"),
		NodePath("../StageLayer/ShakeRoot"),
	]
	_effects.shake_target_paths = target_paths
	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_null(_effects._fallback_flash_canvas,
		"startup-disabled presentation must not allocate a fallback host")

	StellaRuntime.set_setting("effect_enabled", true)
	var reentry := {"disabled": false}
	_effects.child_entered_tree.connect(func(child: Node) -> void:
		if reentry["disabled"] or not child is CanvasLayer:
			return
		reentry["disabled"] = true
		StellaRuntime.set_setting("effect_enabled", false)
	)

	SignalBus.effect_requested.emit(
		"flash", {"color": "red", "duration": 5.0})

	assert_true(reentry["disabled"],
		"fallback host creation must exercise synchronous disable reentry")
	assert_false(bool(StellaRuntime.get_setting("effect_enabled")))
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)
	assert_null(_effects._fallback_flash_canvas,
		"a stale request cannot leave its newly allocated fallback host behind")
	assert_null(_effects.get_node_or_null("FlashCanvas"))


func test_presenter_snapshots_persisted_false_before_ready_and_cleans_listener() -> void:
	var settings_connections_with_presenter := (
		SignalBus.settings_changed.get_connections().size())
	_parent.remove_child(_effects)
	assert_eq(
		SignalBus.settings_changed.get_connections().size(),
		settings_connections_with_presenter - 1,
		"leaving the scene must release the settings listener",
	)
	_effects.free()
	_effects = null

	# Runtime loads persisted settings before presenter construction, before its
	# long-lived manager bridge can publish any change notification.
	StellaRuntime.settings_manager.settings.effect_enabled = false
	_effects = Node.new()
	_effects.name = "ScreenEffects"
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ShakeRoot"),
		NodePath("../StageLayer/ShakeRoot"),
	]
	_effects.shake_target_paths = target_paths
	_parent.add_child(_effects)
	await get_tree().process_frame

	assert_eq(
		SignalBus.settings_changed.get_connections().size(),
		settings_connections_with_presenter,
		"the replacement presenter installs exactly one settings listener",
	)
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"duration": 5.0})
	_assert_effects_neutral(Vector2.ZERO, Vector2.ZERO)


# --- Shake: dedicated roots move together; surrounding layer offsets compose ---

func test_shake_moves_background_and_stage_roots() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 50.0, "duration": 0.3})

	var max_bg := 0.0
	var max_stage := 0.0
	for _sample in range(6):
		await get_tree().create_timer(0.04).timeout
		max_bg = maxf(max_bg, _bg_shake_root.position.length())
		max_stage = maxf(max_stage, _stage_shake_root.position.length())

	assert_gt(max_bg, 5.0, "background ShakeRoot should move measurably")
	assert_gt(max_stage, 5.0, "stage ShakeRoot should move measurably")
	await get_tree().create_timer(0.2).timeout
	assert_eq(_bg_shake_root.position, Vector2.ZERO, "background root must reset")
	assert_eq(_stage_shake_root.position, Vector2.ZERO, "stage root must reset")


func test_shake_uses_shared_delta_and_restores_each_root_baseline() -> void:
	var bg_baseline := Vector2(12.0, -4.0)
	var stage_baseline := Vector2(-6.0, 8.0)
	_bg_shake_root.position = bg_baseline
	_stage_shake_root.position = stage_baseline

	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.22})
	var saw_motion := false
	for _sample in range(3):
		await get_tree().create_timer(0.055).timeout
		var bg_delta := _bg_shake_root.position - bg_baseline
		var stage_delta := _stage_shake_root.position - stage_baseline
		assert_lt(bg_delta.distance_to(stage_delta), 0.001, "stage roots need one shared delta")
		saw_motion = saw_motion or bg_delta.length() > 0.001
	assert_true(saw_motion, "shake should move the configured roots")

	await get_tree().create_timer(0.12).timeout
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)


func test_canvas_layer_offsets_can_change_while_shake_is_active() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 45.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_ne(_bg_shake_root.position, Vector2.ZERO, "sanity: shake is active")

	# Simulate a camera/pan presenter changing its transform during the effect.
	var new_bg_offset := Vector2(120.0, -35.0)
	var new_stage_offset := Vector2(-20.0, 48.0)
	_bg_layer.offset = new_bg_offset
	_stage_layer.offset = new_stage_offset
	await get_tree().create_timer(0.12).timeout
	assert_eq(_bg_layer.offset, new_bg_offset, "shake must not overwrite camera offset")
	assert_eq(_stage_layer.offset, new_stage_offset, "shake must not overwrite camera offset")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_bg_layer.offset, new_bg_offset, "off must preserve external background offset")
	assert_eq(_stage_layer.offset, new_stage_offset, "off must preserve external stage offset")
	assert_eq(_bg_shake_root.position, Vector2.ZERO)
	assert_eq(_stage_shake_root.position, Vector2.ZERO)


func test_effect_off_cancels_shake_and_prevents_old_callbacks() -> void:
	var bg_baseline := Vector2(5.0, -3.0)
	var stage_baseline := Vector2(-2.0, 7.0)
	_bg_shake_root.position = bg_baseline
	_stage_shake_root.position = stage_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 50.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_ne(_bg_shake_root.position, bg_baseline, "sanity: shake is active")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_shake_root.position, bg_baseline, "cancelled shake must not resume")
	assert_eq(_stage_shake_root.position, stage_baseline, "cancelled shake must not resume")


func test_replacing_shake_preserves_original_root_baselines() -> void:
	var bg_baseline := Vector2(11.0, 3.0)
	var stage_baseline := Vector2(-9.0, -2.0)
	_bg_shake_root.position = bg_baseline
	_stage_shake_root.position = stage_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 45.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 0.1})
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)


func test_reentrant_shake_request_waits_until_every_old_target_is_restored() -> void:
	var first := Control.new()
	first.name = "FirstControlTarget"
	first.position = Vector2(8.0, -3.0)
	first.size = Vector2(100.0, 100.0)
	_bg_layer.add_child(first)
	var second := Control.new()
	second.name = "SecondControlTarget"
	second.position = Vector2(-5.0, 11.0)
	second.size = Vector2(100.0, 100.0)
	_stage_layer.add_child(second)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/FirstControlTarget"),
		NodePath("../StageLayer/SecondControlTarget"),
	]
	_effects.shake_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 1.0})
	var old_tween: Tween = _effects._shake_tween
	_effects._apply_shake_offset(old_tween, Vector2(4.0, -6.0))
	var request_state := {"requested": false}
	first.item_rect_changed.connect(func():
		if request_state["requested"]:
			return
		request_state["requested"] = true
		SignalBus.effect_requested.emit("shake", {"intensity": 5.0, "duration": 1.0})
	)

	SignalBus.effect_requested.emit("off", {})
	assert_true(request_state["requested"])
	assert_not_same(_effects._shake_tween, old_tween)
	assert_eq(_effects._shake_baselines.get(first), Vector2(8.0, -3.0))
	assert_eq(_effects._shake_baselines.get(second), Vector2(-5.0, 11.0))
	assert_eq(_effects._shake_targets.size(), 2)
	SignalBus.effect_requested.emit("off", {})
	assert_eq(first.position, Vector2(8.0, -3.0))
	assert_eq(second.position, Vector2(-5.0, 11.0))


func test_shake_does_not_touch_ui_layer_or_parent() -> void:
	var ui_baseline := Vector2(3.0, -6.0)
	var parent_baseline := Vector2(9.0, 2.0)
	_ui_layer.offset = ui_baseline
	_parent.position = parent_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.2})
	for _sample in range(5):
		await get_tree().create_timer(0.03).timeout
		assert_eq(_ui_layer.offset, ui_baseline, "dialogue UI must stay still")
		assert_eq(_parent.position, parent_baseline, "game root must stay unchanged")


func test_custom_named_nested_node2d_target_can_be_configured() -> void:
	var visuals := Node.new()
	visuals.name = "Visuals"
	_parent.add_child(visuals)
	var custom_root := Node2D.new()
	custom_root.name = "BackdropShake"
	visuals.add_child(custom_root)
	var baseline := Vector2(14.0, -8.0)
	custom_root.position = baseline
	var custom_paths: Array[NodePath] = [NodePath("../Visuals/BackdropShake")]
	_effects.shake_target_paths = custom_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 0.2})
	await get_tree().create_timer(0.06).timeout
	assert_ne(custom_root.position, baseline, "configured nested Node2D should shake")
	assert_eq(_bg_shake_root.position, Vector2.ZERO, "unconfigured root must stay still")
	assert_eq(_stage_shake_root.position, Vector2.ZERO, "unconfigured root must stay still")
	SignalBus.effect_requested.emit("off", {})
	assert_eq(custom_root.position, baseline)


func test_leaving_tree_restores_active_shake_roots() -> void:
	var bg_baseline := Vector2(3.0, 6.0)
	var stage_baseline := Vector2(-4.0, 2.0)
	_bg_shake_root.position = bg_baseline
	_stage_shake_root.position = stage_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	_effects.queue_free()
	await get_tree().process_frame
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)


func test_reentering_tree_reuses_canvas_and_reconnects_signals() -> void:
	var original_canvas = _effects._flash_canvas
	_parent.remove_child(_effects)
	assert_false(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_false(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))

	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_same(_effects._flash_canvas, original_canvas, "re-entry must not duplicate FlashCanvas")
	assert_true(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_true(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))


func test_ready_does_not_pause_a_shake_started_after_enter_tree() -> void:
	# Models a sibling `_ready()` emission that arrives after `_enter_tree()` has
	# connected the signal but before ScreenEffects receives its own `_ready()`.
	_effects._on_effect("shake", {"intensity": 20.0, "duration": 0.2})
	assert_true(_effects.is_processing())
	_effects._ready()
	assert_true(_effects.is_processing(), "ready must not freeze a startup shake")
	assert_not_null(_effects._shake_tween)


func test_shake_startup_can_remove_presenter_without_using_the_killed_tween() -> void:
	var target := Control.new()
	target.name = "RemovingTarget"
	target.position = Vector2(6.0, -2.0)
	target.size = Vector2(100.0, 100.0)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [NodePath("../BackgroundLayer/RemovingTarget")]
	_effects.shake_target_paths = target_paths
	var removal_state := {"removed": false}
	target.item_rect_changed.connect(func():
		if removal_state["removed"]:
			return
		removal_state["removed"] = true
		_parent.remove_child(_effects)
	)

	SignalBus.effect_requested.emit("shake", {"intensity": 10.0, "duration": 1.0})
	assert_true(removal_state["removed"])
	assert_null(_effects._shake_tween)
	assert_eq(target.position, Vector2(6.0, -2.0))
	assert_engine_error_count(0)
	_parent.add_child(_effects)
	await get_tree().process_frame


func test_shake_replacement_cleanup_can_remove_presenter_without_stale_tween() -> void:
	var target := Control.new()
	target.name = "ReplacementRemovingTarget"
	target.position = Vector2(6.0, -2.0)
	target.size = Vector2(100.0, 100.0)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ReplacementRemovingTarget"),
	]
	_effects.shake_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 10.0, "duration": 1.0})
	var first_tween: Tween = _effects._shake_tween
	_effects._apply_shake_offset(first_tween, Vector2(4.0, -6.0))
	var removal_state := {"removed": false}
	target.item_rect_changed.connect(func():
		if removal_state["removed"]:
			return
		removal_state["removed"] = true
		_parent.remove_child(_effects)
	)

	SignalBus.effect_requested.emit("shake", {"intensity": 5.0, "duration": 1.0})
	assert_true(removal_state["removed"])
	assert_false(_effects.is_inside_tree())
	assert_null(_effects._shake_tween)
	assert_eq(_effects._effect_mutation_depth, 0)
	assert_eq(target.position, Vector2(6.0, -2.0))
	assert_engine_error_count(0)
	_parent.add_child(_effects)
	await get_tree().process_frame


func test_huge_finite_shake_duration_has_constant_setup_and_can_be_cancelled() -> void:
	# The old implementation attempted range(ceil(duration / 0.05)) here and
	# hung before returning. Reaching the assertions proves setup stays bounded.
	SignalBus.effect_requested.emit("shake", {"intensity": 8.0, "duration": 1.0e300})
	assert_not_null(_effects._shake_tween)
	assert_eq(_effects._shake_targets.size(), 2)
	assert_true(_effects.is_processing())
	SignalBus.effect_requested.emit("off", {})
	assert_null(_effects._shake_tween)
	assert_false(_effects.is_processing())


func test_non_finite_and_non_numeric_shake_params_are_rejected() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 10.0, "duration": INF})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake duration must be finite")

	SignalBus.effect_requested.emit("shake", {"intensity": NAN, "duration": 1.0})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake intensity must be finite")

	SignalBus.effect_requested.emit("shake", {"intensity": "strong", "duration": 1.0})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake intensity must be a finite number")


func test_invalid_or_zero_replacement_shake_preserves_the_previous_one() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 1.0})
	var active_tween: Tween = _effects._shake_tween
	assert_not_null(active_tween)
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": -1.0})
	assert_same(_effects._shake_tween, active_tween)
	assert_push_warning("shake duration must be non-negative")
	SignalBus.effect_requested.emit("shake", {"intensity": NAN, "duration": 1.0})
	assert_same(_effects._shake_tween, active_tween)
	assert_push_warning("shake intensity must be finite")
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 0.0})
	assert_same(_effects._shake_tween, active_tween)
	SignalBus.effect_requested.emit("shake", {"intensity": 0.0, "duration": 1.0})
	assert_same(_effects._shake_tween, active_tween)


func test_negative_intensity_is_normalized_and_large_intensity_is_clamped() -> void:
	_effects.max_shake_intensity = 7.0
	SignalBus.effect_requested.emit("shake", {"intensity": -100.0, "duration": 0.5})
	assert_almost_eq(_effects._shake_intensity, 7.0, 0.001)
	var delta := _bg_shake_root.position
	assert_true(absf(delta.x) <= 7.0 and absf(delta.y) <= 7.0)
	assert_push_warning("negative shake intensity normalized")
	assert_push_warning("exceeds the configured maximum")


func test_huge_finite_shake_limit_cannot_produce_infinite_positions() -> void:
	_effects.max_shake_intensity = 1.0e308
	SignalBus.effect_requested.emit("shake", {"intensity": 1.0e308, "duration": 0.5})

	assert_almost_eq(
		_effects._shake_intensity,
		_effects.ABSOLUTE_MAX_SHAKE_INTENSITY,
		0.001,
	)
	assert_true(_bg_shake_root.position.is_finite())
	assert_true(_stage_shake_root.position.is_finite())
	assert_true(absf(_bg_shake_root.position.x) <= _effects.ABSOLUTE_MAX_SHAKE_INTENSITY)
	assert_true(absf(_bg_shake_root.position.y) <= _effects.ABSOLUTE_MAX_SHAKE_INTENSITY)
	for _sample in range(20):
		_effects._apply_shake_delta(_effects._shake_tween)
		assert_true(_bg_shake_root.position.is_finite())
		assert_true(_stage_shake_root.position.is_finite())
	assert_push_warning("exceeds the absolute safe maximum")
	assert_push_warning("exceeds the configured maximum")


func test_tiny_shake_coverage_target_is_rejected_before_scale_overflow() -> void:
	var target := Control.new()
	target.name = "TinyCoverageTarget"
	target.size = Vector2(1.0e-35, 1.0e-35)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [NodePath("../BackgroundLayer/TinyCoverageTarget")]
	_effects.shake_target_paths = target_paths
	_effects.shake_coverage_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 4096.0, "duration": 1.0})
	assert_true(target.scale.is_finite())
	assert_eq(target.scale, Vector2.ONE)
	assert_true(target.position.is_finite())
	assert_true(_effects._shake_coverage_baselines.is_empty())
	assert_push_warning("finite size of at least")


func test_active_shake_coverage_recomputes_on_resize_and_disconnects_on_stop() -> void:
	var target := Control.new()
	target.name = "ResizableCoverageTarget"
	target.size = Vector2(320.0, 180.0)
	_bg_layer.add_child(target)
	var target_paths: Array[NodePath] = [NodePath("../BackgroundLayer/ResizableCoverageTarget")]
	_effects.shake_target_paths = target_paths
	_effects.shake_coverage_target_paths = target_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 1.0})
	assert_almost_eq(target.scale.x, 1.0 + 40.0 / 180.0, 0.0001)
	assert_eq(target.pivot_offset, Vector2(160.0, 90.0))
	var coverage_state: Dictionary = _effects._shake_coverage_baselines[target]
	var resized_callback: Callable = coverage_state["resized_callback"]
	assert_true(target.resized.is_connected(resized_callback))

	target.size = Vector2(160.0, 90.0)
	await get_tree().process_frame
	assert_almost_eq(target.scale.x, 1.0 + 40.0 / 90.0, 0.0001)
	assert_eq(target.pivot_offset, Vector2(80.0, 45.0))

	SignalBus.effect_requested.emit("off", {})
	assert_eq(target.scale, Vector2.ONE)
	assert_eq(target.pivot_offset, Vector2.ZERO)
	assert_false(target.resized.is_connected(resized_callback))
	target.size = Vector2(80.0, 45.0)
	assert_eq(target.scale, Vector2.ONE, "a stopped effect must not react to later resizes")


# --- Flash: explicit host when configured; configurable fallback otherwise ---

func test_default_flash_layer_uses_authoritative_shared_presentation_order() -> void:
	assert_eq(_effects.flash_canvas_layer, PresentationLayerOrder.SCREEN_FLASH)
	assert_gt(
		_effects.flash_canvas_layer,
		PresentationLayerOrder.FULLSCREEN_MEDIA,
		"screen flash remains deterministically above the full-screen media surface",
	)


func test_flash_fallback_canvas_uses_configured_layer_and_max_z_index() -> void:
	_effects.flash_canvas_layer = 27
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame

	var overlay := _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(_effects._flash_canvas.layer, 27)
	assert_eq(overlay.z_index, RenderingServer.CANVAS_ITEM_Z_MAX)
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE)


func test_flash_can_use_external_canvas_without_mutating_or_owning_it() -> void:
	var host := CanvasLayer.new()
	host.name = "TopEffectsLayer"
	host.layer = 123
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../TopEffectsLayer")

	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.5})
	await get_tree().process_frame
	var overlay: ColorRect = _effects._flash_overlay
	assert_not_null(overlay)
	assert_same(overlay.get_parent(), host)
	assert_same(_effects._flash_canvas, host)
	assert_false(_effects._owns_flash_canvas)
	assert_eq(host.layer, 123, "ScreenEffects must not rewrite an external host layer")

	_effects.queue_free()
	await get_tree().process_frame
	assert_true(is_instance_valid(host), "freeing ScreenEffects must not free the host")
	assert_eq(host.layer, 123)


func test_detached_external_flash_host_cannot_restore_an_orphaned_overlay() -> void:
	var host := CanvasLayer.new()
	host.name = "DetachableEffectsLayer"
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../DetachableEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 100.0})
	var old_overlay: ColorRect = _effects._flash_overlay

	_parent.remove_child(host)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)
	assert_false(old_overlay.visible)
	_parent.add_child(host)
	await get_tree().process_frame
	assert_false(is_instance_valid(old_overlay))
	assert_engine_error_count(0)


func test_flash_requested_from_host_tree_exiting_cannot_survive_detach() -> void:
	var host := CanvasLayer.new()
	host.name = "LateTrackedEffectsLayer"
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../LateTrackedEffectsLayer")
	var request_state := {"requested": false, "overlay": null}
	host.tree_exiting.connect(func():
		request_state["requested"] = true
		SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 100.0})
		request_state["overlay"] = _effects._flash_overlay
	)

	_parent.remove_child(host)
	assert_true(request_state["requested"])
	var old_overlay: ColorRect = request_state["overlay"]
	assert_not_null(old_overlay, "the adversarial request must reach flash setup")
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)
	assert_false(old_overlay.visible)
	await get_tree().process_frame
	assert_false(is_instance_valid(old_overlay))
	_parent.add_child(host)
	await get_tree().process_frame
	assert_engine_error_count(0)


func test_reentering_presenter_cannot_restore_its_old_fallback_overlay() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": 100.0})
	var old_overlay: ColorRect = _effects._flash_overlay
	assert_not_null(old_overlay)

	_parent.remove_child(_effects)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_false(old_overlay.visible)
	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_false(is_instance_valid(old_overlay))
	assert_engine_error_count(0)


func test_switching_back_to_fallback_reuses_the_private_canvas() -> void:
	var fallback_canvas: CanvasLayer = _effects._flash_canvas
	var host := CanvasLayer.new()
	host.name = "TopEffectsLayer"
	_parent.add_child(host)

	_effects.flash_canvas_path = NodePath("../TopEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_same(_effects._flash_canvas, host)
	SignalBus.effect_requested.emit("off", {})

	_effects.flash_canvas_path = NodePath()
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_same(_effects._flash_canvas, fallback_canvas)
	assert_true(_effects._owns_flash_canvas)
	assert_same(_effects._flash_overlay.get_parent(), fallback_canvas)


func test_reentrant_flash_request_waits_until_old_overlay_is_detached() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 1.0})
	var old_overlay: ColorRect = _effects._flash_overlay
	var request_state := {"requested": false}
	old_overlay.visibility_changed.connect(func():
		if request_state["requested"] or old_overlay.visible:
			return
		request_state["requested"] = true
		SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 1.0})
	)

	SignalBus.effect_requested.emit("off", {})
	assert_true(request_state["requested"])
	assert_not_null(_effects._flash_tween)
	assert_not_same(_effects._flash_overlay, old_overlay)
	assert_eq(_effects._flash_overlay.color, Color.BLUE)
	assert_false(_effects._flash_overlay.is_queued_for_deletion())


func test_flash_replacement_cleanup_can_remove_presenter_without_stale_overlay() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 1.0})
	var old_overlay: ColorRect = _effects._flash_overlay
	var removal_state := {"removed": false}
	old_overlay.visibility_changed.connect(func():
		if removal_state["removed"] or old_overlay.visible:
			return
		removal_state["removed"] = true
		_parent.remove_child(_effects)
	)

	SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 1.0})
	assert_true(removal_state["removed"])
	assert_false(_effects.is_inside_tree())
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_false(old_overlay.visible)
	assert_eq(_effects._effect_mutation_depth, 0)
	assert_engine_error_count(0)
	_parent.add_child(_effects)
	await get_tree().process_frame


func test_external_host_exit_defers_reentrant_flash_until_tree_change_finishes() -> void:
	var host := CanvasLayer.new()
	host.name = "ReentrantEffectsLayer"
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../ReentrantEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 100.0})
	var old_overlay: ColorRect = _effects._flash_overlay
	var request_state := {"requested": false}
	old_overlay.visibility_changed.connect(func():
		if request_state["requested"] or old_overlay.visible:
			return
		request_state["requested"] = true
		SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 1.0})
	)

	_parent.remove_child(host)
	assert_true(request_state["requested"])
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_false(old_overlay.visible)
	assert_eq(_effects._effect_mutation_depth, 1)
	await get_tree().process_frame
	assert_eq(_effects._effect_mutation_depth, 0)
	assert_true(_effects._queued_effect_requests.is_empty())
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_push_warning("flash canvas not found")
	assert_engine_error_count(0)

	_parent.add_child(host)
	SignalBus.effect_requested.emit("flash", {"color": "green", "duration": 1.0})
	assert_not_null(_effects._flash_overlay)
	assert_same(_effects._flash_overlay.get_parent(), host)
	assert_eq(_effects._flash_overlay.color, Color.GREEN)


func test_fallback_host_exit_discards_reentrant_flash_without_reviving_it() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 100.0})
	var old_overlay: ColorRect = _effects._flash_overlay
	var request_state := {"requested": false}
	old_overlay.visibility_changed.connect(func():
		if request_state["requested"] or old_overlay.visible:
			return
		request_state["requested"] = true
		SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 1.0})
	)

	_parent.remove_child(_effects)
	assert_true(request_state["requested"])
	assert_false(_effects.is_inside_tree())
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_false(old_overlay.visible)
	await get_tree().process_frame
	assert_eq(_effects._effect_mutation_depth, 0)
	assert_true(_effects._queued_effect_requests.is_empty())
	assert_engine_error_count(0)

	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_null(_effects._flash_tween, "the detached request must not revive after re-entry")
	assert_null(_effects._flash_overlay)
	SignalBus.effect_requested.emit("flash", {"color": "green", "duration": 1.0})
	assert_not_null(_effects._flash_overlay)
	assert_eq(_effects._flash_overlay.color, Color.GREEN)


func test_invalid_explicit_flash_canvas_does_not_fall_back_silently() -> void:
	_effects.flash_canvas_path = NodePath("../MissingEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)
	assert_push_warning("flash canvas not found")


func test_invalid_replacement_flash_canvas_preserves_the_active_flash() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 1.0})
	var active_tween: Tween = _effects._flash_tween
	var active_overlay: ColorRect = _effects._flash_overlay
	var active_canvas: CanvasLayer = _effects._flash_canvas
	_effects.flash_canvas_path = NodePath("../MissingEffectsLayer")

	SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 1.0})
	assert_same(_effects._flash_tween, active_tween)
	assert_same(_effects._flash_overlay, active_overlay)
	assert_same(_effects._flash_canvas, active_canvas)
	assert_eq(active_overlay.color, Color.RED)
	assert_push_warning("flash canvas not found")


func test_flash_default_and_custom_colors() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)

	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.RED)

	SignalBus.effect_requested.emit("flash", {"color": "#ff0000", "duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.RED)

	SignalBus.effect_requested.emit(
		"flash", {"color": "not_a_real_color_name", "duration": 0.1}
	)
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)


func test_invalid_flash_inputs_are_safe() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": INF})
	assert_null(_effects._flash_tween)
	assert_push_warning("flash duration must be finite")

	SignalBus.effect_requested.emit("flash", {"duration": -1.0})
	assert_null(_effects._flash_tween)
	assert_push_warning("flash duration must be non-negative")

	SignalBus.effect_requested.emit("flash", {"color": 42, "duration": 0.2})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)
	assert_push_warning("flash color must be a string")


func test_invalid_or_zero_replacement_flash_preserves_the_previous_one() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 1.0})
	var active_tween: Tween = _effects._flash_tween
	var active_overlay: ColorRect = _effects._flash_overlay
	assert_not_null(active_tween)
	assert_not_null(active_overlay)

	SignalBus.effect_requested.emit("flash", {"duration": INF})
	assert_same(_effects._flash_tween, active_tween)
	assert_same(_effects._flash_overlay, active_overlay)
	assert_push_warning("flash duration must be finite")
	SignalBus.effect_requested.emit("flash", {"duration": -1.0})
	assert_same(_effects._flash_tween, active_tween)
	assert_same(_effects._flash_overlay, active_overlay)
	assert_push_warning("flash duration must be non-negative")
	SignalBus.effect_requested.emit("flash", {"duration": 0.0})
	assert_same(_effects._flash_tween, active_tween)
	assert_same(_effects._flash_overlay, active_overlay)


func test_freeing_external_flash_host_mid_effect_clears_state_without_engine_errors() -> void:
	var host := CanvasLayer.new()
	host.name = "DisposableEffectsLayer"
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../DisposableEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 100.0})
	assert_not_null(_effects._flash_overlay)

	host.free()
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)

	var replacement_host := CanvasLayer.new()
	replacement_host.name = "DisposableEffectsLayer"
	_parent.add_child(replacement_host)
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	assert_eq(_effects._effect_mutation_depth, 1)
	assert_eq(_effects._queued_effect_requests.size(), 1)
	await get_tree().process_frame
	assert_eq(_effects._effect_mutation_depth, 0)
	assert_true(_effects._queued_effect_requests.is_empty())
	assert_not_null(_effects._flash_overlay)
	assert_same(_effects._flash_overlay.get_parent(), replacement_host)
	assert_engine_error_count(0)


func test_effect_off_removes_active_flash() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.5})
	await get_tree().process_frame
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active")
	SignalBus.effect_requested.emit("off", {})
	await get_tree().process_frame
	assert_null(_find_flash_overlay())
	await get_tree().create_timer(0.12).timeout
	assert_null(_find_flash_overlay(), "cancelled flash must stay removed")


func test_flash_overlay_is_freed_after_completion() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": 0.05})
	assert_not_null(_find_flash_overlay())
	await get_tree().create_timer(0.2).timeout
	assert_null(_find_flash_overlay())


func test_engine_abort_clears_shake_and_flash_without_touching_layer_offsets() -> void:
	var bg_offset := Vector2(8.0, -5.0)
	var stage_offset := Vector2(-3.0, 4.0)
	_bg_layer.offset = bg_offset
	_stage_layer.offset = stage_offset
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	SignalBus.effect_requested.emit("flash", {"duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active")

	SignalBus.engine_abort_requested.emit()
	assert_eq(_bg_shake_root.position, Vector2.ZERO)
	assert_eq(_stage_shake_root.position, Vector2.ZERO)
	assert_eq(_bg_layer.offset, bg_offset)
	assert_eq(_stage_layer.offset, stage_offset)
	await get_tree().process_frame
	assert_null(_find_flash_overlay())


# --- Helpers ---

func _find_flash_overlay() -> ColorRect:
	return _find_color_rect_in(_effects)


func _find_color_rect_in(node: Node) -> ColorRect:
	if node is ColorRect:
		return node
	for child in node.get_children():
		var found := _find_color_rect_in(child)
		if found != null:
			return found
	return null


func _assert_effects_neutral(
	bg_position: Vector2,
	stage_position: Vector2,
) -> void:
	assert_null(_effects._shake_tween)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_true(_effects._shake_targets.is_empty())
	assert_true(_effects._shake_baselines.is_empty())
	assert_true(_effects._shake_motion_baselines.is_empty())
	assert_true(_effects._shake_coverage_baselines.is_empty())
	assert_false(_effects.is_processing())
	assert_eq(_bg_shake_root.position, bg_position)
	assert_eq(_stage_shake_root.position, stage_position)
