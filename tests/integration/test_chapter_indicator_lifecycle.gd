extends GutTest
## Public end-to-end lifecycle contract for issue #170.
##
## Authored paths enter through tracked synthetic .stla files.  Assertions use
## only StellaRuntime's facade, SignalBus, and the project-configured Presenter
## surface.  The one deliberately programmatic orphan case is labelled as a
## composition test because the DSL correctly rejects scenes before @chapter.


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const FIXTURE_ROOT := "res://tests/fixtures/scenarios/chapter_indicator/"
const LIFECYCLE_PATH := FIXTURE_ROOT + "lifecycle.stla"
const BARE_TITLE_PATH := FIXTURE_ROOT + "bare_title.stla"
const EMPTY_TITLE_PATH := FIXTURE_ROOT + "empty_title.stla"
const TRANSITION_PATH := FIXTURE_ROOT + "transition.stla"
const SHORT_TRANSITION_PATH := FIXTURE_ROOT + "short_transition.stla"
const MIDFADE_PATH := FIXTURE_ROOT + "midfade.stla"
const QUORUM_PATH := FIXTURE_ROOT + "quorum.stla"
const CHAINED_TRANSITION_PATH := FIXTURE_ROOT + "chained_transition.stla"
const PRESENTER_PATH := \
	"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd"
const SAVE_SLOT := 170
const NESTED_SAVE_SLOT := 171

var _runtime: Node
var _dialogue_requests: Array[DialogueRequest] = []
var _chapter_events: Array[Dictionary] = []
var _scenario_started_count := 0
var _translations: Array[Translation] = []
var _original_locale := ""
var _temporary_connections: Array[Dictionary] = []
var _hostile_payload_count := 0
var _owned_nodes: Array[Node] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_save(NESTED_SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	_dialogue_requests.clear()
	_chapter_events.clear()
	_scenario_started_count = 0
	_hostile_payload_count = 0
	_owned_nodes.clear()
	_original_locale = TranslationServer.get_locale()
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)
	SignalBus.scenario_started_event.connect(_on_scenario_started)
	if SignalBus.has_signal("current_chapter_changed"):
		SignalBus.connect("current_chapter_changed", _on_chapter_changed)


func after_each() -> void:
	for record: Dictionary in _temporary_connections:
		var signal_name: StringName = record["signal"]
		var callback: Callable = record["callback"]
		if SignalBus.is_connected(signal_name, callback):
			SignalBus.disconnect(signal_name, callback)
	_temporary_connections.clear()
	if SignalBus.dialogue_requested.is_connected(_on_dialogue_requested):
		SignalBus.dialogue_requested.disconnect(_on_dialogue_requested)
	if SignalBus.scenario_started_event.is_connected(_on_scenario_started):
		SignalBus.scenario_started_event.disconnect(_on_scenario_started)
	if (
		SignalBus.has_signal("current_chapter_changed")
		and SignalBus.is_connected(
			"current_chapter_changed", _on_chapter_changed)
	):
		SignalBus.disconnect("current_chapter_changed", _on_chapter_changed)
	for translation: Translation in _translations:
		TranslationServer.remove_translation(translation)
	_translations.clear()
	TranslationServer.set_locale(_original_locale)
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_save(NESTED_SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	await _release_owned_nodes()
	_dialogue_requests.clear()
	_chapter_events.clear()


func _add_owned_node(node: Node) -> void:
	_owned_nodes.append(node)
	add_child_autoqfree(node)


func _release_owned_nodes() -> void:
	for node: Node in _owned_nodes:
		if not is_instance_valid(node):
			continue
		if node.is_inside_tree():
			var exited: Signal = node.tree_exited
			if not node.is_queued_for_deletion():
				node.queue_free()
			await exited
		elif is_instance_valid(node):
			node.free()
	_owned_nodes.clear()
	await get_tree().process_frame


func _on_dialogue_requested(request: DialogueRequest) -> void:
	_dialogue_requests.append(request)


func _on_chapter_changed(chapter_id: String, title: String) -> void:
	_chapter_events.append({"id": chapter_id, "title": title})


func _on_scenario_started(_scenario_id: String) -> void:
	_scenario_started_count += 1


func _require_contract(requires_presenter: bool = false) -> bool:
	var missing: Array[String] = []
	for method_name: String in [
		"get_current_chapter_id",
		"get_current_chapter_title",
		"is_chapter_indicator_visible",
	]:
		if not _runtime.has_method(method_name):
			missing.append("StellaRuntime.%s()" % method_name)
	if not SignalBus.has_signal("current_chapter_changed"):
		missing.append("SignalBus.current_chapter_changed")
	if requires_presenter and not ResourceLoader.exists(PRESENTER_PATH, "Script"):
		missing.append(PRESENTER_PATH)
	assert_eq(missing, [], "missing issue #170 public surface")
	if not missing.is_empty():
		return false

	# Do not launch a real fixture on a baseline that cannot yet compile the
	# command; that would turn an intentional feature-red into unrelated pushed
	# parser errors from every lifecycle test.
	var source := "@chapter probe \"Probe\"\n@scene start\n@chapter_indicator hide\n"
	var data := DslParser.parse(
		DslLexer.tokenize(source), "chapter_indicator_probe", LIFECYCLE_PATH)
	var compiled := false
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			var command: CommandData = command_value
			if command.type == "chapter_indicator":
				compiled = true
			elif command.type == "presentation_batch":
				for operation_value: Variant in command.params.get("operations", []):
					if (
						operation_value is Dictionary
						and String((operation_value as Dictionary).get("kind", ""))
						== "chapter_indicator"
					):
						compiled = true
	var errors := data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)
	assert_true(compiled and errors.is_empty(),
		"@chapter_indicator must compile before lifecycle execution")
	return compiled and errors.is_empty()


