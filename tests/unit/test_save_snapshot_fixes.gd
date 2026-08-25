extends GutTest
## Tests for save/load snapshot fixes:
## - Provider deduplication
## - return_stack persistence
## - PresentationState tracking & snapshot
## - Load flow: restore before engine.run()


# ─── Provider Deduplication ───

func test_register_provider_replaces_same_id():
	var sm = SaveManager.new()
	var p1 = _FakeProvider.new("ctx", {"a": 1})
	var p2 = _FakeProvider.new("ctx", {"a": 2})
	sm.register_provider(p1)
	sm.register_provider(p2)
	assert_eq(sm.get_provider_count(), 1, "should not accumulate duplicates")


func test_register_provider_keeps_different_ids():
	var sm = SaveManager.new()
	var p1 = _FakeProvider.new("ctx", {})
	var p2 = _FakeProvider.new("vars", {})
	sm.register_provider(p1)
	sm.register_provider(p2)
	assert_eq(sm.get_provider_count(), 2)


func test_save_uses_latest_provider_after_replace():
	var sm = SaveManager.new()
	var p1 = _FakeProvider.new("ctx", {"v": 1})
	var p2 = _FakeProvider.new("ctx", {"v": 2})
	sm.register_provider(p1)
	sm.register_provider(p2)

	sm.save(99)
	var loaded = _load_json(sm.save_dir + "save_99.json")
	assert_eq(loaded["ctx"]["v"], 2.0, "should use latest provider's data")
	sm.delete_save(99)


# ─── return_stack Persistence ───

func test_scenario_context_snapshot_includes_return_stack():
	var ctx = ScenarioContext.new()
	ctx.scenario_data = _make_scenario_data()
	ctx.return_stack = [
		{"scene_index": 0, "command_index": 5},
		{"scene_index": 1, "command_index": 2},
	]
	var snap = ctx.capture_snapshot()
	assert_true(snap.has("return_stack"), "snapshot should include return_stack")
	assert_eq(snap["return_stack"].size(), 2)


func test_scenario_context_restore_return_stack():
	var ctx = ScenarioContext.new()
	ctx.scenario_data = _make_scenario_data()
	ctx.restore_snapshot({
		"scene_index": 1,
		"command_index": 3,
		"is_finished": false,
		"return_stack": [{"scene_index": 0, "command_index": 5}],
	})
	assert_eq(ctx.return_stack.size(), 1)
	assert_eq(ctx.return_stack[0]["scene_index"], 0)
	assert_eq(ctx.return_stack[0]["command_index"], 5)


func test_scenario_context_restore_without_return_stack_clears_it():
	var ctx = ScenarioContext.new()
	ctx.scenario_data = _make_scenario_data()
	ctx.return_stack = [{"scene_index": 0, "command_index": 1}]
	ctx.restore_snapshot({
		"scene_index": 0,
		"command_index": 0,
		"is_finished": false,
	})
	assert_eq(ctx.return_stack.size(), 0, "return_stack should be cleared if absent in snapshot")


# ─── PresentationState Tracking ───

func _bgm_state(asset: String = "theme.ogg") -> Dictionary:
	return {
		"asset": asset, "cue": "", "loop": true, "position": 0.0,
		"status": "playing", "stem_mix": {}, "volume": 1.0,
	}


func _bgm_operation(asset: String = "theme.ogg") -> BgmPresentationOperation:
	return BgmPresentationOperation.new({
		"action": "play", "asset": asset, "cue": "", "fade_duration": 0.0,
		"resume_position": 0.0, "stem_mix": {}, "volume": 1.0,
	})

func test_presentation_state_tracks_bg():
	var ps = PresentationState.new()
	ps.connect_signals()
	SignalBus.bg_changed.emit("forest.png", "fade", 0.5)
	assert_eq(ps.current_bg, "forest.png")


func test_presentation_state_tracks_bgm():
	var ps = PresentationState.new()
	ps.connect_signals()
	SignalBus.bgm_operation_committed.emit(
		_bgm_operation("battle.ogg"), _bgm_state("battle.ogg"))
	assert_eq(ps.current_bgm, _bgm_state("battle.ogg"))
	ps.disconnect_signals()


func test_presentation_state_tracks_stopped_bgm():
	var ps = PresentationState.new()
	ps.connect_signals()
	SignalBus.bgm_operation_committed.emit(
		_bgm_operation("battle.ogg"), _bgm_state("battle.ogg"))
	SignalBus.bgm_operation_committed.emit(BgmPresentationOperation.new({
		"action": "stop", "asset": "", "cue": "", "fade_duration": 0.5,
		"resume_position": 0.0, "stem_mix": {}, "volume": 1.0,
	}), {})
	assert_eq(ps.current_bgm, {})
	ps.disconnect_signals()


