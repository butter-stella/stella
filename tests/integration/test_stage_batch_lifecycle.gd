extends GutTest
## Public synthetic end-to-end contract for issue #164.
##
## Missing production classes are discovered dynamically. Exact main therefore
## fails with deliberate assertions instead of missing preload/import errors.
## Once the typed surface exists, these tests drive authored DSL through the
## Runtime, Director, existing Stage SignalBus transport, and StagePresenter.


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const ChapterIndicatorPresenterScript = preload(
	"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd")
const FIXTURE_ROOT := "res://tests/fixtures/scenarios/stage_batch/"
const ATOMIC_JOIN_PATH := FIXTURE_ROOT + "atomic_join.stla"
const FIRE_AND_FORGET_PATH := FIXTURE_ROOT + "fire_and_forget.stla"
const LIFECYCLE_JOIN_PATH := FIXTURE_ROOT + "lifecycle_join.stla"
const SAVE_RESTORE_PATH := FIXTURE_ROOT + "save_restore.stla"
const STAGE_ASSET_ROOT := "res://tests/fixtures/stage/"
const CONFIGURED_TITLE_PROBE := "res://addons/stella/scenes/game.tscn"
const PROGRAMMATIC_SOURCE_PATH := \
	"res://tests/fixtures/scenarios/stage_batch/programmatic_invalid.stla"
const SAVE_SLOT := 164
const REQUIRED_CLASSES := [
	"PresentationOperation",
	"StagePresentationOperation",
	"PresentationOperationReceipt",
	"PresentationBatchRequest",
	"PresentationDirector",
]

class ForeignPresentationOperation extends PresentationOperation:
	func _init(payload: Dictionary) -> void:
		super(&"audio", &"stage:foreign", payload)

var _runtime: Node
var _presenter: StagePresenter
var _dialogue_requests: Array[DialogueRequest] = []
var _batch_observations: Array[Dictionary] = []
var _started_transitions: Array[Dictionary] = []
var _audio_count := 0
var _original_stage_assets_path := ""
var _original_title_scene_path := ""
var _temporary_inputs: Array[Node] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.delete_save(SAVE_SLOT)
	_original_stage_assets_path = _runtime.stage_assets_path
	_original_title_scene_path = _runtime.title_scene_path
	_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_clear_observations()
	_presenter = StagePresenter.new()
	_presenter.name = "StageBatchContractPresenter"
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)
	SignalBus.stage_operations_requested.connect(_on_stage_operations_requested)
	SignalBus.stage_transition_started.connect(_on_stage_transition_started)
	SignalBus.se_play.connect(_on_audio)


func after_each() -> void:
	for input_handler: Node in _temporary_inputs:
		if is_instance_valid(input_handler):
			input_handler.free()
	_temporary_inputs.clear()
	if SignalBus.dialogue_requested.is_connected(_on_dialogue_requested):
		SignalBus.dialogue_requested.disconnect(_on_dialogue_requested)
	if SignalBus.stage_operations_requested.is_connected(
		_on_stage_operations_requested
	):
		SignalBus.stage_operations_requested.disconnect(
			_on_stage_operations_requested)
	if SignalBus.stage_transition_started.is_connected(
		_on_stage_transition_started
	):
		SignalBus.stage_transition_started.disconnect(
			_on_stage_transition_started)
	if SignalBus.se_play.is_connected(_on_audio):
		SignalBus.se_play.disconnect(_on_audio)
	_runtime.stage_assets_path = _original_stage_assets_path
	_runtime.title_scene_path = _original_title_scene_path
	_runtime.delete_save(SAVE_SLOT)
	_runtime._navigation_scene_change_override = Callable()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _on_dialogue_requested(request: DialogueRequest) -> void:
	_dialogue_requests.append(request)


func _on_stage_operations_requested(
	operations: Array,
	force_cut: bool,
) -> void:
	_batch_observations.append({
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"dialogues_at_boundary": _dialogue_requests.size(),
		"audio_at_boundary": _audio_count,
		"canonical": _runtime.presentation_state.stage_layers.duplicate(true),
	})


func _on_stage_transition_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
) -> void:
	var generation := 0
	if (
		_presenter != null
		and presenter_instance_id == _presenter.get_instance_id()
	):
		generation = int(_presenter._layer_transition_generations.get(
			layer_id, 0))
	_started_transitions.append({
		"presenter_instance_id": presenter_instance_id,
		"layer_id": layer_id,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
	})


func _on_audio(_asset: String) -> void:
	_audio_count += 1


func _clear_observations() -> void:
	_dialogue_requests.clear()
	_batch_observations.clear()
	_started_transitions.clear()
	_audio_count = 0


func _wait_until(predicate: Callable, max_frames: int = 120) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _global_class_script(class_name_value: String) -> Script:
	for entry_value: Variant in ProjectSettings.get_global_class_list():
		var entry: Dictionary = entry_value
		if String(entry.get("class", "")) != class_name_value:
			continue
		var path := String(entry.get("path", ""))
		if not path.is_empty() and ResourceLoader.exists(path, "Script"):
			return load(path) as Script
	return null


func _runtime_director() -> Object:
	var director_script := _global_class_script("PresentationDirector")
	if director_script == null:
		return null
	for property_value: Variant in _runtime.get_property_list():
		var property: Dictionary = property_value
		if int(property.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		var property_name := StringName(property.get("name", &""))
		if property_name.is_empty():
			continue
		var candidate: Variant = _runtime.get(property_name)
		if candidate is Object and (candidate as Object).get_script() == director_script:
			return candidate as Object
	for child: Node in _runtime.get_children():
		if child.get_script() == director_script:
			return child
	return null


func _disconnect_test_director(director: PresentationDirector) -> void:
	if SignalBus.stage_transition_receipt_started.is_connected(
		director._on_stage_transition_receipt_started
	):
		SignalBus.stage_transition_receipt_started.disconnect(
			director._on_stage_transition_receipt_started)
	if SignalBus.stage_operation_request_finished.is_connected(
		director._on_stage_operation_request_finished
	):
		SignalBus.stage_operation_request_finished.disconnect(
			director._on_stage_operation_request_finished)
	if SignalBus.stage_transition_terminal.is_connected(
		director._on_stage_transition_terminal
	):
		SignalBus.stage_transition_terminal.disconnect(
			director._on_stage_transition_terminal)
	if SignalBus.advance_requested.is_connected(director._on_advance_requested):
		SignalBus.advance_requested.disconnect(director._on_advance_requested)
	if SignalBus.stage_visuals_reset_requested.is_connected(
		director._on_stage_visuals_reset_requested
	):
		SignalBus.stage_visuals_reset_requested.disconnect(
			director._on_stage_visuals_reset_requested)
	if SignalBus.engine_abort_requested.is_connected(
		director._on_engine_abort_requested
	):
		SignalBus.engine_abort_requested.disconnect(
			director._on_engine_abort_requested)


func _require_contract() -> bool:
	var missing: Array[String] = []
	for required_class: String in REQUIRED_CLASSES:
		if _global_class_script(required_class) == null:
			missing.append(required_class)
	if _runtime_director() == null:
		missing.append("StellaRuntime-owned PresentationDirector")
	if (
		_runtime.engine == null
		or _runtime.engine.registry == null
		or not _runtime.engine.registry.has_handler("stage_batch")
	):
		missing.append("registered stage_batch CommandHandler")
	assert_eq(missing, [], "missing issue #164 runtime composition surface")
	if not missing.is_empty():
		return false

	# Do not launch fixtures on a baseline whose parser lacks the command. This
	# keeps all feature-red failures as assertions, never parser push-errors.
	var probe_source := """@chapter probe
@scene start
@stage_batch policy=join
  @stage probe show asset=stage:redraw_source
@end"""
	var data := DslParser.parse(
		DslLexer.tokenize(probe_source),
		"stage_batch_contract_probe",
		ATOMIC_JOIN_PATH,
	)
	var batches: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			var command: CommandData = command_value
			if command.type == "stage_batch":
				batches.append(command)
	var errors := data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)
	var compiled := batches.size() == 1 and errors.is_empty()
	if compiled:
		var keys := batches[0].params.keys()
		keys.sort()
		compiled = keys == ["operation_lines", "operations", "policy"]
	assert_true(compiled,
		"@stage_batch must compile exactly before lifecycle execution")
	return compiled


func _start_fixture_until(
	path: String,
	predicate: Callable,
) -> bool:
	_runtime.start_scenario(path)
	return await _wait_until(predicate)


func _start_inline(source: String, scenario_id: String) -> ScenarioContext:
	var data := DslParser.parse(
		DslLexer.tokenize(source), scenario_id, "res://synthetic/%s.stla" % scenario_id)
	var errors := data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)
	assert_eq(errors, [], str(data.diagnostics))
	if not errors.is_empty():
		return null
	_runtime.engine.load_scenario(data)
	_runtime.engine.run()
	return _runtime.engine.context


func _reset_live_run() -> void:
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_clear_observations()


func _multi_operation_batches() -> Array[Dictionary]:
	return _batch_observations.filter(
		func(observation: Dictionary) -> bool:
			return (observation["operations"] as Array).size() > 1
	)


func _records_for_request(request_id: int) -> Array:
	return _started_transitions.filter(
		func(record: Dictionary) -> bool:
			return int(record.get("operation_request_id", -1)) == request_id
	)


func _request_ids(records: Array) -> Array[int]:
	var result: Array[int] = []
	for record_value: Variant in records:
		var request_id := int(
			(record_value as Dictionary).get("operation_request_id", -1))
		if request_id not in result:
			result.append(request_id)
	return result


func _finish_records(records: Array) -> void:
	SignalBus.stage_transition_receipts_finish_requested.emit(
		records.duplicate(true))


func _transition_event(
	event_name: String,
	identity: Dictionary,
	outcome: StringName = &"",
) -> Dictionary:
	return {
		"event": event_name,
		"presenter_instance_id": int(identity.get(
			"presenter_instance_id", 0)),
		"layer_id": String(identity.get("layer_id", "")),
		"token": int(identity.get("token", 0)),
		"operation_request_id": int(identity.get(
			"operation_request_id", 0)),
		"generation": int(identity.get("generation", 0)),
		"outcome": outcome,
	}


func _advance_current_dialogue() -> bool:
	return RuntimeTestSupport.advance_dialogue_for_test(get_tree())


func _active_tween(layer_id: String) -> Tween:
	return _presenter._layer_tweens.get(layer_id) as Tween


func _make_chapter_indicator_presenter(name: String) -> Control:
	var presenter := Control.new()
	presenter.name = name
	presenter.set_script(ChapterIndicatorPresenterScript)
	var label := Label.new()
	label.name = "Title"
	presenter.add_child(label)
	presenter.set("title_label_path", NodePath("Title"))
	add_child_autoqfree(presenter)
	return presenter


func _assert_lifecycle_final() -> void:
	var layer := _presenter.get_layer_node("lifecycle")
	assert_not_null(layer, "authored show endpoint retains its named layer")
	if layer == null:
		return
	assert_true(layer.visible)
	assert_eq(layer.position, Vector2.ZERO)
	var composite := layer.get_node("Composite") as CanvasGroup
	assert_almost_eq(composite.self_modulate.a, 1.0, 0.001,
		"terminal completion snaps alpha exactly to canonical final")
	var state: Dictionary = _runtime.presentation_state.stage_layers.get(
		"lifecycle", {})
	assert_eq(state.get("asset", ""), "stage:redraw_source")
	assert_true(bool(state.get("visible", false)))


func _programmatic_context(command: CommandData) -> ScenarioContext:
	var data := ScenarioData.new()
	data.id = "stage_batch_programmatic_invalid"
	data.source_path = PROGRAMMATIC_SOURCE_PATH
	data.source_identity = ScenarioData.make_source_identity(
		PROGRAMMATIC_SOURCE_PATH)
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [command]
	data.scenes = [scene]
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	return context


func _typed_operations(values: Array) -> Array[PresentationOperation]:
	var typed: Array[PresentationOperation] = []
	for value: PresentationOperation in values:
		typed.append(value)
	return typed


func _submit_active_pair(
	layer_a: String,
	layer_b: String,
) -> PresentationBatchRequest:
	return (_runtime_director() as PresentationDirector).submit(
		_typed_operations([
			StagePresentationOperation.new({
				"action": "show", "id": layer_a,
				"properties": {"asset": "stage:redraw_blur_source"},
				"transition_params": {},
				"transition": "fade", "duration": 10.0,
			}),
			StagePresentationOperation.new({
				"action": "show", "id": layer_b,
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "move", "duration": 10.0,
			}),
		]),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_programmatic_context(CommandData.new()),
		{
			"source_path": "res://synthetic/active_pair.stla",
			"line": 2,
		},
	)


func _stage_projection_snapshot(
	layer_id: String,
	asset: String,
	position: Array,
) -> Dictionary:
	var state := StageLayerState.default_state()
	state["asset"] = asset
	state["position"] = position.duplicate()
	return {layer_id: state}


func _json_round_trip_dictionary(value: Dictionary) -> Dictionary:
	var parsed: Variant = JSON.parse_string(JSON.stringify(value))
	assert_true(parsed is Dictionary,
		"the canonical presentation snapshot must remain JSON-representable")
	if not parsed is Dictionary:
		return {}
	return parsed as Dictionary


func _forbidden_snapshot_paths(value: Variant, prefix: String = "") -> Array[String]:
	var forbidden := [
		"policy", "request", "request_id", "token", "generation",
		"tween", "progress", "barrier", "duration", "transition",
	]
	var matches: Array[String] = []
	if value is Dictionary:
		for key_value: Variant in (value as Dictionary).keys():
			var key := String(key_value)
			var path := key if prefix.is_empty() else "%s.%s" % [prefix, key]
			var normalized := key.to_lower()
			for fragment: String in forbidden:
				if fragment in normalized:
					matches.append(path)
					break
			matches.append_array(_forbidden_snapshot_paths(
				(value as Dictionary)[key_value], path))
	elif value is Array:
		for index in range((value as Array).size()):
			matches.append_array(_forbidden_snapshot_paths(
				(value as Array)[index], "%s[%d]" % [prefix, index]))
	return matches


func test_a1_atomic_boundary_commits_three_members_before_tail() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		ATOMIC_JOIN_PATH,
		func() -> bool:
			return (
				_multi_operation_batches().size() == 1
				and _started_transitions.size() >= 3
			),
	))
	var batches := _multi_operation_batches()
	assert_eq(batches.size(), 1,
		"one block crosses SignalBus as one atomic batch")
	var batch: Dictionary = batches[0]
	var operations: Array = batch["operations"]
	assert_eq(operations.map(
		func(operation: Dictionary) -> String:
			return "%s:%s" % [operation["id"], operation["action"]]
	), ["a:show", "b:update", "c:hide"])
	assert_eq(int(batch["dialogues_at_boundary"]), 0)
	assert_eq(int(batch["audio_at_boundary"]), 0)
	assert_eq(_dialogue_requests.size(), 0,
		"JOIN blocks its following dialogue")
	assert_eq(_audio_count, 0, "JOIN blocks its following audio command")
	var canonical: Dictionary = _runtime.presentation_state.stage_layers
	assert_true(canonical.has("a"))
	assert_eq(canonical["b"]["position"], [64.0, 32.0])
	assert_false(bool(canonical["c"]["visible"]),
		"all canonical targets commit at the shared boundary")
	assert_not_null(_presenter.get_layer_node("a"))
	assert_not_null(_presenter.get_layer_node("b"))
	assert_not_null(_presenter.get_layer_node("c"))
	assert_eq(_request_ids(_started_transitions).size(), 1,
		"all animated members are sealed to one exact request")


func test_a1_first_exact_start_reset_invalidates_all_unpublished_members() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var t1_request := _submit_active_pair("dead_a", "dead_b")
	assert_true(t1_request.is_settled())
	assert_eq(t1_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	var t1_records := _records_for_request(t1_request.get_batch_id())
	assert_eq(t1_records.size(), 2,
		"T1 starts with two active Director-owned transitions")
	_clear_observations()
	var reset_once := [false]
	var t2_request_id := [0]
	var t2_identities: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var on_exact_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		var identity := {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		}
		events.append(_transition_event("exact_start", identity))
		if reset_once[0]:
			return
		t2_request_id[0] = operation_request_id
		for active_layer: String in ["dead_a", "dead_b"]:
			t2_identities.append(
				_presenter._active_transition_identity(active_layer).duplicate(true))
		reset_once[0] = true
		SignalBus.reset_stage_visuals()
	var on_legacy_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
	) -> void:
		var identity := _presenter._active_transition_identity(layer_id)
		identity["presenter_instance_id"] = presenter_instance_id
		identity["token"] = token
		identity["operation_request_id"] = operation_request_id
		events.append(_transition_event("legacy_start", identity))
	var on_terminal := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		request_id: int,
		generation: int,
		outcome: StringName,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id():
			return
		events.append(_transition_event("terminal", {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": request_id,
			"generation": generation,
		}, outcome))
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_transition_started.connect(on_legacy_start)
	SignalBus.stage_transition_terminal.connect(on_terminal)
	var context := _start_inline("""@chapter start_reset
@scene start
@stage_batch policy=join
  @stage dead_a show asset=stage:redraw_source transition=fade duration=10
  @stage dead_b show asset=stage:redraw_blur_source transition=move duration=10
@end
「must not advance」""", "stage_batch_exact_start_reset")
	await get_tree().process_frame
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
	SignalBus.stage_transition_started.disconnect(on_legacy_start)
	SignalBus.stage_transition_terminal.disconnect(on_terminal)
	assert_true(reset_once[0])
	assert_gt(t2_request_id[0], 0)
	assert_eq(t2_identities.size(), 2,
		"the full T2 batch installs both owners before its first start callback")
	assert_eq(_started_transitions, [],
		"exact-start reset suppresses its dead legacy companion and later starts")
	assert_eq(events, [
		_transition_event("exact_start", t2_identities[0]),
		_transition_event("terminal", t1_records[0], &"superseded"),
		_transition_event("terminal", t1_records[1], &"superseded"),
		_transition_event("terminal", t2_identities[0], &"cancelled"),
		_transition_event("terminal", t2_identities[1], &"cancelled"),
	], "dead T2-b emits no start; frozen T1 superseded identities precede "
		+ "exact-once T2 cancellation")
	assert_false(director._entries.has(t1_request.get_batch_id()))
	assert_false(director._entries.has(t2_request_id[0]))
	assert_null(_presenter.get_layer_node("dead_a"))
	assert_null(_presenter.get_layer_node("dead_b"))
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())
	assert_eq(_dialogue_requests, [])
	assert_true(context.is_finished,
		"current-owner lifecycle cancellation fail-closes the JOIN tail")


