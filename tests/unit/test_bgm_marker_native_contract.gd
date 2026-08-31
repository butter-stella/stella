extends GutTest
## Synthetic native-playback contract for issue #190.
##
## These tests call mix_audio() to create deterministic audio callback boundaries;
## no wall-clock wait or main-frame polling decides marker selection.

const SYNTHETIC_OGG := \
	"res://tests/fixtures/audio/bgm/synthetic_loop_region.ogg"


func _base_configuration(
	fixture_bytes: PackedByteArray = PackedByteArray(),
) -> Dictionary:
	var bytes := fixture_bytes
	if bytes.is_empty():
		bytes = FileAccess.get_file_as_bytes(SYNTHETIC_OGG)
	return {
		"initial_gains": PackedFloat32Array([1.0, 0.0]),
		"loop": true,
		"loop_end_frame": 1024,
		"loop_start_frame": 0,
		"markers": [
			{"frame": 16, "name": "old"},
			{"frame": 32, "name": "サビ"},
			{"frame": 48, "name": "サビ"},
			{"frame": 64, "name": "A B,=\t\"C\""},
		],
		"schema_version": 1,
		"stem_names": PackedStringArray(["rhythm", "bass"]),
		"stem_ogg_bytes": [bytes, bytes],
	}


func _new_stream_object() -> Object:
	assert_true(ClassDB.class_exists(&"StellaMarkerBgmStream"))
	return ClassDB.instantiate(&"StellaMarkerBgmStream") \
		if ClassDB.class_exists(&"StellaMarkerBgmStream") else null


func _new_playback(
	start_frame: int = 0,
	fixture_bytes: PackedByteArray = PackedByteArray(),
) -> AudioStreamPlayback:
	assert_true(ClassDB.class_exists(&"StellaMarkerBgmStream"),
		"#190 requires one native AudioStreamPlayback transport")
	if not ClassDB.class_exists(&"StellaMarkerBgmStream"):
		return null
	var stream_object: Object = _new_stream_object()
	assert_not_null(stream_object)
	if stream_object == null:
		return null
	var bytes := fixture_bytes
	if bytes.is_empty():
		bytes = FileAccess.get_file_as_bytes(SYNTHETIC_OGG)
	assert_false(bytes.is_empty(), "the fixture must be public synthetic OGG data")
	return _new_playback_from_configuration(
		stream_object, _base_configuration(bytes), start_frame)


func _new_playback_from_configuration(
	stream_object: Object,
	configuration: Dictionary,
	start_frame: int = 0,
	startup: Dictionary = {},
) -> AudioStreamPlayback:
	var configured: Variant = stream_object.call("configure", configuration)
	assert_eq(configured, true)
	if configured != true:
		return null
	if not startup.is_empty():
		var startup_configured: Variant = stream_object.call(
			"configure_startup_marker_mix", startup)
		assert_eq(startup_configured, true)
		if startup_configured != true:
			return null
	var stream := stream_object as AudioStream
	assert_not_null(stream)
	if stream == null:
		return null
	var playback := stream.instantiate_playback()
	assert_not_null(playback)
	if playback != null:
		playback.start(float(start_frame) / 44100.0)
	return playback


func test_export_safe_packet_sequence_rebuilds_identical_decoded_pcm() -> void:
	var imported := ResourceLoader.load(SYNTHETIC_OGG) as AudioStreamOggVorbis
	assert_not_null(imported)
	if imported == null or imported.packet_sequence == null:
		return
	var rebuilt := BgmOggPacketEncoder.encode(
		imported.packet_sequence.packet_data,
		imported.packet_sequence.granule_positions,
		0x53540001,
	)
	assert_false(rebuilt.is_empty())
	assert_eq(
		rebuilt,
		BgmOggPacketEncoder.encode(
			imported.packet_sequence.packet_data,
			imported.packet_sequence.granule_positions,
			0x53540001,
		),
		"the export-time Ogg container is deterministic",
	)
	var raw_playback := _new_playback()
	var rebuilt_playback := _new_playback(0, rebuilt)
	if raw_playback == null or rebuilt_playback == null:
		return
	var raw_pcm := raw_playback.mix_audio(_one_source_frame_rate_scale(), 128)
	var rebuilt_pcm := rebuilt_playback.mix_audio(
		_one_source_frame_rate_scale(), 128)
	assert_eq(rebuilt_pcm, raw_pcm,
		"Godot's export-safe OggPacketSequence must preserve native decoded PCM")