func _wait_until(predicate: Callable, max_frames: int = 120) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _start_fixture(path: String) -> bool:
	var expected_count := _dialogue_requests.size() + 1
	_runtime.start_scenario(path)
	return await _wait_until(
		func() -> bool: return _dialogue_requests.size() >= expected_count)


func _advance_to_next_dialogue() -> bool:
	var expected_count := _dialogue_requests.size() + 1
	if not RuntimeTestSupport.advance_dialogue_for_test(get_tree()):
		return false
	return await _wait_until(
		func() -> bool: return _dialogue_requests.size() >= expected_count)


func _assert_chapter(
	expected_id: String,
	expected_title: String,
	expected_visible: bool,
) -> void:
	assert_eq(String(_runtime.call("get_current_chapter_id")), expected_id)
	assert_eq(String(_runtime.call("get_current_chapter_title")), expected_title)
	assert_eq(bool(_runtime.call("is_chapter_indicator_visible")), expected_visible)


func _chapter_indicator_participant_ids() -> Array[int]:
	var result: Array[int] = []
	for participant: Dictionary in SignalBus._chapter_indicator_participant_snapshot():
		var presenter: Object = participant.get("presenter")
		if presenter != null:
			result.append(presenter.get_instance_id())
	result.sort()
	return result


func _add_translation(locale: String, key: String, value: String) -> void:
	var translation := Translation.new()
	translation.locale = locale
	translation.add_message(key, value)
	TranslationServer.add_translation(translation)
	_translations.append(translation)


func _make_presenter(name: String = "ProjectChapterIndicator") -> Dictionary:
	if not ResourceLoader.exists(PRESENTER_PATH, "Script"):
		return {}
	var script: Script = load(PRESENTER_PATH)
	var presenter := Control.new()
	presenter.name = name
	presenter.custom_minimum_size = Vector2(417.0, 83.0)
	presenter.size = Vector2(417.0, 83.0)
	presenter.set_script(script)
	var label := Label.new()
	label.name = "ProjectOwnedTitle"
	presenter.add_child(label)
	presenter.set("title_label_path", NodePath("ProjectOwnedTitle"))
	_add_owned_node(presenter)
	return {"root": presenter, "label": label}


func _connect_temporary_signal(
	signal_name: StringName,
	callback: Callable,
) -> void:
	SignalBus.connect(signal_name, callback)
	_temporary_connections.append({
		"signal": signal_name,
		"callback": callback,
	})


func _connect_transition_completion_observer(callback: Callable) -> void:
	# As above, discover a two-argument integer/boolean completion notification
	# without promoting its transport name to project API.
	for signal_info_value: Variant in SignalBus.get_signal_list():
		var signal_info: Dictionary = signal_info_value
		var arguments: Array = signal_info.get("args", [])
		if arguments.size() != 2:
			continue
		var first: Dictionary = arguments[0]
		var second: Dictionary = arguments[1]
		if (
			int(first.get("type", TYPE_NIL)) != TYPE_INT
			or int(second.get("type", TYPE_NIL)) != TYPE_BOOL
		):
			continue
		var signal_name := StringName(signal_info.get("name", &""))
		if signal_name.is_empty() or SignalBus.is_connected(signal_name, callback):
			continue
		_connect_temporary_signal(signal_name, callback)


func _connect_after_presenter_one_arg_callbacks(
	presenter_root: Control,
	callback: Callable,
) -> void:
	# Discover the presenter's one-argument transport topology by connection
	# ownership, not by a private signal/method name. This lets the test run
	# immediately after that presenter's validation callback even if the
	# transport evolves from Dictionary to an immutable typed request.
	for signal_info_value: Variant in SignalBus.get_signal_list():
		var signal_info: Dictionary = signal_info_value
		var arguments: Array = signal_info.get("args", [])
		if arguments.size() != 1:
			continue
		var signal_name := StringName(signal_info.get("name", &""))
		var presenter_connected := false
		for connection_value: Variant in SignalBus.get_signal_connection_list(
			signal_name
		):
			var connection: Dictionary = connection_value
			var connected_callable: Callable = connection.get("callable", Callable())
			if connected_callable.get_object() == presenter_root:
				presenter_connected = true
				break
		if (
			presenter_connected
			and not SignalBus.is_connected(signal_name, callback)
		):
			_connect_temporary_signal(signal_name, callback)


func _poison_received_payload(payload: Variant) -> void:
	if payload is Dictionary:
		_hostile_payload_count += 1
		for key: Variant in payload.keys():
			var value: Variant = payload[key]
			if value is Array:
				value.clear()
				value.append(0.5)
				value.append(0.5)
			elif value is Dictionary:
				value.clear()
				value[0.5] = {"foreign": true}
		payload[0.5] = [{"foreign": true}, 0.5]
		return
	if not payload is Object:
		return
	_hostile_payload_count += 1

	# A typed request is still untrusted extension input. Mutate every returned
	# collection copy, then on validation only, try every one-Object boolean
	# method with a foreign live object. Correct authority either exposes no
	# mutator or rejects this caller; it must never enlarge the sealed quorum.
	for method_value: Variant in payload.get_method_list():
		var method: Dictionary = method_value
		var method_name := StringName(method.get("name", &""))
		# Object's virtual `_get_*` hooks appear in reflection metadata but are not
		# callable methods. Only exercise the request's externally callable surface.
		if String(method_name).begins_with("_"):
			continue
		var arguments: Array = method.get("args", [])
		var return_info: Dictionary = method.get("return", {})
		if arguments.is_empty() and int(return_info.get(
			"type", TYPE_NIL)) in [TYPE_ARRAY, TYPE_DICTIONARY]:
			var returned: Variant = payload.call(method_name)
			if returned is Array or returned is Dictionary:
				returned.clear()
		elif _hostile_payload_count == 1 and arguments.size() == 1:
			var argument: Dictionary = arguments[0]
			if (
				int(argument.get("type", TYPE_NIL)) == TYPE_OBJECT
				and int(return_info.get("type", TYPE_NIL)) == TYPE_BOOL
			):
				payload.call(method_name, self)