func test_a1_first_legacy_start_reset_then_t3_batch_wins_atomically() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var t1_request := _submit_active_pair("old_a", "old_b")
	assert_true(t1_request.is_settled())
	assert_eq(t1_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	var t1_records := _records_for_request(t1_request.get_batch_id())
	assert_eq(t1_records.size(), 2,
		"T1 starts with two active Director-owned transitions")
	_clear_observations()
	var reset_once := [false]
	var t2_request_id := [0]
	var t2_identities: Array[Dictionary] = []
	var t3_request := [null]
	var events: Array[Dictionary] = []
	var on_exact_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		events.append(_transition_event("exact_start", {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		}))
	var on_legacy_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
	) -> void:
		var identity := _presenter._active_transition_identity(layer_id)
		identity["presenter_instance_id"] = presenter_instance_id
		identity["token"] = token
		identity["operation_request_id"] = operation_request_id
		events.append(_transition_event("legacy_start", identity))
		if reset_once[0] or layer_id != "old_a":
			return
		t2_request_id[0] = operation_request_id
		for active_layer: String in ["old_a", "old_b"]:
			t2_identities.append(
				_presenter._active_transition_identity(active_layer).duplicate(true))
		reset_once[0] = true
		SignalBus.reset_stage_visuals()
		SignalBus.emit_stage_operations([{
			"action": "clear", "id": "", "properties": {},
			"transition_params": {},
			"transition": "cut", "duration": 0.0,
		}], true)
		t3_request[0] = director.submit(_typed_operations([
			StagePresentationOperation.new({
				"action": "show",
				"id": "winner_a",
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "fade",
				"duration": 10.0,
			}),
			StagePresentationOperation.new({
				"action": "show",
				"id": "winner_b",
				"properties": {"asset": "stage:redraw_blur_source"},
				"transition_params": {},
				"transition": "move",
				"duration": 10.0,
			}),
		]), PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			_programmatic_context(CommandData.new()), {
				"source_path": "res://synthetic/winning_t3.stla",
				"line": 7,
			})
	var on_terminal := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		request_id: int,
		generation: int,
		outcome: StringName,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id():
			return
		events.append(_transition_event("terminal", {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": request_id,
			"generation": generation,
		}, outcome))
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_transition_started.connect(on_legacy_start)
	SignalBus.stage_transition_terminal.connect(on_terminal)
	var context := _start_inline("""@chapter legacy_reset
@scene start
@stage_batch policy=join
  @stage old_a show asset=stage:redraw_source transition=fade duration=10
  @stage old_b show asset=stage:redraw_blur_source transition=move duration=10
@end
「must not advance」""", "stage_batch_legacy_start_reset")
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_presenter._layer_tweens.has("winner_a")
				and _presenter._layer_tweens.has("winner_b")
			)))
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
	SignalBus.stage_transition_started.disconnect(on_legacy_start)
	SignalBus.stage_transition_terminal.disconnect(on_terminal)
	assert_true(reset_once[0])
	assert_gt(t2_request_id[0], 0)
	assert_eq(t2_identities.size(), 2,
		"the full T2 batch installs both owners before its first callback")
	assert_not_null(t3_request[0])
	if t3_request[0] == null:
		return
	var winning_request := t3_request[0] as PresentationBatchRequest
	assert_true(winning_request.is_settled())
	assert_eq(winning_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(winning_request.get_receipts().size(), 2)
	var winning_records := _records_for_request(winning_request.get_batch_id())
	assert_eq(winning_records.size(), 2)
	assert_eq(events, [
		_transition_event("exact_start", t2_identities[0]),
		_transition_event("legacy_start", t2_identities[0]),
		_transition_event("terminal", t1_records[0], &"superseded"),
		_transition_event("terminal", t1_records[1], &"superseded"),
		_transition_event("terminal", t2_identities[0], &"cancelled"),
		_transition_event("terminal", t2_identities[1], &"cancelled"),
		_transition_event("exact_start", winning_records[0]),
		_transition_event("legacy_start", winning_records[0]),
		_transition_event("exact_start", winning_records[1]),
		_transition_event("legacy_start", winning_records[1]),
	], "T1 superseded FIFO precedes cancelled T2 and the winning T3 starts")
	var exact_old_layers: Array = events.filter(
		func(event: Dictionary) -> bool:
			return (
				String(event["event"]) == "exact_start"
				and String(event["layer_id"]).begins_with("old_")
			)
	).map(func(event: Dictionary) -> String: return String(event["layer_id"]))
	var legacy_old_layers: Array = events.filter(
		func(event: Dictionary) -> bool:
			return (
				String(event["event"]) == "legacy_start"
				and String(event["layer_id"]).begins_with("old_")
			)
	).map(func(event: Dictionary) -> String: return String(event["layer_id"]))
	assert_eq(exact_old_layers, ["old_a"],
		"reset suppresses the dead T2-b exact start")
	assert_eq(legacy_old_layers, ["old_a"],
		"reset suppresses the dead T2-b legacy start")
	assert_false(director._entries.has(t1_request.get_batch_id()))
	assert_false(director._entries.has(t2_request_id[0]))
	assert_true(director._entries.has(winning_request.get_batch_id()),
		"the reentrant T3 FNF remains the only live Director owner")
	assert_null(_presenter.get_layer_node("old_a"))
	assert_null(_presenter.get_layer_node("old_b"),
		"the unpublished second old member never revives after reset")
	assert_not_null(_presenter.get_layer_node("winner_a"))
	assert_not_null(_presenter.get_layer_node("winner_b"))
	assert_eq(_presenter._layer_tweens.size(), 2)
	assert_eq(_presenter._layer_transition_tokens.size(), 2)
	var live_tween_layers: Array = _presenter._layer_tweens.keys()
	live_tween_layers.sort()
	assert_eq(live_tween_layers, ["winner_a", "winner_b"])
	var live_token_layers: Array = _presenter._layer_transition_tokens.keys()
	live_token_layers.sort()
	assert_eq(live_token_layers, ["winner_a", "winner_b"])
	assert_eq(_runtime.presentation_state.stage_layers.keys().size(), 2)
	assert_true(_runtime.presentation_state.stage_layers.has("winner_a"))
	assert_true(_runtime.presentation_state.stage_layers.has("winner_b"))
	var started_layers := _started_transitions.map(
		func(record: Dictionary) -> String: return String(record["layer_id"]))
	assert_has(started_layers, "old_a")
	assert_does_not_have(started_layers, "old_b")
	assert_has(started_layers, "winner_a")
	assert_has(started_layers, "winner_b")
	assert_eq(started_layers, ["old_a", "winner_a", "winner_b"])
	assert_true(context.is_finished)
	assert_eq(_dialogue_requests, [])


func test_a2_zero_token_join_is_synchronous_and_n_tokens_are_exact() -> void:
	if not _require_contract():
		return
	_start_inline("""@chapter zero
@scene start
@stage_batch policy=join
  @stage cut show asset=stage:redraw_source transition=cut duration=0
@end
「zero token tail」""", "stage_batch_zero_token")
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_eq(_started_transitions, [],
		"cut/no-token JOIN settles synchronously")
	assert_true(_dialogue_requests[0].get_activation().is_pending())

	await _reset_live_run()
	assert_true(await _start_fixture_until(
		ATOMIC_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 3,
	))
	var request_ids := _request_ids(_started_transitions)
	assert_eq(request_ids.size(), 1)
	var exact := _records_for_request(request_ids[0])
	assert_eq(exact.size(), 3)
	var director: PresentationDirector = _runtime_director()
	var request_entry: Dictionary = director._entries.get(request_ids[0], {})
	assert_false(request_entry.is_empty())
	var batch_request: PresentationBatchRequest = request_entry.get("request")
	var settled_events: Array = []
	batch_request.settled.connect(func(batch_id: int, outcome: int) -> void:
		settled_events.append([batch_id, outcome])
	, CONNECT_ONE_SHOT)
	var terminal_count_before := (
		request_entry.get("terminal_keys", {}) as Dictionary).size()
	SignalBus.stage_transition_terminal.emit(
		int(exact[0]["presenter_instance_id"]),
		String(exact[0]["layer_id"]),
		int(exact[0]["token"]),
		int(exact[0]["operation_request_id"]),
		int(exact[0]["generation"]),
		&"unknown",
	)
	assert_false(batch_request.is_settled(),
		"an unknown exact terminal outcome cannot settle a sealed JOIN")
	assert_eq(
		(request_entry.get("terminal_keys", {}) as Dictionary).size(),
		terminal_count_before,
		"unknown outcomes never enter exact terminal ownership state",
	)
	var foreign: Dictionary = (exact[0] as Dictionary).duplicate(true)
	foreign["presenter_instance_id"] = 0
	var wrong_generation: Dictionary = (
		exact[0] as Dictionary).duplicate(true)
	wrong_generation["generation"] = int(
		wrong_generation["generation"]) + 1
	var missing_request: Dictionary = (exact[0] as Dictionary).duplicate(true)
	missing_request.erase("operation_request_id")
	var missing_generation: Dictionary = (exact[0] as Dictionary).duplicate(true)
	missing_generation.erase("generation")
	_finish_records([
		foreign,
		wrong_generation,
		missing_request,
		missing_generation,
		exact[1],
		exact[1],
	])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0,
		"foreign and duplicate records cannot satisfy the exact sealed set")
	var wrong_terminal: Dictionary = (
		exact[0] as Dictionary).duplicate(true)
	SignalBus.stage_transition_terminal.emit(
		int(wrong_terminal["presenter_instance_id"]),
		String(wrong_terminal["layer_id"]),
		int(wrong_terminal["token"]),
		int(wrong_terminal["operation_request_id"]),
		int(wrong_terminal["generation"]) + 1,
		&"completed",
	)
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0,
		"wrong-generation terminal cannot settle the exact receipt")
	_finish_records([exact[0]])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0,
		"N-1 exact receipts keep JOIN blocked")
	_finish_records([exact[2]])
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_eq(_audio_count, 1)
	assert_eq(settled_events, [[
		request_ids[0], PresentationBatchRequest.Outcome.COMPLETED,
	]], "the first valid exact terminal set settles once as COMPLETED")
	_finish_records(exact)
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1,
		"duplicate and late terminal records cannot settle twice")


func test_a2_preseal_exact_terminal_waits_for_dispatch_tail_once() -> void:
	if not _require_contract():
		return
	var strict_record: Array[Dictionary] = [{}]
	var terminal_count := [0]
	var finish_from_legacy_started := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id():
			return
		strict_record[0] = {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": int(
				_presenter._layer_transition_generations.get(layer_id, 0)),
		}
		_finish_records([strict_record[0], strict_record[0]])
	var on_terminal := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
		_outcome: StringName,
	) -> void:
		if (
			presenter_instance_id == int(strict_record[0].get(
				"presenter_instance_id", -1))
			and layer_id == String(strict_record[0].get("layer_id", ""))
			and token == int(strict_record[0].get("token", -1))
			and operation_request_id == int(strict_record[0].get(
				"operation_request_id", -1))
			and generation == int(strict_record[0].get("generation", -1))
		):
			terminal_count[0] += 1
	SignalBus.stage_transition_started.connect(finish_from_legacy_started)
	SignalBus.stage_transition_terminal.connect(on_terminal)
	_start_inline("""@chapter preseal
@scene start
@stage_batch policy=join
  @stage preseal show asset=stage:redraw_source transition=fade duration=10
@end
「preseal tail」""", "stage_batch_preseal_terminal")
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	SignalBus.stage_transition_started.disconnect(finish_from_legacy_started)
	SignalBus.stage_transition_terminal.disconnect(on_terminal)
	assert_eq(_batch_observations.size(), 1)
	assert_eq(int(_batch_observations[0]["dialogues_at_boundary"]), 0,
		"a pre-seal terminal cannot advance inside Stage dispatch")
	assert_eq(terminal_count[0], 1,
		"reentrant duplicate strict finish publishes one exact terminal")
	assert_false(_presenter._layer_tweens.has("preseal"))
	assert_eq(_dialogue_requests.size(), 1,
		"the sealed cached terminal releases the tail exactly once")
	_finish_records([strict_record[0], strict_record[0]])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1)


func test_a2_nested_join_starts_before_its_tail_from_outer_event_flush() -> void:
	if not _require_contract():
		return
	for outer_event: String in ["terminal", "completion"]:
		await _reset_live_run()
		SignalBus.emit_stage_operations([{
			"action": "show",
			"id": "outer_%s" % outer_event,
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade",
			"duration": 10.0,
		}], false)
		assert_eq(_started_transitions.size(), 1, outer_event)
		var outer_record: Dictionary = _started_transitions[0].duplicate(true)
		var nested_request := [null]
		var terminal_order: Array[String] = []
		var submit_nested := func() -> void:
			if nested_request[0] != null:
				return
			var context := _programmatic_context(CommandData.new())
			nested_request[0] = (
				_runtime_director() as PresentationDirector).submit(
					_typed_operations([StagePresentationOperation.new({
						"action": "show",
						"id": "nested_%s" % outer_event,
						"properties": {"asset": "stage:redraw_blur_source"},
						"transition_params": {},
						"transition": "fade",
						"duration": 10.0,
					})]),
					PresentationBatchRequest.Policy.JOIN,
					context,
					{
						"source_path": "res://synthetic/nested_%s.stla"
							% outer_event,
						"line": 6,
					},
				)
		var on_terminal := func(
			presenter_instance_id: int,
			layer_id: String,
			_token: int,
			_request_id: int,
			_generation: int,
			_outcome: StringName,
		) -> void:
			if presenter_instance_id != _presenter.get_instance_id():
				return
			terminal_order.append(layer_id)
			if outer_event == "terminal" and layer_id == "outer_terminal":
				submit_nested.call()
		var on_completion := func(layer_id: String) -> void:
			if outer_event == "completion" and layer_id == "outer_completion":
				submit_nested.call()
		SignalBus.stage_transition_terminal.connect(on_terminal)
		_presenter.layer_transition_finished.connect(on_completion)
		if outer_event == "terminal":
			SignalBus.stage_transitions_finish_requested.emit([{
				"presenter_instance_id": outer_record["presenter_instance_id"],
				"layer_id": outer_record["layer_id"],
				"token": outer_record["token"],
			}])
		else:
			_active_tween("outer_completion").custom_step(20.0)
		_presenter.layer_transition_finished.disconnect(on_completion)
		assert_not_null(nested_request[0], outer_event)
		if nested_request[0] == null:
			SignalBus.stage_transition_terminal.disconnect(on_terminal)
			continue
		var request := nested_request[0] as PresentationBatchRequest
		assert_gt(request.get_batch_id(), 0, outer_event)
		assert_eq(request.get_receipts().size(), 1,
			"nested start receipt seals before its own dispatch tail: %s"
			% outer_event)
		assert_false(request.is_settled(),
			"a nested animated JOIN cannot zero-receipt complete: %s"
			% outer_event)
		var exact := _records_for_request(request.get_batch_id())
		assert_eq(exact.size(), 1, outer_event)
		if exact.size() == 1:
			_finish_records(exact)
		assert_true(await _wait_until(request.is_settled), outer_event)
		assert_eq(request.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED, outer_event)
		SignalBus.stage_transition_terminal.disconnect(on_terminal)
		assert_eq(terminal_order, [
			"outer_%s" % outer_event,
			"nested_%s" % outer_event,
		], "nested terminal stays behind the frozen outer snapshot")