func _arm(
	playback: AudioStreamPlayback,
	marker: String,
	gains: PackedFloat32Array,
	operation_id: int,
) -> int:
	return int(playback.call(
		"arm_marker_mix", marker, gains, 0, operation_id))


func _snapshot(playback: AudioStreamPlayback) -> Dictionary:
	var value: Variant = playback.call("capture_marker_state")
	assert_true(value is Dictionary)
	return value as Dictionary if value is Dictionary else {}


func _events(playback: AudioStreamPlayback) -> Array:
	var value: Variant = playback.call("drain_marker_events")
	assert_true(value is Array)
	return value as Array if value is Array else []


func _one_source_frame_rate_scale() -> float:
	return float(AudioServer.get_mix_rate()) / 44100.0


func _event_types(events: Array) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in events:
		if value is Dictionary:
			result.append(String(value.get("type", "")))
	return result


func test_enqueue_before_audio_ack_is_one_coherent_queued_snapshot() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	assert_eq(_arm(
		playback, "サビ", PackedFloat32Array([0.0, 1.0]), 101), 0)
	var snapshot := _snapshot(playback)
	assert_eq(snapshot.get("phase"), "queued")
	assert_eq(snapshot.get("queued_operation_id"), 101)
	assert_gt(int(snapshot.get("published_sequence", 0)),
		int(snapshot.get("consumed_sequence", -1)))
	assert_eq(snapshot.get("active_operation_id"), 0)
	assert_eq(snapshot.get("expected_active_arm_id"), 0)


