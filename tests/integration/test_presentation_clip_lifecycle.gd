extends GutTest
## End-to-end synthetic composite lifecycle for issue #198.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://tests/fixtures/scenarios/presentation_clip/lifecycle.stla"
const CLIP_ROOT := "res://tests/fixtures/presentation_clips/"
const SE_ROOT := "res://tests/fixtures/audio/bgm/"
const SAVE_DIR := "user://tests/presentation_clip_lifecycle/"
const INDICATOR_TEXTURE_PATH := (
	"res://tests/integration/fixtures/advance_indicator_4x4.svg")

var _runtime: Node
var _game_scene: Node
var _dialogue: Control
var _clip_presenter: PresentationClipPresenter
var _audio_presenter: AudioPresenter
var _context: ScenarioContext
var _original_engine: ScenarioEngine
var _original_clip_root := ""
var _original_se_root := ""
var _original_skip := false
var _original_clip_resource_budget := 0
var _original_clip_viewport_budget := 0
var _original_save_dir := ""
var _master_bus_index := -1
var _original_master_bus_muted := false
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []
var _audio_cues: Array[Dictionary] = []
var _cue_order: Array[String] = []


func before_each() -> void:
	_master_bus_index = AudioServer.get_bus_index(&"Master")
	assert_true(_master_bus_index >= 0, "the canonical Master bus exists")
	_original_master_bus_muted = AudioServer.is_bus_mute(_master_bus_index)
	AudioServer.set_bus_mute(_master_bus_index, true)
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_engine = _runtime.engine
	_original_clip_root = _runtime.presentation_clips_path
	_original_se_root = _runtime.se_path
	_original_skip = _runtime.skip_controller.is_active
	_original_clip_resource_budget = _runtime.presentation_clip_resource_budget_bytes
	_original_clip_viewport_budget = _runtime.presentation_clip_max_viewport_pixels
	_original_save_dir = _runtime.save_manager.save_dir
	_runtime.presentation_clips_path = CLIP_ROOT
	_runtime.se_path = SE_ROOT
	_runtime.skip_controller.is_active = false
	_runtime.save_manager.save_dir = SAVE_DIR
	_runtime.save_manager.delete_quick_save()
	_clip_presenter = _runtime.get_node("PresentationClipPresenter")
	_audio_presenter = _runtime.get_node("AudioPresenter")
	var scenario := ScenarioData.new()
	scenario.id = "presentation_clip_lifecycle"
	scenario.source_path = SOURCE_PATH
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_context = ScenarioContext.new(scenario)
	_context.variable_store = VariableStore.new()
	var engine := ScenarioEngine.new()
	engine.registry = _runtime.registry
	engine.context = _context
	_runtime.engine = engine
	_receipts.clear()
	_terminals.clear()
	_audio_cues.clear()
	_cue_order.clear()
	SignalBus.presentation_clip_transition_receipt_started.connect(_on_receipt)
	SignalBus.presentation_clip_transition_terminal.connect(_on_terminal)
	SignalBus.presentation_clip_audio_cue_requested.connect(_on_audio_cue)
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel")


func after_each() -> void:
	if SignalBus.presentation_clip_transition_receipt_started.is_connected(_on_receipt):
		SignalBus.presentation_clip_transition_receipt_started.disconnect(_on_receipt)
	if SignalBus.presentation_clip_transition_terminal.is_connected(_on_terminal):
		SignalBus.presentation_clip_transition_terminal.disconnect(_on_terminal)
	if SignalBus.presentation_clip_audio_cue_requested.is_connected(_on_audio_cue):
		SignalBus.presentation_clip_audio_cue_requested.disconnect(_on_audio_cue)
	_runtime.presentation_director.cancel_all()
	SignalBus.reset_presentation_clip()
	if _game_scene != null and is_instance_valid(_game_scene):
		_game_scene.queue_free()
		await _game_scene.tree_exited
		await get_tree().process_frame
	_game_scene = null
	_dialogue = null
	_runtime._navigation_scene_change_override = Callable()
	_runtime.presentation_clips_path = _original_clip_root
	_runtime.se_path = _original_se_root
	_runtime.skip_controller.is_active = _original_skip
	_runtime.presentation_clip_resource_budget_bytes = _original_clip_resource_budget
	_runtime.presentation_clip_max_viewport_pixels = _original_clip_viewport_budget
	_runtime.save_manager.delete_quick_save()
	_runtime.save_manager.save_dir = _original_save_dir
	_runtime.engine = _original_engine
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	assert_eq(AudioServer.get_bus_name(_master_bus_index), &"Master")
	AudioServer.set_bus_mute(_master_bus_index, _original_master_bus_muted)
	assert_eq(AudioServer.is_bus_mute(_master_bus_index), _original_master_bus_muted,
		"the test restores the exact pre-existing Master mute state")
	_master_bus_index = -1


func _operation(asset: String, line: int = 20) -> PresentationClipPresentationOperation:
	return PresentationClipPresentationOperation.new(
		{"asset": asset}, {"source_path": SOURCE_PATH, "line": line})


func _submit(
	asset: String,
	policy: PresentationBatchRequest.Policy = PresentationBatchRequest.Policy.JOIN,
	line: int = 20,
) -> PresentationBatchRequest:
	var operations: Array[PresentationOperation] = [_operation(asset, line)]
	return _runtime.presentation_director.submit(
		operations,
		policy,
		_context,
		{"source_path": SOURCE_PATH, "line": line},
	)


func _await_settled(request: PresentationBatchRequest) -> void:
	if request != null and not request.is_settled():
		await request.settled


func _active_request_id() -> int:
	return int(_clip_presenter._active.get("request_id", 0))


func _active_scene_root() -> Node:
	return _clip_presenter._active.get("scene_root") as Node


func _pause_active_main_clock() -> void:
	var scene_root := _active_scene_root()
	if scene_root == null:
		return
	(scene_root.get_node("AnimationPlayer") as AnimationPlayer).pause()


func _dialogue_segment(text: String) -> Dictionary:
	return {"text": text, "voice_layers": [], "expression": ""}


func _indicator_profile() -> Dictionary:
	return {
		"advance_indicator_texture": INDICATOR_TEXTURE_PATH,
		"advance_indicator_scene": "",
		"advance_indicator_offset": Vector2(4, 4),
		"advance_indicator_animation": "none",
	}