func test_a2_state_apply_and_viewport_terminal_reentry_keep_t3_owner() -> void:
	if not _require_contract():
		return
	for boundary: String in ["state_apply", "viewport"]:
		await _reset_live_run()
		SignalBus.emit_stage_operations([
			{
				"action": "show", "id": "%s_a" % boundary,
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "fade", "duration": 10.0,
			},
			{
				"action": "show", "id": "%s_b" % boundary,
				"properties": {"asset": "stage:redraw_blur_source"},
				"transition_params": {},
				"transition": "move", "duration": 10.0,
			},
		], false)
		assert_eq(_presenter._layer_tweens.size(), 2, boundary)
		var replaced := [false]
		var on_terminal := func(
			presenter_instance_id: int,
			_layer_id: String,
			_token: int,
			_request_id: int,
			_generation: int,
			_outcome: StringName,
		) -> void:
			if replaced[0] or presenter_instance_id != _presenter.get_instance_id():
				return
			replaced[0] = true
			SignalBus.reset_stage_visuals()
			SignalBus.emit_stage_operations([{
				"action": "clear", "id": "", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}], true)
			SignalBus.emit_stage_operations([{
				"action": "show",
				"id": "%s_winner" % boundary,
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "fade",
				"duration": 10.0,
			}], false)
		SignalBus.stage_transition_terminal.connect(on_terminal)
		if boundary == "state_apply":
			var target: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
			for layer_id: String in target:
				(target[layer_id] as Dictionary)["position"] = [40.0, 20.0]
			SignalBus.stage_state_apply_requested.emit(target)
		else:
			_presenter._on_viewport_size_changed()
		SignalBus.stage_transition_terminal.disconnect(on_terminal)
		assert_true(replaced[0], boundary)
		assert_null(_presenter.get_layer_node("%s_a" % boundary), boundary)
		assert_null(_presenter.get_layer_node("%s_b" % boundary), boundary)
		assert_not_null(_presenter.get_layer_node("%s_winner" % boundary), boundary)
		assert_eq(_presenter._layer_tweens.keys(), ["%s_winner" % boundary])
		assert_eq(_presenter._layer_transition_tokens.keys(),
			["%s_winner" % boundary])


func test_a2_completion_snapshot_cannot_alias_reset_same_layer_join() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var completions: Array[String] = []
	var replaced := [false]
	var winner_request := [null]
	var winner_settlements: Array = []
	var on_completion := func(layer_id: String) -> void:
		completions.append(layer_id)
		if replaced[0] or layer_id != "completion_alias_a":
			return
		replaced[0] = true
		SignalBus.reset_stage_visuals()
		winner_request[0] = director.submit(
			_typed_operations([
				StagePresentationOperation.new({
					"action": "show", "id": "completion_alias_a",
					"properties": {"asset": "stage:redraw_source"},
					"transition_params": {},
					"transition": "fade", "duration": 10.0,
				}),
				StagePresentationOperation.new({
					"action": "show", "id": "completion_alias_b",
					"properties": {"asset": "stage:redraw_blur_source"},
					"transition_params": {},
					"transition": "move", "duration": 10.0,
				}),
			]),
			PresentationBatchRequest.Policy.JOIN,
			_programmatic_context(CommandData.new()),
			{
				"source_path": "res://synthetic/completion_alias_join.stla",
				"line": 8,
			},
		)
		(winner_request[0] as PresentationBatchRequest).settled.connect(func(
			batch_id: int,
			outcome: int,
		) -> void:
			winner_settlements.append([batch_id, outcome])
		, CONNECT_ONE_SHOT)
	_presenter.layer_transition_finished.connect(on_completion)
	var cut_target := _stage_projection_snapshot(
		"completion_alias_a", "stage:redraw_source", [17.0, 9.0])
	cut_target.merge(_stage_projection_snapshot(
		"completion_alias_b", "stage:redraw_blur_source", [37.0, 19.0]))
	SignalBus.stage_state_apply_requested.emit(cut_target)

	assert_true(replaced[0])
	assert_eq(completions, ["completion_alias_a"],
		"the frozen old b completion cannot alias Tnew's recycled layer id")
	assert_not_null(winner_request[0])
	if winner_request[0] != null:
		var winner := winner_request[0] as PresentationBatchRequest
		assert_gt(winner.get_batch_id(), 0)
		assert_eq(winner.get_receipts().size(), 2)
		assert_false(winner.is_settled(),
			"old completion delivery cannot finish the animated winning JOIN")
		assert_true(director._entries.has(winner.get_batch_id()))
		assert_true(_presenter._layer_tweens.has("completion_alias_a"))
		assert_true(_presenter._layer_tweens.has("completion_alias_b"))
		var winner_records := _records_for_request(winner.get_batch_id())
		assert_eq(winner_records.size(), 2)
		if winner_records.size() == 2:
			_finish_records(winner_records)
		assert_true(await _wait_until(winner.is_settled))
		assert_eq(winner.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
		assert_eq(winner_settlements, [[
			winner.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
		]], "the two strict endpoints settle the JOIN exactly once")
	_presenter.layer_transition_finished.disconnect(on_completion)
	assert_eq(completions, [
		"completion_alias_a",
		"completion_alias_a",
		"completion_alias_b",
	], "only the first old completion and both real Tnew endpoints publish")
	assert_eq(completions.count("completion_alias_a"), 2)
	assert_eq(completions.count("completion_alias_b"), 1)


func test_a2_absent_remove_completion_cannot_alias_after_reset() -> void:
	if not _require_contract():
		return
	var initial := _stage_projection_snapshot(
		"remove_alias_a", "stage:redraw_source", [11.0, 7.0])
	initial.merge(_stage_projection_snapshot(
		"remove_alias_b", "stage:redraw_blur_source", [31.0, 17.0]))
	SignalBus.stage_state_apply_requested.emit(initial)

	var completions: Array[String] = []
	var replaced := [false]
	var on_completion := func(layer_id: String) -> void:
		completions.append(layer_id)
		if replaced[0] or layer_id != "remove_alias_a":
			return
		replaced[0] = true
		SignalBus.reset_stage_visuals()
		SignalBus.emit_stage_operations([
			{
				"action": "show", "id": "remove_alias_a",
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
			{
				"action": "show", "id": "remove_alias_b",
				"properties": {"asset": "stage:redraw_blur_source"},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
			{
				"action": "remove", "id": "remove_alias_a",
				"properties": {}, "transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
			{
				"action": "remove", "id": "remove_alias_b",
				"properties": {}, "transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
		], false)
	_presenter.layer_transition_finished.connect(on_completion)
	SignalBus.emit_stage_operations([
		{
			"action": "remove", "id": "remove_alias_a",
			"properties": {}, "transition_params": {},
			"transition": "cut", "duration": 0.0,
		},
		{
			"action": "remove", "id": "remove_alias_b",
			"properties": {}, "transition_params": {},
			"transition": "cut", "duration": 0.0,
		},
	], false)
	_presenter.layer_transition_finished.disconnect(on_completion)

	assert_true(replaced[0])
	assert_eq(completions, [
		"remove_alias_a",
		"remove_alias_a",
		"remove_alias_b",
	], "old absent b is suppressed; only the new remove owner publishes once")
	assert_eq(completions.count("remove_alias_a"), 2)
	assert_eq(completions.count("remove_alias_b"), 1)
	assert_false(_presenter._states.has("remove_alias_a"))
	assert_false(_presenter._states.has("remove_alias_b"))
	assert_null(_presenter.get_layer_node("remove_alias_a"))
	assert_null(_presenter.get_layer_node("remove_alias_b"))
	assert_false(_presenter._layer_generations.has("remove_alias_a"))
	assert_false(_presenter._layer_generations.has("remove_alias_b"))
	assert_gt(int(_presenter._layer_generation_counters.get(
		"remove_alias_a", 0)), 2)
	assert_gt(int(_presenter._layer_generation_counters.get(
		"remove_alias_b", 0)), 2)


func test_a2_abort_terminal_reentry_preserves_only_winning_new_batch() -> void:
	if not _require_contract():
		return
	SignalBus.emit_stage_operations([
		{
			"action": "show", "id": "abort_old_a",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade", "duration": 10.0,
		},
		{
			"action": "show", "id": "abort_old_b",
			"properties": {"asset": "stage:redraw_blur_source"},
			"transition_params": {},
			"transition": "move", "duration": 10.0,
		},
	], false)
	var replaced := [false]
	var on_terminal := func(
		presenter_instance_id: int,
		_layer_id: String,
		_token: int,
		_request_id: int,
		_generation: int,
		outcome: StringName,
	) -> void:
		if (
			replaced[0]
			or presenter_instance_id != _presenter.get_instance_id()
			or outcome != &"cancelled"
		):
			return
		replaced[0] = true
		SignalBus.reset_stage_visuals()
		SignalBus.emit_stage_operations([{
			"action": "clear", "id": "", "properties": {},
			"transition_params": {},
			"transition": "cut", "duration": 0.0,
		}], true)
		SignalBus.emit_stage_operations([{
			"action": "show", "id": "abort_winner",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade", "duration": 10.0,
		}], false)
	SignalBus.stage_transition_terminal.connect(on_terminal)
	_presenter._on_engine_abort_requested()
	SignalBus.stage_transition_terminal.disconnect(on_terminal)
	assert_true(replaced[0])
	assert_null(_presenter.get_layer_node("abort_old_a"))
	assert_null(_presenter.get_layer_node("abort_old_b"))
	assert_not_null(_presenter.get_layer_node("abort_winner"))
	assert_eq(_presenter._layer_tweens.keys(), ["abort_winner"])
	assert_eq(_presenter._layer_transition_tokens.keys(), ["abort_winner"])


func test_a3_fire_and_forget_orders_batches_then_releases_audio_and_dialogue() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		FIRE_AND_FORGET_PATH,
		func() -> bool:
			return (
				_batch_observations.size() >= 2
				and _dialogue_requests.size() == 1
				and _audio_count == 1
			),
	))
	assert_eq(_batch_observations.size(), 2)
	assert_eq((_batch_observations[0]["operations"] as Array)[0]["action"],
		"show")
	assert_eq((_batch_observations[1]["operations"] as Array)[0]["action"],
		"update")
	assert_eq(int(_batch_observations[0]["dialogues_at_boundary"]), 0)
	assert_eq(int(_batch_observations[1]["dialogues_at_boundary"]), 0)
	assert_true(_presenter._layer_tweens.has("runner"),
		"FNF releases its tail while the winning tween stays active")
	assert_eq(_started_transitions.size(), 2)
	assert_lt(
		int(_started_transitions[0]["operation_request_id"]),
		int(_started_transitions[1]["operation_request_id"]),
		"consecutive FNF batches begin in submission order",
	)
	var old_record: Dictionary = _started_transitions[0]
	var winning_tween := _active_tween("runner")
	_finish_records([old_record])
	assert_same(_active_tween("runner"), winning_tween,
		"late T1 cannot finish or cut later same-layer T2")
	winning_tween.custom_step(20.0)
	assert_eq(_presenter.get_layer_node("runner").position,
		Vector2(96.0, 48.0))
	assert_eq(_runtime.presentation_state.stage_layers["runner"]["asset"],
		"stage:redraw_blur_source")
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_a3_fnf_lifecycle_cancel_does_not_fail_close_released_context() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		FIRE_AND_FORGET_PATH,
		func() -> bool:
			return (
				_dialogue_requests.size() == 1
				and _presenter._layer_tweens.has("runner")
			),
	))
	var context: ScenarioContext = _runtime.engine.context
	var director: PresentationDirector = _runtime_director()
	var settled_fnf: PresentationBatchRequest
	for entry_value: Variant in director._entries.values():
		var candidate: PresentationBatchRequest = (
			(entry_value as Dictionary)["request"])
		if (
			candidate.get_policy()
			== PresentationBatchRequest.Policy.FIRE_AND_FORGET
			and candidate.is_settled()
		):
			settled_fnf = candidate
	assert_not_null(settled_fnf)
	assert_false(context.is_finished)
	SignalBus.reset_stage_visuals()
	assert_false(context.is_finished,
		"lifecycle cleanup cannot reinterpret a released FNF as command failure")
	assert_eq(_dialogue_requests.size(), 1)
	assert_true(_dialogue_requests[0].get_activation().is_pending())
	if settled_fnf != null:
		assert_true(settled_fnf.is_settled())
		assert_eq(settled_fnf.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._layer_tweens.is_empty())


func test_a3_preseal_fnf_cancel_fail_closes_only_its_current_owner() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var reset_once := [false]
	var exact_starts := [0]
	var context_holder: Array = [null]
	var request_holder: Array = [null]
	var request_id := [0]
	var source_snapshot: Array[Dictionary] = [{}]
	var context_was_current := [false]
	var settlements: Array = []
	var on_exact_start := func(
		_presenter_instance_id: int,
		_layer_id: String,
		_token: int,
		_operation_request_id: int,
		_generation: int,
	) -> void:
		exact_starts[0] += 1
	var on_outer_reset := func() -> void:
		if reset_once[0]:
			return
		reset_once[0] = true
		context_holder[0] = _start_inline("""@chapter preseal_fnf_cancel
@scene start
@stage_batch policy=fire_and_forget
  @stage queued show asset=stage:redraw_source transition=fade duration=10
@end
@se se_select
「cancelled FNF tail」""", "stage_batch_preseal_fnf_cancel")
		var context := context_holder[0] as ScenarioContext
		context_was_current[0] = (
			context != null and context.is_runtime_owner_current())
		for request_id_value: Variant in director._entries:
			var entry: Dictionary = director._entries[request_id_value]
			var source: Dictionary = entry.get("source", {})
			if (
				String(source.get("source_path", ""))
				!= "res://synthetic/stage_batch_preseal_fnf_cancel.stla"
			):
				continue
			request_id[0] = int(request_id_value)
			request_holder[0] = entry.get("request")
			source_snapshot[0] = source.duplicate(true)
		var request := request_holder[0] as PresentationBatchRequest
		if request != null:
			request.settled.connect(func(
				batch_id: int,
				outcome: int,
			) -> void:
				settlements.append([batch_id, outcome])
			, CONNECT_ONE_SHOT)
		# This nested boundary revokes the request while it is still queued behind
		# the outer reset. No Stage consumer can have observed the authored batch.
		SignalBus.reset_stage_visuals()
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_visuals_reset_requested.connect(on_outer_reset)
	SignalBus.reset_stage_visuals()
	SignalBus.stage_visuals_reset_requested.disconnect(on_outer_reset)
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)

	assert_true(reset_once[0])
	assert_true(context_was_current[0],
		"the cancelled pre-seal request belonged to the current Runtime owner")
	assert_gt(request_id[0], 0)
	assert_not_null(request_holder[0])
	if request_holder[0] == null:
		return
	var request := request_holder[0] as PresentationBatchRequest
	assert_true(await _wait_until(request.is_settled))
	assert_true(request.is_settled(),
		"the default outcome value is not settlement evidence")
	assert_eq(request.get_batch_id(), request_id[0])
	assert_eq(request.get_receipts(), [])
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(settlements, [[
		request_id[0], PresentationBatchRequest.Outcome.CANCELLED,
	]], "the queued FNF settles exactly once as genuinely CANCELLED")
	assert_eq(source_snapshot[0], {
		"source_path": "res://synthetic/stage_batch_preseal_fnf_cancel.stla",
		"scenario_id": "stage_batch_preseal_fnf_cancel",
		"line": 3,
	})
	assert_false(director._entries.has(request_id[0]))
	assert_same(_runtime.engine.context, context_holder[0])
	assert_true((context_holder[0] as ScenarioContext).is_finished,
		"a still-current Handler must fail-close a pre-seal cancelled FNF")
	assert_eq(_batch_observations, [],
		"the cancelled queue entry never reaches Stage dispatch")
	assert_eq(exact_starts[0], 0)
	assert_eq(_started_transitions, [])
	assert_eq(_runtime.presentation_state.stage_layers, {})
	assert_null(_presenter.get_layer_node("queued"))
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())
	assert_eq(_audio_count, 0)
	assert_eq(_dialogue_requests, [],
		"the failed command cannot release its audio/dialogue tail")