func _presenter_is_final_visible(record: Dictionary) -> bool:
	var root := record.get("root") as Control
	return (
		root != null
		and is_instance_valid(root)
		and root.visible
		and is_equal_approx(root.modulate.a, 1.0)
	)


func _dialogue_text(request: DialogueRequest) -> String:
	var result := ""
	for segment_value: Variant in request.get_segments():
		var segment: Dictionary = segment_value
		result += String(segment.get("text", ""))
	return result


func _start_transition_and_wait_for_commit(
	path: String,
	presenters: Array[Dictionary],
) -> bool:
	_runtime.start_scenario(path)
	return await _wait_until(
		func() -> bool:
			if not bool(_runtime.call("is_chapter_indicator_visible")):
				return false
			for presenter: Dictionary in presenters:
				var root := presenter.get("root") as Control
				if root == null or not is_instance_valid(root) or not root.visible:
					return false
			return true
	)


func test_tracked_scenario_follows_sequential_jump_and_call_return_identity() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	_assert_chapter("prologue", "chapter.contract.prologue", false)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("aside_chapter", "chapter.contract.aside", false)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("second", "chapter.contract.second", true)
	assert_eq(_chapter_events.map(
		func(event: Dictionary) -> String: return String(event["id"])),
		["prologue", "aside_chapter", "prologue", "second"],
		"identity follows executed scenes; visibility never changes implicitly")


func test_locale_refresh_and_overlays_preserve_live_public_state() -> void:
	if not _require_contract():
		return
	_add_translation("en", "chapter.contract.prologue", "Prologue")
	_add_translation("ja", "chapter.contract.prologue", "序章")
	TranslationServer.set_locale("en")
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "Prologue", true)
	var started_before_refresh := _scenario_started_count
	var event_count := _chapter_events.size()

	for overlay_method: String in [
		"show_settings", "show_backlog", "show_save_load",
	]:
		_runtime.call(overlay_method)
		await get_tree().process_frame
		_assert_chapter("prologue", "Prologue", true)
		_runtime.close_overlay()
		await get_tree().process_frame
		_assert_chapter("prologue", "Prologue", true)

	_runtime.show_settings()
	TranslationServer.set_locale("ja")
	assert_true(await _wait_until(
		func() -> bool: return _chapter_events.size() > event_count))
	_assert_chapter("prologue", "序章", true)
	assert_eq(_scenario_started_count, started_before_refresh,
		"locale refresh republishes metadata without rebuilding the scenario")
	assert_eq(_chapter_events[-1], {"id": "prologue", "title": "序章"},
		"same-id locale refresh must publish the newly resolved title")
	_runtime.close_overlay()
	await get_tree().process_frame
	_assert_chapter("prologue", "序章", true)


func test_manual_and_quick_load_restore_identity_and_visibility_together() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)
	_runtime.save(SAVE_SLOT)

	assert_true(await _advance_to_next_dialogue())
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("aside_chapter", "chapter.contract.aside", false)
	var request_count := _dialogue_requests.size()
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("prologue", "chapter.contract.prologue", true)

	assert_true(await _advance_to_next_dialogue())
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("aside_chapter", "chapter.contract.aside", false)
	_runtime.quick_save()
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)
	request_count = _dialogue_requests.size()
	assert_true(await _runtime.quick_load())
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("aside_chapter", "chapter.contract.aside", false)


func test_backlog_flowchart_and_restart_restore_canonical_target() -> void:
	if not _require_contract():
		return
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	for _step in range(5):
		assert_true(await _advance_to_next_dialogue())
	_assert_chapter("second", "chapter.contract.second", true)

	var request_count := _dialogue_requests.size()
	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("prologue", "chapter.contract.prologue", false)

	request_count = _dialogue_requests.size()
	assert_true(_runtime.jump_from_flowchart("second"))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("second", "chapter.contract.second", true)

	request_count = _dialogue_requests.size()
	_runtime.start_scenario(LIFECYCLE_PATH)
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("prologue", "chapter.contract.prologue", false)


func test_bare_empty_and_late_bound_presenter_apply_public_policy() -> void:
	if not _require_contract(true):
		return
	assert_true(await _start_fixture(BARE_TITLE_PATH))
	_assert_chapter("bare", "bare", true)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_dialogue_requests.clear()
	var empty_presenter := _make_presenter("EmptyTitleSkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(EMPTY_TITLE_PATH))
	_assert_chapter("silent", "", true)
	assert_false((empty_presenter["root"] as Control).visible,
		"missing presentable title gates rendering, not authored visibility")
	assert_eq((empty_presenter["label"] as Label).text, "")

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_dialogue_requests.clear()
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	var late_presenter := _make_presenter("LateBoundSkin")
	await get_tree().process_frame
	assert_true((late_presenter["root"] as Control).visible,
		"late-bound Presenter cuts directly to canonical state")
	assert_eq((late_presenter["label"] as Label).text,
		"chapter.contract.prologue")
	assert_eq((late_presenter["root"] as Control).size, Vector2(417.0, 83.0),
		"late binding cannot take ownership of project geometry")


func test_programmatic_orphan_scene_keeps_authored_target_until_metadata_exists() -> void:
	if not _require_contract(true):
		return
	# Composition-only malformed-data guard.  The authored DSL rejects orphan
	# scenes; this exercises runtime behavior for extension-created ScenarioData.
	var data := ScenarioData.new()
	data.id = "programmatic_orphan_contract"
	var orphan := SceneData.new()
	orphan.id = "orphan"
	var show := CommandData.new()
	show.type = "chapter_indicator"
	show.params = {"action": "show", "transition": "cut", "duration": 0.0}
	orphan.commands.append(show)
	var first_dialogue := CommandData.new()
	first_dialogue.type = "dialogue"
	first_dialogue.params = {"character": "narrator", "text": "orphan"}
	orphan.commands.append(first_dialogue)
	data.scenes.append(orphan)

	var chapter := ChapterData.new()
	chapter.id = "recovered"
	chapter.display_name = "chapter.contract.recovered"
	chapter.scene_ids = ["recovered_scene"]
	data.chapters.append(chapter)
	var recovered := SceneData.new()
	recovered.id = "recovered_scene"
	recovered.chapter_id = "recovered"
	var second_dialogue := CommandData.new()
	second_dialogue.type = "dialogue"
	second_dialogue.params = {"character": "narrator", "text": "recovered"}
	recovered.commands.append(second_dialogue)
	data.scenes.append(recovered)

	var presenter := _make_presenter("OrphanPolicySkin")
	await get_tree().process_frame
	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)
	_runtime.engine.run()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() >= 1))
	_assert_chapter("", "", true)
	assert_false((presenter["root"] as Control).visible)

	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("recovered", "chapter.contract.recovered", true)
	assert_true((presenter["root"] as Control).visible)
	assert_eq((presenter["label"] as Label).text,
		"chapter.contract.recovered")


