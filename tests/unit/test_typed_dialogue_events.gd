extends GutTest
## Canonical request/event DTOs are read-only snapshots. Legacy signals remain
## notifications/adapters, but built-in state must not depend on their payloads.


func test_dialogue_request_returns_defensive_copies_to_every_listener() -> void:
	var source_segments := [{"text": "original", "voice": ""}]
	var source_profile := {"line_spacing": 4}
	var source_entries := [{"character": "a", "segments": source_segments}]
	var request := DialogueRequest.new(
		"speaker", source_segments, "nvl", source_profile, true, "page:1",
		{}, source_entries, "entry:1", 7)
	source_segments[0]["text"] = "source mutation"
	source_profile["line_spacing"] = 99
	source_entries[0]["character"] = "source mutation"

	assert_eq(request.get_segments()[0].get("text"), "original")
	assert_eq(request.get_presentation_profile().get("line_spacing"), 4)
	assert_eq(request.get_nvl_page_entries()[0].get("character"), "a")

	var observed: Array = []
	var first: Callable = func(received: DialogueRequest):
		var copy := received.get_segments()
		copy[0]["text"] = "listener mutation"
	var second: Callable = func(received: DialogueRequest):
		observed.append(received.get_segments()[0].get("text"))
	SignalBus.dialogue_requested.connect(first)
	SignalBus.dialogue_requested.connect(second)
	SignalBus.emit_dialogue_request(request)
	SignalBus.dialogue_requested.disconnect(first)
	SignalBus.dialogue_requested.disconnect(second)

	assert_eq(observed, ["original"],
		"an early listener cannot mutate the canonical payload seen later")
	var property_names: Array[String] = []
	for property in request.get_property_list():
		property_names.append(String(property.get("name", "")))
	for old_public_name in [
		"character", "segments", "mode", "presentation_profile",
		"presentation_provenance", "nvl_page_entries", "entry_id",
	]:
		assert_false(property_names.has(old_public_name),
			"canonical input '%s' is getter-only" % old_public_name)


func test_signal_bus_assigns_stable_identity_to_direct_raw_dialogues() -> void:
	var entry_ids: Array[String] = []
	var capture: Callable = func(request: DialogueRequest):
		entry_ids.append(request.get_entry_id())
	SignalBus.dialogue_requested.connect(capture)
	SignalBus.show_dialogue.emit("", [{"text": "one", "voice": ""}], "adv")
	SignalBus.show_dialogue.emit("", [{"text": "two", "voice": ""}], "adv")
	SignalBus.dialogue_requested.disconnect(capture)

	assert_eq(entry_ids.size(), 2)
	assert_false(entry_ids[0].is_empty())
	assert_ne(entry_ids[0], entry_ids[1],
		"direct raw requests cannot collide on an implicit current command")


func test_runtime_delayed_backlog_enrichment_updates_only_request_entry() -> void:
	StellaRuntime.backlog_manager.clear()
	StellaRuntime.backlog_manager.add_entry(
		"a", [{"text": "first", "voice": ""}], 10,
		Callable(), [], "entry:a")
	StellaRuntime.backlog_manager.add_entry(
		"b", [{"text": "second", "voice": ""}], 11,
		Callable(), [], "entry:b")
	var request_a := DialogueRequest.new(
		"a", [{"text": "[custom amp=2]first[/custom]", "voice": ""}],
		"adv", {}, false, "", {}, [], "entry:a", 10)

	# Simulate a custom Presenter resolving its effect registry after request B has
	# already moved the runtime cursor. Enrichment must use request A's identity.
	SignalBus.dialogue_backlog_effects_resolved.emit(request_a, ["custom"])

	var entries: Array = StellaRuntime.backlog_manager.get_entries()
	assert_eq(entries.size(), 2,
		"delayed enrichment updates in place instead of re-adding a row")
	assert_eq(entries[0].get("text"), "first")
	assert_eq(entries[1].get("text"), "second",
		"the current/following command cannot be rewritten by request A")
	StellaRuntime.backlog_manager.clear()