func test_a3_clear_owns_pending_remove_and_true_empty_dispatches() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "ghost",
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	assert_true(_runtime.presentation_state.stage_layers.has("ghost"))
	assert_not_null(_presenter.get_layer_node("ghost"))
	_clear_observations()

	var requests: Dictionary = {}
	var exact_records: Array[Dictionary] = []
	var settlements: Array = []
	var terminal_events: Array[Dictionary] = []
	var pending_remove_snapshot: Array[Dictionary] = [{}]
	var on_settled := func(batch_id: int, outcome: int) -> void:
		settlements.append([batch_id, outcome])
	var on_exact_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id() or layer_id != "ghost":
			return
		exact_records.append({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		})
		if requests.has(operation_request_id):
			return
		var entry: Dictionary = director._entries.get(operation_request_id, {})
		var request: PresentationBatchRequest = entry.get("request")
		if request != null:
			requests[operation_request_id] = request
			request.settled.connect(on_settled, CONNECT_ONE_SHOT)
	var on_operations := func(operations: Array, _force_cut: bool) -> void:
		if operations.size() != 1:
			return
		var operation: Dictionary = operations[0]
		if String(operation.get("action", "")) != "remove":
			return
		var old_tween := _active_tween("ghost")
		pending_remove_snapshot[0] = {
			"canonical": _runtime.presentation_state.stage_layers.duplicate(true),
			"node": _presenter.get_layer_node("ghost"),
			"tween": old_tween,
			"tween_was_valid": old_tween != null and old_tween.is_valid(),
			"token": int(_presenter._layer_transition_tokens.get("ghost", 0)),
			"generation": int(
				_presenter._layer_transition_generations.get("ghost", 0)),
			"request_id": SignalBus.current_stage_operation_request_id(),
		}
	var on_terminal := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
		outcome: StringName,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id() or layer_id != "ghost":
			return
		terminal_events.append({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
			"outcome": outcome,
		})
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_operations_requested.connect(on_operations)
	SignalBus.stage_transition_terminal.connect(on_terminal)
	_start_inline("""@chapter pending_clear
@scene start
@stage_batch policy=fire_and_forget
  @stage ghost remove transition=fade duration=10
@end
@stage_batch policy=join
  @stage clear transition=fade duration=10
@end
「clear tail」""", "stage_batch_pending_clear")
	assert_true(await _wait_until(func() -> bool:
		return exact_records.size() == 2))
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
	SignalBus.stage_operations_requested.disconnect(on_operations)

	assert_eq(pending_remove_snapshot[0].get("canonical"), {},
		"remove commits canonical absence before its visual fade completes")
	assert_not_null(pending_remove_snapshot[0].get("node"))
	assert_true(bool(pending_remove_snapshot[0].get("tween_was_valid", false)))
	assert_gt(int(pending_remove_snapshot[0].get("token", 0)), 0)
	assert_gt(int(pending_remove_snapshot[0].get("generation", 0)), 0)
	var old_record: Dictionary = exact_records[0].duplicate(true)
	var clear_record: Dictionary = exact_records[1].duplicate(true)
	assert_eq(int(pending_remove_snapshot[0].get("request_id", 0)),
		int(old_record["operation_request_id"]))
	assert_ne(old_record["operation_request_id"],
		clear_record["operation_request_id"])
	assert_ne(old_record["token"], clear_record["token"])
	assert_ne(old_record["generation"], clear_record["generation"])
	var old_tween: Tween = pending_remove_snapshot[0].get("tween")
	assert_not_null(old_tween)
	if old_tween != null:
		assert_false(old_tween.is_valid(),
			"clear retires the pending remove tween before claiming its owner")
	var old_request: PresentationBatchRequest = requests.get(
		int(old_record["operation_request_id"]))
	var clear_request: PresentationBatchRequest = requests.get(
		int(clear_record["operation_request_id"]))
	assert_not_null(old_request)
	assert_not_null(clear_request)
	if old_request == null or clear_request == null:
		SignalBus.stage_transition_terminal.disconnect(on_terminal)
		return
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(old_request.get_receipts().size(), 1)
	assert_gt(clear_request.get_batch_id(), 0)
	assert_eq(clear_request.get_receipts().size(), 1)
	assert_false(clear_request.is_settled())
	assert_eq(_runtime.presentation_state.stage_layers, {})
	assert_not_null(_presenter.get_layer_node("ghost"))
	assert_true(_presenter._layer_tweens.has("ghost"))
	assert_eq(int(_presenter._layer_transition_tokens["ghost"]),
		int(clear_record["token"]))
	assert_eq(terminal_events.filter(func(event: Dictionary) -> bool:
		return (
			int(event["operation_request_id"])
			== int(old_record["operation_request_id"])
			and event["outcome"] == &"superseded"
		)
	).size(), 1, "clear supersedes the pending remove's exact owner")

	var clear_tween := _active_tween("ghost")
	_finish_records([old_record])
	assert_same(_active_tween("ghost"), clear_tween,
		"the old remove identity cannot finish the clear owner")
	assert_false(clear_request.is_settled())
	assert_eq(_dialogue_requests, [])
	_finish_records([clear_record])
	assert_true(await _wait_until(func() -> bool:
		return _dialogue_requests.size() == 1))
	assert_true(clear_request.is_settled())
	assert_eq(clear_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(settlements, [
		[old_request.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED],
		[clear_request.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED],
	], "FNF release and JOIN completion each settle exactly once")
	assert_false(director._entries.has(old_request.get_batch_id()))
	assert_false(director._entries.has(clear_request.get_batch_id()))
	assert_null(_presenter.get_layer_node("ghost"))
	assert_false(_presenter._layer_tweens.has("ghost"))
	assert_false(_presenter._layer_transition_tokens.has("ghost"))
	assert_eq(terminal_events.filter(func(event: Dictionary) -> bool:
		return (
			int(event["operation_request_id"])
			== int(clear_record["operation_request_id"])
			and event["outcome"] == &"completed"
		)
	).size(), 1, "clear publishes its exact completed terminal once")
	assert_true(_dialogue_requests[0].get_activation().is_pending())
	var terminal_count := terminal_events.size()
	_finish_records([old_record, clear_record])
	await get_tree().process_frame
	SignalBus.stage_transition_terminal.disconnect(on_terminal)
	assert_eq(_dialogue_requests.size(), 1)
	assert_eq(settlements.size(), 2)
	assert_eq(terminal_events.size(), terminal_count,
		"late old and duplicate clear identities publish no new terminal")

	var batches_before_empty := _batch_observations.size()
	var starts_before_empty := _started_transitions.size()
	var empty_clear := director.submit(_typed_operations([
		StagePresentationOperation.new({
			"action": "clear", "id": "", "properties": {},
			"transition_params": {},
			"transition": "fade", "duration": 10.0,
		}),
	]), PresentationBatchRequest.Policy.JOIN,
		_programmatic_context(CommandData.new()), {
			"source_path": "res://synthetic/true_empty_clear.stla",
			"line": 3,
		})
	assert_gt(empty_clear.get_batch_id(), 0,
		"true-empty clear still owns a positive typed dispatch")
	assert_true(empty_clear.is_settled())
	assert_eq(empty_clear.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(empty_clear.get_receipts(), [])
	assert_eq(_batch_observations.size(), batches_before_empty + 1)
	assert_eq((_batch_observations[-1]["operations"] as Array)[0]["action"],
		"clear")
	assert_eq(_started_transitions.size(), starts_before_empty)
	assert_null(_presenter.get_layer_node("ghost"))
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_a4_semantic_left_space_and_enter_finish_only_the_current_join() -> void:
	if not _require_contract():
		return
	var cases := ["semantic", "left", "space", "enter"]
	for case_name: String in cases:
		await _reset_live_run()
		var input_script: Script = load(
			"res://addons/stella/presentation/input/input_handler.gd")
		var input_handler: Node = input_script.new()
		add_child(input_handler)
		_temporary_inputs.append(input_handler)
		await get_tree().process_frame
		assert_true(await _start_fixture_until(
			LIFECYCLE_JOIN_PATH,
			func() -> bool: return _started_transitions.size() == 1,
		), case_name)
		var terminal_record: Dictionary = _started_transitions[0].duplicate(true)

		match case_name:
			"semantic":
				SignalBus.emit_advance_requested()
			"left":
				var left := InputEventMouseButton.new()
				left.button_index = MOUSE_BUTTON_LEFT
				left.pressed = true
				input_handler._input(left)
			"space", "enter":
				var key := InputEventKey.new()
				key.keycode = KEY_SPACE if case_name == "space" else KEY_ENTER
				key.pressed = true
				key.echo = false
				input_handler._unhandled_input(key)

		assert_true(await _wait_until(
			func() -> bool: return _dialogue_requests.size() == 1), case_name)
		assert_false(_presenter._layer_tweens.has("lifecycle"), case_name)
		_assert_lifecycle_final()
		assert_true(_dialogue_requests[0].get_activation().is_pending(),
			"one dispatch cannot chain into the newly installed dialogue: %s"
			% case_name)
		await get_tree().process_frame
		assert_eq(_dialogue_requests.size(), 1, case_name)
		_finish_records([terminal_record, terminal_record])
		await get_tree().process_frame
		assert_eq(_dialogue_requests.size(), 1,
			"late/duplicate completion cannot advance twice: %s" % case_name)
		_assert_lifecycle_final()
		_temporary_inputs.erase(input_handler)
		input_handler.free()


func test_a4_skip_finishes_once_auto_and_fnf_do_not_claim_completion() -> void:
	if not _require_contract():
		return
	_runtime.auto_play.is_active = true
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var skip_record: Dictionary = _started_transitions[0].duplicate(true)
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0, "Auto never owns JOIN completion")
	_runtime.skip_controller.is_active = true
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_runtime.skip_controller.is_active)
	assert_true(_runtime.auto_play.is_active,
		"finishing a batch does not rewrite independent intent")
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"Skip's activation edge cannot leak into the following dialogue")
	_assert_lifecycle_final()
	_finish_records([skip_record, skip_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1,
		"late/duplicate Skip terminal cannot settle twice")
	_assert_lifecycle_final()

	await _reset_live_run()
	var director: PresentationDirector = _runtime_director()
	var persistent_requests: Array[PresentationBatchRequest] = []
	var persistent_exact_starts := [0]
	var on_persistent_dispatch := func(
		_operations: Array,
		force_cut: bool,
	) -> void:
		if not force_cut:
			return
		var request_id := SignalBus.current_stage_operation_request_id()
		var entry: Dictionary = director._entries.get(request_id, {})
		var request: PresentationBatchRequest = entry.get("request")
		if request != null:
			persistent_requests.append(request)
	var on_persistent_exact := func(
		_presenter_instance_id: int,
		_layer_id: String,
		_token: int,
		_operation_request_id: int,
		_generation: int,
	) -> void:
		persistent_exact_starts[0] += 1
	SignalBus.stage_operations_requested.connect(on_persistent_dispatch)
	SignalBus.stage_transition_receipt_started.connect(on_persistent_exact)
	_runtime.skip_controller.is_active = true
	_runtime.start_scenario(LIFECYCLE_JOIN_PATH)
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_eq(_batch_observations.size(), 1)
	assert_true(bool(_batch_observations[0]["force_cut"]))
	assert_eq(persistent_requests.size(), 1)
	if persistent_requests.size() == 1:
		assert_eq(persistent_requests[0].get_policy(),
			PresentationBatchRequest.Policy.JOIN)
		assert_gt(persistent_requests[0].get_batch_id(), 0)
		assert_eq(persistent_requests[0].get_receipts(), [])
		assert_true(persistent_requests[0].is_settled())
		assert_eq(persistent_requests[0].get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_started_transitions, [],
		"already-active Skip force-cuts JOIN before token allocation")
	assert_eq(persistent_exact_starts[0], 0)
	assert_false(_presenter._layer_tweens.has("lifecycle"))
	assert_false(_presenter._layer_transition_tokens.has("lifecycle"))
	_assert_lifecycle_final()
	assert_true(_dialogue_requests[0].get_activation().is_pending())

	await _reset_live_run()
	_runtime.skip_controller.is_active = true
	_runtime.start_scenario(FIRE_AND_FORGET_PATH)
	assert_true(await _wait_until(func() -> bool:
		return (
			_dialogue_requests.size() == 1
			and _batch_observations.size() == 2
		)))
	SignalBus.stage_operations_requested.disconnect(on_persistent_dispatch)
	SignalBus.stage_transition_receipt_started.disconnect(on_persistent_exact)
	assert_eq(persistent_requests.size(), 3,
		"persistent Skip force-cuts the JOIN and both FNF batches")
	for index in range(1, persistent_requests.size()):
		var request: PresentationBatchRequest = persistent_requests[index]
		assert_eq(request.get_policy(),
			PresentationBatchRequest.Policy.FIRE_AND_FORGET)
		assert_gt(request.get_batch_id(), 0)
		assert_eq(request.get_receipts(), [])
		assert_true(request.is_settled())
		assert_eq(request.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_batch_observations.size(), 2)
	for observation: Dictionary in _batch_observations:
		assert_true(bool(observation["force_cut"]))
	assert_eq(persistent_exact_starts[0], 0,
		"persistent Skip cuts every policy before exact receipt allocation")
	assert_eq(_started_transitions, [],
		"persistent Skip cuts every policy before legacy start publication")
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())
	var runner := _presenter.get_layer_node("runner")
	assert_not_null(runner)
	if runner != null:
		assert_eq(runner.position, Vector2(96.0, 48.0))
	assert_eq(_runtime.presentation_state.stage_layers["runner"]["asset"],
		"stage:redraw_blur_source")
	assert_eq(_runtime.presentation_state.stage_layers["runner"]["position"],
		[96.0, 48.0])
	assert_true(_dialogue_requests[0].get_activation().is_pending())

	await _reset_live_run()
	assert_true(await _start_fixture_until(
		FIRE_AND_FORGET_PATH,
		func() -> bool:
			return (
				_dialogue_requests.size() == 1
				and _presenter._layer_tweens.has("runner")
			),
	))
	var fnf_tween := _active_tween("runner")
	SignalBus.emit_advance_requested()
	await get_tree().process_frame
	assert_same(_active_tween("runner"), fnf_tween,
		"FNF never claims normal advance as a batch barrier")