func test_confirmed_title_clears_then_continue_restores_auto_saved_target() -> void:
	if not _require_contract():
		return
	var expected_title_scene: PackedScene = _runtime.resolve_title_scene()
	var expected_title_scene_path: String = expected_title_scene.resource_path
	var baseline_participant_ids: Array[int] = _chapter_indicator_participant_ids()
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	_assert_chapter("prologue", "chapter.contract.prologue", true)
	var request_count := _dialogue_requests.size()

	_runtime.return_to_title()
	_assert_chapter("prologue", "chapter.contract.prologue", true)
	assert_true(await _wait_until(
		func() -> bool:
			return String(_runtime.call("get_current_chapter_id")) == ""))
	_assert_chapter("", "", false)
	assert_true(_runtime.has_auto_save(),
		"title navigation snapshots the authored target before detaching context")

	assert_true(await _runtime.continue_game())
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	_assert_chapter("prologue", "chapter.contract.prologue", true)

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return not _runtime._return_to_title_pending))
	assert_eq(
		_runtime.game_state.current_state, GameStateMachine.State.TITLE,
		"fixture cleanup must restore the public title state",
	)
	assert_not_null(get_tree().current_scene)
	assert_eq(
		get_tree().current_scene.scene_file_path, expected_title_scene_path,
		"fixture cleanup must re-enter the configured title scene",
	)
	assert_eq(
		_chapter_indicator_participant_ids(), baseline_participant_ids,
		"the continue fixture must retire its real game Presenter before teardown",
	)


func test_mutating_one_listener_payload_cannot_change_quorum_or_other_skins() -> void:
	if not _require_contract(true):
		return
	var first := _make_presenter("ImmutablePayloadFirst")
	await get_tree().process_frame
	_connect_after_presenter_one_arg_callbacks(
		first["root"] as Control, _poison_received_payload)
	var second := _make_presenter("ImmutablePayloadSecond")
	await get_tree().process_frame

	_runtime.start_scenario(SHORT_TRANSITION_PATH)
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1),
		"a hostile extension payload mutation must never strand the barrier")
	_assert_chapter(
		"short_transition", "chapter.contract.short_transition", true)
	assert_true(_presenter_is_final_visible(first),
		"the first accepted skin reaches the authored final state")
	assert_true(_presenter_is_final_visible(second),
		"one listener cannot erase another accepted participant")
	assert_false(_runtime.engine.context.is_finished,
		"payload mutation cannot stop an otherwise valid scenario")


func test_one_presenter_ack_cannot_release_another_presenter_barrier() -> void:
	if not _require_contract(true):
		return
	var immediate := _make_presenter("ImmediateQuorumSkin")
	var delayed := _make_presenter("DelayedQuorumSkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(QUORUM_PATH))
	assert_eq(_dialogue_requests.size(), 1)

	# The first skin is already at the authored visual target and acknowledges
	# synchronously. The second accepts the fade but its bound tween is paused.
	(immediate["root"] as Control).visible = true
	(delayed["root"] as Control).process_mode = Node.PROCESS_MODE_DISABLED
	assert_true(RuntimeTestSupport.advance_dialogue_for_test(get_tree()))
	assert_true(await _wait_until(
		func() -> bool:
			return bool(_runtime.call("is_chapter_indicator_visible"))))
	assert_eq(_dialogue_requests.size(), 1,
		"one synchronous acknowledgement cannot release the joined command")
	assert_eq(_runtime.engine.context.current_command_index, 1,
		"the cursor remains on the blocking chapter operation")

	(delayed["root"] as Control).process_mode = Node.PROCESS_MODE_INHERIT
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 2))
	assert_true(_presenter_is_final_visible(immediate))
	assert_true(_presenter_is_final_visible(delayed))


func test_presenter_added_midfade_is_cut_projected_but_not_added_to_quorum() -> void:
	if not _require_contract(true):
		return
	var accepted := _make_presenter("AcceptedBeforeDispatch")
	await get_tree().process_frame
	(accepted["root"] as Control).process_mode = Node.PROCESS_MODE_DISABLED
	assert_true(await _start_transition_and_wait_for_commit(
		SHORT_TRANSITION_PATH, [accepted]))
	assert_eq(_dialogue_requests.size(), 0)

	var late := _make_presenter("LateDuringFade")
	await get_tree().process_frame
	assert_true(_presenter_is_final_visible(late),
		"a late skin cuts to the committed facade instead of joining the fade")
	assert_eq(_dialogue_requests.size(), 0,
		"late projection cannot acknowledge the accepted participant")

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_presenter_is_final_visible(accepted))
	assert_true(_presenter_is_final_visible(late))