func test_voice_request_exposes_read_only_response_and_completion_views() -> void:
	var audio := StellaRuntime.get_node("AudioPresenter")
	var audio_callback := Callable(audio, "_on_voice_playback_requested")
	SignalBus.voice_playback_requested.disconnect(audio_callback)
	var accepted: Callable = func(received: VoicePlaybackRequest):
		SignalBus.resolve_voice_playback_request(received, true)
	SignalBus.voice_playback_requested.connect(accepted)
	var result := SignalBus.request_voice_playback(
		"voice", "speaker", Callable(), false)
	SignalBus.voice_playback_requested.disconnect(accepted)
	SignalBus.voice_playback_requested.connect(audio_callback)

	assert_true(result.was_handled())
	assert_true(result.was_accepted())
	assert_gt(result.get_playback_token(), 0)
	var completion := result.get_completion()
	assert_not_null(completion)
	assert_false(completion.is_finished())
	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
		result.get_playback_token()))
	assert_true(completion.is_finished(),
		"only the bus-owned FINISHED path mutates completion state")
	_assert_getter_only(result, [
		"handled", "accepted", "playback_token", "completion",
	])
	_assert_getter_only(completion, ["finished"])


func test_voice_request_and_events_hide_mutable_protocol_fields() -> void:
	var request := VoicePlaybackRequest.new(
		"voice", "speaker", func(): return false)
	var physical := VoicePlaybackEvent.started(
		"speaker", "voice", 17, func(): return false)
	var logical := DialogueVoicePlaybackEvent.progress(
		1.0, 4.0, func(): return false)

	_assert_getter_only(request, [
		"asset", "character", "owner_validator", "handled", "accepted",
		"playback_token", "completion_state",
	])
	_assert_getter_only(physical, [
		"kind", "playback_token", "character", "asset", "position",
		"duration", "owner_validator", "legacy_raw",
	])
	_assert_getter_only(logical, [
		"kind", "position", "total_duration", "owner_validator", "legacy_raw",
	])
	assert_false(request.is_current())
	assert_false(physical.is_current())
	assert_false(logical.is_current())


func test_demo_voice_progress_bar_consumes_typed_logical_events() -> void:
	var progress := ProgressBar.new()
	progress.set_script(load("res://examples/demo/scripts/voice_progress_bar.gd"))
	add_child_autoqfree(progress)
	await get_tree().process_frame

	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.started(4.0))
	assert_true(progress.visible)
	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.progress(1.0, 4.0))
	assert_almost_eq(progress.value, 0.25, 0.001)
	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.finished())
	assert_false(progress.visible)


func test_legacy_logical_signals_are_bidirectional_typed_adapters() -> void:
	var progress := ProgressBar.new()
	progress.set_script(load("res://examples/demo/scripts/voice_progress_bar.gd"))
	add_child_autoqfree(progress)
	await get_tree().process_frame
	var compatibility_started: Array[float] = []
	var typed_events: Array[DialogueVoicePlaybackEvent] = []
	var on_started: Callable = func(total_duration: float):
		compatibility_started.append(total_duration)
	var on_typed: Callable = func(event: DialogueVoicePlaybackEvent):
		typed_events.append(event)
	SignalBus.dialogue_voice_started.connect(on_started)
	SignalBus.dialogue_voice_playback_event.connect(on_typed)

	SignalBus.dialogue_voice_started.emit(8.0)
	assert_true(progress.visible,
		"a raw legacy START is adapted into the typed built-in UI path")
	SignalBus.dialogue_voice_progress.emit(2.0, 8.0)
	assert_almost_eq(progress.value, 0.25, 0.001)
	SignalBus.dialogue_voice_finished.emit()
	assert_false(progress.visible)
	assert_eq(typed_events.size(), 3)
	for event in typed_events:
		assert_true(event.is_legacy_raw(),
			"inbound compatibility signals are explicitly marked legacy raw")

	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.started(3.0))
	assert_eq(compatibility_started, [8.0, 3.0],
		"typed START remains visible to legacy extension listeners")
	assert_eq(typed_events.size(), 4,
		"the outbound compatibility notification must not loop back into typed")
	assert_false(typed_events[-1].is_legacy_raw())
	SignalBus.dialogue_voice_started.disconnect(on_started)
	SignalBus.dialogue_voice_playback_event.disconnect(on_typed)


func test_retired_typed_logical_event_cannot_mutate_demo_ui() -> void:
	var progress := ProgressBar.new()
	progress.set_script(load("res://examples/demo/scripts/voice_progress_bar.gd"))
	add_child_autoqfree(progress)
	await get_tree().process_frame
	var current := [true]

	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.started(2.0, func(): return current[0]))
	current[0] = false
	SignalBus.emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.finished(func(): return current[0]))

	assert_true(progress.visible,
		"a retired FINISHED event is rejected before built-in UI consumes it")


func _assert_getter_only(value: Object, removed_public_names: Array) -> void:
	var property_names: Array[String] = []
	for property in value.get_property_list():
		property_names.append(String(property.get("name", "")))
	for public_name in removed_public_names:
		assert_false(property_names.has(String(public_name)),
			"canonical field '%s' is getter-only" % public_name)