func test_a4_skip_edge_during_dispatch_finishes_newly_sealed_join_once() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var exact_record: Array[Dictionary] = [{}]
	var request_holder: Array = [null]
	var preseal_snapshot: Array[Dictionary] = [{}]
	var settlements: Array = []
	var finish_requests: Array = []
	var on_finish_requested := func(records: Array) -> void:
		finish_requests.append(records.duplicate(true))
	var on_exact_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if presenter_instance_id != _presenter.get_instance_id() or layer_id != "lifecycle":
			return
		exact_record[0] = {
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		}
		var entry: Dictionary = director._entries.get(operation_request_id, {})
		var request: PresentationBatchRequest = entry.get("request")
		request_holder[0] = request
		preseal_snapshot[0] = {
			"sealed": bool(entry.get("sealed", true)),
			"settled": request == null or request.is_settled(),
		}
		if request != null:
			request.settled.connect(func(
				batch_id: int,
				outcome: int,
			) -> void:
				settlements.append([batch_id, outcome])
			, CONNECT_ONE_SHOT)
		# Ordinary advance and the Skip edge both arrive before dispatch seal.
		# Only persistent Skip state may be re-read at the request-finished tail.
		SignalBus.emit_advance_requested()
		_runtime.skip_controller.is_active = true
	SignalBus.stage_transition_receipts_finish_requested.connect(
		on_finish_requested)
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	_start_inline("""@chapter skip_dispatch_edge
@scene start
@stage_batch policy=join
  @stage lifecycle show kind=overlay asset=stage:redraw_source transition=fade duration=10
@end
「Skip edge tail」""", "stage_batch_skip_dispatch_edge")
	assert_true(await _wait_until(func() -> bool:
		return _dialogue_requests.size() == 1))
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)

	assert_eq(preseal_snapshot[0], {"sealed": false, "settled": false},
		"the observer fires while the JOIN is still pre-seal")
	assert_false(exact_record[0].is_empty())
	assert_not_null(request_holder[0])
	if request_holder[0] == null:
		SignalBus.stage_transition_receipts_finish_requested.disconnect(
			on_finish_requested)
		return
	var request := request_holder[0] as PresentationBatchRequest
	assert_eq(_batch_observations.size(), 1)
	assert_false(bool(_batch_observations[0]["force_cut"]),
		"Skip became active only after submit allocated the live transition")
	assert_eq(finish_requests, [[exact_record[0]]],
		"the dispatch tail exact-finishes only the just-sealed JOIN")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(request.get_receipts().size(), 1)
	assert_eq(settlements, [[
		request.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
	]], "the Skip edge settles the newly sealed JOIN exactly once")
	assert_false(director._entries.has(request.get_batch_id()))
	assert_false(_presenter._layer_tweens.has("lifecycle"))
	assert_false(_presenter._layer_transition_tokens.has("lifecycle"))
	_assert_lifecycle_final()
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"the pre-seal ordinary advance cannot replay into the new dialogue")

	var finish_count := finish_requests.size()
	director.on_skip_active_changed(true)
	await get_tree().process_frame
	assert_eq(finish_requests.size(), finish_count,
		"late duplicate Skip callbacks cannot republish an exact finish")
	SignalBus.stage_transition_receipts_finish_requested.disconnect(
		on_finish_requested)
	_finish_records([exact_record[0], exact_record[0]])
	await get_tree().process_frame
	assert_eq(settlements.size(), 1)
	assert_eq(_dialogue_requests.size(), 1)
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_a5_abort_and_reset_revoke_old_generation_before_late_callbacks() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var abort_record: Dictionary = _started_transitions[0].duplicate(true)
	var abort_target: Dictionary = (
		_runtime.presentation_state.stage_layers.duplicate(true))
	_runtime.engine.cancel_current_run()
	SignalBus.engine_abort_requested.emit()
	assert_false(_presenter._layer_tweens.has("lifecycle"))
	assert_eq(_runtime.presentation_state.stage_layers, abort_target,
		"abort snaps to the committed canonical final target")
	_finish_records([abort_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0,
		"retired completion cannot resume the cancelled scenario tail")

	await _reset_live_run()
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var reset_record: Dictionary = _started_transitions[0].duplicate(true)
	var reset_context: ScenarioContext = _runtime.engine.context
	var winning_snapshot: Dictionary = (
		_runtime.presentation_state.stage_layers.duplicate(true))
	SignalBus.reset_stage_visuals()
	assert_null(_presenter.get_layer_node("lifecycle"))
	assert_true(reset_context.is_finished,
		"current-owner JOIN cancellation fail-closes before its tail")
	_finish_records([reset_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0)
	SignalBus.stage_state_apply_requested.emit(winning_snapshot)
	assert_not_null(_presenter.get_layer_node("lifecycle"))
	assert_false(_presenter._layer_tweens.has("lifecycle"),
		"winning snapshot is cut-projected after generation reset")


func test_a5_context_restart_replaces_waiter_and_old_token_cannot_settle_new() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	_runtime.start_scenario(LIFECYCLE_JOIN_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != old_context
				and _started_transitions.size() >= 2
			)))
	var new_record: Dictionary = _started_transitions[-1]
	assert_ne(old_record["operation_request_id"],
		new_record["operation_request_id"])
	var new_tween := _active_tween("lifecycle")
	_finish_records([old_record])
	assert_same(_active_tween("lifecycle"), new_tween)
	assert_eq(_dialogue_requests.size(), 0)
	_finish_records([new_record])
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_a5_rejected_title_handoff_fresh_dispatches_generic_waiter() -> void:
	if not _require_contract():
		return
	var property_names: Array[String] = []
	for property_value: Variant in _runtime.get_property_list():
		property_names.append(String(
			(property_value as Dictionary).get("name", "")))
	for property_name: String in property_names:
		assert_false(
			(
				"indicator_waiter_cancelled" in property_name
				or "indicator_presentation_waiter" in property_name
				or "stage_batch_waiter" in property_name
				or "stage_waiter_cancelled" in property_name
				or "stage_presentation_waiter" in property_name
			),
			"reversible navigation must query only the generic Director waiter: %s"
			% property_name,
		)
	var director := _runtime_director()
	assert_not_null(director)
	assert_true(director.has_method("submit"))
	assert_eq(_runtime.presentation_state.stage_layers, {},
		"an empty pre-batch snapshot is a real reversible restore authority")
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var retained_context: ScenarioContext = _runtime.engine.context
	var retained_index: int = int(retained_context.current_command_index)
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return ERR_CANT_CREATE
	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return _started_transitions.size() >= 2))
	assert_push_error("failed to request the configured title scene")
	assert_push_error(
		"failed to enter the configured title scene; falling back")
	assert_push_error("failed to request the built-in title scene")
	assert_push_error("failed to enter the built-in title scene")
	assert_same(_runtime.engine.context, retained_context,
		"rejected reversible handoff retains the exact Context")
	assert_false(retained_context.is_finished,
		"owner-revoked CANCELLED never marks the retained Context finished")
	assert_eq(retained_context.current_command_index, retained_index)
	var fresh_record: Dictionary = _started_transitions[-1]
	assert_ne(old_record["operation_request_id"],
		fresh_record["operation_request_id"],
		"reset-woken waiter is fresh-dispatched at the retained cursor")
	var fresh_tween := _active_tween("lifecycle")
	_finish_records([old_record])
	assert_same(_active_tween("lifecycle"), fresh_tween)
	assert_eq(_dialogue_requests.size(), 0,
		"dead coroutine never resumes after the rejected handoff")
	_finish_records([fresh_record])
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_a5_only_indicator_blocker_preserves_existing_stage_on_rejection() -> void:
	if not _require_contract():
		return
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "retained",
		"properties": {
			"asset": "stage:redraw_source",
			"position": [24.0, 12.0],
		},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	var retained_state: Dictionary = (
		_runtime.presentation_state.stage_layers.duplicate(true))
	var indicator := _make_chapter_indicator_presenter(
		"StageBatchIndicatorOnlyBlocker")
	await get_tree().process_frame
	_start_inline("""@chapter indicator_only title="Synthetic"
@scene start
@chapter_indicator show transition=fade duration=10
「indicator tail」""", "stage_batch_indicator_only_rejection")
	assert_true(await _wait_until(
		func() -> bool: return int(indicator.get("_active_request_id")) > 0))
	var old_request_id := int(indicator.get("_active_request_id"))
	var retained_context: ScenarioContext = _runtime.engine.context
	var retained_index := retained_context.current_command_index
	var fresh_apply_requests: Array = []
	var on_fresh_apply := func(request: Variant) -> void:
		fresh_apply_requests.append(request)
	SignalBus.chapter_indicator_apply_requested.connect(on_fresh_apply)
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return ERR_CANT_CREATE
	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				fresh_apply_requests.size() >= 1
				and _dialogue_requests.size() >= 1
			)))
	if SignalBus.chapter_indicator_apply_requested.is_connected(on_fresh_apply):
		SignalBus.chapter_indicator_apply_requested.disconnect(on_fresh_apply)
	assert_push_error("failed to request the configured title scene")
	assert_push_error(
		"failed to enter the configured title scene; falling back")
	assert_push_error("failed to request the built-in title scene")
	assert_push_error("failed to enter the built-in title scene")
	assert_eq(fresh_apply_requests.size(), 1,
		"recovery fresh-dispatches the retained authored indicator exactly once")
	if fresh_apply_requests.size() == 1:
		var fresh_request: Variant = fresh_apply_requests[0]
		assert_gt(fresh_request.get_request_id(), 0)
		assert_ne(fresh_request.get_request_id(), old_request_id)
		assert_true(fresh_request.was_successful(),
			"the canonical cut makes the fresh indicator request a synchronous no-op")
	assert_eq(int(indicator.get("_active_request_id")), 0)
	assert_same(_runtime.engine.context, retained_context)
	assert_false(retained_context.is_finished)
	assert_eq(retained_context.current_command_index, retained_index + 1,
		"the fresh run advances once from the retained cursor to the dialogue tail")
	assert_eq(_dialogue_requests.size(), 1)
	if _dialogue_requests.size() == 1:
		assert_true(_dialogue_requests[0].get_activation().is_pending(),
			"the dead cancelled coroutine cannot advance the fresh dialogue tail")
	assert_eq(_runtime.presentation_state.stage_layers, retained_state,
		"external-only blocker cancellation never restores a fake empty Stage")
	var retained_layer := _presenter.get_layer_node("retained")
	assert_not_null(retained_layer)
	if retained_layer != null:
		assert_eq(retained_layer.position, Vector2(24.0, 12.0),
			"rejected recovery cut-projects the unchanged canonical Stage")
	assert_false(_presenter._layer_tweens.has("retained"))


func test_a5_reentrant_external_cancel_stops_all_outer_reset_boundaries() -> void:
	if not _require_contract():
		return
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "cas_retained",
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	var retained_state: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	_start_inline("""@chapter cas_old
@scene start
「old owner」""", "stage_batch_cas_old")
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	var old_context: ScenarioContext = _runtime.engine.context
	var replacement := DslParser.parse(
		DslLexer.tokenize("""@chapter cas_new
@scene start
「new owner」"""),
		"stage_batch_cas_new",
		"res://synthetic/stage_batch_cas_new.stla",
	)
	var stage_resets := [0]
	var chapter_resets := [0]
	var on_stage_reset := func() -> void: stage_resets[0] += 1
	var on_chapter_reset := func(_epoch: int) -> void: chapter_resets[0] += 1
	SignalBus.stage_visuals_reset_requested.connect(on_stage_reset)
	SignalBus.chapter_indicator_reset_requested.connect(on_chapter_reset)
	var blocker_owner := RefCounted.new()
	var director: PresentationDirector = _runtime_director()
	assert_true(director._register_blocking_waiter(
		old_context,
		blocker_owner,
		func() -> void: _runtime.engine.load_scenario(replacement),
	))
	var navigation: int = _runtime._begin_navigation("stage_batch_cas_probe", true)
	assert_false(_runtime._acquire_navigation_runtime_ownership(
		navigation, true, true))
	SignalBus.stage_visuals_reset_requested.disconnect(on_stage_reset)
	SignalBus.chapter_indicator_reset_requested.disconnect(on_chapter_reset)
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(stage_resets[0], 0,
		"context replacement after Director cancellation stops Stage reset")
	assert_eq(chapter_resets[0], 0,
		"the same failed CAS stops the later chapter reset boundary")
	assert_eq(_runtime.presentation_state.stage_layers, retained_state)
	assert_not_null(_presenter.get_layer_node("cas_retained"))


func test_a5_stage_and_chapter_reset_callbacks_each_have_context_cas() -> void:
	if not _require_contract():
		return
	for replacement_boundary: String in ["stage", "chapter"]:
		await _reset_live_run()
		_start_inline("""@chapter cas_boundary
@scene start
「old boundary owner」""", "stage_batch_cas_%s" % replacement_boundary)
		assert_true(await _wait_until(
			func() -> bool: return _dialogue_requests.size() == 1))
		var old_context: ScenarioContext = _runtime.engine.context
		var replacement := DslParser.parse(
			DslLexer.tokenize("""@chapter replacement
@scene start
「replacement」"""),
			"stage_batch_%s_replacement" % replacement_boundary,
			"res://synthetic/stage_batch_%s_replacement.stla"
				% replacement_boundary,
		)
		var stage_resets := [0]
		var chapter_resets := [0]
		var on_stage_reset := func() -> void:
			stage_resets[0] += 1
			if replacement_boundary == "stage":
				_runtime.engine.load_scenario(replacement)
		var on_chapter_reset := func(_epoch: int) -> void:
			chapter_resets[0] += 1
			if replacement_boundary == "chapter":
				_runtime.engine.load_scenario(replacement)
		SignalBus.stage_visuals_reset_requested.connect(on_stage_reset)
		SignalBus.chapter_indicator_reset_requested.connect(on_chapter_reset)
		var navigation: int = _runtime._begin_navigation(
			"stage_batch_%s_cas" % replacement_boundary, true)
		assert_false(_runtime._acquire_navigation_runtime_ownership(
			navigation, true, true), replacement_boundary)
		SignalBus.stage_visuals_reset_requested.disconnect(on_stage_reset)
		SignalBus.chapter_indicator_reset_requested.disconnect(on_chapter_reset)
		assert_ne(_runtime.engine.context, old_context, replacement_boundary)
		assert_eq(stage_resets[0], 1, replacement_boundary)
		assert_eq(
			chapter_resets[0],
			0 if replacement_boundary == "stage" else 1,
			"each failed CAS stops the next reset boundary",
		)