func test_binding_changed_during_active_fade_fails_and_rolls_back_atomically() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("MutatedBindingSkin")
	await get_tree().process_frame
	assert_true(await _start_transition_and_wait_for_commit(
		TRANSITION_PATH, [presenter]))
	var root := presenter["root"] as Control
	root.set("title_label_path", NodePath("MissingAfterAcceptance"))

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _runtime.engine.context.is_finished))
	assert_push_error(TRANSITION_PATH + ":3")
	assert_false(bool(_runtime.call("is_chapter_indicator_visible")),
		"accepted target rolls back when the binding disappears")
	assert_false(root.visible,
		"a failed accepted binding cannot leave partially shown UI")
	assert_eq(_dialogue_requests.size(), 0,
		"the command after a failed binding must not execute")


func test_binding_identity_changed_after_validation_rejects_before_commit() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("ValidationBindingSwapSkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(QUORUM_PATH))
	var root := presenter["root"] as Control
	var original_label := presenter["label"] as Label
	var alternate_label := Label.new()
	alternate_label.name = "AlternateTitle"
	root.add_child(alternate_label)
	var swapped := [false]
	var swap_after_validation := func(_request: Variant) -> void:
		if swapped[0]:
			return
		swapped[0] = true
		root.set("title_label_path", NodePath("AlternateTitle"))
	_connect_after_presenter_one_arg_callbacks(root, swap_after_validation)

	assert_true(RuntimeTestSupport.advance_dialogue_for_test(get_tree()))
	assert_true(await _wait_until(
		func() -> bool: return _runtime.engine.context.is_finished))
	assert_push_error(QUORUM_PATH + ":4")
	assert_true(swapped[0],
		"the project binding changes after this Presenter validates")
	assert_false(bool(_runtime.call("is_chapter_indicator_visible")),
		"apply-time binding identity rejection happens before target commit")
	assert_false(root.visible)
	assert_eq(original_label.text, "chapter.contract.quorum",
		"apply rejection cannot write through the previously validated Label")
	assert_eq(alternate_label.text, "",
		"the replacement Label is not silently adopted mid-operation")
	assert_eq(_dialogue_requests.size(), 1,
		"the sentinel dialogue after the rejected command never runs")


func test_presenter_disappearing_during_apply_fails_without_a_stranded_wait() -> void:
	if not _require_contract(true):
		return
	var survivor := _make_presenter("ApplySurvivor")
	var disappearing := _make_presenter("ApplyDisappearing")
	await get_tree().process_frame
	var survivor_root := survivor["root"] as Control
	var disappearing_root := disappearing["root"] as Control
	var disappearing_ref: WeakRef = weakref(disappearing_root)
	var removed := [false]
	var on_survivor_visibility := func() -> void:
		if survivor_root.visible and not removed[0]:
			removed[0] = true
			var current: Control = disappearing_ref.get_ref() as Control
			if current != null:
				current.free()
	survivor_root.visibility_changed.connect(on_survivor_visibility)

	_runtime.start_scenario(SHORT_TRANSITION_PATH)
	assert_true(await _wait_until(
		func() -> bool: return _runtime.engine.context.is_finished),
		"participant disappearance must settle failure instead of hanging")
	assert_push_error(SHORT_TRANSITION_PATH + ":3")
	assert_true(removed[0])
	assert_false(bool(_runtime.call("is_chapter_indicator_visible")))
	assert_false(survivor_root.visible,
		"surviving participants cut-roll back to the previous target")
	assert_eq(_dialogue_requests.size(), 0)


func test_skip_activation_snaps_only_the_current_transition_generation() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("SkipTransitionSkin")
	await get_tree().process_frame
	assert_true(await _start_transition_and_wait_for_commit(
		TRANSITION_PATH, [presenter]))
	assert_false(_runtime.skip_controller.is_active)

	_runtime.skip_controller.is_active = true
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_runtime.skip_controller.is_active,
		"chapter completion does not rewrite the Skip controller intent")
	assert_true(_presenter_is_final_visible(presenter))
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"the same Skip activation cannot also advance the following dialogue")

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_dialogue_requests.clear()
	_runtime.skip_controller.is_active = true
	var already_skipping := _make_presenter("AlreadySkippingSkin")
	await get_tree().process_frame
	_runtime.start_scenario(TRANSITION_PATH)
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_runtime.skip_controller.is_active)
	assert_true(_presenter_is_final_visible(already_skipping),
		"a transition admitted while Skip is active cuts immediately")


func test_semantic_and_existing_physical_inputs_complete_only_the_fade() -> void:
	if not _require_contract(true):
		return
	var cases := ["semantic", "left", "space", "enter"]
	for case_name: String in cases:
		await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
		_dialogue_requests.clear()
		var presenter := _make_presenter("InputSkin_%s" % case_name)
		var input_script: Script = load(
			"res://addons/stella/presentation/input/input_handler.gd")
		var input_handler: Node = input_script.new()
		_add_owned_node(input_handler)
		await get_tree().process_frame
		assert_true(await _start_transition_and_wait_for_commit(
			TRANSITION_PATH, [presenter]))

		var right_click := InputEventMouseButton.new()
		right_click.button_index = MOUSE_BUTTON_RIGHT
		right_click.pressed = true
		input_handler._input(right_click)
		await get_tree().process_frame
		assert_eq(_dialogue_requests.size(), 0,
			"right-click is not normal transition completion input")

		match case_name:
			"semantic":
				SignalBus.emit_advance_requested()
			"left":
				var left_click := InputEventMouseButton.new()
				left_click.button_index = MOUSE_BUTTON_LEFT
				left_click.pressed = true
				input_handler._input(left_click)
			"space", "enter":
				var key := InputEventKey.new()
				key.keycode = KEY_SPACE if case_name == "space" else KEY_ENTER
				key.pressed = true
				key.echo = false
				input_handler._unhandled_input(key)

		assert_true(await _wait_until(
			func() -> bool: return _dialogue_requests.size() == 1))
		assert_true(_dialogue_requests[0].get_activation().is_pending(),
			"%s must not advance the dialogue installed by its fade" % case_name)
		assert_eq(_runtime.engine.context.current_command_index, 1,
			"%s finishes only the blocking transition" % case_name)
		await get_tree().process_frame
		assert_eq(_dialogue_requests.size(), 1,
			"the input dispatch tail cannot leak into the next owner")
		assert_true(_presenter_is_final_visible(presenter))

		(presenter["root"] as Control).free()
		input_handler.free()
		await get_tree().process_frame