func _mouse_advance(position: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	return event


func _key_advance(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.echo = false
	return event


func _joy_advance() -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	return event


func _replace_scene_owned_dialogue_fixture() -> int:
	var outgoing_id := _dialogue.get_instance_id()
	_game_scene.free()
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	return outgoing_id


func _dialogue_target_nodes(target: String) -> Array[CanvasItem]:
	var result: Array[CanvasItem] = []
	for node_value: Variant in _dialogue._dialogue_visibility_nodes.get(target, []):
		var node := node_value as CanvasItem
		if node != null and is_instance_valid(node):
			result.append(node)
	return result


func _first_visible_quick_menu_node() -> CanvasItem:
	for node: CanvasItem in _dialogue_target_nodes("quick_menu"):
		if node.visible:
			return node
	return null


func _assert_clip_projection_retired(label: String) -> void:
	assert_true(_clip_presenter._active.is_empty(), label + " visual active")
	assert_true(_clip_presenter._claimed.is_empty(), label + " visual claims")
	assert_true(_clip_presenter._prepared_plans.is_empty(), label + " visual plans")
	assert_true(_audio_presenter._presentation_clip_audio.is_empty(), label + " audio")
	assert_true(_audio_presenter._presentation_clip_claimed.is_empty(), label + " audio claims")
	assert_true(_dialogue._presentation_clip_suppression.is_empty(), label + " dialogue suppression")
	assert_eq(_clip_presenter._reserved_resource_bytes, 0, label + " resource budget")


func _on_receipt(
	presenter_instance_id: int,
	token: int,
	request_id: int,
	generation: int,
) -> void:
	if presenter_instance_id != _clip_presenter.get_instance_id():
		return
	_receipts.append({
		"presenter": presenter_instance_id,
		"token": token,
		"request_id": request_id,
		"generation": generation,
	})


func _on_terminal(
	presenter_instance_id: int,
	token: int,
	request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if presenter_instance_id != _clip_presenter.get_instance_id():
		return
	_terminals.append({
		"presenter": presenter_instance_id,
		"token": token,
		"request_id": request_id,
		"generation": generation,
		"outcome": outcome,
	})


func _on_audio_cue(request_id: int, cue_index: int, generation: int) -> void:
	_cue_order.append("audio")
	var position := Vector2.ZERO
	var cue_player_is_playing := false
	if not _clip_presenter._active.is_empty():
		var scene_root: Node = _clip_presenter._active.get("scene_root")
		if scene_root != null:
			position = (scene_root.get_node("Visual") as ColorRect).position
	var players_by_cue: Dictionary = _audio_presenter._presentation_clip_audio.get(
		"players_by_cue", {})
	if players_by_cue.has(cue_index):
		var cue_player := players_by_cue[cue_index] as AudioStreamPlayer
		cue_player_is_playing = cue_player != null and cue_player.playing
	_audio_cues.append({
		"request_id": request_id,
		"cue_index": cue_index,
		"generation": generation,
		"visual_position": position,
		"player_is_playing": cue_player_is_playing,
	})


func _on_state_animation_started(animation_name: StringName) -> void:
	_cue_order.append("state:" + String(animation_name))


func test_join_runs_one_clock_and_same_offset_state_cues_in_authored_order() -> void:
	var quick_menu := _first_visible_quick_menu_node()
	assert_not_null(quick_menu, "the public game fixture starts with a visible quick menu")
	var quick_menu_edges: Array[bool] = []
	var record_quick_menu_edge := func() -> void:
		quick_menu_edges.append(quick_menu.visible)
	quick_menu.visibility_changed.connect(record_quick_menu_edge)
	var request := _submit("synthetic_clip")
	assert_false(request.is_settled(), "JOIN waits for the bounded authored timeline")
	assert_false(_clip_presenter._active.is_empty())
	assert_false(_audio_presenter._presentation_clip_audio.is_empty())
	var active_definition: PresentationClipDefinition = (
		_clip_presenter._active.get("definition"))
	assert_eq(active_definition.cues.size(), 3)
	var active_root: Node = _clip_presenter._active.get("scene_root")
	var active_group := _clip_presenter._active.get("visual_group") as CanvasGroup
	assert_eq(active_group.fit_margin, 0.0,
		"the real Presenter owns exact clip texture bounds")
	assert_eq(active_group.clear_margin, 0.0,
		"the real Presenter adds no shader sampling margin")
	var state_player := active_root.get_node("StatePlayer") as AnimationPlayer
	state_player.animation_started.connect(_on_state_animation_started)
	for surface_node: CanvasItem in _dialogue_target_nodes("surface"):
		assert_false(surface_node.visible,
			"published clip suppresses every configured dialogue-surface group")
	await _await_settled(request)
	# The Director settles JOIN inside its terminal listener; yield one real tree
	# boundary so later listeners on that same typed terminal broadcast run.
	await get_tree().process_frame
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), 1)
	assert_eq(_terminals.size(), 1)
	if not _terminals.is_empty():
		assert_eq(_terminals[0].get("outcome"), &"completed")
	assert_eq(_audio_cues.size(), 1)
	if not _audio_cues.is_empty():
		assert_eq(_audio_cues[0].get("cue_index"), 1)
		assert_true(_audio_cues[0].get("player_is_playing", false),
			"the locally muted fixture still exercises real audio playback ownership")
		var observed_position: Vector2 = _audio_cues[0].get("visual_position")
		assert_true(observed_position.x >= 8.0 and observed_position.x < 12.0,
			"audio observes the prior left-state projection before the right state cue")
		assert_eq(observed_position.y, 8.0)
	assert_eq(_cue_order, ["state:left", "audio", "state:right"],
		"cross-kind same-offset cues dispatch in authored array order")
	quick_menu.visibility_changed.disconnect(record_quick_menu_edge)
	assert_eq(quick_menu_edges, [false, true],
		"normal completion hides and restores the quick menu exactly once")
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())


func test_real_presenter_owns_explicit_clip_and_sealed_under_surfaces() -> void:
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 34)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var clip_viewport := _clip_presenter._active.get("clip_viewport") as SubViewport
	var material := _clip_presenter._active.get("material") as ShaderMaterial
	var sealed_under := _clip_presenter._active.get("under_texture") as ImageTexture
	assert_not_null(clip_viewport)
	assert_not_null(material)
	assert_not_null(sealed_under)
	assert_true(material.get_shader_parameter("clip_texture") is ViewportTexture,
		"the real Presenter samples its explicit rendered clip surface")
	assert_same(material.get_shader_parameter("clip_texture"),
		clip_viewport.get_texture())
	assert_same(material.get_shader_parameter("under_texture"), sealed_under,
		"the projector never falls through to a default white sampler")
	var before_image := sealed_under.get_image()
	assert_false(before_image.is_empty())
	var before_bytes := before_image.get_data()
	await get_tree().process_frame
	var bytes_unchanged := sealed_under.get_image().get_data() == before_bytes
	assert_true(bytes_unchanged,
		"FNF retains one immutable under snapshot for its whole active lifetime")
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	_assert_clip_projection_retired("explicit-surface terminal")


func test_state_animation_is_projected_only_from_the_bounded_main_clock() -> void:
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 35)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var request_id := int(_clip_presenter._active.get("request_id", 0))
	var scene_root: Node = _clip_presenter._active.get("scene_root")
	var main_player := scene_root.get_node("AnimationPlayer") as AnimationPlayer
	var state_player := scene_root.get_node("StatePlayer") as AnimationPlayer
	main_player.pause()
	main_player.seek(0.15, true)
	_clip_presenter._process(0.0)
	assert_eq(state_player.current_animation, &"right")
	assert_almost_eq(state_player.current_animation_position, 0.05, 0.0001,
		"named-state time is derived from main position minus authored offset")
	assert_eq(
		state_player.callback_mode_process,
		AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL,
		"named-state AnimationPlayer never owns an autonomous clock")
	assert_eq((scene_root.get_node("Visual") as ColorRect).position, Vector2(18, 8))
	SignalBus.presentation_clip_finish_requested.emit(request_id)
	assert_true(_clip_presenter._active.is_empty())