func test_a5_director_cutover_preserves_reentrant_entry_and_blocker() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var director: PresentationDirector = _runtime_director()
	var old_context: ScenarioContext = _runtime.engine.context
	var old_entry: Dictionary = director._entries.values()[0]
	var old_request: PresentationBatchRequest = old_entry["request"]
	var new_context := _programmatic_context(CommandData.new())
	var new_request := [null]
	var new_blocker_owner := RefCounted.new()
	var new_blocker_cancelled := [false]
	old_request.settled.connect(func(_batch_id: int, _outcome: int) -> void:
		new_request[0] = director.submit(_typed_operations([
			StagePresentationOperation.new({
				"action": "show",
				"id": "lifecycle",
				"properties": {
					"asset": "stage:redraw_blur_source",
					"position": [88.0, 44.0],
				},
				"transition_params": {},
				"transition": "move",
				"duration": 10.0,
			}),
		]), PresentationBatchRequest.Policy.FIRE_AND_FORGET, new_context, {
			"source_path": "res://synthetic/reentrant_cutover.stla",
			"line": 8,
		})
	, CONNECT_ONE_SHOT)
	var old_blocker_owner := RefCounted.new()
	assert_true(director._register_blocking_waiter(
		old_context,
		old_blocker_owner,
		func() -> void:
			assert_true(director._register_blocking_waiter(
				new_context,
				new_blocker_owner,
				func() -> void: new_blocker_cancelled[0] = true,
			))
	))
	assert_true(director.cancel_blocking_waiters(old_context, true))
	assert_not_null(new_request[0])
	if new_request[0] == null:
		return
	assert_true((new_request[0] as PresentationBatchRequest).is_settled())
	assert_eq((new_request[0] as PresentationBatchRequest).get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(director._entries.has(
		(new_request[0] as PresentationBatchRequest).get_batch_id()),
		"old snapshot cleanup cannot erase a reentrant new-generation FNF entry")
	assert_true(director._external_blockers.has(new_context.get_instance_id()),
		"old external cleanup cannot erase a reentrant new-generation blocker")
	assert_false(new_blocker_cancelled[0])
	assert_eq(
		_runtime.presentation_state.stage_layers["lifecycle"]["asset"],
		"stage:redraw_blur_source",
		"old previous-state restore happens before the winning callback commit",
	)
	assert_true(_presenter._layer_tweens.has("lifecycle"))


func test_a5_stage_reset_barrier_preserves_reentrant_new_generation() -> void:
	if not _require_contract():
		return
	for reset_entry: String in ["raw", "projection"]:
		await _reset_live_run()
		var director: PresentationDirector = _runtime_director()
		var old_data := _programmatic_context(CommandData.new()).scenario_data
		_runtime.engine.load_scenario(old_data)
		var old_context: ScenarioContext = _runtime.engine.context
		var old_request := director.submit(_typed_operations([
			StagePresentationOperation.new({
				"action": "show",
				"id": "reset_owner",
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "fade",
				"duration": 10.0,
			}),
		]), PresentationBatchRequest.Policy.JOIN, old_context, {
			"source_path": "res://synthetic/n3_old_%s.stla" % reset_entry,
			"line": 2,
		})
		assert_false(old_request.is_settled(), reset_entry)
		var old_records := _records_for_request(old_request.get_batch_id())
		assert_eq(old_records.size(), 1, reset_entry)
		if old_records.size() != 1:
			continue
		var old_record: Dictionary = old_records[0].duplicate(true)
		var old_tween := _active_tween("reset_owner")
		_clear_observations()

		var events: Array[String] = []
		var new_request := [null]
		var new_settlements: Array = []
		old_request.settled.connect(func(
			_batch_id: int,
			_outcome: int,
		) -> void:
			var new_data := _programmatic_context(CommandData.new()).scenario_data
			_runtime.engine.load_scenario(new_data)
			var new_context: ScenarioContext = _runtime.engine.context
			new_request[0] = director.submit(_typed_operations([
				StagePresentationOperation.new({
					"action": "show",
					"id": "reset_owner",
					"properties": {
						"asset": "stage:redraw_blur_source",
						"position": [91.0, 47.0],
					},
					"transition_params": {},
					"transition": "move",
					"duration": 10.0,
				}),
			]), PresentationBatchRequest.Policy.JOIN, new_context, {
				"source_path": "res://synthetic/n3_new_%s.stla"
					% reset_entry,
				"line": 8,
			})
			(new_request[0] as PresentationBatchRequest).settled.connect(func(
				batch_id: int,
				outcome: int,
			) -> void:
				new_settlements.append([batch_id, outcome])
			, CONNECT_ONE_SHOT)
		, CONNECT_ONE_SHOT)
		var on_reset_complete := func() -> void:
			events.append("old_visual_reset_complete")
		var on_state_apply := func(_layers: Dictionary) -> void:
			events.append("old_cut_applied")
		var on_exact_start := func(
			_presenter_instance_id: int,
			layer_id: String,
			_token: int,
			_operation_request_id: int,
			_generation: int,
		) -> void:
			if layer_id == "reset_owner":
				events.append("tnew_exact")
		var on_legacy_start := func(
			_presenter_instance_id: int,
			layer_id: String,
			_token: int,
			_operation_request_id: int,
		) -> void:
			if layer_id == "reset_owner":
				events.append("tnew_legacy")
		SignalBus.stage_visuals_reset_requested.connect(on_reset_complete)
		SignalBus.stage_state_apply_requested.connect(on_state_apply)
		SignalBus.stage_transition_receipt_started.connect(on_exact_start)
		SignalBus.stage_transition_started.connect(on_legacy_start)
		if reset_entry == "raw":
			SignalBus.reset_stage_visuals()
		else:
			_runtime.presentation_state.apply_to_presenters()
		SignalBus.stage_visuals_reset_requested.disconnect(on_reset_complete)
		SignalBus.stage_state_apply_requested.disconnect(on_state_apply)
		SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
		SignalBus.stage_transition_started.disconnect(on_legacy_start)

		assert_not_null(new_request[0], reset_entry)
		if new_request[0] == null:
			continue
		var winner := new_request[0] as PresentationBatchRequest
		assert_gt(winner.get_batch_id(), 0, reset_entry)
		assert_eq(winner.get_receipts().size(), 1, reset_entry)
		assert_false(winner.is_settled(), reset_entry)
		assert_eq(events,
			[
				"old_visual_reset_complete", "tnew_exact", "tnew_legacy",
			] if reset_entry == "raw" else [
				"old_visual_reset_complete", "old_cut_applied",
				"tnew_exact", "tnew_legacy",
			],
			"the winner starts only after the complete old reset boundary",
		)
		assert_false(director._entries.has(old_request.get_batch_id()))
		assert_true(director._entries.has(winner.get_batch_id()))
		assert_false(old_tween.is_valid(), reset_entry)
		assert_not_same(_active_tween("reset_owner"), old_tween, reset_entry)
		assert_eq(_presenter._layer_tweens.keys(), ["reset_owner"])
		assert_eq(_presenter._layer_transition_tokens.keys(), ["reset_owner"])
		assert_eq(_runtime.presentation_state.stage_layers.keys(), ["reset_owner"])
		assert_eq(
			_runtime.presentation_state.stage_layers["reset_owner"]["asset"],
			"stage:redraw_blur_source",
			reset_entry,
		)
		var layer := _presenter.get_layer_node("reset_owner")
		assert_not_null(layer, reset_entry)
		if layer != null and reset_entry == "projection":
			assert_eq(layer.position, Vector2.ZERO,
				"the winning move starts from the cut-projected old endpoint")
		var winner_records := _records_for_request(winner.get_batch_id())
		assert_eq(winner_records.size(), 1, reset_entry)
		var winner_tween := _active_tween("reset_owner")
		_finish_records([old_record])
		assert_same(_active_tween("reset_owner"), winner_tween,
			"a late old receipt cannot cut the reset winner: %s" % reset_entry)
		if winner_records.size() == 1:
			_finish_records(winner_records)
		assert_true(await _wait_until(winner.is_settled), reset_entry)
		assert_eq(winner.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED, reset_entry)
		assert_eq(new_settlements, [[
			winner.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
		]], "the reset winner settles exactly once: %s" % reset_entry)
		var final_layer := _presenter.get_layer_node("reset_owner")
		assert_not_null(final_layer, reset_entry)
		if final_layer != null:
			assert_eq(final_layer.position, Vector2(91.0, 47.0),
				"strict completion commits the winning canonical endpoint")


func test_a5_nested_reset_projection_newest_boundary_wins_all_presenters() -> void:
	if not _require_contract():
		return
	var outer := _stage_projection_snapshot(
		"nested_projection", "stage:redraw_source", [11.0, 7.0])
	var inner := _stage_projection_snapshot(
		"nested_projection", "stage:redraw_blur_source", [73.0, 29.0])
	var nested_once := [false]
	var on_reset_between_presenters := func() -> void:
		if nested_once[0]:
			return
		nested_once[0] = true
		SignalBus.reset_and_apply_stage_state(inner)
	SignalBus.stage_visuals_reset_requested.connect(
		on_reset_between_presenters)
	# This presenter connects after the reentrant reset listener. The stale
	# outer reset tail must not clear the inner projection it just received.
	var late_presenter := StagePresenter.new()
	late_presenter.name = "NestedResetLatePresenter"
	add_child_autoqfree(late_presenter)
	await get_tree().process_frame
	SignalBus.reset_and_apply_stage_state(outer)
	SignalBus.stage_visuals_reset_requested.disconnect(
		on_reset_between_presenters)
	assert_true(nested_once[0])
	for presenter: StagePresenter in [_presenter, late_presenter]:
		assert_true(presenter._states.has("nested_projection"))
		assert_eq(
			presenter._states["nested_projection"]["asset"],
			"stage:redraw_blur_source",
			"the stale outer reset/projection cannot run after nested boundary",
		)
		var layer := presenter.get_layer_node("nested_projection")
		assert_not_null(layer)
		if layer != null:
			assert_eq(layer.position, Vector2(73.0, 29.0))
	assert_true(SignalBus._stage_reset_epoch_stack.is_empty())
	assert_true(SignalBus._stage_projection_epoch_stack.is_empty())
	SignalBus.stage_visuals_reset_requested.emit()
	assert_null(_presenter.get_layer_node("nested_projection"),
		"a direct legacy reset remains valid when the reset stack is empty")
	assert_null(late_presenter.get_layer_node("nested_projection"))


func test_a5_stale_outer_reset_cannot_cancel_late_director_winner() -> void:
	if not _require_contract():
		return
	var nested_once := [false]
	var late_director := [null]
	var winner_request := [null]
	var on_reset_before_director := func() -> void:
		if nested_once[0]:
			return
		nested_once[0] = true
		SignalBus.reset_stage_visuals()
		winner_request[0] = (
			late_director[0] as PresentationDirector).submit(
				_typed_operations([StagePresentationOperation.new({
					"action": "show",
					"id": "late_director_winner",
					"properties": {"asset": "stage:redraw_source"},
					"transition_params": {},
					"transition": "fade",
					"duration": 10.0,
				})]),
				PresentationBatchRequest.Policy.JOIN,
				_programmatic_context(CommandData.new()),
				{
					"source_path": "res://synthetic/n3b_late_director.stla",
					"line": 9,
				},
			)
	SignalBus.stage_visuals_reset_requested.connect(on_reset_before_director)
	late_director[0] = PresentationDirector.new(
		_runtime.presentation_state, func() -> bool: return false)
	SignalBus.reset_stage_visuals()
	SignalBus.stage_visuals_reset_requested.disconnect(on_reset_before_director)
	assert_true(nested_once[0])
	assert_not_null(winner_request[0])
	if winner_request[0] == null:
		_disconnect_test_director(late_director[0] as PresentationDirector)
		return
	var winner := winner_request[0] as PresentationBatchRequest
	assert_gt(winner.get_batch_id(), 0)
	assert_eq(winner.get_receipts().size(), 1)
	assert_false(winner.is_settled(),
		"the resumed stale outer Director reset cannot cancel the nested winner")
	assert_true((late_director[0] as PresentationDirector)._entries.has(
		winner.get_batch_id()))
	assert_true(_presenter._layer_tweens.has("late_director_winner"))
	var winner_records := _records_for_request(winner.get_batch_id())
	assert_eq(winner_records.size(), 1)
	if winner_records.size() == 1:
		_finish_records(winner_records)
	assert_true(await _wait_until(winner.is_settled))
	assert_eq(winner.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(SignalBus._stage_reset_epoch_stack.is_empty())
	_disconnect_test_director(late_director[0] as PresentationDirector)


func test_a5_cancel_callback_nested_boundary_skips_old_reset_signal() -> void:
	if not _require_contract():
		return
	var inner := _stage_projection_snapshot(
		"presignal_boundary", "stage:redraw_blur_source", [67.0, 31.0])
	var stale_outer := _stage_projection_snapshot(
		"presignal_boundary", "stage:redraw_source", [5.0, 2.0])
	var reset_signal_count := [0]
	var queued_request := [null]
	var winner_request := [null]
	var winner_exact: Array[Dictionary] = []
	var winner_settlements: Array = []
	var late_presenter_holder := [null]
	var inner_cut_observed := [false]
	var dispatch_once := [false]
	var on_reset := func() -> void:
		reset_signal_count[0] += 1
	var on_outer_dispatch := func() -> void:
		if dispatch_once[0]:
			return
		dispatch_once[0] = true
		queued_request[0] = (
			_runtime_director() as PresentationDirector).submit(
				_typed_operations([StagePresentationOperation.new({
					"action": "show",
					"id": "must_never_dispatch",
					"properties": {"asset": "stage:redraw_source"},
					"transition_params": {},
					"transition": "fade",
					"duration": 10.0,
				})]),
				PresentationBatchRequest.Policy.JOIN,
				_programmatic_context(CommandData.new()),
				{
					"source_path": "res://synthetic/n3b_queued.stla",
					"line": 4,
				},
			)
		(queued_request[0] as PresentationBatchRequest).settled.connect(func(
			_batch_id: int,
			_outcome: int,
		) -> void:
			SignalBus.reset_and_apply_stage_state(inner)
			inner_cut_observed[0] = true
			for presenter: StagePresenter in [
				_presenter, late_presenter_holder[0],
			]:
				if (
					presenter == null
					or not presenter._states.has("presignal_boundary")
					or presenter._states["presignal_boundary"]["asset"]
						!= "stage:redraw_blur_source"
				):
					inner_cut_observed[0] = false
			winner_request[0] = (
				_runtime_director() as PresentationDirector).submit(
					_typed_operations([StagePresentationOperation.new({
						"action": "show",
						"id": "presignal_boundary",
						"properties": {
							"asset": "stage:redraw_source",
							"position": [113.0, 59.0],
						},
						"transition_params": {},
						"transition": "fade",
						"duration": 10.0,
					})]),
					PresentationBatchRequest.Policy.JOIN,
					_programmatic_context(CommandData.new()),
					{
						"source_path": "res://synthetic/n3b_presignal_winner.stla",
						"line": 11,
					},
				)
			(winner_request[0] as PresentationBatchRequest).settled.connect(func(
				batch_id: int,
				outcome: int,
			) -> void:
				winner_settlements.append([batch_id, outcome])
			, CONNECT_ONE_SHOT)
		, CONNECT_ONE_SHOT)
		SignalBus.reset_and_apply_stage_state(stale_outer)
	var on_winner_exact := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if layer_id != "presignal_boundary":
			return
		winner_exact.append({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		})
	SignalBus.stage_visuals_reset_requested.connect(on_reset)
	SignalBus.stage_transition_receipt_started.connect(on_winner_exact)
	var late_presenter := StagePresenter.new()
	late_presenter.name = "PreSignalCasLatePresenter"
	add_child_autoqfree(late_presenter)
	late_presenter_holder[0] = late_presenter
	await get_tree().process_frame
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "outer_dispatch",
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true, 0, on_outer_dispatch)
	SignalBus.stage_visuals_reset_requested.disconnect(on_reset)
	SignalBus.stage_transition_receipt_started.disconnect(on_winner_exact)
	assert_not_null(queued_request[0])
	if queued_request[0] != null:
		var cancelled := queued_request[0] as PresentationBatchRequest
		assert_true(cancelled.is_settled())
		assert_eq(cancelled.get_outcome(),
			PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(reset_signal_count[0], 1,
		"the stale outer reset never emits after its cancellation callback nests")
	assert_true(inner_cut_observed[0],
		"both presenters receive the inner cut before Tnew is submitted")
	for presenter: StagePresenter in [_presenter, late_presenter]:
		assert_true(presenter._states.has("presignal_boundary"))
		assert_eq(
			presenter._states["presignal_boundary"]["asset"],
			"stage:redraw_source",
		)
		assert_eq(presenter._states["presignal_boundary"]["position"],
			[113.0, 59.0])
		assert_false(presenter._states.has("must_never_dispatch"))
		assert_true(presenter._layer_tweens.has("presignal_boundary"))
	assert_eq(_runtime.presentation_state.stage_layers.keys(),
		["presignal_boundary"])
	assert_eq(
		_runtime.presentation_state.stage_layers["presignal_boundary"]["asset"],
		"stage:redraw_source",
	)
	assert_eq(
		_runtime.presentation_state.stage_layers["presignal_boundary"]["position"],
		[113.0, 59.0],
	)
	assert_not_null(winner_request[0])
	if winner_request[0] != null:
		var winner := winner_request[0] as PresentationBatchRequest
		assert_gt(winner.get_batch_id(), 0)
		assert_eq(winner.get_receipts().size(), 2)
		assert_false(winner.is_settled())
		assert_true((_runtime_director() as PresentationDirector)._entries.has(
			winner.get_batch_id()))
		assert_eq(winner_exact.size(), 2)
		var first_winner_tween := _presenter._layer_tweens[
			"presignal_boundary"] as Tween
		var late_winner_tween := late_presenter._layer_tweens[
			"presignal_boundary"] as Tween
		SignalBus.stage_operation_request_finished.emit(
			(queued_request[0] as PresentationBatchRequest).get_batch_id(), false)
		assert_same(_presenter._layer_tweens["presignal_boundary"],
			first_winner_tween)
		assert_same(late_presenter._layer_tweens["presignal_boundary"],
			late_winner_tween)
		_finish_records(winner_exact)
		assert_true(await _wait_until(winner.is_settled))
		assert_eq(winner.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
		assert_eq(winner_settlements, [[
			winner.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
		]], "the cancellation-callback winner settles exactly once")
	assert_true(SignalBus._stage_reset_epoch_stack.is_empty())
	assert_true(SignalBus._stage_projection_epoch_stack.is_empty())


func test_a5_stage_reset_partitions_unified_requests_by_stage_domain_atomically() -> void:
	if not _require_contract():
		return
	assert_true(SignalBus._presentation_operation_queue.is_empty())
	var finish_events: Array[Dictionary] = []
	var stage_dispatches := [0]
	var visibility_dispatches := [0]
	var on_finish := func(request_id: int, delivered: bool) -> void:
		finish_events.append({"request_id": request_id, "delivered": delivered})
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_dispatches[0] += 1
	var on_visibility := func(_operations: Array, _force_cut: bool) -> void:
		visibility_dispatches[0] += 1
	SignalBus.presentation_operation_request_finished.connect(on_finish)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)

	var stage_free_id := [0]
	var mixed_id := [0]
	var nonretained_observation: Array[Dictionary] = [{}]
	var keep_not_stage_free := func(request: Dictionary) -> bool:
		return int(request.get("request_id", 0)) != stage_free_id[0]
	SignalBus.run_presentation_projection(func() -> void:
		stage_free_id[0] = SignalBus.emit_presentation_operations([
			DialogueVisibilityPresentationOperation.new({
				"target": "surface", "action": "hide",
				"transition": "cut", "duration": 0.0,
			}),
		])
		mixed_id[0] = SignalBus.emit_presentation_operations([
			StagePresentationOperation.new({
				"action": "show", "id": "mixed_reset_cancel",
				"properties": {"asset": "stage:redraw_source"},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}),
			DialogueVisibilityPresentationOperation.new({
				"target": "quick_menu", "action": "hide",
				"transition": "cut", "duration": 0.0,
			}),
		])
		var stage_free_epoch_before := -1
		for request: Dictionary in SignalBus._presentation_operation_queue:
			if int(request.get("request_id", 0)) == stage_free_id[0]:
				stage_free_epoch_before = int(request.get("stage_epoch", -1))
		SignalBus.reset_stage_visuals()
		var queued_ids: Array[int] = []
		var stage_free_epoch_after := -1
		for request: Dictionary in SignalBus._presentation_operation_queue:
			var request_id := int(request.get("request_id", 0))
			queued_ids.append(request_id)
			if request_id == stage_free_id[0]:
				stage_free_epoch_after = int(request.get("stage_epoch", -1))
		nonretained_observation[0] = {
			"queued_ids": queued_ids,
			"stage_free_epoch_before": stage_free_epoch_before,
			"stage_free_epoch_after": stage_free_epoch_after,
		}
		SignalBus._presentation_operation_queue = (
			SignalBus._presentation_operation_queue.filter(
				keep_not_stage_free
			)
		)
	)
	assert_eq(finish_events, [{"request_id": mixed_id[0], "delivered": false}],
		"a non-retained mixed request is cancelled exactly once as one atomic owner")
	assert_true(stage_free_id[0] in nonretained_observation[0]["queued_ids"],
		"a Stage-free unified neighbor remains queued across the Stage reset")
	assert_false(mixed_id[0] in nonretained_observation[0]["queued_ids"],
		"the mixed request is removed as a whole before any reset consumer")
	assert_eq(
		nonretained_observation[0]["stage_free_epoch_after"],
		nonretained_observation[0]["stage_free_epoch_before"],
		"Stage-free neighbors do not claim or migrate Stage epoch ownership",
	)
	assert_eq(stage_dispatches[0], 0)
	assert_eq(visibility_dispatches[0], 0,
		"the cancelled mixed request cannot partially apply its non-Stage child")

	var retained_id := [0]
	var retained_observation: Array[Dictionary] = [{}]
	var finishes_before_retained := finish_events.size()
	var keep_not_retained := func(request: Dictionary) -> bool:
		return int(request.get("request_id", 0)) != retained_id[0]
	SignalBus.run_presentation_projection(func() -> void:
		SignalBus.reset_stage_visuals()
		retained_id[0] = SignalBus.emit_presentation_operations([
			StagePresentationOperation.new({
				"action": "show", "id": "retained_mixed_reset",
				"properties": {"asset": "stage:redraw_blur_source"},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}),
			DialogueVisibilityPresentationOperation.new({
				"target": "surface", "action": "show",
				"transition": "cut", "duration": 0.0,
			}),
		])
		var stage_epoch_before := -1
		var visibility_epoch_before := -1
		for request: Dictionary in SignalBus._presentation_operation_queue:
			if int(request.get("request_id", 0)) == retained_id[0]:
				stage_epoch_before = int(request.get("stage_epoch", -1))
				visibility_epoch_before = int(request.get("visibility_epoch", -1))
		SignalBus.reset_stage_visuals()
		for request: Dictionary in SignalBus._presentation_operation_queue:
			if int(request.get("request_id", 0)) != retained_id[0]:
				continue
			var retained_operations: Array = request.get("operations", [])
			retained_observation[0] = {
				"stage_epoch_before": stage_epoch_before,
				"stage_epoch_after": int(request.get("stage_epoch", -1)),
				"visibility_epoch_before": visibility_epoch_before,
				"visibility_epoch_after": int(request.get("visibility_epoch", -1)),
				"operation_count": retained_operations.size(),
				"has_stage": (
					retained_operations.size() == 2
					and retained_operations[0] is StagePresentationOperation
				),
				"has_visibility": (
					retained_operations.size() == 2
					and retained_operations[1]
						is DialogueVisibilityPresentationOperation
				),
				"current_stage_epoch": SignalBus.current_stage_operation_epoch(),
			}
		SignalBus._presentation_operation_queue = (
			SignalBus._presentation_operation_queue.filter(
				keep_not_retained
			)
		)
	)
	assert_eq(finish_events.size(), finishes_before_retained,
		"a retained mixed owner is not cancelled by its own projection reset")
	assert_false(retained_observation[0].is_empty())
	assert_ne(
		retained_observation[0]["stage_epoch_after"],
		retained_observation[0]["stage_epoch_before"],
	)
	assert_eq(
		retained_observation[0]["stage_epoch_after"],
		retained_observation[0]["current_stage_epoch"],
		"retained mixed ownership migrates to the exact current Stage epoch",
	)
	assert_eq(
		retained_observation[0]["visibility_epoch_after"],
		retained_observation[0]["visibility_epoch_before"],
		"a Stage-only reset cannot rewrite another domain's epoch",
	)
	assert_eq(retained_observation[0]["operation_count"], 2)
	assert_true(retained_observation[0]["has_stage"])
	assert_true(retained_observation[0]["has_visibility"],
		"retention preserves the complete mixed request without child splitting")
	assert_eq(stage_dispatches[0], 0)
	assert_eq(visibility_dispatches[0], 0)
	SignalBus.presentation_operation_request_finished.disconnect(on_finish)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	assert_true(SignalBus._presentation_operation_queue.is_empty())


func test_a5_nested_projection_signal_tail_is_epoch_guarded() -> void:
	if not _require_contract():
		return
	var outer := _stage_projection_snapshot(
		"projection_tail", "stage:redraw_source", [13.0, 5.0])
	var inner := _stage_projection_snapshot(
		"projection_tail", "stage:redraw_blur_source", [81.0, 33.0])
	var nested_once := [false]
	var on_projection_between_presenters := func(layers: Dictionary) -> void:
		if nested_once[0] or not layers.has("projection_tail"):
			return
		nested_once[0] = true
		SignalBus.reset_and_apply_stage_state(inner)
	SignalBus.stage_state_apply_requested.connect(
		on_projection_between_presenters)
	var late_presenter := StagePresenter.new()
	late_presenter.name = "NestedProjectionLatePresenter"
	add_child_autoqfree(late_presenter)
	await get_tree().process_frame
	SignalBus.reset_and_apply_stage_state(outer)
	SignalBus.stage_state_apply_requested.disconnect(
		on_projection_between_presenters)
	assert_true(nested_once[0])
	for presenter: StagePresenter in [_presenter, late_presenter]:
		assert_true(presenter._states.has("projection_tail"))
		assert_eq(
			presenter._states["projection_tail"]["asset"],
			"stage:redraw_blur_source",
			"a later-connected presenter rejects the stale outer apply tail",
		)


func test_a5_nested_projection_cuts_before_reentrant_winner_start() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var outer := _stage_projection_snapshot(
		"projection_winner", "stage:redraw_source", [19.0, 3.0])
	var inner := _stage_projection_snapshot(
		"projection_winner", "stage:redraw_blur_source", [41.0, 17.0])
	var events: Array[String] = []
	var nested_once := [false]
	var winner_request := [null]
	var on_projection := func(layers: Dictionary) -> void:
		if not layers.has("projection_winner"):
			return
		if nested_once[0]:
			events.append("inner_cut")
			return
		nested_once[0] = true
		events.append("outer_cut_enter")
		SignalBus.stage_visuals_reset_requested.connect(func() -> void:
			winner_request[0] = director.submit(_typed_operations([
				StagePresentationOperation.new({
					"action": "show",
					"id": "projection_winner",
					"properties": {
						"asset": "stage:redraw_source",
						"position": [109.0, 61.0],
					},
					"transition_params": {},
					"transition": "move",
					"duration": 10.0,
				}),
			]), PresentationBatchRequest.Policy.JOIN,
				_programmatic_context(CommandData.new()), {
					"source_path": "res://synthetic/nested_projection_winner.stla",
					"line": 12,
				})
		, CONNECT_ONE_SHOT)
		SignalBus.reset_and_apply_stage_state(inner)
	var on_exact_start := func(
		_presenter_instance_id: int,
		layer_id: String,
		_token: int,
		_operation_request_id: int,
		_generation: int,
	) -> void:
		if layer_id == "projection_winner":
			events.append("tnew_exact")
	var on_legacy_start := func(
		_presenter_instance_id: int,
		layer_id: String,
		_token: int,
		_operation_request_id: int,
	) -> void:
		if layer_id == "projection_winner":
			events.append("tnew_legacy")
	SignalBus.stage_state_apply_requested.connect(on_projection)
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_transition_started.connect(on_legacy_start)
	SignalBus.reset_and_apply_stage_state(outer)
	SignalBus.stage_state_apply_requested.disconnect(on_projection)
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
	SignalBus.stage_transition_started.disconnect(on_legacy_start)
	assert_eq(events, [
		"outer_cut_enter", "inner_cut", "tnew_exact", "tnew_legacy",
	], "the newest cut completes before its queued winner dispatches")
	assert_not_null(winner_request[0])
	if winner_request[0] == null:
		return
	var winner := winner_request[0] as PresentationBatchRequest
	assert_gt(winner.get_batch_id(), 0)
	assert_eq(winner.get_receipts().size(), 1)
	assert_false(winner.is_settled())
	assert_eq(
		_runtime.presentation_state.stage_layers["projection_winner"]["position"],
		[109.0, 61.0],
	)
	assert_eq(_presenter._states["projection_winner"]["position"],
		[109.0, 61.0])
	assert_true(_presenter._layer_tweens.has("projection_winner"))
	var winner_records := _records_for_request(winner.get_batch_id())
	assert_eq(winner_records.size(), 1)
	if winner_records.size() == 1:
		_finish_records(winner_records)
	assert_true(await _wait_until(winner.is_settled))
	assert_eq(winner.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_a5_cancel_all_does_not_clear_reentrant_new_blocker() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	var old_context := _programmatic_context(CommandData.new())
	var new_context := _programmatic_context(CommandData.new())
	var old_owner := RefCounted.new()
	var new_owner := RefCounted.new()
	var new_cancelled := [false]
	assert_true(director._register_blocking_waiter(
		old_context,
		old_owner,
		func() -> void:
			assert_true(director._register_blocking_waiter(
				new_context,
				new_owner,
				func() -> void: new_cancelled[0] = true,
			))
	))
	director.cancel_all()
	assert_false(new_cancelled[0])
	assert_true(director._external_blockers.has(new_context.get_instance_id()),
		"old cancel_all snapshot cannot clear a blocker installed by its callback")
	director.cancel_all()
	assert_true(new_cancelled[0],
		"the surviving blocker remains independently cancellable")
	assert_false(director._external_blockers.has(new_context.get_instance_id()))


func test_a5_rollback_cancels_old_generation_and_same_cursor_is_no_work() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	_runtime.backlog_manager.add_entry(
		"synthetic stage batch",
		[],
		164,
		func() -> Dictionary: return snapshot.duplicate(true),
	)
	_started_transitions.clear()
	_batch_observations.clear()
	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != old_context
				and _dialogue_requests.size() == 1
			)))
	assert_eq(_started_transitions, [],
		"rollback cut-projects then dry-runs the retained batch cursor")
	assert_eq(_batch_observations.size(), 1,
		"rollback revalidates the same-target Stage run through one public boundary")
	if _batch_observations.size() == 1:
		var rollback_observation: Dictionary = _batch_observations[0]
		var rollback_operations: Array = rollback_observation["operations"]
		assert_eq(rollback_operations.size(), 1)
		if rollback_operations.size() == 1:
			assert_eq(rollback_operations[0]["action"], "show")
			assert_eq(rollback_operations[0]["id"], "lifecycle")
		assert_false(bool(rollback_observation["force_cut"]))
	assert_false(_presenter._layer_tweens.has("lifecycle"))
	_assert_lifecycle_final()
	_finish_records([old_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1,
		"old generation cannot advance rollback's new owner")


func test_a5_title_atomic_clear_yields_to_reentrant_new_owner() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return _runtime._navigation_scene_slot_active_serial > 0))
	var navigation_serial: int = int(
		_runtime._navigation_scene_slot_active_serial)

	var outgoing_presenter := _presenter
	outgoing_presenter.free()
	_presenter = StagePresenter.new()
	_presenter.name = "TitleAtomicFirstPresenter"
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	var events: Array[String] = []
	var winner_request := [null]
	var winner_context := [null]
	var winner_exact: Array[Dictionary] = []
	var winner_settlements: Array = []
	var title_reset_once := [false]
	var on_title_reset_between_presenters := func() -> void:
		if title_reset_once[0]:
			return
		title_reset_once[0] = true
		events.append("title_reset")
		var new_data := _programmatic_context(CommandData.new()).scenario_data
		_runtime.engine.load_scenario(new_data)
		winner_context[0] = _runtime.engine.context
		winner_request[0] = (
			_runtime_director() as PresentationDirector).submit(
				_typed_operations([StagePresentationOperation.new({
					"action": "show",
					"id": "title_winner",
					"properties": {"asset": "stage:redraw_source"},
					"transition_params": {},
					"transition": "fade",
					"duration": 10.0,
				})]),
				PresentationBatchRequest.Policy.JOIN,
				winner_context[0],
				{
					"source_path": "res://synthetic/title_atomic_winner.stla",
					"line": 15,
				},
			)
		(winner_request[0] as PresentationBatchRequest).settled.connect(func(
			batch_id: int,
			outcome: int,
		) -> void:
			winner_settlements.append([batch_id, outcome])
		, CONNECT_ONE_SHOT)
	SignalBus.stage_visuals_reset_requested.connect(
		on_title_reset_between_presenters)
	var late_presenter := StagePresenter.new()
	late_presenter.name = "TitleAtomicLatePresenter"
	add_child_autoqfree(late_presenter)
	await get_tree().process_frame
	var on_empty_cut := func(layers: Dictionary) -> void:
		if layers.is_empty():
			events.append("title_empty_cut")
	var on_exact_start := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if layer_id != "title_winner":
			return
		events.append("tnew_exact")
		winner_exact.append({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		})
	var on_legacy_start := func(
		_presenter_instance_id: int,
		layer_id: String,
		_token: int,
		_operation_request_id: int,
	) -> void:
		if layer_id == "title_winner":
			events.append("tnew_legacy")
	var chapter_reset_count := [0]
	var on_chapter_reset := func(_epoch: int) -> void:
		chapter_reset_count[0] += 1
	SignalBus.stage_state_apply_requested.connect(on_empty_cut)
	SignalBus.stage_transition_receipt_started.connect(on_exact_start)
	SignalBus.stage_transition_started.connect(on_legacy_start)
	SignalBus.chapter_indicator_reset_requested.connect(on_chapter_reset)
	_runtime._settle_navigation_scene_slot(navigation_serial, true)
	assert_true(await _wait_until(func() -> bool:
		return (
			winner_request[0] != null
			and (winner_request[0] as PresentationBatchRequest).get_batch_id() > 0
		)
	))
	SignalBus.stage_visuals_reset_requested.disconnect(
		on_title_reset_between_presenters)
	SignalBus.stage_state_apply_requested.disconnect(on_empty_cut)
	SignalBus.stage_transition_receipt_started.disconnect(on_exact_start)
	SignalBus.stage_transition_started.disconnect(on_legacy_start)
	SignalBus.chapter_indicator_reset_requested.disconnect(on_chapter_reset)
	assert_eq(events, [
		"title_reset", "title_empty_cut",
		"tnew_exact", "tnew_legacy", "tnew_exact", "tnew_legacy",
	], "the complete title cut precedes both presenters' winner starts")
	assert_not_null(winner_request[0])
	if winner_request[0] == null:
		return
	var winner := winner_request[0] as PresentationBatchRequest
	assert_eq(winner.get_receipts().size(), 2)
	assert_false(winner.is_settled())
	assert_eq(winner_exact.size(), 2)
	assert_eq(_runtime.presentation_state.stage_layers.keys(), ["title_winner"])
	assert_eq(
		_runtime.presentation_state.stage_layers["title_winner"]["asset"],
		"stage:redraw_source",
	)
	assert_same(_runtime.engine.context, winner_context[0])
	assert_eq(chapter_reset_count[0], 0,
		"the title tail stops at its post-projection context CAS")
	assert_eq(_runtime._navigation_scene_slot_active_serial, 0)
	assert_eq(_runtime._navigation_kind, "")
	for presenter: StagePresenter in [_presenter, late_presenter]:
		assert_not_null(presenter.get_layer_node("title_winner"))
		assert_true(presenter._layer_tweens.has("title_winner"))
	var first_tween := _active_tween("title_winner")
	_finish_records([old_record])
	assert_same(_active_tween("title_winner"), first_tween,
		"the retired pre-title receipt cannot touch the winning generation")
	_finish_records(winner_exact)
	assert_true(await _wait_until(winner.is_settled))
	assert_eq(winner.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(winner_settlements, [[
		winner.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
	]], "the winning multi-presenter title request settles exactly once")


func test_a5_accepted_title_scene_replacement_retires_old_presenter_token() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return _runtime._navigation_scene_slot_active_serial > 0),
		"accepted title navigation waits for exact SceneTree confirmation")
	var navigation_serial: int = int(
		_runtime._navigation_scene_slot_active_serial)

	var outgoing_presenter := _presenter
	outgoing_presenter.free()
	_presenter = StagePresenter.new()
	_presenter.name = "StageBatchReplacementPresenter"
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_runtime._settle_navigation_scene_slot(navigation_serial, true)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				_runtime.engine.context != old_context
				and _runtime._navigation_kind == ""
			)))
	assert_false(old_context.is_runtime_owner_current())
	assert_eq(_runtime._navigation_scene_slot_active_serial, 0)
	assert_eq(_runtime._navigation_kind, "")
	assert_null(_presenter.get_layer_node("lifecycle"),
		"replacement SceneTree presenter receives only the winning title projection")
	_finish_records([old_record])
	await get_tree().process_frame
	assert_null(_presenter.get_layer_node("lifecycle"))
	assert_eq(_dialogue_requests.size(), 0,
		"outgoing SceneTree token cannot publish into its replacement")