func test_semantic_advance_handles_show_and_hide_without_changing_auto_intent() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("ShowHideTransitionSkin")
	await get_tree().process_frame
	_runtime.auto_play.is_active = true
	assert_true(await _start_transition_and_wait_for_commit(
		TRANSITION_PATH, [presenter]))

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_runtime.auto_play.is_active,
		"normal chapter completion does not rewrite Auto intent")
	assert_true(_dialogue_requests[0].get_activation().is_pending())

	assert_true(RuntimeTestSupport.advance_dialogue_for_test(get_tree()))
	assert_true(await _wait_until(
		func() -> bool:
			return not bool(
				_runtime.call("is_chapter_indicator_visible"))))
	assert_eq(_dialogue_requests.size(), 1,
		"hide fade blocks before the following dialogue")
	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 2))
	assert_false((presenter["root"] as Control).visible)
	assert_true(_dialogue_requests[1].get_activation().is_pending())
	assert_true(_runtime.auto_play.is_active)


func test_midfade_save_commits_bool_and_load_cut_restores_without_replay() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("MidfadeSaveSkin")
	await get_tree().process_frame
	var root := presenter["root"] as Control
	var nested_saved := [false]
	var on_visibility_changed := func() -> void:
		if root.visible and not nested_saved[0]:
			nested_saved[0] = true
			_runtime.save(NESTED_SAVE_SLOT)
	root.visibility_changed.connect(on_visibility_changed)

	assert_true(await _start_transition_and_wait_for_commit(
		MIDFADE_PATH, [presenter]))
	assert_true(nested_saved[0],
		"the project callback must run inside participant apply")
	var nested_data: Variant = _runtime.save_manager.read_save_data(
		NESTED_SAVE_SLOT)
	assert_not_null(nested_data)
	if nested_data is Dictionary:
		var nested_context: Dictionary = nested_data.get("scenario_context", {})
		assert_true(nested_context.get(
			"chapter_indicator_visible") is bool)
		assert_false(bool(nested_context.get(
			"chapter_indicator_visible", true)),
			"apply reentry before full acceptance observes the previous target")
		assert_eq(int(nested_context.get("command_index", -1)), 0)

	_runtime.save(SAVE_SLOT)
	var midfade_data: Variant = _runtime.save_manager.read_save_data(SAVE_SLOT)
	assert_not_null(midfade_data)
	if midfade_data is Dictionary:
		var midfade_context: Dictionary = midfade_data.get("scenario_context", {})
		assert_true(midfade_context.get(
			"chapter_indicator_visible") is bool)
		assert_true(bool(midfade_context.get(
			"chapter_indicator_visible", false)),
			"an accepted in-flight fade persists its committed target")
		assert_eq(int(midfade_context.get("command_index", -1)), 0,
			"save keeps the blocking command cursor, not a tween identity")

	var old_context: ScenarioContext = _runtime.engine.context
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(old_context.current_command_index, 0,
		"navigation invalidates the old run before waking its transition")
	assert_eq(old_context.variable_store.get_var(
		"retired_transition_tail_ran"), null,
		"the retired command tail cannot execute its following sentinel")
	assert_eq(_runtime.engine.context.variable_store.get_var(
		"retired_transition_tail_ran"), "true",
		"only the restored owner executes the command after the no-op cursor")
	_assert_chapter("midfade", "chapter.contract.midfade", true)
	assert_true(_presenter_is_final_visible(presenter),
		"load cut-projects the saved authored target")
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"restoring the same command cursor is a no-op, not a replayed fade")

	# Wait just beyond the authored 0.3-second transition so an uncancelled old
	# tween would fire. This is authored lifecycle timing, not a race-masking nap.
	await get_tree().create_timer(0.35).timeout
	assert_eq(_dialogue_requests.size(), 1,
		"the retired tween tail cannot advance or replay the restored owner")
	assert_true(_dialogue_requests[0].get_activation().is_pending())
	assert_true(_presenter_is_final_visible(presenter))


func test_midfade_quick_load_cancels_old_cursor_before_restored_noop() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("MidfadeQuickLoadSkin")
	await get_tree().process_frame
	assert_true(await _start_transition_and_wait_for_commit(
		MIDFADE_PATH, [presenter]))
	_runtime.quick_save()
	var old_context: ScenarioContext = _runtime.engine.context

	assert_true(await _runtime.quick_load())
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(old_context.current_command_index, 0)
	assert_eq(old_context.variable_store.get_var(
		"retired_transition_tail_ran"), null,
		"quick-load invalidates before the old transition waiter wakes")
	assert_eq(_runtime.engine.context.variable_store.get_var(
		"retired_transition_tail_ran"), "true")
	_assert_chapter("midfade", "chapter.contract.midfade", true)
	assert_true(_presenter_is_final_visible(presenter))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_backlog_jump_midfade_cancels_old_generation_and_cut_restores() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("MidfadeBacklogSkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(QUORUM_PATH))
	var root := presenter["root"] as Control
	root.process_mode = Node.PROCESS_MODE_DISABLED
	assert_true(RuntimeTestSupport.advance_dialogue_for_test(get_tree()))
	assert_true(await _wait_until(
		func() -> bool:
			return bool(_runtime.call("is_chapter_indicator_visible"))))
	var old_context: ScenarioContext = _runtime.engine.context
	assert_eq(old_context.current_command_index, 1)

	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 2))
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(old_context.current_command_index, 1,
		"rollback invalidates the old transition before reset wakes it")
	_assert_chapter("quorum", "chapter.contract.quorum", false)
	assert_false(root.visible,
		"rollback cut-projects the snapshot target instead of replaying a fade")
	assert_true(_dialogue_requests[-1].get_activation().is_pending())

	root.process_mode = Node.PROCESS_MODE_INHERIT
	await get_tree().create_timer(0.08).timeout
	assert_eq(_dialogue_requests.size(), 2,
		"the retired authored tween cannot publish into rollback's owner")
	assert_true(_dialogue_requests[-1].get_activation().is_pending())