func test_particles_are_a_deterministic_projection_of_only_the_main_clock() -> void:
	var request := _submit(
		"synthetic_particle_clip",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		36,
	)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var projections: Array = _clip_presenter._active.get(
		"particle_projections", [])
	assert_eq(projections.size(), 2)
	if projections.size() != 2:
		return
	assert_eq((projections[0] as Dictionary).get("id"), &"burst_front")
	assert_eq((projections[1] as Dictionary).get("id"), &"rate_back")
	var pool_size := 0
	for projection_value: Variant in projections:
		var multimesh := (projection_value as Dictionary).get("multimesh") as MultiMesh
		pool_size += multimesh.instance_count
	assert_eq(pool_size, 8, "the bounded pool is fully reserved before publication")
	var main := _clip_presenter._active.get("animation_player") as AnimationPlayer
	var schedule_identity := func() -> String:
		var values: Array = []
		for projection_value: Variant in (
			_clip_presenter._active.get("particle_projections", []) as Array):
			var projection := projection_value as Dictionary
			values.append([
				String(projection.get("id")),
				projection.get("spawn_times"),
				projection.get("spawn_x"),
				projection.get("spawn_y"),
				projection.get("motion_scales"),
				projection.get("initial_scales"),
				projection.get("initial_rotations"),
			])
		return str(values)
	var visible_counts := func() -> Array[int]:
		var values: Array[int] = []
		for projection_value: Variant in (
			_clip_presenter._active.get("particle_projections", []) as Array):
			var multimesh := (projection_value as Dictionary).get(
				"multimesh") as MultiMesh
			values.append(multimesh.visible_instance_count)
		return values
	var sealed_schedule_identity: String = schedule_identity.call()
	main.pause()
	main.seek(0.25, true)
	_clip_presenter._process(0.0)
	assert_eq(visible_counts.call(), [3, 2],
		"the second sealed spawn .2495960786 <= .250001 while the first remains in its 0.3s lifetime window")
	assert_eq(String(schedule_identity.call()), sealed_schedule_identity,
		"projection does not mutate the sealed event arrays")
	main.seek(0.2, true)
	_clip_presenter._process(0.0)
	var first_counts: Array[int] = visible_counts.call()
	assert_eq(first_counts, [3, 1])
	await get_tree().process_frame
	_clip_presenter._process(0.0)
	assert_eq(visible_counts.call(), first_counts,
		"a paused main position has no autonomous particle clock")
	main.seek(0.55, true)
	_clip_presenter._process(0.0)
	assert_eq(visible_counts.call(), [3, 2],
		"a different authored position projects a different bounded state")
	main.seek(0.2, true)
	_clip_presenter._process(0.0)
	assert_eq(visible_counts.call(), first_counts,
		"seeking back reprojects the exact stable seed and spawn order")
	assert_eq(String(schedule_identity.call()), sealed_schedule_identity,
		"same-position reseek preserves every sealed event array exactly")
	var particle_root := _clip_presenter._active.get("particle_root") as Node2D
	var input_blocker := _clip_presenter._active.get("input_blocker") as Control
	SignalBus.reset_presentation_clip()
	assert_true(_clip_presenter._active.is_empty())
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)
	assert_true(input_blocker.is_queued_for_deletion(),
		"reset retires the exact owner of the particle subtree")
	await get_tree().process_frame
	assert_false(is_instance_valid(input_blocker))
	assert_false(is_instance_valid(particle_root),
		"reset retires the whole preallocated pool without a tail clock")


func test_interleaved_state_players_project_in_latest_authored_activation_order() -> void:
	var request := _submit(
		"synthetic_clip_interleaved",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		37,
	)
	await _await_settled(request)
	var request_id := int(_clip_presenter._active.get("request_id", 0))
	var scene_root: Node = _clip_presenter._active.get("scene_root")
	var main_player := scene_root.get_node("AnimationPlayer") as AnimationPlayer
	main_player.pause()
	main_player.seek(0.1, true)
	_clip_presenter._process(0.0)
	var projections: Array = _clip_presenter._active.get("state_projections", [])
	assert_eq(projections.size(), 2)
	if projections.size() == 2:
		assert_eq(int((projections[0] as Dictionary).get("ordinal")), 1)
		assert_eq(int((projections[1] as Dictionary).get("ordinal")), 2)
	assert_eq((scene_root.get_node("Visual") as ColorRect).position, Vector2(18, 8),
		"A/B/A activation re-appends latest A after B for every main-clock projection")
	SignalBus.presentation_clip_finish_requested.emit(request_id)


func test_state_cue_cannot_replace_the_bounded_main_animation_player() -> void:
	var request := _submit(
		"invalid_main_state_clip", PresentationBatchRequest.Policy.JOIN, 38)
	await _await_settled(request)
	assert_push_error(
		SOURCE_PATH + ":38] presentation clip request rejected: visual participant: "
		+ "clip 'invalid_main_state_clip' definition: "
		+ "res://tests/fixtures/presentation_clips/invalid_main_state_clip.tres "
		+ "cues[0]: named state cue must not target the bounded main AnimationPlayer")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(_clip_presenter._active.is_empty())


func test_public_definition_snapshot_and_cached_resource_cannot_mutate_active() -> void:
	var public_values: Array[Dictionary] = []
	var capture := func(request: PresentationClipOperationRequest) -> void:
		public_values.append(request.get_definition())
	SignalBus.presentation_clip_validate_requested.connect(capture)
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 36)
	SignalBus.presentation_clip_validate_requested.disconnect(capture)
	await _await_settled(request)
	assert_eq(public_values.size(), 1)
	var before_fingerprint := String(
		(_clip_presenter._active.get("definition") as PresentationClipDefinition)
			.semantic_fingerprint())
	var before_resource_bytes := int(_clip_presenter._active.get("resource_bytes", 0))
	public_values[0]["skippable"] = false
	public_values[0]["exit_transition"] = "cut"
	(public_values[0].get("cues", []) as Array).clear()
	var cached := load(CLIP_ROOT + "synthetic_clip.tres") as PresentationClipDefinition
	var cached_skippable := cached.skippable
	var cached_exit_transition := cached.exit_transition
	var cached_exit_duration := cached.exit_duration
	var cached_cues: Array[PresentationClipCue] = []
	for cue: PresentationClipCue in cached.cues:
		cached_cues.append(cue)
	cached.skippable = false
	cached.exit_transition = &"cut"
	cached.exit_duration = 0.0
	cached.cues.clear()
	var active_definition := (
		_clip_presenter._active.get("definition") as PresentationClipDefinition)
	assert_true(active_definition.skippable)
	assert_eq(active_definition.exit_transition, &"turn")
	assert_eq(active_definition.cues.size(), 3)
	assert_eq(active_definition.semantic_fingerprint(), before_fingerprint)
	assert_eq(int(_clip_presenter._active.get("resource_bytes", 0)),
		before_resource_bytes)
	cached.skippable = cached_skippable
	cached.exit_transition = cached_exit_transition
	cached.exit_duration = cached_exit_duration
	cached.cues.clear()
	for cue: PresentationClipCue in cached_cues:
		cached.cues.append(cue)
	var request_id := int(_clip_presenter._active.get("request_id", 0))
	SignalBus.presentation_clip_finish_requested.emit(request_id)
	assert_true(_clip_presenter._active.is_empty(),
		"the sealed skippable/exit/cue snapshot is unaffected by retained aliases")


func test_bgm_reset_during_validation_does_not_revoke_clip_authority() -> void:
	var before_clip_epoch := SignalBus.current_presentation_clip_epoch()
	var before_bgm_epoch := SignalBus.current_bgm_epoch()
	var reset_bgm := func(_request: PresentationClipOperationRequest) -> void:
		SignalBus.reset_bgm_presentation()
	SignalBus.presentation_clip_validate_requested.connect(
		reset_bgm, CONNECT_ONE_SHOT)
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 38)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED,
		"orthogonal BGM reset cannot revoke the captured clip transaction")
	assert_eq(SignalBus.current_bgm_epoch(), before_bgm_epoch + 1)
	assert_eq(SignalBus.current_presentation_clip_epoch(), before_clip_epoch)
	assert_false(_clip_presenter._active.is_empty())
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	_assert_clip_projection_retired("orthogonal BGM reset")