func test_a6_same_layer_supersession_never_success_unblocks_old_join() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		LIFECYCLE_JOIN_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	SignalBus.emit_stage_operations([{
		"action": "update",
		"id": "lifecycle",
		"properties": {"position": [320.0, 180.0]},
		"transition_params": {},
		"transition": "move",
		"duration": 10.0,
	}], false)
	assert_true(await _wait_until(
		func() -> bool: return _started_transitions.size() == 2))
	var replacement_record: Dictionary = _started_transitions[1]
	var replacement_tween := _active_tween("lifecycle")
	_finish_records([old_record])
	assert_same(_active_tween("lifecycle"), replacement_tween,
		"old exact barrier finish cannot cut replacement T2")
	assert_eq(_dialogue_requests.size(), 0,
		"superseded live JOIN cannot report success")
	_finish_records([replacement_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0,
		"an external replacement cancels only; it never releases old tail")
	SignalBus.reset_stage_visuals()
	_finish_records([old_record, replacement_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 0)


func test_a7_programmatic_wrong_shapes_fail_before_any_mutation() -> void:
	if not _require_contract():
		return
	var handler: CommandHandler = _runtime.engine.registry.get_handler(
		"stage_batch")
	assert_not_null(handler)
	var invalid_cases: Array[Dictionary] = [
		{"params": {}, "line": 43},
		{"params": {
			"policy": "join", "operations": [], "operation_lines": [],
			"unknown": true,
		}, "line": 43},
		{"params": {
			"policy": 7, "operations": [], "operation_lines": [],
		}, "line": 43},
		{"params": {
			"policy": "join", "operations": {}, "operation_lines": [],
		}, "line": 43},
		{"params": {
			"policy": "join",
			"operations": [{
				"action": "show", "id": "bad", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}],
			"operation_lines": [],
		}, "line": 43},
		{"params": {
			"policy": "join",
			"operations": [{
				"action": "update", "id": "unknown", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}],
			"operation_lines": [44],
		}, "line": 44},
		{"params": {
			"policy": "join",
			"operations": [{
				"action": "hide", "id": "unknown", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}],
			"operation_lines": [45],
		}, "line": 45},
		{"params": {
			"policy": "join",
			"operations": [{
				"action": "show", "id": " raw ", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}],
			"operation_lines": [46],
		}, "line": 46},
	]
	for invalid_case: Dictionary in invalid_cases:
		var before_state: Dictionary = (
			_runtime.presentation_state.stage_layers.duplicate(true))
		var before_batches: int = _batch_observations.size()
		var before_tokens: int = _started_transitions.size()
		var command := CommandData.new()
		command.type = "stage_batch"
		command.params = (invalid_case["params"] as Dictionary).duplicate(true)
		command.declared_line = 43
		var context: ScenarioContext = _programmatic_context(command)
		handler.execute(command, context)
		await get_tree().process_frame
		assert_push_error("%s:%d" % [
			PROGRAMMATIC_SOURCE_PATH,
			int(invalid_case["line"]),
		])
		assert_eq(_runtime.presentation_state.stage_layers, before_state,
			"invalid programmatic payload cannot mutate canonical state")
		assert_eq(_batch_observations.size(), before_batches,
			"validation precedes every Stage SignalBus dispatch")
		assert_eq(_started_transitions.size(), before_tokens,
			"validation precedes request-id and token allocation")
		assert_true(_presenter._layer_tweens.is_empty())


func test_a7_handler_rejects_missing_cancelled_and_deauthorized_contexts() -> void:
	if not _require_contract():
		return
	var handler: CommandHandler = _runtime.engine.registry.get_handler(
		"stage_batch")
	var valid_command := CommandData.new()
	valid_command.type = "stage_batch"
	valid_command.declared_line = 43
	valid_command.params = {
		"policy": "join",
		"operations": [{
			"action": "show", "id": "context_probe",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade", "duration": 10.0,
		}],
		"operation_lines": [44],
	}
	var before_id := int(SignalBus._next_stage_operation_request_id)
	var before_state: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var before_batches := _batch_observations.size()

	handler.execute(valid_command, null)
	assert_push_error("ScenarioContext is missing")
	var cancelled := _programmatic_context(valid_command)
	cancelled.request_cancellation()
	handler.execute(valid_command, cancelled)
	assert_push_error("ScenarioContext is missing")
	var deauthorized := _programmatic_context(valid_command)
	deauthorized.bind_runtime_owner({"current": false})
	handler.execute(valid_command, deauthorized)
	assert_push_error("ScenarioContext is missing")
	assert_false(deauthorized.is_finished,
		"a retired retained cursor cannot be fail-closed by its dead handler tail")

	var invalid_current := _programmatic_context(CommandData.new())
	var invalid_command := CommandData.new()
	invalid_command.type = "stage_batch"
	invalid_command.declared_line = 47
	invalid_command.params = {}
	handler.execute(invalid_command, invalid_current)
	assert_push_error("%s:47" % PROGRAMMATIC_SOURCE_PATH)
	assert_true(invalid_current.is_finished,
		"only the still-current invalid command fail-closes its run")
	assert_eq(int(SignalBus._next_stage_operation_request_id), before_id)
	assert_eq(_runtime.presentation_state.stage_layers, before_state)
	assert_eq(_batch_observations.size(), before_batches)
	assert_null(_presenter.get_layer_node("context_probe"))
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_a7_direct_submit_preflights_context_invalid_no_work_before_id() -> void:
	if not _require_contract():
		return
	var director: PresentationDirector = _runtime_director()
	assert_not_null(director)
	if director == null:
		return
	var source := {
		"source_path": PROGRAMMATIC_SOURCE_PATH,
		"scenario_id": "direct_submit_preflight",
		"line": 44,
		"previous_stage_layers": {"forged": {}},
	}
	var context := _programmatic_context(CommandData.new())
	var before_id := int(SignalBus._next_stage_operation_request_id)
	var before_state: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var before_batches := _batch_observations.size()
	var canonical_show := {
		"action": "show",
		"id": "shape",
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "fade",
		"duration": 1.0,
	}
	var missing_field := canonical_show.duplicate(true)
	missing_field.erase("duration")
	var extra_field := canonical_show.duplicate(true)
	extra_field["extra"] = true
	var wrong_type := canonical_show.duplicate(true)
	wrong_type["duration"] = "1.0"
	var invalid_operation_sets: Array = [
		[ForeignPresentationOperation.new(canonical_show)],
		[StagePresentationOperation.new({
			"action": "update",
			"id": "unknown",
			"properties": {"x": 12.0},
			"transition_params": {},
			"transition": "move",
			"duration": 1.0,
		})],
		[StagePresentationOperation.new(missing_field)],
		[StagePresentationOperation.new(extra_field)],
		[StagePresentationOperation.new(wrong_type)],
		[
			StagePresentationOperation.new(canonical_show),
			StagePresentationOperation.new(canonical_show),
		],
		[
			StagePresentationOperation.new({
				"action": "clear", "id": "", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}),
			StagePresentationOperation.new(canonical_show),
		],
	]
	for invalid_operations: Array in invalid_operation_sets:
		var invalid_request := director.submit(
			_typed_operations(invalid_operations),
			PresentationBatchRequest.Policy.JOIN,
			context,
			source,
		)
		assert_push_error("%s:44" % PROGRAMMATIC_SOURCE_PATH)
		assert_true(invalid_request.is_settled())
		assert_eq(invalid_request.get_outcome(),
			PresentationBatchRequest.Outcome.FAILED)
		assert_eq(invalid_request.get_batch_id(), 0)
		assert_eq(invalid_request.get_receipts(), [])
		assert_eq(int(SignalBus._next_stage_operation_request_id), before_id)
		assert_eq(_runtime.presentation_state.stage_layers, before_state)
		assert_eq(_batch_observations.size(), before_batches)
		assert_true(_presenter._layer_tweens.is_empty())

	var no_work_request := director.submit(_typed_operations([
		StagePresentationOperation.new({
			"action": "remove",
			"id": "absent",
			"properties": {},
			"transition_params": {},
			"transition": "fade",
			"duration": 5.0,
		}),
	]), PresentationBatchRequest.Policy.JOIN, context, source)
	assert_true(no_work_request.is_settled())
	assert_eq(no_work_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(no_work_request.get_batch_id(), before_id,
		"even a same-state Stage run validates the live Presenter/provider binding")
	assert_eq(no_work_request.get_receipts(), [])

	var valid_payload := {
		"action": "show",
		"id": "direct",
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "fade",
		"duration": 10.0,
	}
	var null_request := director.submit(_typed_operations([
		StagePresentationOperation.new(valid_payload),
	]), PresentationBatchRequest.Policy.JOIN, null, source)
	assert_push_error("ScenarioContext is missing")
	assert_eq(null_request.get_batch_id(), 0)
	assert_eq(null_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	var stale_context := _programmatic_context(CommandData.new())
	stale_context.request_cancellation()
	var stale_request := director.submit(_typed_operations([
		StagePresentationOperation.new(valid_payload),
	]), PresentationBatchRequest.Policy.JOIN, stale_context, source)
	assert_push_error("ScenarioContext is missing")
	assert_eq(stale_request.get_batch_id(), 0)
	assert_eq(stale_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)

	assert_eq(int(SignalBus._next_stage_operation_request_id), before_id + 1,
		"only the validated Stage no-visual-work run consumes a request id")
	assert_eq(_runtime.presentation_state.stage_layers, before_state)
	assert_eq(_batch_observations.size(), before_batches + 1)
	var valid_request := director.submit(_typed_operations([
		StagePresentationOperation.new(valid_payload),
	]), PresentationBatchRequest.Policy.JOIN, context, source)
	assert_eq(valid_request.get_batch_id(), before_id + 1)
	assert_eq(int(SignalBus._next_stage_operation_request_id), before_id + 2)
	assert_eq(_batch_observations.size(), before_batches + 2)
	assert_false(valid_request.is_settled())
	var exact := _records_for_request(valid_request.get_batch_id())
	assert_eq(exact.size(), 1)
	if exact.size() == 1:
		_finish_records(exact)
	assert_true(await _wait_until(valid_request.is_settled))
	assert_eq(valid_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)


func test_a7_director_replay_ignores_caller_forged_previous_state() -> void:
	if not _require_contract():
		return
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "real_before",
		"properties": {
			"asset": "stage:redraw_source",
			"position": [17.0, 9.0],
		},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	var real_before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var context := _programmatic_context(CommandData.new())
	var director: PresentationDirector = _runtime_director()
	var request := director.submit(_typed_operations([
		StagePresentationOperation.new({
			"action": "show",
			"id": "transient_target",
			"properties": {"asset": "stage:redraw_blur_source"},
			"transition_params": {},
			"transition": "fade",
			"duration": 10.0,
		}),
	]), PresentationBatchRequest.Policy.JOIN, context, {
		"source_path": "res://synthetic/forged_replay.stla",
		"line": 12,
		"previous_stage_layers": {
			"forged": StageLayerState.default_state(),
		},
	})
	assert_false(request.is_settled())
	assert_true(director.cancel_blocking_waiters(context, true))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_runtime.presentation_state.stage_layers, real_before,
		"replay authority is the Director preflight snapshot, never caller source")
	assert_false(_runtime.presentation_state.stage_layers.has("forged"))
	assert_false(_runtime.presentation_state.stage_layers.has("transient_target"))
	SignalBus.reset_stage_visuals()
	SignalBus.stage_state_apply_requested.emit(real_before)


func test_a8_mid_join_save_contains_only_canonical_target_and_cursor() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		SAVE_RESTORE_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	assert_eq(_runtime.engine.context.current_command_index, 0)
	assert_eq(_runtime.presentation_state.stage_layers["saved"]["asset"],
		"stage:redraw_source",
		"the final canonical target commits before the tween finishes")
	_runtime.save(SAVE_SLOT)
	var saved_data: Variant = _runtime.save_manager.read_save_data(SAVE_SLOT)
	assert_true(saved_data is Dictionary)
	if not saved_data is Dictionary:
		return
	var presentation_snapshot: Dictionary = saved_data.get(
		"presentation_state", {})
	var expected_presentation_snapshot: Dictionary = _json_round_trip_dictionary(
		_runtime.presentation_state.capture_snapshot())
	assert_eq(presentation_snapshot.get("stage_layers", {}),
		expected_presentation_snapshot.get("stage_layers", {}))
	assert_eq(_forbidden_snapshot_paths(presentation_snapshot), [],
		"presentation JSON contains no policy/request/token/generation/"
		+ "tween/progress/barrier/transition timing")
	var scenario_snapshot: Dictionary = saved_data.get("scenario_context", {})
	assert_eq(int(scenario_snapshot.get("command_index", -1)), 0,
		"JOIN save retains the current authored batch cursor")


func test_a8_mid_fire_and_forget_save_contains_only_canonical_target() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		FIRE_AND_FORGET_PATH,
		func() -> bool:
			return (
				_started_transitions.size() == 2
				and _dialogue_requests.size() == 1
				and _presenter._layer_tweens.has("runner")
			),
	))
	var canonical_runner: Dictionary = (
		_runtime.presentation_state.stage_layers["runner"] as Dictionary
	).duplicate(true)
	assert_eq(canonical_runner.get("asset", ""),
		"stage:redraw_blur_source")
	assert_eq(canonical_runner.get("position", []), [96.0, 48.0],
		"FNF commits its final canonical target before its tween finishes")
	var saved_cursor: int = int(
		_runtime.engine.context.current_command_index)
	var old_context: ScenarioContext = _runtime.engine.context
	var old_records: Array = _started_transitions.duplicate(true)
	_runtime.save(SAVE_SLOT)
	var saved_data: Variant = _runtime.save_manager.read_save_data(SAVE_SLOT)
	assert_true(saved_data is Dictionary)
	if not saved_data is Dictionary:
		return
	var presentation_snapshot: Dictionary = saved_data.get(
		"presentation_state", {})
	var expected_presentation_snapshot: Dictionary = _json_round_trip_dictionary(
		_runtime.presentation_state.capture_snapshot())
	assert_eq(presentation_snapshot.get("stage_layers", {}),
		expected_presentation_snapshot.get("stage_layers", {}))
	assert_eq(_forbidden_snapshot_paths(presentation_snapshot), [],
		"FNF save excludes policy/request/token/generation/tween/progress/"
		+ "barrier/transition timing while the winning tween stays active")
	var scenario_snapshot: Dictionary = saved_data.get("scenario_context", {})
	assert_eq(int(scenario_snapshot.get("command_index", -1)), saved_cursor,
		"FNF save retains the current tail cursor")
	assert_true(_presenter._layer_tweens.has("runner"),
		"capturing a stable FNF target does not cancel the live presentation")

	_started_transitions.clear()
	_batch_observations.clear()
	_dialogue_requests.clear()
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(_started_transitions, [],
		"FNF restore allocates zero replacement tokens")
	assert_eq(_batch_observations, [],
		"FNF restore cut-projects without a new Stage batch/request")
	assert_false(_presenter._layer_tweens.has("runner"))
	var restored_runner := _presenter.get_layer_node("runner")
	assert_not_null(restored_runner)
	if restored_runner != null:
		assert_eq(restored_runner.position, Vector2(96.0, 48.0))
		var composite := restored_runner.get_node("Composite") as CanvasGroup
		assert_almost_eq(composite.self_modulate.a, 1.0, 0.001,
			"FNF restore cut-projects the exact visible endpoint")
	assert_eq(_runtime.presentation_state.stage_layers["runner"],
		canonical_runner)
	_finish_records(old_records)
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1,
		"late FNF receipts cannot advance the restored owner twice")
	assert_eq(_batch_observations, [])
	assert_eq(_started_transitions, [])
	assert_false(_presenter._layer_tweens.has("runner"))
	assert_eq(_runtime.presentation_state.stage_layers["runner"],
		canonical_runner,
		"late FNF receipts cannot mutate the winning cut projection")
	if restored_runner != null:
		assert_eq(restored_runner.position, Vector2(96.0, 48.0))
		var final_composite := (
			restored_runner.get_node("Composite") as CanvasGroup)
		assert_almost_eq(final_composite.self_modulate.a, 1.0, 0.001,
			"late FNF receipts cannot alter the winning visible endpoint")