func test_one_advance_cannot_leak_from_old_quorum_into_chained_fade() -> void:
	if not _require_contract(true):
		return
	var first := _make_presenter("ChainedFirst")
	await get_tree().process_frame
	assert_true(await _start_transition_and_wait_for_commit(
		CHAINED_TRANSITION_PATH, [first]))
	var late := _make_presenter("ChainedLate")
	await get_tree().process_frame
	assert_true(_presenter_is_final_visible(late))

	# P1 owns the old request before P2's advance listener. P1 completes show,
	# which synchronously installs hide with both participants. The outer event's
	# remaining listener tail must not let P2 consume that newer generation.
	SignalBus.emit_advance_requested()
	assert_false(bool(_runtime.call("is_chapter_indicator_visible")),
		"the chained hide target commits while its fade remains blocking")
	assert_eq(_runtime.engine.context.current_command_index, 1)
	assert_eq(_dialogue_requests.size(), 0)
	for record: Dictionary in [first, late]:
		var root := record["root"] as Control
		assert_true(root.visible,
			"the old advance tail cannot snap a participant in the new hide")
		assert_true(is_equal_approx(root.modulate.a, 1.0),
			"the next generation begins at its authored fade boundary")

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_false((first["root"] as Control).visible)
	assert_false((late["root"] as Control).visible)
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_failure_completion_reentry_cannot_roll_back_the_fresh_owner() -> void:
	if not _require_contract(true):
		return
	var replacement_started := [false]
	var on_completion := func(_request_id: int, success: bool) -> void:
		if success or replacement_started[0]:
			return
		replacement_started[0] = true
		_runtime.start_scenario(BARE_TITLE_PATH)
	_connect_transition_completion_observer(on_completion)
	var survivor := _make_presenter("FailureReentrySurvivor")
	var failing := _make_presenter("FailureReentryRemoved")
	await get_tree().process_frame
	assert_true(await _start_transition_and_wait_for_commit(
		TRANSITION_PATH, [survivor, failing]))

	(failing["root"] as Control).free()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				replacement_started[0]
				and _dialogue_requests.size() == 1
			)))
	assert_push_error(TRANSITION_PATH + ":3")
	_assert_chapter("bare", "bare", true)
	assert_false(_runtime.engine.context.is_finished,
		"the retired handler cannot finish the replacement context")
	assert_true(_presenter_is_final_visible(survivor),
		"retired rollback projection cannot overwrite the fresh owner")
	assert_eq((survivor["label"] as Label).text, "bare")


func test_metadata_listener_navigation_reentry_keeps_the_nested_fade_owner() -> void:
	if not _require_contract(true):
		return
	var nested_started := [false]
	var on_metadata := func(chapter_id: String, _title: String) -> void:
		if chapter_id == "prologue" and not nested_started[0]:
			nested_started[0] = true
			_runtime.start_scenario(TRANSITION_PATH)
	_connect_temporary_signal(&"current_chapter_changed", on_metadata)
	# Connect the built-in Presenter after the adversarial public listener so the
	# outer signal still has a stale tail after the nested navigation returns.
	var presenter := _make_presenter("MetadataReentrySkin")
	await get_tree().process_frame

	_runtime.start_scenario(LIFECYCLE_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	assert_eq((presenter["label"] as Label).text,
		"chapter.contract.transition",
		"the outer metadata signal tail cannot overwrite the nested owner")
	assert_true((presenter["root"] as Control).visible)
	assert_eq(_dialogue_requests.size(), 0)

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_reset_listener_fresh_fade_wins_over_the_outer_reset_tail() -> void:
	if not _require_contract(true):
		return
	var first := _make_presenter("ResetReentryFirst")
	var trailing := _make_presenter("ResetReentryTrailing")
	await get_tree().process_frame
	assert_true(await _start_fixture(BARE_TITLE_PATH))
	assert_true(_presenter_is_final_visible(first))
	assert_true(_presenter_is_final_visible(trailing))
	_dialogue_requests.clear()

	var nested_started := [false]
	var first_root := first["root"] as Control
	var on_first_visibility := func() -> void:
		if not first_root.visible and not nested_started[0]:
			nested_started[0] = true
			_runtime.start_scenario(TRANSITION_PATH)
	first_root.visibility_changed.connect(on_first_visibility)

	_runtime.start_scenario(LIFECYCLE_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	for record: Dictionary in [first, trailing]:
		assert_eq((record["label"] as Label).text,
			"chapter.contract.transition")
		assert_true((record["root"] as Control).visible,
			"the stale outer reset tail cannot cancel the nested fade owner")

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_state_projection_listener_fresh_fade_wins_over_outer_state_tail() -> void:
	if not _require_contract(true):
		return
	var first := _make_presenter("StateReentryFirst")
	var trailing := _make_presenter("StateReentryTrailing")
	await get_tree().process_frame
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	_runtime.save(SAVE_SLOT)
	_dialogue_requests.clear()

	var armed := [false]
	var nested_started := [false]
	var first_root := first["root"] as Control
	var on_metadata := func(chapter_id: String, _title: String) -> void:
		if chapter_id == "prologue" and not nested_started[0]:
			first_root.visible = true
			armed[0] = true
	var on_first_visibility := func() -> void:
		if armed[0] and not first_root.visible and not nested_started[0]:
			nested_started[0] = true
			_runtime.start_scenario(TRANSITION_PATH)
	_connect_temporary_signal(&"current_chapter_changed", on_metadata)
	first_root.visibility_changed.connect(on_first_visibility)

	# The outer load is expected to lose ownership to the nested start. Its
	# boolean projection still has a trailing Presenter listener to retire.
	await _runtime.continue_from_save(SAVE_SLOT)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	for record: Dictionary in [first, trailing]:
		assert_eq((record["label"] as Label).text,
			"chapter.contract.transition")
		assert_true((record["root"] as Control).visible,
			"outer state projection cannot clear a nested authored fade")

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))