func test_bgm_reset_during_bgm_validation_fails_the_same_domain_request() -> void:
	var committed_count: Array[int] = [0]
	var receipt_count: Array[int] = [0]
	var on_committed := func(
		_operation: BgmPresentationOperation,
		_force_cut: bool,
		_request_id: int,
	) -> void:
		committed_count[0] += 1
	var on_receipt := func(
		_presenter_id: int,
		_token: int,
		_request_id: int,
		_generation: int,
	) -> void:
		receipt_count[0] += 1
	var reset_bgm := func(_request: BgmOperationRequest) -> void:
		SignalBus.reset_bgm_presentation()
	SignalBus.bgm_operation_committed.connect(on_committed)
	SignalBus.bgm_transition_receipt_started.connect(on_receipt)
	SignalBus.bgm_validate_requested.connect(reset_bgm, CONNECT_ONE_SHOT)
	var operations: Array[PresentationOperation] = [
		BgmPresentationOperation.new({
			"action": "stop",
			"asset": "",
			"cue": "",
			"fade_duration": 0.0,
			"resume_position": 0.0,
			"stem_mix": {},
			"volume": 1.0,
		}, {"source_path": SOURCE_PATH, "line": 381}),
	]
	var request: PresentationBatchRequest = _runtime.presentation_director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		{"source_path": SOURCE_PATH, "line": 381},
	)
	assert_push_error(SOURCE_PATH + ":381")
	await _await_settled(request)
	assert_ne(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED,
		"a direct same-domain reset fail-closes the captured BGM request")
	assert_eq(committed_count[0], 0)
	assert_eq(receipt_count[0], 0)
	assert_true(_runtime.presentation_director._entries.is_empty())
	SignalBus.bgm_operation_committed.disconnect(on_committed)
	SignalBus.bgm_transition_receipt_started.disconnect(on_receipt)


func test_receipt_listener_reset_cannot_write_back_old_generation() -> void:
	var resetter := func(
		presenter_id: int, _token: int, _request_id: int, _generation: int,
	) -> void:
		if presenter_id == _clip_presenter.get_instance_id():
			SignalBus.reset_presentation_clip()
	SignalBus.presentation_clip_transition_receipt_started.connect(resetter)
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 39)
	SignalBus.presentation_clip_transition_receipt_started.disconnect(resetter)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED,
		"the synchronous reset boundary owns cancellation of the old request")
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_dialogue._presentation_clip_suppression.is_empty())
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)


func test_main_animation_started_reset_cannot_reveal_or_recreate_old_clip() -> void:
	var on_apply := func(_request: PresentationClipOperationRequest) -> void:
		if _clip_presenter._claimed.is_empty():
			return
		var player := (
			_clip_presenter._claimed.get("animation_player") as AnimationPlayer)
		player.animation_started.connect(
			func(animation_name: StringName) -> void:
				if animation_name == &"clip":
					SignalBus.reset_presentation_clip(),
			CONNECT_ONE_SHOT,
		)
	SignalBus.presentation_clip_apply_requested.connect(on_apply)
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 40)
	SignalBus.presentation_clip_apply_requested.disconnect(on_apply)
	await _await_settled(request)
	assert_push_error(
		SOURCE_PATH + ":40] presentation clip request rejected: "
		+ "request invalidated during publication preparation")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED,
		"the synchronous reset boundary owns cancellation of the old request")
	assert_true(_clip_presenter._active.is_empty())
	assert_eq(_receipts.size(), 0,
		"main animation re-entry happens before receipt publication")
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_dialogue._presentation_clip_suppression.is_empty())


func test_audio_cue_reset_cannot_dispatch_later_cue_or_resurrect_active() -> void:
	var resetter := func(
		_request_id: int, cue_ordinal: int, _generation: int,
	) -> void:
		if cue_ordinal == 1:
			SignalBus.reset_presentation_clip()
	SignalBus.presentation_clip_audio_cue_requested.connect(resetter)
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 41)
	await _await_settled(request)
	var main_player := (
		_clip_presenter._active.get("animation_player") as AnimationPlayer)
	main_player.pause()
	main_player.seek(0.15, true)
	_clip_presenter._process(0.0)
	SignalBus.presentation_clip_audio_cue_requested.disconnect(resetter)
	assert_eq(_audio_cues.size(), 1)
	assert_eq(_cue_order, ["audio"],
		"reset at the audio ordinal prevents the later state callback")
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_dialogue._presentation_clip_suppression.is_empty())


func test_nested_finish_preclaims_current_cue_and_skips_pending_audio_once() -> void:
	var request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 42)
	await _await_settled(request)
	var scene_root: Node = _clip_presenter._active.get("scene_root")
	var state_player := scene_root.get_node("StatePlayer") as AnimationPlayer
	state_player.animation_started.connect(_on_state_animation_started)
	var request_id := int(_clip_presenter._active.get("request_id", 0))
	var finisher := func(animation_name: StringName) -> void:
		if animation_name == &"left":
			SignalBus.presentation_clip_finish_requested.emit(request_id)
	state_player.animation_started.connect(finisher)
	var main_player := scene_root.get_node("AnimationPlayer") as AnimationPlayer
	main_player.pause()
	main_player.seek(0.1, true)
	_clip_presenter._process(0.0)
	assert_eq(_cue_order, ["state:left", "state:right"],
		"nested finish cannot replay its already-claimed state ordinal")
	assert_eq(_audio_cues.size(), 0, "finish skips not-yet-fired audio cues")
	assert_true(_clip_presenter._active.is_empty())


func test_resource_and_viewport_budgets_fail_before_claim_and_return_to_zero() -> void:
	_runtime.presentation_clip_resource_budget_bytes = 1
	var resource_rejected := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.JOIN, 43)
	await _await_settled(resource_rejected)
	assert_push_error(
		SOURCE_PATH + ":43] presentation clip request rejected: visual participant: "
		+ "clip 'synthetic_clip' definition: clip textures, transition surfaces, "
		+ "and particle work exceed the configured resource budget; clip participant "
		+ "'visual:%d' did not validate" % _clip_presenter.get_instance_id())
	assert_eq(resource_rejected.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)
	_runtime.presentation_clip_resource_budget_bytes = _original_clip_resource_budget
	_runtime.presentation_clip_max_viewport_pixels = 1
	var viewport_rejected := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.JOIN, 44)
	await _await_settled(viewport_rejected)
	assert_push_error(
		SOURCE_PATH + ":44] presentation clip request rejected: visual participant: "
		+ "clip 'synthetic_clip' definition: clip logical or target viewport "
		+ "exceeds the configured pixel budget")
	assert_eq(viewport_rejected.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)


func test_equal_entry_boundary_replaces_its_tween_once_without_late_write() -> void:
	var request := _submit(
		"synthetic_clip_equal_entry",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		45,
	)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var entry_tween := _clip_presenter._active.get("transition_tween") as Tween
	assert_not_null(entry_tween)
	var main := _clip_presenter._active.get("animation_player") as AnimationPlayer
	main.advance(0.2)
	assert_false(_clip_presenter._active.is_empty())
	assert_eq(_clip_presenter._active.get("phase"), &"exiting")
	var exit_tween := _clip_presenter._active.get("transition_tween") as Tween
	assert_not_null(exit_tween)
	assert_ne(exit_tween, entry_tween,
		"natural end at the entry boundary owns one replacement Tween")
	assert_false(entry_tween.is_valid(),
		"the entry Tween cannot retain a late shader write after exit starts")
	exit_tween.custom_step(0.05)
	_assert_clip_projection_retired("equal entry/exit boundary")