func test_a8_load_cancels_old_generation_then_dry_runs_without_tokens() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture_until(
		SAVE_RESTORE_PATH,
		func() -> bool: return _started_transitions.size() == 1,
	))
	_runtime.save(SAVE_SLOT)
	var old_context: ScenarioContext = _runtime.engine.context
	var old_record: Dictionary = _started_transitions[0].duplicate(true)
	_started_transitions.clear()
	_batch_observations.clear()
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(_started_transitions, [],
		"restored same-cursor dry-run allocates zero tokens")
	assert_eq(_batch_observations.size(), 1,
		"load revalidates the same-target Stage run through one public boundary")
	if _batch_observations.size() == 1:
		var load_observation: Dictionary = _batch_observations[0]
		var load_operations: Array = load_observation["operations"]
		assert_eq(load_operations.size(), 1)
		if load_operations.size() == 1:
			assert_eq(load_operations[0]["action"], "show")
			assert_eq(load_operations[0]["id"], "saved")
		assert_false(bool(load_observation["force_cut"]))
	assert_false(_presenter._layer_tweens.has("saved"))
	assert_not_null(_presenter.get_layer_node("saved"))
	assert_eq(_runtime.presentation_state.stage_layers["saved"]["asset"],
		"stage:redraw_source")
	assert_true(_dialogue_requests[0].get_activation().is_pending())
	_finish_records([old_record])
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1,
		"old generation cannot replay or advance the restored owner")


func test_a8_idempotent_stage_runs_revalidate_without_visual_work() -> void:
	if not _require_contract():
		return
	var operations := [
		{
			"setup": {
				"action": "show", "id": "same", "properties": {
					"asset": "stage:redraw_source", "position": [12.0, 34.0],
				}, "transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
			"authored": "@stage same update position=12,34 transition=move duration=10",
		},
		{
			"setup": {
				"action": "show", "id": "hidden", "properties": {
					"asset": "stage:redraw_source",
				}, "transition_params": {},
				"transition": "cut", "duration": 0.0,
			},
			"prepare_hidden": true,
			"authored": "@stage hidden hide transition=fade duration=10",
		},
		{
			"setup": null,
			"authored": "@stage absent remove transition=fade duration=10",
		},
	]
	for index in range(operations.size()):
		await _reset_live_run()
		var case: Dictionary = operations[index]
		if case["setup"] is Dictionary:
			SignalBus.emit_stage_operations([case["setup"]], true)
		if bool(case.get("prepare_hidden", false)):
			SignalBus.emit_stage_operations([{
				"action": "hide", "id": "hidden", "properties": {},
				"transition_params": {},
				"transition": "cut", "duration": 0.0,
			}], true)
		_batch_observations.clear()
		_started_transitions.clear()
		_start_inline("""@chapter no_work
@scene start
@stage_batch policy=join
  %s
@end
「no work tail」""" % String(case["authored"]),
			"stage_batch_no_work_%d" % index)
		assert_true(await _wait_until(
			func() -> bool: return _dialogue_requests.size() == 1),
			String(case["authored"]))
		assert_eq(_batch_observations.size(), 1, String(case["authored"]))
		assert_eq(_started_transitions, [], String(case["authored"]))
		assert_true(_presenter._layer_tweens.is_empty(),
			String(case["authored"]))


func test_standalone_stage_and_public_raw_facade_stay_nonblocking_void() -> void:
	if not _require_contract():
		return
	_start_inline("""@chapter standalone
@scene start
@stage standalone show asset=stage:redraw_source transition=fade duration=10
「standalone tail」""", "standalone_stage_nonblocking")
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_presenter._layer_tweens.has("standalone"),
		"standalone @stage remains nonblocking")
	assert_true(_dialogue_requests[0].get_activation().is_pending())

	var result: Variant = _runtime.apply_stage_operations([{
		"action": "show",
		"id": "raw",
		"properties": {"asset": "stage:redraw_blur_source"},
		"transition": "fade",
		"transition_params": {},
		"duration": 10.0,
	}], false)
	assert_eq(result, null, "public raw Dictionary facade retains void semantics")
	assert_true(_presenter._layer_tweens.has("raw"))