func test_confirmed_title_empty_event_reentry_preserves_fresh_navigation() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("TitleReentrySkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	_dialogue_requests.clear()
	var nested_started := [false]
	var on_metadata := func(chapter_id: String, _title: String) -> void:
		if chapter_id.is_empty() and not nested_started[0]:
			nested_started[0] = true
			_runtime.start_scenario(TRANSITION_PATH)
			_runtime.auto_play.is_active = true
	_connect_temporary_signal(&"current_chapter_changed", on_metadata)

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	assert_true(_runtime.game_state.is_playing(),
		"the retired title tail cannot force the fresh owner back to TITLE")
	assert_true(_runtime.auto_play.is_active,
		"the retired title cleanup cannot stop the fresh controller intent")
	assert_eq((presenter["label"] as Label).text,
		"chapter.contract.transition")
	assert_true((presenter["root"] as Control).visible)

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_true(_dialogue_requests[0].get_activation().is_pending())


func test_engine_abort_callback_fresh_start_wins_over_outer_start_tail() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("AbortNavigationReentrySkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(BARE_TITLE_PATH))
	_dialogue_requests.clear()
	var nested_started := [false]
	var on_abort := func() -> void:
		if nested_started[0]:
			return
		nested_started[0] = true
		_runtime.start_scenario(TRANSITION_PATH)
	_connect_temporary_signal(&"engine_abort_requested", on_abort)

	_runtime.start_scenario(LIFECYCLE_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	assert_eq((presenter["label"] as Label).text,
		"chapter.contract.transition")
	assert_true((presenter["root"] as Control).visible)
	assert_eq(_dialogue_requests.size(), 0,
		"outer start must not run after the nested navigation wins abort")

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_eq(_dialogue_text(_dialogue_requests[0]),
		"after show transition")


func test_auto_stop_callback_fresh_start_wins_over_return_title_tail() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("AutoStopNavigationReentrySkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_true(await _advance_to_next_dialogue())
	_dialogue_requests.clear()
	_runtime.auto_play.is_active = true
	var nested_started := [false]
	var auto_controller: AutoPlayController = _runtime.auto_play
	var on_auto_active_changed := func(active: bool) -> void:
		if active or nested_started[0]:
			return
		nested_started[0] = true
		_runtime.start_scenario(TRANSITION_PATH)
		_runtime.auto_play.is_active = true
	auto_controller.active_changed.connect(on_auto_active_changed)

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				nested_started[0]
				and String(_runtime.call(
					"get_current_chapter_id")) == "transition"
				and bool(_runtime.call(
					"is_chapter_indicator_visible"))
			)))
	assert_true(_runtime.game_state.is_playing())
	assert_true(_runtime.auto_play.is_active,
		"the retired title cleanup cannot stop the fresh controller")
	assert_eq((presenter["label"] as Label).text,
		"chapter.contract.transition")
	assert_true((presenter["root"] as Control).visible)
	assert_eq(_dialogue_requests.size(), 0)

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() == 1))
	assert_eq(_dialogue_text(_dialogue_requests[0]),
		"after show transition")
	if auto_controller.active_changed.is_connected(on_auto_active_changed):
		auto_controller.active_changed.disconnect(on_auto_active_changed)


func test_nested_backlog_restore_latest_snapshot_wins_exactly() -> void:
	if not _require_contract(true):
		return
	var presenter := _make_presenter("NestedBacklogRestoreSkin")
	await get_tree().process_frame
	assert_true(await _start_fixture(LIFECYCLE_PATH))
	assert_eq(_dialogue_text(_dialogue_requests[-1]), "opening hidden")
	assert_true(await _advance_to_next_dialogue())
	assert_eq(_dialogue_text(_dialogue_requests[-1]), "opening visible")
	assert_gte(_runtime.get_backlog().size(), 2)
	_runtime.show_backlog()
	await get_tree().process_frame
	var nested_result := [false]
	var nested_called := [false]
	var on_state_changed := func(
		from_state: int,
		to_state: int,
	) -> void:
		if (
			from_state != GameStateMachine.State.BACKLOG
			or to_state != GameStateMachine.State.PLAYING
			or nested_called[0]
		):
			return
		nested_called[0] = true
		nested_result[0] = _runtime.jump_from_backlog(1)
	_runtime.game_state.state_changed.connect(on_state_changed)
	var request_count := _dialogue_requests.size()

	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_until(
		func() -> bool: return _dialogue_requests.size() > request_count))
	assert_true(nested_called[0])
	assert_true(nested_result[0])
	_assert_chapter("prologue", "chapter.contract.prologue", true)
	assert_eq(_runtime.engine.context.current_command_index, 3,
		"the nested/latest visible snapshot owns the final cursor")
	assert_eq(_dialogue_text(_dialogue_requests[-1]), "opening visible")
	assert_true((presenter["root"] as Control).visible)
	assert_true(_dialogue_requests[-1].get_activation().is_pending())
	if _runtime.game_state.state_changed.is_connected(on_state_changed):
		_runtime.game_state.state_changed.disconnect(on_state_changed)