func test_fnf_dialogue_show_keeps_surface_indicator_and_menu_suppressed() -> void:
	var quick_menu := _first_visible_quick_menu_node()
	assert_not_null(quick_menu)
	var quick_menu_edges: Array[bool] = []
	var record_quick_menu_edge := func() -> void:
		quick_menu_edges.append(quick_menu.visible)
	quick_menu.visibility_changed.connect(record_quick_menu_edge)
	var request := _submit(
		"synthetic_clip_long",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		46,
	)
	await _await_settled(request)
	_pause_active_main_clock()
	_dialogue._char_interval = 0.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("Latest dialogue under the active clip")], "adv",
		_indicator_profile(), true)
	var ready: bool = await wait_until(
		func() -> bool:
			return _dialogue._dialogue_ready and not _dialogue._is_typing,
		2.0,
		"the latest dialogue reaches its real ready boundary while suppressed",
	)
	assert_true(ready)
	var indicator := _dialogue.get_node_or_null("AdvanceIndicator") as CanvasItem
	assert_not_null(indicator)
	var indicator_edges: Array[bool] = []
	var record_indicator_edge := func() -> void:
		indicator_edges.append(indicator.visible)
	indicator.visibility_changed.connect(record_indicator_edge)
	for surface_node: CanvasItem in _dialogue_target_nodes("surface"):
		assert_false(surface_node.is_visible_in_tree(),
			"a later SHOW cannot reveal a suppressed dialogue surface")
	for menu_node: CanvasItem in _dialogue_target_nodes("quick_menu"):
		assert_false(menu_node.is_visible_in_tree(),
			"a later profile cannot reveal a suppressed quick menu")
	assert_true(indicator == null or not indicator.visible,
		"the ready marker shares the canonical effective surface gate")
	assert_eq(quick_menu_edges, [false],
		"SHOW/profile changes do not replay quick-menu visibility while suppressed")
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	var indicator_restored: bool = await wait_until(
		func() -> bool:
			return (
				indicator != null
				and is_instance_valid(indicator)
				and indicator.visible
			),
		2.0,
		"the latest line marker restores after clip retirement",
	)
	assert_true(indicator_restored)
	assert_eq(indicator_edges, [true],
		"only the latest ready marker restores once after suppression retires")
	assert_eq(quick_menu_edges, [false, true],
		"the latest canonical quick-menu baseline restores exactly once")
	indicator.visibility_changed.disconnect(record_indicator_edge)
	quick_menu.visibility_changed.disconnect(record_quick_menu_edge)


func test_advance_indicator_follows_canonical_surface_visibility() -> void:
	_dialogue._char_interval = 0.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("Canonical surface marker")], "adv",
		_indicator_profile(), true)
	var initially_ready: bool = await wait_until(
		func() -> bool:
			var marker := _dialogue.get_node_or_null("AdvanceIndicator") as CanvasItem
			return marker != null and marker.visible,
		2.0,
		"the canonical visible surface admits its latest marker",
	)
	assert_true(initially_ready)
	var indicator := _dialogue.get_node("AdvanceIndicator") as CanvasItem
	var binding: Dictionary = _dialogue._dialogue_visibility_runtime_binding
	var hide := DialogueVisibilityPresentationOperation.new({
		"action": "hide", "duration": 0.0,
		"target": "surface", "transition": "cut",
	}, binding, {"source_path": SOURCE_PATH, "line": 461})
	var hide_operations: Array[PresentationOperation] = [hide]
	var hide_request: PresentationBatchRequest = _runtime.presentation_director.submit(
		hide_operations, PresentationBatchRequest.Policy.FIRE_AND_FORGET, _context,
		{"source_path": SOURCE_PATH, "line": 461})
	await _await_settled(hide_request)
	assert_false(indicator.visible,
		"canonical surface=false hides the marker without a clip-only bypass")
	var show := DialogueVisibilityPresentationOperation.new({
		"action": "show", "duration": 0.0,
		"target": "surface", "transition": "cut",
	}, binding, {"source_path": SOURCE_PATH, "line": 462})
	var show_operations: Array[PresentationOperation] = [show]
	var show_request: PresentationBatchRequest = _runtime.presentation_director.submit(
		show_operations, PresentationBatchRequest.Policy.FIRE_AND_FORGET, _context,
		{"source_path": SOURCE_PATH, "line": 462})
	await _await_settled(show_request)
	var restored: bool = await wait_until(
		func() -> bool: return indicator.visible,
		2.0,
		"the same latest marker restores after canonical surface=true",
	)
	assert_true(restored)

	var fade_hide := DialogueVisibilityPresentationOperation.new({
		"action": "hide", "duration": 0.2,
		"target": "surface", "transition": "fade",
	}, binding, {"source_path": SOURCE_PATH, "line": 463})
	var fade_hide_operations: Array[PresentationOperation] = [fade_hide]
	var fade_hide_request: PresentationBatchRequest = _runtime.presentation_director.submit(
		fade_hide_operations, PresentationBatchRequest.Policy.JOIN, _context,
		{"source_path": SOURCE_PATH, "line": 463})
	var fade_hide_active: Dictionary = (
		_dialogue._dialogue_visibility_active.get("surface", {}))
	var fade_hide_tween := fade_hide_active.get("tween") as Tween
	assert_not_null(fade_hide_tween)
	assert_true(indicator.visible,
		"the marker begins the hide fade with the canonical surface")
	if fade_hide_tween != null:
		fade_hide_tween.custom_step(0.1)
	assert_true(indicator.visible)
	assert_true(indicator.modulate.a > 0.0 and indicator.modulate.a < 1.0,
		"the marker shares the surface fade projection at its midpoint")
	if fade_hide_tween != null:
		fade_hide_tween.custom_step(0.1)
	await _await_settled(fade_hide_request)
	assert_false(indicator.visible)
	assert_eq(indicator.modulate.a, 1.0,
		"temporary fade alpha is restored at the hidden stable target")

	var fade_show := DialogueVisibilityPresentationOperation.new({
		"action": "show", "duration": 0.2,
		"target": "surface", "transition": "fade",
	}, binding, {"source_path": SOURCE_PATH, "line": 464})
	var fade_show_operations: Array[PresentationOperation] = [fade_show]
	var fade_show_request: PresentationBatchRequest = _runtime.presentation_director.submit(
		fade_show_operations, PresentationBatchRequest.Policy.JOIN, _context,
		{"source_path": SOURCE_PATH, "line": 464})
	var fade_show_active: Dictionary = (
		_dialogue._dialogue_visibility_active.get("surface", {}))
	var fade_show_tween := fade_show_active.get("tween") as Tween
	assert_not_null(fade_show_tween)
	assert_true(indicator.visible)
	assert_eq(indicator.modulate.a, 0.0,
		"the marker begins the show fade at the same transparent endpoint")
	if fade_show_tween != null:
		fade_show_tween.custom_step(0.1)
	assert_true(indicator.modulate.a > 0.0 and indicator.modulate.a < 1.0)
	if fade_show_tween != null:
		fade_show_tween.custom_step(0.1)
	await _await_settled(fade_show_request)
	assert_true(indicator.visible)
	assert_eq(indicator.modulate.a, 1.0)