func test_queued_replacement_snapshot_identifies_the_old_arm_without_torn_state() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	assert_eq(_arm(
		playback, "old", PackedFloat32Array([0.5, 0.5]), 201), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	var armed := _snapshot(playback)
	assert_eq(armed.get("phase"), "armed")
	assert_eq(armed.get("active_operation_id"), 201)
	var old_arm_id := int(armed.get("arm_id", 0))
	assert_gt(old_arm_id, 0)

	assert_eq(_arm(
		playback, "サビ", PackedFloat32Array([0.0, 1.0]), 202), 0)
	var queued := _snapshot(playback)
	assert_eq(queued.get("phase"), "queued")
	assert_eq(queued.get("queued_operation_id"), 202)
	assert_eq(queued.get("expected_active_arm_id"), old_arm_id)
	assert_eq(queued.get("active_operation_id"), 201)
	assert_gt(int(queued.get("published_sequence", 0)),
		int(queued.get("consumed_sequence", -1)))


func test_replacement_admission_failure_keeps_the_old_arm_unchanged() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	assert_eq(_arm(
		playback, "old", PackedFloat32Array([0.5, 0.5]), 301), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	var before := _snapshot(playback)
	assert_eq(before.get("phase"), "armed")

	var held: Variant = playback.call("debug_hold_all_free_event_credits")
	assert_eq(held, true)
	var result := _arm(
		playback, "サビ", PackedFloat32Array([0.0, 1.0]), 302)
	assert_lt(result, 0, "event admission must reject before publishing a command")
	var after := _snapshot(playback)
	assert_eq(after, before,
		"failed replacement admission preserves the old arm and its receipt owner")
	playback.call("debug_release_held_event_credits")


func test_multiple_callback_failures_keep_unique_pre_reserved_terminal_events() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	var metrics: Variant = playback.call("debug_get_marker_metrics")
	assert_true(metrics is Dictionary)
	if not metrics is Dictionary:
		return
	var command_capacity := int(metrics.get("command_capacity", 0))
	var event_capacity := int(metrics.get("event_capacity", 0))
	assert_gt(command_capacity, 1)
	assert_true(event_capacity >= command_capacity * 3,
		"every admitted command owns its worst-case ARMED/TRIGGERED/COMPLETED credits")
	for index in range(command_capacity):
		assert_eq(_arm(
			playback,
			"missing-%d" % index,
			PackedFloat32Array([0.0, 1.0]),
			400 + index,
		), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	var events_value: Variant = playback.call("drain_marker_events")
	assert_true(events_value is Array)
	if not events_value is Array:
		return
	var failed_ids: Array[int] = []
	for event_value: Variant in events_value:
		if (
			event_value is Dictionary
			and String(event_value.get("type", "")) == "failed_no_marker"
		):
			failed_ids.append(int(event_value.get("operation_id", 0)))
	assert_eq(failed_ids.size(), command_capacity,
		"a sticky single slot must not overwrite concurrent failures")
	failed_ids.sort()
	for index in range(command_capacity):
		assert_eq(failed_ids[index], 400 + index)
	var snapshot := _snapshot(playback)
	assert_eq(snapshot.get("phase"), "none")
	assert_eq(snapshot.get("active_operation_id"), 0)


func test_callback_boundary_selects_h_minus_one_h_and_h_plus_one_by_occurrence() -> void:
	for case: Dictionary in [
		{"cursor": 31, "frame": 32, "ordinal": 1, "types": ["armed"]},
		{
			"cursor": 32, "frame": 32, "ordinal": 1,
			"types": ["armed", "triggered", "completed"],
		},
		{"cursor": 33, "frame": 48, "ordinal": 2, "types": ["armed"]},
	]:
		var playback := _new_playback(int(case["cursor"]))
		if playback == null:
			return
		assert_eq(int(_snapshot(playback).get("frame_cursor", -1)), case["cursor"])
		assert_eq(_arm(
			playback, "サビ", PackedFloat32Array([0.0, 1.0]),
			500 + int(case["cursor"])), 0)
		playback.mix_audio(_one_source_frame_rate_scale(), 1)
		var events := _events(playback)
		assert_eq(_event_types(events), case["types"])
		assert_eq(int(events[0].get("marker_frame", -1)), case["frame"])
		assert_eq(int(events[0].get("marker_ordinal", -1)), case["ordinal"])


func test_duplicate_unicode_markers_advance_in_order_then_wrap_the_loop() -> void:
	var first := _new_playback(32)
	if first == null:
		return
	assert_eq(_arm(first, "サビ", PackedFloat32Array([0.0, 1.0]), 601), 0)
	first.mix_audio(_one_source_frame_rate_scale(), 1)
	var first_events := _events(first)
	assert_eq(int(first_events[0].get("marker_frame", -1)), 32)
	assert_eq(int(first_events[0].get("marker_ordinal", -1)), 1)

	var duplicate := _new_playback(33)
	assert_eq(_arm(
		duplicate, "サビ", PackedFloat32Array([0.0, 1.0]), 602), 0)
	duplicate.mix_audio(_one_source_frame_rate_scale(), 1)
	var duplicate_events := _events(duplicate)
	assert_eq(int(duplicate_events[0].get("marker_frame", -1)), 48)
	assert_eq(int(duplicate_events[0].get("marker_ordinal", -1)), 2)

	var wrapped := _new_playback(1000)
	assert_eq(_arm(
		wrapped, "サビ", PackedFloat32Array([0.0, 1.0]), 603), 0)
	wrapped.mix_audio(_one_source_frame_rate_scale(), 1)
	var armed_events := _events(wrapped)
	assert_eq(_event_types(armed_events), ["armed"])
	assert_eq(int(armed_events[0].get("marker_frame", -1)), 32)
	assert_eq(int(armed_events[0].get("marker_ordinal", -1)), 1)
	assert_true(bool(armed_events[0].get("wraps_loop", false)))
	wrapped.mix_audio(_one_source_frame_rate_scale(), 56)
	var trigger_events := _events(wrapped)
	assert_eq(_event_types(trigger_events), ["triggered", "completed"])
	assert_true(bool(trigger_events[0].get("wraps_loop", false)))
	assert_eq(int(_snapshot(wrapped).get("frame_cursor", -1)), 33)


func test_trigger_splits_one_callback_and_ramp_uses_exact_source_frames() -> void:
	var playback := _new_playback(15)
	if playback == null:
		return
	assert_eq(int(playback.call(
		"arm_marker_mix",
		"old",
		PackedFloat32Array([0.0, 1.0]),
		4,
		701,
	)), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 2)
	assert_eq(_event_types(_events(playback)), ["armed", "triggered"])
	assert_eq(playback.call("debug_get_current_gains"),
		PackedFloat32Array([1.0, 0.0]),
		"marker frame H is the first ramp frame at progress zero")
	assert_eq(_snapshot(playback).get("phase"), "triggered")
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	var quarter: PackedFloat32Array = playback.call("debug_get_current_gains")
	assert_almost_eq(quarter[0], 0.75, 0.000001)
	assert_almost_eq(quarter[1], 0.25, 0.000001)
	playback.mix_audio(_one_source_frame_rate_scale(), 2)
	assert_eq(_event_types(_events(playback)), ["completed"])
	assert_eq(playback.call("debug_get_current_gains"),
		PackedFloat32Array([0.0, 1.0]))
	var metrics: Dictionary = playback.call("debug_get_marker_metrics")
	assert_eq(metrics.get("rt_allocation_violations"), 0)
	assert_eq(metrics.get("rt_lock_violations"), 0)
	assert_eq(metrics.get("available_event_credits"), metrics.get("event_capacity"))


func test_non_unity_rate_uses_linear_pcm_interpolation_without_a_second_transport() -> void:
	var unity := _new_playback()
	var half_rate := _new_playback()
	if unity == null or half_rate == null:
		return
	var reference := unity.mix_audio(_one_source_frame_rate_scale(), 4)
	var interpolated := half_rate.mix_audio(
		_one_source_frame_rate_scale() * 0.5, 7)
	assert_eq(reference.size(), 4)
	assert_eq(interpolated.size(), 7)
	if reference.size() != 4 or interpolated.size() != 7:
		return
	for source_index in range(4):
		var output_index := source_index * 2
		assert_almost_eq(
			interpolated[output_index].x, reference[source_index].x, 0.000001)
		assert_almost_eq(
			interpolated[output_index].y, reference[source_index].y, 0.000001)
		if source_index == 3:
			continue
		assert_almost_eq(
			interpolated[output_index + 1].x,
			(reference[source_index].x + reference[source_index + 1].x) * 0.5,
			0.000001,
		)
		assert_almost_eq(
			interpolated[output_index + 1].y,
			(reference[source_index].y + reference[source_index + 1].y) * 0.5,
			0.000001,
		)
	assert_almost_eq(
		unity.get_playback_position(), 4.0 / 44100.0, 0.000001)
	assert_almost_eq(
		half_rate.get_playback_position(), 3.0 / 44100.0, 0.000001)
	assert_eq(_snapshot(half_rate).get("playback_frame_cursor"), 3)
	assert_eq(
		(half_rate.call("debug_get_marker_metrics") as Dictionary).get(
			"rt_allocation_violations"),
		0,
	)


func test_fractional_prefetch_keeps_h_available_for_intercallback_arm() -> void:
	var reference := _new_playback(15)
	var playback := _new_playback(15)
	if reference == null or playback == null:
		return
	var source_reference := reference.mix_audio(
		_one_source_frame_rate_scale(), 2)
	var before_arm := playback.mix_audio(
		_one_source_frame_rate_scale() * 0.5, 2)
	assert_eq(before_arm.size(), 2)
	assert_eq(_snapshot(playback).get("frame_cursor"), 16,
		"H is the earliest source boundary not yet rendered exactly")
	assert_eq(_arm(
		playback, "old", PackedFloat32Array([0.5, 0.0]), 850), 0)
	var exact_h := playback.mix_audio(
		_one_source_frame_rate_scale() * 0.5, 1)
	assert_eq(_event_types(_events(playback)), [
		"armed", "triggered", "completed",
	])
	assert_eq(exact_h.size(), 1)
	if exact_h.size() == 1 and source_reference.size() == 2:
		assert_almost_eq(exact_h[0].x, source_reference[1].x * 0.5, 0.000001)
		assert_almost_eq(exact_h[0].y, source_reference[1].y * 0.5, 0.000001)
	assert_eq(playback.call("debug_get_current_gains"),
		PackedFloat32Array([0.5, 0.0]))


func test_rate_above_one_selects_earliest_unactivated_h_minus_h_and_h_plus_one() -> void:
	var configuration := _base_configuration()
	configuration["loop"] = false
	configuration["markers"] = [
		{"frame": 0, "name": "H-1"},
		{"frame": 1, "name": "H"},
		{"frame": 2, "name": "H+1"},
	]
	for case: Dictionary in [
		{"label": "H-1", "frame": -1, "ordinal": -1,
			"types": ["failed_no_marker"]},
		{"label": "H", "frame": 1, "ordinal": 1,
			"types": ["armed", "triggered", "completed"]},
		{"label": "H+1", "frame": 2, "ordinal": 2,
			"types": ["armed", "triggered", "completed"]},
	]:
		var stream_object := _new_stream_object()
		var playback := _new_playback_from_configuration(
			stream_object, configuration)
		if playback == null:
			return
		var identity := playback.get_instance_id()
		playback.mix_audio(_one_source_frame_rate_scale() * 2.5, 1)
		var before := _snapshot(playback)
		assert_eq(before.get("horizon_frame"), 1)
		assert_eq(before.get("horizon_loop_epoch"), 0)
		assert_eq(_arm(
			playback, String(case["label"]),
			PackedFloat32Array([0.0, 1.0]), 855), 0)
		playback.mix_audio(_one_source_frame_rate_scale() * 2.5, 1)
		var events := _events(playback)
		assert_eq(_event_types(events), case["types"])
		if int(case["frame"]) >= 0:
			assert_eq(events[0].get("marker_frame"), case["frame"])
			assert_eq(events[0].get("marker_ordinal"), case["ordinal"])
			assert_eq(events[0].get("marker_loop_epoch"), 0)
		assert_eq(playback.get_instance_id(), identity,
			"rate-scale marker selection never replaces or restarts playback")


func test_high_rate_short_loop_binds_duplicate_occurrences_to_exact_loop_epoch() -> void:
	var configuration := _base_configuration()
	configuration["loop_end_frame"] = 4
	configuration["markers"] = [
		{"frame": 1, "name": "tick"},
		{"frame": 1, "name": "wrap"},
		{"frame": 3, "name": "tick"},
	]
	var stream_object := _new_stream_object()
	var playback := _new_playback_from_configuration(
		stream_object, configuration)
	if playback == null:
		return
	var identity := playback.get_instance_id()
	var high_rate := _one_source_frame_rate_scale() * 10.5
	playback.mix_audio(high_rate, 1)
	assert_eq(_snapshot(playback).get("horizon_frame"), 1)
	assert_eq(_arm(
		playback, "tick", PackedFloat32Array([0.0, 1.0]), 856), 0)
	playback.mix_audio(high_rate, 1)
	var first := _events(playback)
	assert_eq(_event_types(first), ["armed", "triggered", "completed"])
	assert_eq(first[0].get("marker_frame"), 1)
	assert_eq(first[0].get("marker_ordinal"), 0)
	assert_eq(first[0].get("marker_loop_epoch"), 0)

	var second_horizon := _snapshot(playback)
	assert_eq(second_horizon.get("horizon_frame"), 3)
	assert_eq(second_horizon.get("horizon_loop_epoch"), 2)
	assert_eq(_arm(
		playback, "tick", PackedFloat32Array([1.0, 0.0]), 857), 0)
	playback.mix_audio(high_rate, 1)
	var second := _events(playback)
	assert_eq(_event_types(second), ["armed", "triggered", "completed"])
	assert_eq(second[0].get("marker_frame"), 3)
	assert_eq(second[0].get("marker_ordinal"), 2)
	assert_eq(second[0].get("marker_loop_epoch"), 2)
	assert_false(bool(second[0].get("wraps_loop", true)))

	var wrap_horizon := _snapshot(playback)
	assert_eq(_arm(
		playback, "wrap", PackedFloat32Array([0.5, 0.5]), 858), 0)
	playback.mix_audio(high_rate, 1)
	var wrapped := _events(playback)
	assert_eq(_event_types(wrapped), ["armed", "triggered", "completed"])
	assert_eq(wrapped[0].get("marker_frame"), 1)
	assert_eq(wrapped[0].get("marker_ordinal"), 1)
	assert_eq(
		wrapped[0].get("marker_loop_epoch"),
		int(wrap_horizon.get("horizon_loop_epoch", -1)) + 1,
	)
	assert_true(bool(wrapped[0].get("wraps_loop", false)))
	assert_eq(playback.get_instance_id(), identity)


func test_startup_restore_arm_is_queued_before_playback_can_mix() -> void:
	var stream_object := _new_stream_object()
	var startup := {
		"fade_frames": 0,
		"gains": PackedFloat32Array([0.0, 1.0]),
		"horizon_frame": 15,
		"horizon_loop_epoch": 7,
		"marker": "old",
		"marker_frame": 16,
		"marker_loop_epoch": 7,
		"marker_ordinal": 0,
		"operation_id": 859,
		"schema_version": 1,
	}
	var playback := _new_playback_from_configuration(
		stream_object, _base_configuration(), 15, startup)
	if playback == null:
		return
	var before := _snapshot(playback)
	assert_eq(before.get("phase"), "queued")
	assert_eq(before.get("horizon_frame"), 15)
	assert_eq(before.get("horizon_loop_epoch"), 7)
	assert_eq(before.get("playback_frame_cursor"), 15,
		"play/start cannot advance a sample before the restore arm is visible")
	assert_true(bool(before.get("startup_gate_closed", false)))
	var gains_before: PackedFloat32Array = playback.call(
		"debug_get_current_gains")
	var metrics_before: Dictionary = playback.call("debug_get_marker_metrics")
	var gated_pcm := playback.mix_audio(_one_source_frame_rate_scale(), 4)
	assert_eq(gated_pcm.size(), 4,
		"the startup gate satisfies AudioServer's complete-buffer contract")
	for sample: Vector2 in gated_pcm:
		assert_eq(sample, Vector2.ZERO,
			"the complete startup buffer is silence, not decoded source PCM")
	var after_gate := _snapshot(playback)
	assert_eq(after_gate, before,
		"the silent callback preserves cursor, arm phase, and command sequences")
	assert_eq(playback.call("debug_get_current_gains"), gains_before,
		"the silent callback cannot start or advance the pending ramp")
	var metrics_after: Dictionary = playback.call("debug_get_marker_metrics")
	assert_eq(
		metrics_after.get("rt_decoder_refill_calls"),
		metrics_before.get("rt_decoder_refill_calls"),
		"the silent callback performs no decoder work",
	)
	assert_eq(_events(playback), [],
		"the silent callback neither consumes the command nor emits an event")
	playback.call("release_startup_gate")
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	var armed := _events(playback)
	assert_eq(_event_types(armed), ["armed"])
	assert_eq(armed[0].get("marker_loop_epoch"), 7)
	assert_eq(_snapshot(playback).get("horizon_frame"), 16)


func test_unsupported_source_steps_hold_silence_before_command_consumption() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	assert_eq(_arm(
		playback, "サビ", PackedFloat32Array([0.0, 1.0]), 8581), 0)
	var queued := _snapshot(playback)
	var gains_before: PackedFloat32Array = playback.call(
		"debug_get_current_gains")
	var metrics_before: Dictionary = playback.call("debug_get_marker_metrics")
	var tiny_rate := _one_source_frame_rate_scale() * 1.0e-12
	var huge_rate := _one_source_frame_rate_scale() * 2048.0
	for unsupported_rate: float in [tiny_rate, huge_rate]:
		var held_pcm := playback.mix_audio(unsupported_rate, 8)
		assert_eq(held_pcm.size(), 8,
			"unsupported positive source steps keep the playback alive")
		for sample: Vector2 in held_pcm:
			assert_eq(sample, Vector2.ZERO)
		assert_eq(_snapshot(playback), queued,
			"rate hold precedes control/command/arm state mutation")
		assert_eq(playback.call("debug_get_current_gains"), gains_before)
		assert_eq(_events(playback), [])
	var metrics_after: Dictionary = playback.call("debug_get_marker_metrics")
	assert_eq(
		metrics_after.get("rt_decoder_refill_calls"),
		metrics_before.get("rt_decoder_refill_calls"),
		"both rate holds perform zero decoder work",
	)
	assert_eq(
		int(metrics_after.get("rate_hold_callback_count", 0))
			- int(metrics_before.get("rate_hold_callback_count", 0)),
		2,
	)

	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(_event_types(_events(playback)), ["armed"],
		"the retained queued command arms exactly once at the first valid boundary")
	playback.mix_audio(_one_source_frame_rate_scale(), 32)
	assert_eq(_event_types(_events(playback)), ["triggered", "completed"],
		"the retained command triggers and completes exactly once")


func test_true_nonloop_eof_settles_an_active_native_ramp() -> void:
	var configuration := _base_configuration()
	configuration["loop"] = false
	var stream_object := _new_stream_object()
	var playback := _new_playback_from_configuration(
		stream_object, configuration)
	if playback == null:
		return
	assert_eq(int(playback.call(
		"arm_marker_mix", "サビ", PackedFloat32Array([0.0, 1.0]),
		100000, 8582)), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(_event_types(_events(playback)), ["armed"])
	var frame_count := int(stream_object.call("get_source_frame_count"))
	playback.mix_audio(_one_source_frame_rate_scale(), frame_count - 1)
	assert_eq(_event_types(_events(playback)), ["triggered"])
	assert_eq(
		playback.mix_audio(_one_source_frame_rate_scale(), 1).size(), 0,
		"only the explicit non-loop EOF returns a short terminal buffer",
	)
	assert_eq(_event_types(_events(playback)), ["completed"],
		"EOF cannot strand the already-triggered ramp receipt")


func test_capture_waits_for_inflight_callback_before_pairing_a_queued_command() -> void:
	var configuration := _base_configuration()
	configuration["loop_end_frame"] = 4
	configuration["markers"] = [
		{"frame": 1, "name": "tick"},
		{"frame": 3, "name": "tick"},
	]
	var stream_object := _new_stream_object()
	var playback := _new_playback_from_configuration(stream_object, configuration)
	if playback == null:
		return
	var high_rate := _one_source_frame_rate_scale() * 10.5
	playback.mix_audio(high_rate, 1)
	assert_eq(_snapshot(playback).get("horizon_frame"), 1)

	playback.call("debug_set_hold_after_consume", true)
	var mix_thread := Thread.new()
	assert_eq(mix_thread.start(func() -> PackedVector2Array:
		return playback.mix_audio(high_rate, 1)
	), OK)
	var spin_count := 0
	while not bool(playback.call("debug_is_callback_held")) and spin_count < 10000000:
		spin_count += 1
	var callback_is_held := bool(playback.call("debug_is_callback_held"))
	assert_true(callback_is_held,
		"debug handshake stops the callback after its command-consume boundary")
	if not callback_is_held:
		playback.call("debug_set_hold_after_consume", false)
		mix_thread.wait_to_finish()
		return

	assert_eq(_arm(
		playback, "tick", PackedFloat32Array([0.0, 1.0]), 8591), 0)
	var capture_thread := Thread.new()
	assert_eq(capture_thread.start(func() -> Dictionary:
		return playback.call("capture_marker_state") as Dictionary
	), OK)
	spin_count = 0
	while (
		int(playback.call("debug_get_capture_waiter_count")) == 0
		and spin_count < 10000000
	):
		spin_count += 1
	assert_eq(int(playback.call("debug_get_capture_waiter_count")), 1,
		"capture observes the callback-wide odd generation before release")
	playback.call("debug_set_hold_after_consume", false)
	var mixed_value: Variant = mix_thread.wait_to_finish()
	var captured_value: Variant = capture_thread.wait_to_finish()
	assert_true(mixed_value is PackedVector2Array)
	assert_true(captured_value is Dictionary)
	var captured: Dictionary = captured_value as Dictionary \
		if captured_value is Dictionary else {}
	assert_eq(captured.get("phase"), "queued")
	assert_eq(captured.get("horizon_frame"), 3)
	assert_eq(captured.get("horizon_loop_epoch"), 2)

	playback.mix_audio(high_rate, 1)
	var live_events := _events(playback)
	assert_eq(_event_types(live_events), ["armed", "triggered", "completed"])
	assert_eq(live_events[0].get("marker_frame"), 3)
	assert_eq(live_events[0].get("marker_ordinal"), 1)
	assert_eq(live_events[0].get("marker_loop_epoch"), 2)

	var restore_stream := _new_stream_object()
	var restored := _new_playback_from_configuration(
		restore_stream,
		configuration,
		int(captured.get("horizon_frame", -1)),
		{
			"fade_frames": 0,
			"gains": captured.get("target_gains"),
			"horizon_frame": captured.get("horizon_frame"),
			"horizon_loop_epoch": captured.get("horizon_loop_epoch"),
			"marker": "tick",
			"marker_frame": 3,
			"marker_loop_epoch": 2,
			"marker_ordinal": 1,
			"operation_id": 8592,
			"schema_version": 1,
		},
	)
	if restored == null:
		return
	restored.call("release_startup_gate")
	restored.mix_audio(_one_source_frame_rate_scale(), 1)
	var restored_events := _events(restored)
	assert_eq(_event_types(restored_events), ["armed", "triggered", "completed"])
	for key: String in ["marker_frame", "marker_ordinal", "marker_loop_epoch"]:
		assert_eq(restored_events[0].get(key), live_events[0].get(key),
			"save/restore and the live callback bind the same exact occurrence")


func test_cut_acknowledges_only_after_the_audio_callback_applies_gains() -> void:
	var playback := _new_playback()
	if playback == null:
		return
	assert_eq(_arm(
		playback, "サビ", PackedFloat32Array([0.0, 1.0]), 860), 0)
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(_event_types(_events(playback)), ["armed"])
	assert_eq(int(playback.call(
		"cut_marker_mix", PackedFloat32Array([0.25, 0.75]), 861)), 0)
	assert_eq(playback.call("debug_get_current_gains"),
		PackedFloat32Array([1.0, 0.0]))
	assert_eq(_events(playback), [],
		"enqueue success is not a physical apply acknowledgement")
	playback.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(playback.call("debug_get_current_gains"),
		PackedFloat32Array([0.25, 0.75]))
	var applied := _events(playback)
	assert_eq(_event_types(applied), ["cut_applied"])
	assert_eq(applied[0].get("operation_id"), 861)


func test_configure_rejects_nonadjacent_same_frame_duplicate_and_wrong_types() -> void:
	var duplicate := _base_configuration()
	duplicate["markers"] = [
		{"frame": 16, "name": "A"},
		{"frame": 16, "name": "B"},
		{"frame": 16, "name": "A"},
	]
	assert_eq(_new_stream_object().call("configure", duplicate), false)

	for mutation: Dictionary in [
		{"schema_version": 1.0},
		{"loop_start_frame": 0.0},
		{"loop_end_frame": 1024.0},
		{"markers": [{"frame": 16.0, "name": "A"}]},
		{"loop_end_frame": 9223372036854775807},
		{"markers": [{"frame": 9223372036854775807, "name": "A"}]},
		{"extra": true},
	]:
		var configuration := _base_configuration()
		configuration.merge(mutation, true)
		assert_eq(_new_stream_object().call("configure", configuration), false,
			"strict closed schema rejects %s" % mutation)


func test_32_stems_decode_in_preallocated_chunks_not_per_source_sample() -> void:
	var bytes := FileAccess.get_file_as_bytes(SYNTHETIC_OGG)
	var configuration := _base_configuration(bytes)
	var stem_names := PackedStringArray()
	var stem_bytes: Array = []
	var gains := PackedFloat32Array()
	for index in range(32):
		stem_names.append("stem_%02d" % index)
		stem_bytes.append(bytes)
		gains.append(1.0 if index == 0 else 0.0)
	configuration["stem_names"] = stem_names
	configuration["stem_ogg_bytes"] = stem_bytes
	configuration["initial_gains"] = gains
	var stream_object := _new_stream_object()
	assert_eq(stream_object.call("configure", configuration), true)
	var playback: AudioStreamPlayback = (stream_object as AudioStream).instantiate_playback()
	playback.start()
	assert_eq(playback.mix_audio(_one_source_frame_rate_scale(), 512).size(), 512)
	var metrics: Dictionary = playback.call("debug_get_marker_metrics")
	assert_true(int(metrics.get("rt_decoder_refill_calls", 0)) <= 64,
		"32 stems refill bounded chunks instead of issuing one decoder call per sample")
	assert_eq(metrics.get("rt_allocation_violations"), 0)
	assert_eq(metrics.get("rt_lock_violations"), 0)
	assert_eq(metrics.get("rt_event_overflow_violations"), 0)


func test_invalidation_drops_queued_and_armed_commands_without_stale_events() -> void:
	var queued := _new_playback()
	if queued == null:
		return
	assert_eq(_arm(
		queued, "サビ", PackedFloat32Array([0.0, 1.0]), 801), 0)
	queued.call("invalidate_marker_arms")
	queued.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(_events(queued), [])
	assert_eq(_snapshot(queued).get("phase"), "none")

	var armed := _new_playback()
	assert_eq(_arm(
		armed, "サビ", PackedFloat32Array([0.0, 1.0]), 802), 0)
	armed.mix_audio(_one_source_frame_rate_scale(), 1)
	assert_eq(_event_types(_events(armed)), ["armed"])
	armed.call("invalidate_marker_arms")
	armed.mix_audio(_one_source_frame_rate_scale(), 64)
	assert_eq(_events(armed), [])
	assert_eq(_snapshot(armed).get("phase"), "none")