func test_presentation_state_snapshot_roundtrip():
	var ps = PresentationState.new()
	ps.connect_signals()
	SignalBus.bg_changed.emit("forest.png", "fade", 0.5)
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "alice",
		"properties": {
			"asset": "character:alice/happy",
			"redraw": [
				{"type": "blur", "radius": [1, 1]},
				{"type": "blur", "radius": [2, 0]},
				{"type": "blur", "radius": [0, 3]},
				{"type": "blur", "radius": [4, 2]},
			],
		},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	SignalBus.bgm_operation_committed.emit(
		_bgm_operation(), _bgm_state())

	var snap = ps.capture_snapshot()

	var ps2 = PresentationState.new()
	ps2.restore_snapshot(snap)
	assert_eq(ps2.current_bg, "forest.png")
	assert_true(BgmChannelState.validate_snapshot_state(snap.get("bgm"), false),
		"captured BGM state uses the exact stable schema")
	assert_eq(ps2.current_bgm, snap.get("bgm"),
		"round-trip preserves the sampled current playback cursor")
	ps.disconnect_signals()
	assert_true(ps2.stage_layers.has("alice"))
	assert_eq(ps2.stage_layers["alice"]["asset"], "character:alice/happy")
	assert_eq(ps2.stage_layers["alice"]["redraw"], [
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 0]},
		{"type": "blur", "radius": [0, 3]},
		{"type": "blur", "radius": [4, 2]},
	])


func test_presentation_state_restore_emits_signals():
	var ps = PresentationState.new()
	ps.current_bg = "forest.png"
	ps.current_bgm = {}
	ps.stage_layers = {
		"alice": StageLayerState.normalize_full({"asset": "character:alice/happy"}),
	}

	var bg_received := []
	var stage_received := []
	var bg_cb = func(a, _t, _d): bg_received.append(a)
	var stage_cb = func(layers): stage_received.append(layers)
	SignalBus.bg_changed.connect(bg_cb)
	SignalBus.stage_state_apply_requested.connect(stage_cb)

	ps.apply_to_presenters()

	assert_eq(bg_received, ["forest.png"])
	assert_eq(stage_received.size(), 1)
	assert_eq(stage_received[0]["alice"]["asset"], "character:alice/happy")

	SignalBus.bg_changed.disconnect(bg_cb)
	SignalBus.stage_state_apply_requested.disconnect(stage_cb)


func test_presentation_state_restore_uses_zero_duration():
	var ps = PresentationState.new()
	ps.current_bg = "forest.png"

	var results := []
	var cb = func(_a, _t, d): results.append(d)
	SignalBus.bg_changed.connect(cb)
	ps.apply_to_presenters()
	assert_eq(results.size(), 1, "bg_changed should have been emitted once")
	if results.size() > 0:
		assert_eq(results[0], 0.0, "restore should use duration=0 for instant apply")
	SignalBus.bg_changed.disconnect(cb)


func test_presentation_state_restore_projects_empty_bgm_as_canonical_reset():
	var ps = PresentationState.new()
	var reset_epochs: Array[int] = []
	var cb = func(epoch: int): reset_epochs.append(epoch)
	SignalBus.bgm_projection_reset_requested.connect(cb)

	ps.apply_to_presenters()

	SignalBus.bgm_projection_reset_requested.disconnect(cb)
	assert_eq(reset_epochs.size(), 1)


func test_presentation_state_disconnect_signals():
	var ps = PresentationState.new()
	ps.connect_signals()
	ps.disconnect_signals()
	SignalBus.bg_changed.emit("new.png", "fade", 0.5)
	assert_eq(ps.current_bg, "", "should not track after disconnect")


func test_presentation_state_clear():
	var ps = PresentationState.new()
	ps.current_bg = "forest.png"
	ps.current_bgm = _bgm_state()
	ps.stage_layers = {"alice": StageLayerState.default_state()}
	ps.clear()
	assert_eq(ps.current_bg, "")
	assert_eq(ps.current_bgm, {})
	assert_eq(ps.stage_layers.size(), 0)


# ─── Engine Load Flow ───

func test_engine_has_stop_method():
	var engine = ScenarioEngine.new()
	assert_true(engine.has_method("stop"), "engine should have stop() for load reset")


func test_engine_stop_sets_finished():
	var engine = ScenarioEngine.new()
	var data = _make_scenario_data()
	engine.load_scenario(data)
	engine.stop()
	assert_true(engine.context.is_finished, "stop should halt the run loop")


# ─── Helpers ───

func _make_scenario_data() -> ScenarioData:
	var data = ScenarioData.new()
	data.id = "test"
	var scene = SceneData.new()
	scene.id = "main"
	data.scenes.append(scene)
	return data


func _load_json(path: String) -> Dictionary:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	return JSON.parse_string(file.get_as_text())


class _FakeProvider:
	var _id: String
	var _data: Dictionary
	func _init(id: String, data: Dictionary):
		_id = id
		_data = data
	func get_provider_id() -> String:
		return _id
	func capture_snapshot() -> Dictionary:
		return _data
	func restore_snapshot(_snapshot: Dictionary) -> void:
		pass