func test_active_clip_claims_real_input_before_hidden_dialogue_and_gui() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_dialogue._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("The underlying dialogue must not advance")], "adv")
	var owner_ready: bool = await wait_until(
		func() -> bool:
			return (
				_dialogue._is_typing
				and _dialogue.text_label.visible_characters > 0
				and _dialogue._dialogue_timer_waiters.size() == 1
			),
		2.0,
		"the underlying line establishes its real typewriter owner",
	)
	assert_true(owner_ready)
	var dialogue_generation := int(_dialogue._dialogue_gen)
	var visible_characters := int(_dialogue.text_label.visible_characters)
	var timer_waiter_ids: Array = _dialogue._dialogue_timer_waiters.keys()
	_dialogue._ui_hidden = true
	_dialogue.visible = false
	var raw_advance_count: Array[int] = [0]
	var on_raw_advance := func() -> void: raw_advance_count[0] += 1
	SignalBus.advance_requested.connect(on_raw_advance)
	var fnf := _submit(
		"synthetic_clip_long",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		47,
	)
	await _await_settled(fnf)
	_pause_active_main_clock()
	var blocker := _clip_presenter._active.get("input_blocker") as Control
	var pointer := Vector2(16, 16)
	var motion := InputEventMouseMotion.new()
	motion.position = pointer
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	assert_same(get_viewport().gui_get_hovered_control(), blocker,
		"the real pointer is over the presenter-owned full-screen blocker")
	var before_terminals := _terminals.size()
	get_viewport().push_input(_mouse_advance(pointer), true)
	await get_tree().process_frame
	assert_true(_clip_presenter._active.is_empty())
	assert_eq(_terminals.size(), before_terminals + 1,
		"the public SceneTree mouse route completes the clip exactly once")
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_eq(_dialogue.text_label.visible_characters, visible_characters)
	assert_eq(_dialogue._dialogue_timer_waiters.keys(), timer_waiter_ids,
		"the real mouse edge cannot replace the hidden typewriter timer owner")
	assert_true(_dialogue._ui_hidden,
		"the foremost clip consumes the click before soft-hidden restoration")
	assert_eq(raw_advance_count[0], 0,
		"a physical clip completion does not echo an underlying advance")

	_dialogue._ui_hidden = false
	_dialogue.visible = true
	var join := _submit("synthetic_clip_long", PresentationBatchRequest.Policy.JOIN, 48)
	_pause_active_main_clock()
	get_viewport().push_input(_key_advance(KEY_SPACE), true)
	await get_tree().process_frame
	await _await_settled(join)
	assert_eq(join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_eq(_dialogue.text_label.visible_characters, visible_characters)
	assert_eq(_dialogue._dialogue_timer_waiters.keys(), timer_waiter_ids)

	var joy_fnf := _submit(
		"synthetic_clip_long",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		49,
	)
	await _await_settled(joy_fnf)
	_pause_active_main_clock()
	get_viewport().push_input(_joy_advance(), true)
	await get_tree().process_frame
	assert_true(_clip_presenter._active.is_empty())
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_eq(_dialogue._dialogue_timer_waiters.keys(), timer_waiter_ids)
	assert_eq(raw_advance_count[0], 0)
	SignalBus.advance_requested.disconnect(on_raw_advance)


func test_public_raw_typed_ctrl_and_skip_respect_active_clip_modal_owner() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_dialogue._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("Modal input owner")], "adv")
	_dialogue.complete_typewriter()
	var dialogue_generation := int(_dialogue._dialogue_gen)
	var visible_characters := int(_dialogue.text_label.visible_characters)
	var unskippable := _submit(
		"synthetic_clip_unskippable",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		50,
	)
	await _await_settled(unskippable)
	_pause_active_main_clock()
	SignalBus.advance_requested.emit()
	assert_false(_clip_presenter._active.is_empty(),
		"raw public advance is claimed but cannot finish an unskippable clip")
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_eq(_dialogue.text_label.visible_characters, visible_characters)
	assert_true(_dialogue.request_current_dialogue_advance(),
		"the typed presenter input is consumed by the modal clip")
	assert_false(_clip_presenter._active.is_empty())
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	get_viewport().push_input(_key_advance(KEY_CTRL), true)
	await get_tree().process_frame
	assert_false(_clip_presenter._active.is_empty(),
		"Ctrl cannot bypass an unskippable modal projection")
	assert_false(_dialogue._ctrl_held)
	_runtime.skip_controller.is_active = true
	await get_tree().process_frame
	assert_false(_clip_presenter._active.is_empty(),
		"persistent Skip cannot cut an unskippable active clip")
	assert_false(_runtime.skip_controller.is_active,
		"the claimed Skip edge cannot remain armed against content behind the clip")
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	SignalBus.reset_presentation_clip()
	_runtime.skip_controller.is_active = false


func test_persistent_skip_is_consumed_by_published_unskippable_fnf() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.skip_controller.is_active = true
	var request := _submit(
		"synthetic_clip_unskippable",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		525,
	)
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_clip_presenter._active.is_empty(),
		"the unskippable bounded projection remains active")
	assert_false(_runtime.skip_controller.is_active,
		"the published modal owner consumes pre-existing persistent Skip intent")
	_pause_active_main_clock()
	_dialogue._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("Typing behind an unskippable FNF clip")], "adv")
	var owner_ready: bool = await wait_until(
		func() -> bool:
			return (
				_dialogue._is_typing
				and _dialogue.text_label.visible_characters > 0
				and _dialogue._dialogue_timer_waiters.size() == 1
			),
		2.0,
		"the dialogue establishes its real timer owner after Skip is consumed",
	)
	assert_true(owner_ready)
	var dialogue_generation := int(_dialogue._dialogue_gen)
	var visible_characters := int(_dialogue.text_label.visible_characters)
	var timer_waiter_count: int = _dialogue._dialogue_timer_waiters.size()
	var timer_waiter_ids: Array = _dialogue._dialogue_timer_waiters.keys()
	await get_tree().process_frame
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_eq(_dialogue.text_label.visible_characters, visible_characters)
	assert_eq(_dialogue._dialogue_timer_waiters.size(), timer_waiter_count,
		"the consumed Skip intent cannot retire or replace the line timer owner")
	assert_eq(_dialogue._dialogue_timer_waiters.keys(), timer_waiter_ids)
	assert_true(_dialogue._is_typing,
		"the bounded clip leaves the underlying typewriter owner intact")
	SignalBus.reset_presentation_clip()


func test_auto_commit_does_not_masquerade_as_player_clip_finish() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var activation := DialogueActivation.new()
	SignalBus.emit_dialogue_request(DialogueRequest.new(
		"",
		[_dialogue_segment("Auto continues authored FNF progression")],
		"adv", {}, false, "", {}, [], "clip-auto-dialogue", 53,
		activation,
	))
	var request := _submit(
		"synthetic_clip_long",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		53,
	)
	await _await_settled(request)
	_pause_active_main_clock()
	var clip_request_id := _active_request_id()
	assert_true(_dialogue._commit_current_dialogue_advance(),
		"the Auto-owned commit seam may settle the typed FNF successor")
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ADVANCED)
	assert_eq(_active_request_id(), clip_request_id,
		"Auto progression does not impersonate a player/Skip clip finish")
	SignalBus.presentation_clip_finish_requested.emit(clip_request_id)


func test_mid_active_skip_claims_fnf_and_join_once() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_dialogue._char_interval = 0.0
	SignalBus.emit_show_dialogue(
		"", [_dialogue_segment("Skip remains owned by the active clip")], "adv")
	_dialogue.complete_typewriter()
	var dialogue_generation := int(_dialogue._dialogue_gen)

	var skip_fnf := _submit(
		"synthetic_clip_long",
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		51,
	)
	await _await_settled(skip_fnf)
	_pause_active_main_clock()
	_runtime.skip_controller.is_active = true
	await get_tree().process_frame
	assert_true(_clip_presenter._active.is_empty(),
		"a mid-active Skip finishes the FNF skippable boundary")
	assert_false(_runtime.skip_controller.is_active)
	_runtime.skip_controller.is_active = false
	var skip_join := _submit(
		"synthetic_clip_long", PresentationBatchRequest.Policy.JOIN, 52)
	_pause_active_main_clock()
	_runtime.skip_controller.is_active = true
	await _await_settled(skip_join)
	assert_eq(skip_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_dialogue._dialogue_gen, dialogue_generation)
	assert_false(_runtime.skip_controller.is_active)
	_runtime.skip_controller.is_active = false


func test_persistent_skip_force_cuts_only_a_skippable_clip_after_preflight() -> void:
	var before_visibility: Dictionary = {}
	for target: String in ["surface", "quick_menu"]:
		for node: CanvasItem in _dialogue_target_nodes(target):
			before_visibility[node.get_instance_id()] = node.visible
	var quick_menu := _first_visible_quick_menu_node()
	assert_not_null(quick_menu)
	var quick_menu_edges: Array[bool] = []
	var record_quick_menu_edge := func() -> void:
		quick_menu_edges.append(quick_menu.visible)
	quick_menu.visibility_changed.connect(record_quick_menu_edge)
	_runtime.skip_controller.is_active = true
	var request := _submit("synthetic_clip")
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), 0, "force-cut creates no transition receipt")
	assert_eq(_audio_cues.size(), 0, "skip never plays pending system-audio cues")
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_dialogue._presentation_clip_suppression.is_empty(),
		"a synchronously completed clip cannot leave late UI suppression behind")
	for surface_node: CanvasItem in _dialogue_target_nodes("surface"):
		assert_eq(
			surface_node.visible,
			bool(before_visibility.get(surface_node.get_instance_id())),
			"surface visibility is restored after the cut clip settles")
	for menu_node: CanvasItem in _dialogue_target_nodes("quick_menu"):
		assert_eq(
			menu_node.visible,
			bool(before_visibility.get(menu_node.get_instance_id())),
			"quick-menu visibility is restored after the cut clip settles")
	assert_eq(quick_menu_edges, [false, true],
		"persistent Skip hides and restores the quick menu exactly once")
	SignalBus.advance_requested.emit()
	assert_eq(quick_menu_edges, [false, true],
		"the next ordinary advance cannot replay the retired clip boundary")
	quick_menu.visibility_changed.disconnect(record_quick_menu_edge)


func test_persistent_skip_does_not_cut_an_unskippable_clip() -> void:
	_runtime.skip_controller.is_active = true
	var request := _submit("synthetic_clip_unskippable")
	assert_false(request.is_settled())
	assert_false(_runtime.skip_controller.is_active,
		"publication consumes the persistent intent without cutting the clip")
	assert_eq(_receipts.size(), 1,
		"an unskippable clip keeps its real bounded clock under persistent Skip")
	SignalBus.advance_requested.emit()
	assert_false(request.is_settled(), "active advance/Skip edges cannot cut it either")
	await _await_settled(request)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_missing_definition_fails_source_located_before_any_claim() -> void:
	var request := _submit("missing_clip", PresentationBatchRequest.Policy.JOIN, 77)
	await _await_settled(request)
	assert_push_error(SOURCE_PATH + ":77")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(_clip_presenter._prepared_plans.is_empty())
	assert_true(_clip_presenter._claimed.is_empty())
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_audio_presenter._presentation_clip_prepared.is_empty())
	assert_eq(_receipts.size(), 0)


func test_later_missing_audio_cue_rejects_the_whole_plan_before_mutation() -> void:
	var request := _submit(
		"invalid_audio_clip", PresentationBatchRequest.Policy.JOIN, 78)
	await _await_settled(request)
	assert_push_error(
		SOURCE_PATH + ":78] presentation clip request rejected: audio participant: "
		+ CLIP_ROOT + "invalid_audio_clip.tres cues[0] authored at "
		+ SOURCE_PATH + ":79 asset 'missing_synthetic_system_cue' could not be resolved")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_clip_presenter._claimed.is_empty())
	assert_true(_clip_presenter._prepared_plans.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_audio_presenter._presentation_clip_claimed.is_empty())
	assert_true(_audio_presenter._presentation_clip_prepared.is_empty())
	assert_true(_dialogue._presentation_clip_suppression.is_empty())
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)
	assert_eq(_receipts.size(), 0)
	assert_eq(_audio_cues.size(), 0)


func test_later_participant_retirement_rolls_back_claim_and_preserves_active() -> void:
	var active_request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 90)
	await _await_settled(active_request)
	assert_eq(active_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_clip_presenter._active.is_empty())
	var active_root: Node = _clip_presenter._active.get("scene_root")
	var active_resource_bytes := _clip_presenter._reserved_resource_bytes
	var invalidator := func(_request: PresentationClipOperationRequest) -> void:
		if _dialogue != null and is_instance_valid(_dialogue):
			_dialogue.queue_free()
	SignalBus.presentation_clip_apply_requested.connect(invalidator)
	var replacement := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.JOIN, 91)
	SignalBus.presentation_clip_apply_requested.disconnect(invalidator)
	await _await_settled(replacement)
	assert_push_error(
		"[%s:91] presentation clip request rejected: dialogue participant retired during apply"
		% SOURCE_PATH)
	assert_eq(replacement.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_false(_clip_presenter._active.is_empty())
	assert_same(_clip_presenter._active.get("scene_root"), active_root,
		"failed B releases only its hidden claim and preserves published A")
	assert_true(_clip_presenter._claimed.is_empty())
	assert_true(_audio_presenter._presentation_clip_claimed.is_empty())
	assert_eq(_receipts.size(), 1, "failed B creates no new receipt")
	assert_eq(_clip_presenter._reserved_resource_bytes, active_resource_bytes,
		"failed B releases only its reservation and preserves active A budget")


func test_publication_preparation_retirement_preserves_published_a() -> void:
	var active_request := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 92)
	await _await_settled(active_request)
	var active_root: Node = _clip_presenter._active.get("scene_root")
	var active_input: Control = _clip_presenter._active.get("input_blocker")
	var active_audio_players: Array = _audio_presenter._presentation_clip_audio.get(
		"players", [])
	var active_audio_player := active_audio_players[0] as AudioStreamPlayer
	var old_capability: RefCounted = _dialogue._presentation_clip_participant_capability
	var unregistered := [false]
	var on_apply := func(_request: PresentationClipOperationRequest) -> void:
		if _clip_presenter._claimed.is_empty():
			return
		var player := (
			_clip_presenter._claimed.get("animation_player") as AnimationPlayer)
		player.animation_started.connect(
			func(animation_name: StringName) -> void:
				if animation_name != &"clip":
					return
				unregistered[0] = _runtime._unregister_presentation_clip_composition_participant(
					_dialogue,
					old_capability,
					PresentationClipOperationRequest.ROLE_DIALOGUE,
				),
			CONNECT_ONE_SHOT,
		)
	SignalBus.presentation_clip_apply_requested.connect(on_apply)
	var replacement := _submit(
		"synthetic_clip", PresentationBatchRequest.Policy.JOIN, 93)
	SignalBus.presentation_clip_apply_requested.disconnect(on_apply)
	if unregistered[0]:
		_dialogue._presentation_clip_participant_capability = (
			_runtime._register_presentation_clip_dialogue_participant(_dialogue))
	await _await_settled(replacement)
	assert_push_error(
		SOURCE_PATH + ":93] presentation clip request rejected: "
		+ "dialogue participant binding changed during publication preparation")
	assert_true(unregistered[0])
	assert_not_null(_dialogue._presentation_clip_participant_capability)
	assert_eq(replacement.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_same(_clip_presenter._active.get("scene_root"), active_root)
	assert_true(active_input.visible)
	var restored_audio_players: Array = _audio_presenter._presentation_clip_audio.get(
		"players", [])
	assert_same(restored_audio_players[0], active_audio_player)
	assert_eq(_receipts.size(), 1, "hidden B emits no receipt before final completion")
	assert_true(_clip_presenter._claimed.is_empty())
	assert_true(_audio_presenter._presentation_clip_claimed.is_empty())


func test_typed_batch_rejects_clip_mixed_with_an_external_owner() -> void:
	var visibility := DialogueVisibilityPresentationOperation.new({
		"target": "surface",
		"action": "hide",
		"transition": "cut",
		"duration": 0.0,
	}, {"source_path": SOURCE_PATH, "line": 101})
	var operations: Array[PresentationOperation] = [_operation("synthetic_clip", 100), visibility]
	var request: PresentationBatchRequest = _runtime.presentation_director.submit(
		operations,
		PresentationBatchRequest.Policy.JOIN,
		_context,
		{"source_path": SOURCE_PATH, "line": 100},
	)
	await _await_settled(request)
	assert_push_error(SOURCE_PATH + ":100")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(_clip_presenter._active.is_empty())
	assert_eq(_receipts.size(), 0)


func test_projection_reset_retires_active_clip_and_all_private_claims() -> void:
	var request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 110)
	await _await_settled(request)
	assert_false(_clip_presenter._active.is_empty())
	SignalBus.reset_presentation_clip()
	assert_true(_clip_presenter._active.is_empty())
	assert_true(_clip_presenter._claimed.is_empty())
	assert_true(_clip_presenter._prepared_plans.is_empty())
	assert_true(_audio_presenter._presentation_clip_audio.is_empty())
	assert_true(_audio_presenter._presentation_clip_claimed.is_empty())
	assert_eq(_clip_presenter._reserved_resource_bytes, 0)


func test_public_quick_save_load_replaces_the_active_clip_generation() -> void:
	await _runtime.start_scenario(SOURCE_PATH)
	assert_true(await wait_until(
		func() -> bool: return _active_request_id() > 0,
		1.0,
		"public scenario entry publishes the clip before quick-save",
	))
	var retired_context: ScenarioContext = _runtime.engine.context
	var retired_request_id := _active_request_id()
	var retired_root := _active_scene_root()
	_pause_active_main_clock()
	_runtime.quick_save()

	assert_true(await _runtime.quick_load())
	assert_true(await wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != retired_context
				and _active_request_id() > 0
				and _active_request_id() != retired_request_id
			),
		1.0,
		"quick-load replays the saved command under a fresh typed owner",
	))
	assert_false(is_instance_valid(retired_root),
		"quick-load retires the old visual projection before replay")
	assert_false(_dialogue._presentation_clip_suppression.is_empty(),
		"the replayed public clip owns its sealed dialogue suppression")
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	_assert_clip_projection_retired("quick-load terminal")


func test_public_backlog_rollback_retires_clip_before_restored_context_runs() -> void:
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	_runtime.backlog_manager.add_entry(
		"Narrator",
		[{"text": "before clip", "voice_layers": []}],
		701,
		func() -> Dictionary: return snapshot,
		[],
		"presentation-clip-before",
	)
	var request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 121)
	await _await_settled(request)
	var retired_context: ScenarioContext = _runtime.engine.context
	var retired_root := _active_scene_root()
	_pause_active_main_clock()

	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != retired_context
				and _clip_presenter._active.is_empty()
			),
		1.0,
		"backlog rollback installs the captured context after retiring the clip",
	))
	assert_false(is_instance_valid(retired_root))
	_assert_clip_projection_retired("backlog rollback")


func test_public_scenario_restart_retires_old_clip_before_new_owner() -> void:
	var request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 131)
	await _await_settled(request)
	var retired_context: ScenarioContext = _runtime.engine.context
	var retired_request_id := _active_request_id()
	var retired_root := _active_scene_root()
	_pause_active_main_clock()

	await _runtime.start_scenario(SOURCE_PATH)
	assert_true(await wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != retired_context
				and _active_request_id() > 0
				and _active_request_id() != retired_request_id
			),
		1.0,
		"scenario restart installs a fresh clip owner",
	))
	assert_false(is_instance_valid(retired_root))
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	_assert_clip_projection_retired("scenario restart terminal")


func test_public_return_to_title_retires_clip_without_late_projection() -> void:
	var request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 141)
	await _await_settled(request)
	var retired_root := _active_scene_root()
	var retired_generation := int(_clip_presenter._active.get("generation", 0))
	_pause_active_main_clock()

	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	_runtime.return_to_title()
	assert_true(await wait_until(
		func() -> bool:
			return int(_runtime._navigation_scene_slot_active_serial) > 0,
		2.0,
		"return-to-title opens its exact accepted SceneTree slot",
	))
	var navigation_serial := int(_runtime._navigation_scene_slot_active_serial)
	var outgoing_dialogue_id := await _replace_scene_owned_dialogue_fixture()
	var replacement_dialogue_id := _dialogue.get_instance_id()
	_runtime._settle_navigation_scene_slot(navigation_serial, true)
	assert_true(await wait_until(
		func() -> bool:
			return (
				not _runtime._return_to_title_pending
				and String(_runtime._navigation_kind).is_empty()
			),
		2.0,
		"return-to-title confirms the accepted replacement owner",
	))
	assert_false(is_instance_valid(retired_root))
	_assert_clip_projection_retired("return-to-title")
	assert_ne(replacement_dialogue_id, outgoing_dialogue_id)
	assert_not_null(_dialogue._presentation_clip_participant_capability)
	assert_gt(_clip_presenter._generation, retired_generation,
		"title replacement retires the old clip generation exactly once")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.TITLE)


func test_public_game_scene_replacement_retires_then_replays_clip() -> void:
	var request := _submit(
		"synthetic_particle_clip", PresentationBatchRequest.Policy.FIRE_AND_FORGET, 151)
	await _await_settled(request)
	var retired_context: ScenarioContext = _runtime.engine.context
	var retired_request_id := _active_request_id()
	var retired_root := _active_scene_root()
	var retired_generation := int(_clip_presenter._active.get("generation", 0))
	_pause_active_main_clock()

	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	_runtime.call_deferred(
		"start_game", SOURCE_PATH, "res://addons/stella/scenes/game.tscn")
	assert_true(await wait_until(
		func() -> bool:
			return int(_runtime._navigation_scene_slot_active_serial) > 0,
		2.0,
		"start-game opens its exact accepted SceneTree slot",
	))
	var navigation_serial := int(_runtime._navigation_scene_slot_active_serial)
	var outgoing_dialogue_id := await _replace_scene_owned_dialogue_fixture()
	var replacement_dialogue_id := _dialogue.get_instance_id()
	_runtime._settle_navigation_scene_slot(navigation_serial, true)
	assert_true(await wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != retired_context
				and _active_request_id() > 0
				and _active_request_id() != retired_request_id
			),
		2.0,
		"public game-scene replacement installs the clip in the accepted scene",
	))
	assert_false(is_instance_valid(retired_root))
	assert_ne(replacement_dialogue_id, outgoing_dialogue_id)
	assert_not_null(_dialogue._presentation_clip_participant_capability)
	assert_gt(int(_clip_presenter._active.get("generation", 0)), retired_generation,
		"the accepted game replacement owns a fresh clip generation")
	SignalBus.presentation_clip_finish_requested.emit(_active_request_id())
	_assert_clip_projection_retired("game-scene replacement terminal")
