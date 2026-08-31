## Audio presenter — manages BGM, SE, Voice, and System SE playback.
class_name AudioPresenter extends Node

const MAX_NATIVE_BGM_FADE_FRAMES := 2147483647

const BGM_NATURAL_LOOP_END := -1.0
const BGM_MAX_SIGNED_MIXER_FRAMES := 2147483647.0

var _se_players: Array = []
var _max_se_channels: int = 4
var _voice_player: AudioStreamPlayer
var _system_se_player: AudioStreamPlayer
var _current_voice_character: String = ""
var _voice_started_advance_serial: int = -1
var _voice_playback_token: int = -1
var _voice_lifecycle_revision: int = 0
var _voice_playback_revision: int = -1
var _voice_dsp_bus_name: StringName = &""
var _voice_dsp_bus_serial: int = 0
var _voice_dsp_tail_timer: Timer
var _voice_dsp_tail_seconds: float = 0.0
var _voice_dsp_active: bool = false
var _voice_request_owned: bool = false
var _voice_group_raw_eligible: bool = false
## Ordered physical members of the one active typed voice group. Dictionary
## keys are canonical layer ids; _voice_layer_order preserves authored order.
var _voice_layers: Dictionary = {}
var _voice_layer_order: Array[String] = []
var _bgm_capability: RefCounted
var _bgm_channel: Dictionary = {}
var _bgm_validation_cache: Dictionary = {}
var _bgm_generation: int = 1
var _next_bgm_token: int = 1
var _next_bgm_restore_operation_id: int = 9000000000000000
## Debug-build-only deterministic interleaving hook. Tests use this to run a
## native callback immediately after AudioStreamPlayer.play(), before voice
## construction can perform any later main-thread work.
var _bgm_after_player_played_debug_hook: Callable
var _loop_se_capability: RefCounted
var _loop_se_channels: Dictionary = {}
var _loop_se_validation_cache: Dictionary = {}
var _loop_se_generation: int = 1
var _next_loop_se_token: int = 1
var _shutdown_quiesced := false
var _presentation_clip_participant_capability: RefCounted
var _presentation_clip_prepared: Dictionary = {}
var _presentation_clip_claimed: Dictionary = {}
var _presentation_clip_audio: Dictionary = {}
var _presentation_clip_transaction: Dictionary = {}


func _ready():
	# Shutdown is terminal for this Runtime. Presenter replacement can occur while
	# the Runtime is waiting for an AudioServer mix rollover. A duplicate can also
	# fail the unique-owner contract during ordinary play. Both remain completely
	# inert: acquire the dual typed capability before players or signal consumers.
	_shutdown_quiesced = SignalBus.runtime_audio_shutdown_has_started()
	if _shutdown_quiesced:
		set_process(false)
		return
	var capabilities := StellaRuntime._register_audio_presenter(self)
	if capabilities.is_empty():
		set_process(false)
		return
	_bgm_capability = capabilities.get("bgm") as RefCounted
	_loop_se_capability = capabilities.get("loop_se") as RefCounted
	if _bgm_capability == null or _loop_se_capability == null:
		set_process(false)
		return
	_presentation_clip_participant_capability = (
		StellaRuntime._register_presentation_clip_audio_participant(self))
	if _presentation_clip_participant_capability == null:
		StellaRuntime._unregister_audio_presenter(
			self, _loop_se_capability, _bgm_capability)
		_bgm_capability = null
		_loop_se_capability = null
		set_process(false)
		return

	# Create SE player pool
	for i in range(_max_se_channels):
		var player = AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_se_players.append(player)

	# Create Voice player
	if not _create_voice_dsp_bus():
		push_error("AudioPresenter: could not acquire the private voice DSP bus")
		StellaRuntime._unregister_audio_presenter(
			self, _loop_se_capability, _bgm_capability)
		_bgm_capability = null
		_loop_se_capability = null
		StellaRuntime._unregister_presentation_clip_composition_participant(
			self,
			_presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
		)
		_presentation_clip_participant_capability = null
		set_process(false)
		return
	_voice_player = AudioStreamPlayer.new()
	_voice_player.bus = _voice_dsp_bus_name
	_voice_player.finished.connect(_on_voice_playback_finished)
	add_child(_voice_player)
	_voice_dsp_tail_timer = Timer.new()
	_voice_dsp_tail_timer.one_shot = true
	_voice_dsp_tail_timer.timeout.connect(_on_voice_dsp_tail_timeout)
	add_child(_voice_dsp_tail_timer)

	# Create System SE player
	_system_se_player = AudioStreamPlayer.new()
	_system_se_player.bus = "Master"
	add_child(_system_se_player)

	# Connect signals
	SignalBus.se_play.connect(_on_se_play)
	SignalBus.voice_playback_requested.connect(_on_voice_playback_requested)
	SignalBus.advance_requested.connect(_on_advance_requested)
	SignalBus.hide_dialogue.connect(_on_voice_lifecycle_boundary)
	SignalBus.engine_abort_requested.connect(_on_voice_lifecycle_boundary)
	SignalBus.settings_changed.connect(_on_settings_changed)
	SignalBus.system_se_play.connect(_on_system_se_play)
	SignalBus.choice_selected.connect(_on_choice_selected)
	SignalBus.loop_se_validate_requested.connect(_on_loop_se_validate_requested)
	SignalBus.loop_se_accept_requested.connect(_on_loop_se_accept_requested)
	SignalBus.loop_se_apply_requested.connect(_on_loop_se_apply_requested)
	SignalBus.loop_se_transition_receipts_finish_requested.connect(
		_on_loop_se_transition_receipts_finish_requested)
	SignalBus.loop_se_projection_reset_requested.connect(
		_on_loop_se_projection_reset_requested)
	SignalBus.loop_se_state_apply_requested.connect(_on_loop_se_state_apply_requested)
	SignalBus.loop_se_targets_state_apply_requested.connect(
		_on_loop_se_targets_state_apply_requested)
	SignalBus.loop_se_state_capture_requested.connect(
		_on_loop_se_state_capture_requested)
	SignalBus.bgm_validate_requested.connect(_on_bgm_validate_requested)
	SignalBus.bgm_accept_requested.connect(_on_bgm_accept_requested)
	SignalBus.bgm_apply_requested.connect(_on_bgm_apply_requested)
	SignalBus.bgm_transition_receipts_finish_requested.connect(
		_on_bgm_transition_receipts_finish_requested)
	SignalBus.bgm_projection_reset_requested.connect(
		_on_bgm_projection_reset_requested)
	SignalBus.bgm_state_apply_requested.connect(_on_bgm_state_apply_requested)
	SignalBus.bgm_title_cut_requested.connect(_on_bgm_title_cut_requested)
	SignalBus.bgm_state_capture_requested.connect(
		_on_bgm_state_capture_requested)
	SignalBus.bgm_state_restore_validate_requested.connect(
		_on_bgm_state_restore_validate_requested)
	SignalBus.runtime_audio_shutdown_requested.connect(
		_on_runtime_audio_shutdown_requested)
	SignalBus.presentation_clip_validate_requested.connect(
		_on_presentation_clip_validate_requested)
	SignalBus.presentation_clip_accept_requested.connect(
		_on_presentation_clip_accept_requested)
	SignalBus.presentation_clip_apply_readiness_requested.connect(
		_on_presentation_clip_apply_readiness_requested)
	SignalBus.presentation_clip_apply_requested.connect(
		_on_presentation_clip_apply_requested)
	SignalBus.presentation_clip_publish_readiness_requested.connect(
		_on_presentation_clip_publish_readiness_requested)
	SignalBus.presentation_clip_audio_cue_requested.connect(
		_on_presentation_clip_audio_cue_requested)
	SignalBus.presentation_clip_retire_requested.connect(
		_on_presentation_clip_retire_requested)
	SignalBus.presentation_clip_projection_reset_requested.connect(
		_on_presentation_clip_projection_reset_requested)
	SignalBus.presentation_clip_request_settled.connect(
		_on_presentation_clip_request_settled)

	_apply_volumes()
	SignalBus.announce_loop_se_presenter_registered(
		self, _loop_se_capability)
	SignalBus.announce_bgm_presenter_registered(self, _bgm_capability)


func _on_runtime_audio_shutdown_requested(request_serial: int) -> void:
	if _bgm_capability == null or _loop_se_capability == null:
		return
	if not _shutdown_quiesced:
		_shutdown_quiesced = true
		_retire_voice_for_shutdown()
		for player_value: Variant in _se_players:
			_retire_fixed_audio_player(player_value as AudioStreamPlayer)
		_retire_fixed_audio_player(_system_se_player)
		_retire_presentation_clip_audio()
		_release_presentation_clip_claimed()
		_release_presentation_clip_prepared()
	# First quiesce always invalidates both typed epochs. A validation/pre-apply
	# request can own a Director/Bus slot before either local player map exists;
	# map emptiness is therefore never sufficient evidence of lifecycle idleness.
	# The Bus admits only this unique dual-capability owner and makes the reset
	# globally once-only across Presenter replacement.
	if not SignalBus.retire_runtime_audio_epochs_for_shutdown(
		self, _bgm_capability):
		return
	if not _runtime_audio_shutdown_presenter_is_idle():
		return
	SignalBus.acknowledge_runtime_audio_shutdown(
		self, _bgm_capability, request_serial)


func _audio_admission_is_closed() -> bool:
	return (
		_shutdown_quiesced
		or SignalBus.runtime_audio_shutdown_has_started()
	)


func _runtime_audio_shutdown_presenter_is_idle() -> bool:
	if (
		not _bgm_channel.is_empty()
		or not _loop_se_channels.is_empty()
		or not _bgm_validation_cache.is_empty()
		or not _loop_se_validation_cache.is_empty()
		or not _presentation_clip_prepared.is_empty()
		or not _presentation_clip_claimed.is_empty()
		or not _presentation_clip_audio.is_empty()
		or _voice_playback_token >= 0
		or not _voice_layers.is_empty()
	):
		return false
	if _voice_dsp_tail_timer != null and not _voice_dsp_tail_timer.is_stopped():
		return false
	for layer_value: Variant in _voice_layers.values():
		if not layer_value is Dictionary:
			return false
		var layer: Dictionary = layer_value
		var layer_player := layer.get("player") as AudioStreamPlayer
		var layer_timer := layer.get("timer") as Timer
		if layer_player != null and (layer_player.playing or layer_player.stream != null):
			return false
		if layer_timer != null and not layer_timer.is_stopped():
			return false
	var voice_dsp_bus_index := AudioServer.get_bus_index(_voice_dsp_bus_name)
	if (
		voice_dsp_bus_index >= 0
		and AudioServer.get_bus_effect_count(voice_dsp_bus_index) != 0
	):
		return false
	for player_value: Variant in _se_players:
		var player := player_value as AudioStreamPlayer
		if player != null and (player.playing or player.stream != null):
			return false
	for player: AudioStreamPlayer in [_voice_player, _system_se_player]:
		if player != null and (player.playing or player.stream != null):
			return false
	return (
		StellaRuntime.presentation_director == null
		or StellaRuntime.presentation_director._entries.is_empty()
	)


func _retire_voice_for_shutdown() -> void:
	_voice_lifecycle_revision += 1
	_retire_active_voice(_voice_lifecycle_revision)


func _retire_fixed_audio_player(player: AudioStreamPlayer) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream_paused = false
	player.stream = null


func _exit_tree() -> void:
	_voice_lifecycle_revision += 1
	_abort_presentation_clip_audio_transaction()
	_retire_presentation_clip_audio()
	_release_presentation_clip_claimed()
	_release_presentation_clip_prepared()
	_retire_voice_group_projection()
	_release_voice_dsp_bus()
	if _bgm_capability != null and _loop_se_capability != null:
		if not _shutdown_quiesced:
			SignalBus.commit_bgm_runtime_state(
				self, _bgm_capability, _capture_bgm_state(),
				SignalBus.current_bgm_epoch())
			SignalBus.reset_bgm_presentation()
			SignalBus.commit_loop_se_positions(
				self, _loop_se_capability, _capture_loop_se_positions())
			# Presenter replacement retires only the old projection generation. The
			# canonical channel state survives and the replacement receives one cut
			# projection after it acquires the Runtime-owned capability.
			SignalBus.reset_loop_se_presentation()
		StellaRuntime._unregister_audio_presenter(
			self, _loop_se_capability, _bgm_capability)
		_bgm_capability = null
		_loop_se_capability = null
	if _presentation_clip_participant_capability != null:
		StellaRuntime._unregister_presentation_clip_composition_participant(
			self,
			_presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
		)
		_presentation_clip_participant_capability = null


func _process(_delta: float) -> void:
	_drain_bgm_marker_events()
	var entry_revision := _voice_playback_revision
	var entry_token := _voice_playback_token
	var entry_order: Array[String] = _voice_layer_order.duplicate()
	for layer_id in entry_order:
		if not _voice_playback_event_is_current(entry_revision, entry_token):
			return
		var layer_value: Variant = _voice_layers.get(layer_id)
		if not layer_value is Dictionary:
			continue
		var layer: Dictionary = layer_value
		var player := layer.get("player") as AudioStreamPlayer
		if player == null or not player.playing or player.stream == null:
			continue
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.progress(
			player.get_playback_position(),
			player.stream.get_length(),
			entry_token,
			_voice_playback_event_is_current.bind(
				entry_revision, entry_token),
			false,
			String(layer_id),
			String(layer.get("character", "")),
			String(layer.get("asset", "")),
			_voice_group_raw_eligible,
		))


# ─── Volume ───

func _apply_volumes(changed_key: String = ""):
	var master := _get_volume_setting("master_volume", 1.0)
	var update_all := changed_key == ""
	if update_all or changed_key in ["master_volume", "bgm_volume"]:
		_apply_bgm_volumes()

	if update_all or changed_key in ["master_volume", "se_volume"]:
		var se_vol := _get_volume_setting("se_volume", 1.0)
		for player in _se_players:
			player.volume_db = _to_db(master * se_vol)
		_apply_loop_se_volumes()

	if update_all or changed_key in [
		"master_volume", "voice_volume",
		"character_voice_volume", "character_voice_enabled",
	]:
		# The player remains unity-gain. The private bus is the single effective
		# voice gain authority so already-buffered DSP tails follow live settings.
		_voice_player.volume_db = 0.0
		if _voice_layers.is_empty():
			_set_voice_dsp_bus_volume(
				_voice_dsp_bus_name,
				_get_voice_target_db_for_character(_current_voice_character),
			)
		else:
			for layer_value: Variant in _voice_layers.values():
				if not layer_value is Dictionary:
					continue
				var layer: Dictionary = layer_value
				var layer_player := layer.get("player") as AudioStreamPlayer
				if layer_player != null:
					layer_player.volume_db = 0.0
				_set_voice_dsp_bus_volume(
					StringName(layer.get("bus_name", &"")),
					_get_voice_target_db_for_character(
						String(layer.get("character", ""))),
				)

	if update_all or changed_key in ["master_volume", "system_se_volume"]:
		var sys_se_vol := _get_volume_setting("system_se_volume", 1.0)
		_system_se_player.volume_db = _to_db(master * sys_se_vol)
	_apply_presentation_clip_audio_volumes()
	if not _presentation_clip_claimed.is_empty():
		_apply_presentation_clip_record_volumes(_presentation_clip_claimed)


func _get_volume_setting(key: String, fallback: float) -> float:
	var value = StellaRuntime.get_setting(key)
	return fallback if value == null else float(value)


func _get_voice_target_db_for_character(character: String) -> float:
	var char_enabled = StellaRuntime.get_setting("character_voice_enabled")
	if char_enabled is Dictionary and not bool(char_enabled.get(character, true)):
		return -80.0

	var final_volume := (
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("voice_volume", 1.0)
	)
	var char_volume = StellaRuntime.get_setting("character_voice_volume")
	if char_volume is Dictionary:
		final_volume *= float(char_volume.get(character, 1.0))
	return _to_db(final_volume)


func _to_db(linear: float) -> float:
	if linear <= 0.0:
		return -80.0
	return linear_to_db(linear)


func _on_settings_changed(key: String, _value: Variant):
	if key in ["master_volume", "bgm_volume", "se_volume", "voice_volume",
			"system_se_volume", "character_voice_volume", "character_voice_enabled"]:
		if key == "character_voice_enabled":
			_retire_untriggered_disabled_presentation_clip_choices(
				_presentation_clip_audio)
			_retire_untriggered_disabled_presentation_clip_choices(
				_presentation_clip_claimed)
		_apply_volumes(key)


# ─── BGM ───

func _on_bgm_validate_requested(request: BgmOperationRequest) -> void:
	if _bgm_capability == null or request == null or not request.is_target(self):
		return
	if _audio_admission_is_closed():
		SignalBus.reject_bgm_request(
			request, self, _bgm_capability, "audio presenter is quiescing")
		return
	var payload := request.get_payload()
	if not BgmChannelState.validate_operation(payload, false):
		SignalBus.reject_bgm_request(
			request, self, _bgm_capability, "invalid canonical operation")
		return
	var request_key := request.get_instance_id()
	var action := String(payload["action"])
	var prepared := {"action": action}
	if action == "play":
		prepared = _resolve_bgm_track(
			String(payload["asset"]),
			String(payload["cue"]),
			payload["stem_mix"] as Dictionary,
		)
		if prepared.is_empty():
			SignalBus.reject_bgm_request(
				request,
				self,
				_bgm_capability,
				"asset '%s' or cue '%s' is missing, ambiguous, or has invalid metadata"
					% [String(payload["asset"]), String(payload["cue"])],
			)
			return
		var current_target: Dictionary = _bgm_channel.get("target_state", {})
		var current_voice: Dictionary = _bgm_channel.get("current", {})
		var would_reuse_live_voice := (
			not current_target.is_empty()
			and String(current_target.get("status", "")) == "playing"
			and String(current_target.get("asset", "")) == String(payload["asset"])
			and String(current_target.get("cue", "")) == String(payload["cue"])
			and _bgm_voice_is_live(
				current_voice, String(payload["asset"]), String(payload["cue"]))
		)
		if would_reuse_live_voice and not _bgm_voice_matches_prepared(
			current_voice, prepared):
			SignalBus.reject_bgm_request(
				request,
				self,
				_bgm_capability,
				"the live BGM resource schema changed and cannot be reused without restarting",
			)
			return
	elif action == "mix":
		var current_state: Dictionary = _bgm_channel.get("target_state", {})
		var marker := String(payload.get("marker", ""))
		prepared = _resolve_bgm_track(
			String(current_state.get("asset", "")),
			String(current_state.get("cue", "")),
			payload["stem_mix"] as Dictionary,
		)
		var current_voice: Dictionary = _bgm_channel.get("current", {})
		if (
			prepared.is_empty()
			or (prepared["stem_mix"] as Dictionary).is_empty()
			or (not marker.is_empty() and not bool(prepared.get("marker_capable", false)))
			or not _bgm_voice_matches_prepared(current_voice, prepared)
		):
			SignalBus.reject_bgm_request(
				request,
				self,
				_bgm_capability,
				"the current BGM is not a compatible multi-stem track or the stem mix is invalid",
			)
			return
		if bool(prepared.get("marker_capable", false)):
			var native_fade_frames := _native_bgm_fade_frames(
				float(payload["fade_duration"]),
				int(prepared.get("sample_rate", 0)),
			)
			if native_fade_frames < 0:
				SignalBus.reject_bgm_request(
					request,
					self,
					_bgm_capability,
					"fade duration exceeds the native marker frame range",
				)
				return
			prepared["native_fade_frames"] = native_fade_frames
		if not marker.is_empty():
			var playback := current_voice.get("marker_playback") as Object
			var gains := _marker_bgm_gains(
				prepared.get("stem_mix", {}) as Dictionary,
				current_voice.get("stem_names", []) as Array,
			)
			if (
				request.get_force_cut()
				and not _prepared_bgm_has_marker(prepared, marker)
			):
				SignalBus.reject_bgm_request(
					request,
					self,
					_bgm_capability,
					"marker '%s' is absent from the current BGM marker table"
						% marker,
				)
				return
			if (
				playback == null
				or not is_instance_valid(playback)
				or not playback.has_method(&"can_arm_marker_mix")
				or gains.is_empty()
				or not bool(playback.call("can_arm_marker_mix", marker, gains))
			):
				SignalBus.reject_bgm_request(
					request,
					self,
					_bgm_capability,
					"native marker command capacity is unavailable",
				)
				return
	_bgm_validation_cache[request_key] = prepared
	request.finished.connect(
		_cleanup_bgm_validation.bind(request_key), CONNECT_ONE_SHOT)
	SignalBus.validate_bgm_request(request, self, _bgm_capability)


func _on_bgm_accept_requested(request: BgmOperationRequest) -> void:
	if (
		_bgm_capability == null
		or request == null
		or not _bgm_validation_cache.has(request.get_instance_id())
	):
		return
	SignalBus.accept_bgm_request(request, self, _bgm_capability)


func _on_bgm_apply_requested(request: BgmOperationRequest) -> void:
	if _bgm_capability == null or request == null:
		return
	var prepared: Dictionary = _bgm_validation_cache.get(
		request.get_instance_id(), {})
	if prepared.is_empty():
		return
	var committed_state := _apply_bgm_operation(
		request.get_payload(),
		prepared,
		request.get_request_id(),
		request.get_force_cut(),
	)
	if committed_state == null:
		return
	SignalBus.acknowledge_bgm_apply(
		request, self, _bgm_capability, committed_state)


func _cleanup_bgm_validation(request_key: int) -> void:
	_bgm_validation_cache.erase(request_key)


func _apply_bgm_operation(
	payload: Dictionary,
	prepared: Dictionary,
	request_id: int,
	force_cut: bool,
) -> Variant:
	var action := String(payload["action"])
	var fade_duration := 0.0 if force_cut else float(payload["fade_duration"])
	match action:
		"play":
			return _play_bgm(payload, prepared, fade_duration, request_id)
		"mix":
			return _mix_bgm(
				payload, prepared, fade_duration, request_id, force_cut)
		"pause":
			return _pause_bgm(fade_duration, request_id)
		"resume":
			return _resume_bgm(fade_duration, request_id)
		"stop":
			return _stop_bgm(fade_duration, request_id)
	return null


func _play_bgm(
	payload: Dictionary,
	prepared: Dictionary,
	fade_duration: float,
	request_id: int,
) -> Variant:
	var asset := String(payload["asset"])
	var cue := String(payload["cue"])
	var volume := float(payload["volume"])
	var stem_mix: Dictionary = prepared.get("stem_mix", {}).duplicate(true)
	var current_state: Dictionary = _bgm_channel.get("target_state", {})
	var current: Dictionary = _bgm_channel.get("current", {})
	var exact_playing_target := (
		not current_state.is_empty()
		and String(current_state.get("status", "")) == "playing"
		and String(current_state.get("asset", "")) == asset
		and String(current_state.get("cue", "")) == cue
	)
	if exact_playing_target:
		# A canonical playing target may still be owned by either a play fade or
		# a resume fade. Stabilize that exact owner before applying the aligned
		# play so two Tweens can never compete for the same physical voice.
		_complete_active_bgm_receipt()
		current = _bgm_channel.get("current", {})
		if _bgm_voice_is_live(current, asset, cue):
			var state := current_state.duplicate(true)
			state["position"] = _capture_bgm_position()
			state["stem_mix"] = stem_mix.duplicate(true)
			state["volume"] = volume
			_bgm_channel["target_state"] = state.duplicate(true)
			var current_mix: Dictionary = current.get("stem_mix", {})
			var mix_aligned := BgmChannelState.stem_mix_equal(
				current_mix, stem_mix)
			var level_aligned := is_equal_approx(
				float(current.get("level", -1.0)), volume)
			if mix_aligned and level_aligned:
				return state
			if bool(current.get("marker_capable", false)) and not mix_aligned:
				var native_state := _start_native_bgm_immediate_mix(
					current_state, current, stem_mix, fade_duration, request_id)
				if native_state == null:
					return null
				native_state["volume"] = volume
				_bgm_channel["target_state"] = native_state.duplicate(true)
				if level_aligned:
					return native_state
				if fade_duration <= 0.0:
					_set_bgm_voice_level(volume, current)
					return native_state
				var marker_operations: Dictionary = _bgm_channel.get(
					"marker_operations", {})
				var native_record: Dictionary = marker_operations.get(request_id, {})
				if native_record.is_empty():
					return null
				native_record["wait_for_volume"] = true
				native_record["volume_completed"] = false
				marker_operations[request_id] = native_record
				_bgm_channel["marker_operations"] = marker_operations
				var level_tween := create_tween()
				_bgm_channel["tween"] = level_tween
				level_tween.tween_method(
					_set_bgm_voice_level.bind(current),
					float(current.get("level", 0.0)), volume, fade_duration)
				level_tween.finished.connect(
					_complete_native_bgm_volume_part.bind(request_id), CONNECT_ONE_SHOT)
				return native_state
			if fade_duration <= 0.0:
				_set_bgm_voice_level(volume, current)
				_set_bgm_stem_mix(stem_mix, current)
				return state
			var receipt := _start_bgm_receipt(request_id, &"play")
			var tween := create_tween().set_parallel(true)
			_bgm_channel["tween"] = tween
			if not level_aligned:
				tween.tween_method(
					_set_bgm_voice_level.bind(current),
					float(current.get("level", 0.0)), volume, fade_duration)
			if not mix_aligned:
				tween.tween_method(
					_set_bgm_stem_mix_progress.bind(
						current_mix.duplicate(true), stem_mix.duplicate(true), current),
					0.0, 1.0, fade_duration)
			tween.chain().tween_callback(_complete_bgm_receipt.bind(receipt))
			return state

	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	var old_current: Dictionary = _bgm_channel.get("current", {})
	var stream: AudioStream = prepared.get("stream")
	var start_position := float(prepared.get("start_position", 0.0))
	var new_voice := _create_bgm_voice(
		stream, asset, cue, bool(prepared["loop"]), start_position,
		float(prepared["loop_position"]), float(prepared["loop_end_position"]),
		0.0 if fade_duration > 0.0 else volume,
		stem_mix,
		prepared.get("stem_names", []) as Array,
		prepared.get("resource_signature", {}) as Dictionary,
		prepared,
	)
	if new_voice.is_empty():
		return null
	var state := {
		"asset": asset,
		"cue": cue,
		"loop": bool(prepared["loop"]),
		"pending_marker_mix": {},
		"position": start_position,
		"status": "playing",
		"stem_mix": stem_mix.duplicate(true),
		"volume": volume,
	}
	_bgm_channel["current"] = new_voice
	_bgm_channel["outgoing"] = old_current
	_bgm_channel["target_state"] = state.duplicate(true)
	if fade_duration <= 0.0:
		_stop_bgm_voice(old_current)
		_bgm_channel["outgoing"] = {}
		_set_bgm_voice_level(volume, new_voice)
		return state
	var receipt := _start_bgm_receipt(request_id, &"play")
	var tween := create_tween().set_parallel(true)
	_bgm_channel["tween"] = tween
	tween.tween_method(
		_set_bgm_voice_level.bind(new_voice), 0.0, volume, fade_duration)
	if not old_current.is_empty():
		tween.tween_method(
			_set_bgm_voice_level.bind(old_current),
			float(old_current.get("level", 0.0)), 0.0, fade_duration)
	tween.chain().tween_callback(_complete_bgm_receipt.bind(receipt))
	return state


func _mix_bgm(
	payload: Dictionary,
	prepared: Dictionary,
	fade_duration: float,
	request_id: int,
	force_cut: bool,
) -> Variant:
	var state: Dictionary = _bgm_channel.get("target_state", {})
	var current: Dictionary = _bgm_channel.get("current", {})
	if state.is_empty() or current.is_empty():
		return null
	var stem_mix: Dictionary = prepared.get("stem_mix", {}).duplicate(true)
	if stem_mix.is_empty():
		return null
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if (
		not receipt.is_empty()
		and StringName(receipt.get("action", &"")) != &"mix"
		and StringName(receipt.get("action", &"")) != &"marker_mix"
	):
		_complete_active_bgm_receipt()
		state = _bgm_channel.get("target_state", {})
		current = _bgm_channel.get("current", {})
		if state.is_empty() or current.is_empty():
			return null
	var marker := String(payload.get("marker", ""))
	if not marker.is_empty():
		if force_cut:
			return _start_native_bgm_immediate_mix(
				state, current, stem_mix, 0.0, request_id)
		return _arm_marker_bgm_mix(
			state, current, marker, stem_mix, fade_duration, request_id)
	if bool(current.get("marker_capable", false)):
		return _start_native_bgm_immediate_mix(
			state, current, stem_mix, fade_duration, request_id)
	var current_target_mix: Dictionary = state.get("stem_mix", {})
	if BgmChannelState.stem_mix_equal(current_target_mix, stem_mix):
		_complete_matching_bgm_receipt(&"mix")
		return state.duplicate(true)
	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	current = _bgm_channel.get("current", {})
	if current.is_empty():
		return null
	var from_mix: Dictionary = current.get("stem_mix", {}).duplicate(true)
	state = state.duplicate(true)
	state["position"] = _capture_bgm_position()
	state["stem_mix"] = stem_mix.duplicate(true)
	_bgm_channel["target_state"] = state.duplicate(true)
	if fade_duration <= 0.0:
		_set_bgm_stem_mix(stem_mix, current)
		return state
	var mix_receipt := _start_bgm_receipt(request_id, &"mix")
	var tween := create_tween()
	_bgm_channel["tween"] = tween
	tween.tween_method(
		_set_bgm_stem_mix_progress.bind(
			from_mix, stem_mix.duplicate(true), current),
		0.0, 1.0, fade_duration)
	tween.finished.connect(
		_complete_bgm_receipt.bind(mix_receipt), CONNECT_ONE_SHOT)
	return state


func _arm_marker_bgm_mix(
	state: Dictionary,
	current: Dictionary,
	marker: String,
	stem_mix: Dictionary,
	fade_duration: float,
	request_id: int,
) -> Variant:
	if not bool(current.get("marker_capable", false)):
		return null
	var fade_frames := _native_bgm_fade_frames(
		fade_duration, int(current.get("sample_rate", 0)))
	if fade_frames < 0:
		return null
	var playback := current.get("marker_playback") as Object
	if playback == null or not is_instance_valid(playback):
		return null
	var pending := BgmPendingMarkerMixState.from_snapshot(
		state.get("pending_marker_mix", {}))
	if pending != null and pending.target_equals(marker, stem_mix, fade_duration):
		var marker_operations: Dictionary = _bgm_channel.get(
			"marker_operations", {})
		for operation_id_value: Variant in marker_operations.keys():
			var record: Dictionary = marker_operations[operation_id_value]
			var record_pending := record.get("pending") as BgmPendingMarkerMixState
			if (
				record_pending == null
				or not record_pending.target_equals(marker, stem_mix, fade_duration)
			):
				continue
			var old_receipt: Dictionary = record.get("receipt", {})
			if not old_receipt.is_empty():
				_emit_bgm_terminal(old_receipt, &"superseded")
			var replacement_receipt := _start_bgm_receipt(
				request_id, &"marker_mix")
			record["receipt"] = replacement_receipt
			marker_operations[operation_id_value] = record
			_bgm_channel["marker_operations"] = marker_operations
			return state.duplicate(true)
		return null
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	for record_value: Variant in marker_operations.values():
		if record_value is Dictionary and int(
			(record_value as Dictionary).get("arm_id", 0)) == 0:
			return null
	var gains := _marker_bgm_gains(stem_mix, current.get("stem_names", []) as Array)
	if gains.is_empty():
		return null
	var admission := int(playback.call(
		"arm_marker_mix", marker, gains, fade_frames, request_id))
	if admission != 0:
		return null
	var enqueue_snapshot_value: Variant = playback.call("capture_marker_state")
	if not enqueue_snapshot_value is Dictionary:
		playback.call("invalidate_marker_arms")
		return null
	var enqueue_snapshot: Dictionary = enqueue_snapshot_value
	var horizon_frame := int(enqueue_snapshot.get("horizon_frame", -1))
	var horizon_loop_epoch := int(
		enqueue_snapshot.get("horizon_loop_epoch", -1))
	var queued := BgmPendingMarkerMixState.queued(
		marker,
		stem_mix,
		fade_duration,
		String(current.get("marker_table_fingerprint", "")),
		String(current.get("track_fingerprint", "")),
		horizon_frame,
		horizon_loop_epoch,
	)
	if queued == null:
		playback.call("invalidate_marker_arms")
		return null
	var before_state := BgmChannelState.normalize_snapshot_state(state)
	var receipt := _start_bgm_receipt(request_id, &"marker_mix")
	marker_operations[request_id] = {
		"arm_id": 0,
		"before_state": before_state.duplicate(true),
		"generation": _bgm_generation,
		"pending": queued,
		"receipt": receipt,
	}
	_bgm_channel["marker_operations"] = marker_operations
	var queued_state := before_state.duplicate(true)
	queued_state["position"] = (
		float(horizon_frame) / float(current.get("sample_rate", 1)))
	queued_state["pending_marker_mix"] = queued.to_snapshot()
	_bgm_channel["target_state"] = queued_state.duplicate(true)
	return queued_state


func _marker_bgm_gains(stem_mix: Dictionary, stem_names: Array) -> PackedFloat32Array:
	if stem_names.size() != stem_mix.size():
		return PackedFloat32Array()
	var gains := PackedFloat32Array()
	gains.resize(stem_names.size())
	for index in range(stem_names.size()):
		var stem_name := String(stem_names[index])
		if not stem_mix.has(stem_name):
			return PackedFloat32Array()
		gains[index] = float(stem_mix[stem_name])
	return gains


func _prepared_bgm_has_marker(prepared: Dictionary, marker: String) -> bool:
	for occurrence_value: Variant in prepared.get("marker_occurrences", []):
		if (
			occurrence_value is Dictionary
			and String((occurrence_value as Dictionary).get("name", "")) == marker
		):
			return true
	return false


func _native_bgm_fade_frames(fade_duration: float, sample_rate: int) -> int:
	if not is_finite(fade_duration) or fade_duration < 0.0 or sample_rate <= 0:
		return -1
	var scaled_frames := fade_duration * float(sample_rate)
	if (
		not is_finite(scaled_frames)
		or scaled_frames < 0.0
		or scaled_frames > float(MAX_NATIVE_BGM_FADE_FRAMES)
	):
		return -1
	return roundi(scaled_frames)


func _start_native_bgm_immediate_mix(
	state: Dictionary,
	current: Dictionary,
	stem_mix: Dictionary,
	fade_duration: float,
	request_id: int,
) -> Variant:
	var playback := current.get("marker_playback") as Object
	if playback == null or not is_instance_valid(playback):
		return null
	var fade_frames := _native_bgm_fade_frames(
		fade_duration, int(current.get("sample_rate", 0)))
	if fade_frames < 0:
		return null
	var normalized_state := BgmChannelState.normalize_snapshot_state(state)
	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	current = _bgm_channel.get("current", {})
	playback = current.get("marker_playback") as Object
	if playback == null or not is_instance_valid(playback):
		return null
	var gains := _marker_bgm_gains(
		stem_mix, current.get("stem_names", []) as Array)
	if gains.is_empty():
		return null
	if int(playback.call(
		"start_immediate_mix", gains, fade_frames, request_id)) != 0:
		return null
	var receipt := _start_bgm_receipt(request_id, &"native_mix")
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	marker_operations[request_id] = {
		"arm_id": 0,
		"before_state": normalized_state.duplicate(true),
		"generation": _bgm_generation,
		"immediate": true,
		"receipt": receipt,
		"target_mix": stem_mix.duplicate(true),
	}
	_bgm_channel["marker_operations"] = marker_operations
	var target_state := normalized_state.duplicate(true)
	target_state["position"] = _capture_bgm_position()
	target_state["pending_marker_mix"] = {}
	target_state["stem_mix"] = stem_mix.duplicate(true)
	_bgm_channel["target_state"] = target_state.duplicate(true)
	return target_state


func _drain_bgm_marker_events() -> void:
	if _bgm_capability == null or _bgm_channel.is_empty():
		return
	var current: Dictionary = _bgm_channel.get("current", {})
	var playback := current.get("marker_playback") as Object
	if playback == null or not is_instance_valid(playback):
		return
	var events_value: Variant = playback.call("drain_marker_events")
	if not events_value is Array:
		return
	for event_value: Variant in events_value:
		if not event_value is Dictionary:
			continue
		_handle_bgm_marker_event(event_value as Dictionary, current)


func _handle_bgm_marker_event(event: Dictionary, current: Dictionary) -> void:
	var operation_id := int(event.get("operation_id", 0))
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	if not marker_operations.has(operation_id):
		return
	var record: Dictionary = marker_operations[operation_id]
	if (
		int(record.get("generation", -1)) != _bgm_generation
		or not SignalBus.is_current_bgm_operation_valid()
	):
		return
	var event_type := String(event.get("type", ""))
	if event_type == "cut_applied":
		_finish_native_bgm_cut_applied(operation_id, record, current)
		return
	# Once a physical cut barrier is admitted, older ARMED/TRIGGERED/COMPLETED
	# events for the same operation cannot settle or rewrite its target. The
	# callback's CUT_APPLIED event is the sole linearization acknowledgement.
	if bool(record.get("cut_pending", false)):
		return
	if event_type in ["failed_no_marker", "failed_conflict"]:
		var failed_receipt: Dictionary = record.get("receipt", {})
		marker_operations.erase(operation_id)
		_bgm_channel["marker_operations"] = marker_operations
		_emit_bgm_terminal(failed_receipt, &"failed")
		var before_state: Dictionary = record.get("before_state", {})
		before_state = BgmChannelState.with_position(
			before_state, _capture_bgm_position())
		_bgm_channel["target_state"] = before_state.duplicate(true)
		_restore_current_bgm_receipt_from_marker_records(marker_operations)
		_publish_bgm_runtime_state(before_state)
		return
	if bool(record.get("immediate", false)):
		if event_type == "triggered":
			var target_mix: Dictionary = record.get("target_mix", {})
			current["stem_mix"] = target_mix.duplicate(true)
			_publish_bgm_runtime_state(
				_bgm_channel.get("target_state", {}) as Dictionary)
			return
		if event_type == "completed":
			record["native_completed"] = true
			if (
				bool(record.get("wait_for_volume", false))
				and not bool(record.get("volume_completed", false))
			):
				marker_operations[operation_id] = record
				_bgm_channel["marker_operations"] = marker_operations
				return
			var immediate_receipt: Dictionary = record.get("receipt", {})
			marker_operations.erase(operation_id)
			_bgm_channel["marker_operations"] = marker_operations
			_emit_bgm_terminal(immediate_receipt, &"completed")
			_restore_current_bgm_receipt_from_marker_records(marker_operations)
			return
	var pending := record.get("pending") as BgmPendingMarkerMixState
	if pending == null:
		return
	if event_type in ["armed", "armed_replaced"]:
		if event_type == "armed_replaced":
			var replaced_arm_id := int(event.get("replaced_arm_id", 0))
			for old_operation_value: Variant in marker_operations.keys():
				var old_operation_id := int(old_operation_value)
				if old_operation_id == operation_id:
					continue
				var old_record: Dictionary = marker_operations[old_operation_value]
				if int(old_record.get("arm_id", 0)) != replaced_arm_id:
					continue
				_emit_bgm_terminal(
					old_record.get("receipt", {}) as Dictionary, &"superseded")
				marker_operations.erase(old_operation_value)
				break
		var armed := pending.armed(
			int(event.get("marker_frame", -1)),
			int(event.get("marker_ordinal", -1)),
			int(event.get("marker_loop_epoch", -1)),
			int(event.get("horizon_frame", -1)),
			int(event.get("horizon_loop_epoch", -1)),
		)
		if armed == null:
			return
		var restore_expected := record.get(
			"restore_expected") as BgmPendingMarkerMixState
		if (
			restore_expected != null
			and restore_expected.phase == BgmPendingMarkerMixState.Phase.ARMED
			and (
				restore_expected.marker_frame != armed.marker_frame
				or restore_expected.marker_ordinal != armed.marker_ordinal
				or restore_expected.marker_loop_epoch != armed.marker_loop_epoch
			)
		):
			var playback := current.get("marker_playback") as Object
			if playback != null and is_instance_valid(playback):
				playback.call("invalidate_marker_arms")
			marker_operations.erase(operation_id)
			_bgm_channel["marker_operations"] = marker_operations
			var failed_restore_state: Dictionary = record.get("before_state", {})
			_bgm_channel["target_state"] = failed_restore_state.duplicate(true)
			_publish_bgm_runtime_state(failed_restore_state)
			push_error("AudioPresenter: saved marker occurrence is no longer reachable")
			return
		record["arm_id"] = int(event.get("arm_id", 0))
		record["pending"] = armed
		marker_operations[operation_id] = record
		_bgm_channel["marker_operations"] = marker_operations
		var armed_state := BgmChannelState.normalize_snapshot_state(
			_bgm_channel.get("target_state", {}))
		if armed_state.is_empty():
			return
		armed_state["pending_marker_mix"] = armed.to_snapshot()
		_bgm_channel["target_state"] = armed_state.duplicate(true)
		_publish_bgm_runtime_state(armed_state)
		return
	if event_type == "triggered":
		var triggered_state := BgmChannelState.normalize_snapshot_state(
			_bgm_channel.get("target_state", {}))
		if triggered_state.is_empty():
			return
		triggered_state["stem_mix"] = pending.stem_mix.duplicate(true)
		triggered_state["pending_marker_mix"] = {}
		_bgm_channel["target_state"] = triggered_state.duplicate(true)
		current["stem_mix"] = pending.stem_mix.duplicate(true)
		record["triggered"] = true
		marker_operations[operation_id] = record
		_bgm_channel["marker_operations"] = marker_operations
		_publish_bgm_runtime_state(triggered_state)
		return
	if event_type == "completed":
		var completed_receipt: Dictionary = record.get("receipt", {})
		marker_operations.erase(operation_id)
		_bgm_channel["marker_operations"] = marker_operations
		_emit_bgm_terminal(completed_receipt, &"completed")
		_restore_current_bgm_receipt_from_marker_records(marker_operations)


func _finish_native_bgm_cut_applied(
	operation_id: int,
	record: Dictionary,
	current: Dictionary,
) -> void:
	if not bool(record.get("cut_pending", false)):
		return
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	marker_operations.erase(operation_id)
	_bgm_channel["marker_operations"] = marker_operations
	var target_mix: Dictionary = record.get("target_mix", {})
	var state := BgmChannelState.normalize_snapshot_state(
		_bgm_channel.get("target_state", {}))
	if state.is_empty() or not BgmChannelState.validate_stem_mix(
		target_mix, false, true):
		_emit_bgm_terminal(record.get("receipt", {}) as Dictionary, &"failed")
		_restore_current_bgm_receipt_from_marker_records(marker_operations)
		return
	state["stem_mix"] = target_mix.duplicate(true)
	state["pending_marker_mix"] = {}
	current["stem_mix"] = target_mix.duplicate(true)
	_set_bgm_voice_level(float(state.get("volume", 1.0)), current)
	_bgm_channel["target_state"] = state.duplicate(true)
	_publish_bgm_runtime_state(state)
	_emit_bgm_terminal(record.get("receipt", {}) as Dictionary, &"completed")
	_restore_current_bgm_receipt_from_marker_records(marker_operations)


func _restore_current_bgm_receipt_from_marker_records(records: Dictionary) -> void:
	if not (_bgm_channel.get("receipt", {}) as Dictionary).is_empty():
		return
	for record_value: Variant in records.values():
		if record_value is Dictionary:
			_bgm_channel["receipt"] = (record_value as Dictionary).get("receipt", {})


func _complete_native_bgm_volume_part(operation_id: int) -> void:
	_bgm_channel["tween"] = null
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	var record: Dictionary = marker_operations.get(operation_id, {})
	if record.is_empty() or not bool(record.get("immediate", false)):
		return
	record["volume_completed"] = true
	if not bool(record.get("native_completed", false)):
		marker_operations[operation_id] = record
		_bgm_channel["marker_operations"] = marker_operations
		return
	var receipt: Dictionary = record.get("receipt", {})
	marker_operations.erase(operation_id)
	_bgm_channel["marker_operations"] = marker_operations
	_emit_bgm_terminal(receipt, &"completed")
	_restore_current_bgm_receipt_from_marker_records(marker_operations)


func _publish_bgm_runtime_state(state: Dictionary) -> void:
	if BgmChannelState.validate_snapshot_state(state, false):
		SignalBus.commit_bgm_runtime_state(
			self, _bgm_capability, state, SignalBus.current_bgm_epoch())


func _pause_bgm(fade_duration: float, request_id: int) -> Variant:
	var state: Dictionary = _bgm_channel.get("target_state", {})
	if state.is_empty():
		return null
	if String(state.get("status", "")) == "paused":
		_complete_matching_bgm_receipt(&"pause")
		return state.duplicate(true)
	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	var current: Dictionary = _bgm_channel.get("current", {})
	if current.is_empty():
		return null
	state = state.duplicate(true)
	state["position"] = _capture_bgm_position()
	state["status"] = "paused"
	_bgm_channel["target_state"] = state.duplicate(true)
	if fade_duration <= 0.0:
		_set_bgm_voice_level(0.0, current)
		(current.get("player") as AudioStreamPlayer).stream_paused = true
		return state
	var receipt := _start_bgm_receipt(request_id, &"pause")
	var tween := create_tween()
	_bgm_channel["tween"] = tween
	tween.tween_method(
		_set_bgm_voice_level.bind(current),
		float(current.get("level", 0.0)), 0.0, fade_duration)
	tween.finished.connect(
		_complete_bgm_receipt.bind(receipt), CONNECT_ONE_SHOT)
	return state


func _resume_bgm(fade_duration: float, request_id: int) -> Variant:
	var state: Dictionary = _bgm_channel.get("target_state", {})
	if state.is_empty():
		return null
	if String(state.get("status", "")) == "playing":
		_complete_matching_bgm_receipt(&"resume")
		return state.duplicate(true)
	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	var current: Dictionary = _bgm_channel.get("current", {})
	var player: AudioStreamPlayer = current.get("player")
	if player == null or not is_instance_valid(player):
		return null
	player.stream_paused = false
	state = state.duplicate(true)
	state["position"] = _capture_bgm_position()
	state["status"] = "playing"
	_bgm_channel["target_state"] = state.duplicate(true)
	var volume := float(state["volume"])
	if fade_duration <= 0.0:
		_set_bgm_voice_level(volume, current)
		return state
	_set_bgm_voice_level(0.0, current)
	var receipt := _start_bgm_receipt(request_id, &"resume")
	var tween := create_tween()
	_bgm_channel["tween"] = tween
	tween.tween_method(
		_set_bgm_voice_level.bind(current), 0.0, volume, fade_duration)
	tween.finished.connect(
		_complete_bgm_receipt.bind(receipt), CONNECT_ONE_SHOT)
	return state


func _stop_bgm(fade_duration: float, request_id: int) -> Variant:
	if _bgm_channel.is_empty():
		return {}
	if (_bgm_channel.get("target_state", {}) as Dictionary).is_empty():
		_complete_matching_bgm_receipt(&"stop")
		return {}
	_retire_bgm_transition(&"superseded")
	if not SignalBus.is_current_bgm_operation_valid():
		return null
	var current: Dictionary = _bgm_channel.get("current", {})
	_bgm_channel["target_state"] = {}
	if current.is_empty() or fade_duration <= 0.0:
		_stop_bgm_voice(current)
		_bgm_channel.clear()
		return {}
	var receipt := _start_bgm_receipt(request_id, &"stop")
	var tween := create_tween()
	_bgm_channel["tween"] = tween
	tween.tween_method(
		_set_bgm_voice_level.bind(current),
		float(current.get("level", 0.0)), 0.0, fade_duration)
	tween.finished.connect(
		_complete_bgm_receipt.bind(receipt), CONNECT_ONE_SHOT)
	return {}


func _new_bgm_channel() -> Dictionary:
	return {
		"current": {}, "outgoing": {}, "receipt": {},
		"receipts": {}, "marker_operations": {},
		"target_state": {}, "tween": null,
	}


func _start_bgm_receipt(request_id: int, action: StringName) -> Dictionary:
	var receipt := {
		"action": action,
		"generation": _bgm_generation,
		"operation_request_id": request_id,
		"token": _next_bgm_token,
	}
	_next_bgm_token += 1
	_bgm_channel["receipt"] = receipt
	var receipts: Dictionary = _bgm_channel.get("receipts", {})
	receipts[int(receipt["token"])] = receipt
	_bgm_channel["receipts"] = receipts
	SignalBus.bgm_transition_receipt_started.emit(
		get_instance_id(), int(receipt["token"]), request_id,
		int(receipt["generation"]))
	return receipt


## An aligned operation is a positive handoff, not a guessed no-op. Finish the
## exact older receipt for the same authored target first so its FNF owner drains
## once; the newly applying operation can then acknowledge synchronously without
## allocating a second Tween or inheriting a stale completion token.
func _complete_matching_bgm_receipt(action: StringName) -> void:
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if StringName(receipt.get("action", &"")) == action:
		_complete_bgm_receipt(receipt)


func _complete_active_bgm_receipt() -> void:
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if not receipt.is_empty():
		_complete_bgm_receipt(receipt)


func _complete_bgm_receipt(receipt: Dictionary) -> void:
	if not _bgm_receipt_is_current(receipt):
		return
	var tween: Tween = _bgm_channel.get("tween")
	_bgm_channel["tween"] = null
	if tween != null and tween.is_valid():
		tween.kill()
	var action := StringName(receipt.get("action", &""))
	if action == &"marker_mix":
		_finish_bgm_marker_mix_receipts(receipt)
		return
	if action == &"native_mix":
		_finish_native_bgm_immediate_mix(receipt)
		return
	var current: Dictionary = _bgm_channel.get("current", {})
	match action:
		&"stop":
			_stop_bgm_voice(current)
			_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
			_bgm_channel["current"] = {}
			_bgm_channel["outgoing"] = {}
		&"pause":
			_set_bgm_voice_level(0.0, current)
			var player: AudioStreamPlayer = current.get("player")
			if player != null and is_instance_valid(player):
				player.stream_paused = true
		_:
			var target: Dictionary = _bgm_channel.get("target_state", {})
			if not target.is_empty():
				_set_bgm_voice_level(float(target.get("volume", 1.0)), current)
				_set_bgm_stem_mix(
					target.get("stem_mix", {}) as Dictionary, current)
			_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
			_bgm_channel["outgoing"] = {}
	_emit_bgm_terminal(receipt, &"completed")
	if action == &"stop":
		_bgm_channel.clear()


func _finish_bgm_marker_mix_receipts(requested_receipt: Dictionary) -> void:
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	var selected_record: Dictionary = {}
	var selected_operation_id := 0
	var current_receipt: Dictionary = _bgm_channel.get("receipt", {})
	for operation_id_value: Variant in marker_operations.keys():
		var candidate: Dictionary = marker_operations[operation_id_value]
		if candidate.get("receipt", {}) == current_receipt:
			selected_record = candidate
			selected_operation_id = int(operation_id_value)
			break
	if selected_record.is_empty():
		for operation_id_value: Variant in marker_operations.keys():
			var candidate: Dictionary = marker_operations[operation_id_value]
			if candidate.get("receipt", {}) == requested_receipt:
				selected_record = candidate
				selected_operation_id = int(operation_id_value)
				break
	if selected_record.is_empty():
		_emit_bgm_terminal(requested_receipt, &"failed")
		return
	var pending := selected_record.get("pending") as BgmPendingMarkerMixState
	var current: Dictionary = _bgm_channel.get("current", {})
	var playback := current.get("marker_playback") as Object
	var gains := _marker_bgm_gains(
		pending.stem_mix if pending != null else {},
		current.get("stem_names", []) as Array,
	)
	var cut_accepted := (
		pending != null
		and playback != null
		and is_instance_valid(playback)
		and not gains.is_empty()
		and int(playback.call(
			"cut_marker_mix", gains, selected_operation_id)) == 0
	)
	if not cut_accepted and playback != null and is_instance_valid(playback):
		playback.call("invalidate_marker_arms")
	var all_operation_ids: Array = marker_operations.keys().duplicate()
	for operation_id_value: Variant in all_operation_ids:
		var record_value: Variant = marker_operations[operation_id_value]
		if not record_value is Dictionary:
			marker_operations.erase(operation_id_value)
			continue
		var record_receipt: Dictionary = (record_value as Dictionary).get("receipt", {})
		if record_receipt.is_empty():
			marker_operations.erase(operation_id_value)
			continue
		if int(operation_id_value) == selected_operation_id:
			continue
		marker_operations.erase(operation_id_value)
		_emit_bgm_terminal(record_receipt, &"superseded")
	var target := BgmChannelState.normalize_snapshot_state(
		_bgm_channel.get("target_state", {}))
	if cut_accepted:
		selected_record["cut_pending"] = true
		selected_record["target_mix"] = pending.stem_mix.duplicate(true)
		marker_operations[selected_operation_id] = selected_record
		_bgm_channel["marker_operations"] = marker_operations
		_bgm_channel["receipt"] = selected_record.get("receipt", {})
		return
	else:
		marker_operations.erase(selected_operation_id)
		_bgm_channel["marker_operations"] = marker_operations
		_emit_bgm_terminal(
			selected_record.get("receipt", {}) as Dictionary, &"failed")
		target = BgmChannelState.normalize_snapshot_state(
			selected_record.get("before_state", {}))
		if not target.is_empty():
			target["pending_marker_mix"] = {}
			_bgm_channel["target_state"] = target.duplicate(true)
			_publish_bgm_runtime_state(target)
		_restore_current_bgm_receipt_from_marker_records(marker_operations)


func _finish_native_bgm_immediate_mix(receipt: Dictionary) -> void:
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	var operation_key: Variant = null
	var record: Dictionary = {}
	for key: Variant in marker_operations.keys():
		var candidate: Dictionary = marker_operations[key]
		if candidate.get("receipt", {}) == receipt:
			operation_key = key
			record = candidate
			break
	if record.is_empty():
		_emit_bgm_terminal(receipt, &"failed")
		return
	var current: Dictionary = _bgm_channel.get("current", {})
	var playback := current.get("marker_playback") as Object
	var target_mix: Dictionary = record.get("target_mix", {})
	var gains := _marker_bgm_gains(
		target_mix, current.get("stem_names", []) as Array)
	var accepted := (
		playback != null
		and is_instance_valid(playback)
		and not gains.is_empty()
		and int(playback.call("cut_marker_mix", gains, int(operation_key))) == 0
	)
	if not accepted and playback != null and is_instance_valid(playback):
		playback.call("invalidate_marker_arms")
	if accepted:
		record["cut_pending"] = true
		record["target_mix"] = target_mix.duplicate(true)
		marker_operations[operation_key] = record
		_bgm_channel["marker_operations"] = marker_operations
		return
	marker_operations.erase(operation_key)
	_bgm_channel["marker_operations"] = marker_operations
	_emit_bgm_terminal(receipt, &"failed")
	var state := BgmChannelState.normalize_snapshot_state(
		record.get("before_state", {}))
	if not state.is_empty():
		state["pending_marker_mix"] = {}
		_bgm_channel["target_state"] = state.duplicate(true)
		_publish_bgm_runtime_state(state)
	_restore_current_bgm_receipt_from_marker_records(marker_operations)


func _retire_bgm_transition(outcome: StringName) -> void:
	if _bgm_channel.is_empty():
		_bgm_channel = _new_bgm_channel()
		return
	var tween: Tween = _bgm_channel.get("tween")
	_bgm_channel["tween"] = null
	if tween != null and tween.is_valid():
		tween.kill()
	_invalidate_bgm_marker_arms(_bgm_channel.get("current", {}))
	_bgm_channel["marker_operations"] = {}
	var target: Dictionary = _bgm_channel.get("target_state", {})
	if not target.is_empty():
		target = BgmChannelState.normalize_snapshot_state(target)
		target["pending_marker_mix"] = {}
		_bgm_channel["target_state"] = target
	_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
	_bgm_channel["outgoing"] = {}
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if not receipt.is_empty():
		_emit_bgm_terminal(receipt, outcome)
	var remaining_receipts: Array = (
		_bgm_channel.get("receipts", {}) as Dictionary).values().duplicate()
	for remaining_value: Variant in remaining_receipts:
		if remaining_value is Dictionary:
			_emit_bgm_terminal(remaining_value as Dictionary, outcome)


func _emit_bgm_terminal(receipt: Dictionary, outcome: StringName) -> void:
	var receipts: Dictionary = _bgm_channel.get("receipts", {})
	var token := int(receipt.get("token", 0))
	if not receipts.has(token) or receipts[token] != receipt:
		return
	receipts.erase(token)
	_bgm_channel["receipts"] = receipts
	if _bgm_channel.get("receipt", {}) == receipt:
		_bgm_channel["receipt"] = {}
	SignalBus.bgm_transition_terminal.emit(
		get_instance_id(), int(receipt.get("token", 0)),
		int(receipt.get("operation_request_id", 0)),
		int(receipt.get("generation", 0)), outcome)


func _bgm_receipt_is_current(receipt: Dictionary) -> bool:
	return (
		not _bgm_channel.is_empty()
		and not receipt.is_empty()
		and _bgm_channel.get("receipt", {}) == receipt
		and (_bgm_channel.get("receipts", {}) as Dictionary).has(
			int(receipt.get("token", 0)))
		and int(receipt.get("generation", -1)) == _bgm_generation
	)


func _on_bgm_transition_receipts_finish_requested(records: Array) -> void:
	for record_value: Variant in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if int(record.get("presenter_instance_id", 0)) != get_instance_id():
			continue
		var receipt: Dictionary = (_bgm_channel.get("receipts", {}) as Dictionary).get(
			int(record.get("token", -1)), {})
		if (
			int(receipt.get("token", 0)) != int(record.get("token", -1))
			or int(receipt.get("operation_request_id", 0))
				!= int(record.get("operation_request_id", -1))
			or int(receipt.get("generation", 0))
				!= int(record.get("generation", -1))
		):
			continue
		_complete_bgm_receipt(receipt)


func _on_bgm_projection_reset_requested(epoch: int) -> void:
	if _bgm_capability == null or epoch != SignalBus.current_bgm_epoch():
		return
	_bgm_generation += 1
	_retire_bgm_transition(&"cancelled")
	_stop_bgm_voice(_bgm_channel.get("current", {}))
	_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
	_bgm_channel.clear()
	_bgm_validation_cache.clear()


func _on_bgm_state_apply_requested(state: Dictionary, generation: int) -> void:
	if (
		_bgm_capability == null
		or generation != SignalBus.current_bgm_epoch()
		or not _bgm_channel.is_empty()
	):
		return
	if state.is_empty():
		return
	state = BgmChannelState.normalize_snapshot_state(state)
	if state.is_empty():
		return
	var resolved := _resolve_bgm_track(
		String(state["asset"]),
		String(state["cue"]),
		state["stem_mix"] as Dictionary,
	)
	var restored_position := float(state["position"])
	var restored_pending := BgmPendingMarkerMixState.from_snapshot(
		state.get("pending_marker_mix", {}))
	if restored_pending != null and (
		not bool(resolved.get("marker_capable", false))
		or restored_pending.marker_table_fingerprint
			!= String(resolved.get("marker_table_fingerprint", ""))
		or restored_pending.track_fingerprint
			!= String(resolved.get("track_fingerprint", ""))
	):
		push_error("AudioPresenter: cannot restore pending marker mix: track fingerprint changed")
		return
	var restored_length := (
		(resolved.get("stream") as AudioStream).get_length()
		if not resolved.is_empty()
		else 0.0
	)
	if (
		resolved.is_empty()
		or not BgmChannelState.stem_mix_equal(
			resolved.get("stem_mix", {}) as Dictionary,
			state["stem_mix"] as Dictionary,
		)
		or bool(resolved["loop"]) != bool(state["loop"])
		or not is_finite(restored_length)
		or restored_position >= (
			float(resolved["loop_end_position"])
			if bool(resolved["loop"])
			else restored_length)
	):
		push_error("AudioPresenter: cannot project saved BGM state: resource metadata changed")
		return
	var restore_arm: Dictionary = {}
	if restored_pending != null:
		restore_arm = _configure_bgm_restore_startup(
			restored_pending, resolved)
		if restore_arm.is_empty():
			push_error("AudioPresenter: could not prepare saved pending marker mix")
			return
	var level := float(state["volume"])
	var voice := _create_bgm_voice(
		resolved.get("stream") as AudioStream,
		String(state["asset"]), String(state["cue"]), bool(state["loop"]),
		restored_position, float(resolved["loop_position"]),
		float(resolved["loop_end_position"]), level,
		resolved.get("stem_mix", {}) as Dictionary,
		resolved.get("stem_names", []) as Array,
		resolved.get("resource_signature", {}) as Dictionary,
		resolved,
		String(state["status"]) == "paused",
	)
	if voice.is_empty():
		return
	_bgm_channel = _new_bgm_channel()
	_bgm_channel["current"] = voice
	_bgm_channel["target_state"] = state.duplicate(true)
	if not restore_arm.is_empty():
		var before_state := state.duplicate(true)
		before_state["pending_marker_mix"] = {}
		_bgm_channel["marker_operations"] = {
			int(restore_arm["operation_id"]): {
				"arm_id": 0,
				"before_state": before_state,
				"generation": _bgm_generation,
				"pending": restore_arm["queued"],
				"receipt": {},
				"restore_expected": restored_pending.duplicate_value(),
			},
		}
		var restored_playback := voice.get("marker_playback") as Object
		if (
			restored_playback == null
			or not is_instance_valid(restored_playback)
			or not restored_playback.has_method(&"release_startup_gate")
		):
			_stop_bgm_voice(voice)
			_bgm_channel.clear()
			push_error("AudioPresenter: pending marker startup gate is unavailable")
			return
		restored_playback.call("release_startup_gate")


func _on_bgm_title_cut_requested(asset: String, generation: int) -> void:
	if (
		_bgm_capability == null
		or generation != SignalBus.current_bgm_epoch()
		or not _bgm_channel.is_empty()
	):
		return
	var resolved := _resolve_bgm_track(asset, "")
	if resolved.is_empty():
		push_warning("AudioPresenter: cannot project title BGM asset '%s'" % asset)
		return
	var voice := _create_bgm_voice(
		resolved.get("stream") as AudioStream,
		asset, "", bool(resolved["loop"]), float(resolved["start_position"]),
		float(resolved["loop_position"]), float(resolved["loop_end_position"]), 1.0,
		resolved.get("stem_mix", {}) as Dictionary,
		resolved.get("stem_names", []) as Array,
		resolved.get("resource_signature", {}) as Dictionary,
		resolved,
	)
	if voice.is_empty():
		return
	_bgm_channel = _new_bgm_channel()
	_bgm_channel["current"] = voice
	_bgm_channel["target_state"] = {
		"asset": asset, "cue": "", "loop": bool(resolved["loop"]),
		"pending_marker_mix": {},
		"position": float(resolved["start_position"]), "status": "playing",
		"stem_mix": (resolved.get("stem_mix", {}) as Dictionary).duplicate(true),
		"volume": 1.0,
	}


func _configure_bgm_restore_startup(
	pending: BgmPendingMarkerMixState,
	resolved: Dictionary,
) -> Dictionary:
	var stream := resolved.get("stream") as Object
	if (
		stream == null
		or not is_instance_valid(stream)
		or not stream.has_method(&"configure_startup_marker_mix")
	):
		return {}
	var gains := _marker_bgm_gains(
		pending.stem_mix, resolved.get("stem_names", []) as Array)
	if gains.is_empty():
		return {}
	var occurrence := _select_saved_bgm_marker_occurrence(
		pending.marker,
		pending.restore_horizon_frame,
		pending.restore_horizon_loop_epoch,
		resolved,
	)
	if occurrence.is_empty():
		return {}
	var operation_id := _next_bgm_restore_operation_id
	var fade_frames := _native_bgm_fade_frames(
		pending.fade_duration, int(resolved.get("sample_rate", 0)))
	if fade_frames < 0:
		return {}
	var configured: Variant = stream.call("configure_startup_marker_mix", {
		"fade_frames": fade_frames,
		"gains": gains,
		"horizon_frame": pending.restore_horizon_frame,
		"horizon_loop_epoch": pending.restore_horizon_loop_epoch,
		"marker": pending.marker,
		"marker_frame": int(occurrence["frame"]),
		"marker_loop_epoch": int(occurrence["loop_epoch"]),
		"marker_ordinal": int(occurrence["ordinal"]),
		"operation_id": operation_id,
		"schema_version": 1,
	})
	if configured != true:
		return {}
	_next_bgm_restore_operation_id += 1
	var queued := BgmPendingMarkerMixState.queued(
		pending.marker,
		pending.stem_mix,
		pending.fade_duration,
		pending.marker_table_fingerprint,
		pending.track_fingerprint,
		pending.restore_horizon_frame,
		pending.restore_horizon_loop_epoch,
	)
	if queued == null:
		return {}
	return {"operation_id": operation_id, "queued": queued}


func _on_bgm_state_capture_requested(request: BgmStateCaptureRequest) -> void:
	if _bgm_capability == null:
		return
	SignalBus.resolve_bgm_state_capture(
		request, self, _bgm_capability, _capture_bgm_state())


func _on_bgm_state_restore_validate_requested(
	request: BgmStateRestoreValidationRequest,
) -> void:
	if _bgm_capability == null or request == null:
		return
	SignalBus.resolve_bgm_state_restore_validation(
		request,
		self,
		_bgm_capability,
		_validate_bgm_state_restore(request.get_state()),
	)


func _validate_bgm_state_restore(state: Dictionary) -> bool:
	var normalized := BgmChannelState.normalize_snapshot_state(state)
	if normalized.is_empty():
		return false
	var pending := BgmPendingMarkerMixState.from_snapshot(
		normalized.get("pending_marker_mix", {}))
	if pending == null:
		return false
	var resolved := _resolve_bgm_track(
		String(normalized.get("asset", "")),
		String(normalized.get("cue", "")),
		normalized.get("stem_mix", {}) as Dictionary,
	)
	if (
		resolved.is_empty()
		or not bool(resolved.get("marker_capable", false))
		or pending.marker_table_fingerprint
			!= String(resolved.get("marker_table_fingerprint", ""))
		or pending.track_fingerprint
			!= String(resolved.get("track_fingerprint", ""))
		or _marker_bgm_gains(
			pending.stem_mix, resolved.get("stem_names", []) as Array).is_empty()
	):
		return false
	var sample_rate := int(resolved.get("sample_rate", 0))
	var source_frame_count := int(resolved.get("source_frame_count", 0))
	if sample_rate <= 0 or source_frame_count <= 0:
		return false
	if _native_bgm_fade_frames(pending.fade_duration, sample_rate) < 0:
		return false
	var horizon_frame := pending.restore_horizon_frame
	var horizon_loop_epoch := pending.restore_horizon_loop_epoch
	var loop_start_frame := roundi(
		float(resolved.get("loop_position", 0.0)) * sample_rate)
	var loop_end_frame := roundi(
		float(resolved.get("loop_end_position", 0.0)) * sample_rate)
	if (
		horizon_frame < 0
		or horizon_frame >= source_frame_count
		or horizon_frame >= loop_end_frame
		or horizon_loop_epoch < 0
		or (not bool(resolved.get("loop", false)) and horizon_loop_epoch != 0)
		or (
			bool(resolved.get("loop", false))
			and horizon_loop_epoch > 0
			and horizon_frame < loop_start_frame
		)
		or roundi(float(normalized.get("position", 0.0)) * sample_rate)
			!= horizon_frame
	):
		return false
	var occurrence := _select_saved_bgm_marker_occurrence(
		pending.marker, horizon_frame, horizon_loop_epoch, resolved)
	if occurrence.is_empty():
		return false
	if pending.phase == BgmPendingMarkerMixState.Phase.QUEUED:
		return true
	return (
		pending.marker_frame == int(occurrence.get("frame", -1))
		and pending.marker_ordinal == int(occurrence.get("ordinal", -1))
		and pending.marker_loop_epoch
			== int(occurrence.get("loop_epoch", -1))
	)


func _select_saved_bgm_marker_occurrence(
	marker_name: String,
	horizon_frame: int,
	horizon_loop_epoch: int,
	resolved: Dictionary,
) -> Dictionary:
	var occurrences: Array = resolved.get("marker_occurrences", [])
	var loop_end_frame := roundi(
		float(resolved.get("loop_end_position", 0.0))
		* float(resolved.get("sample_rate", 0)))
	for ordinal in range(occurrences.size()):
		var occurrence: Dictionary = occurrences[ordinal]
		var frame := int(occurrence.get("frame", -1))
		if (
			String(occurrence.get("name", "")) == marker_name
			and frame >= horizon_frame
			and frame < loop_end_frame
		):
			return {
				"frame": frame,
				"loop_epoch": horizon_loop_epoch,
				"ordinal": ordinal,
			}
	if not bool(resolved.get("loop", false)):
		return {}
	var loop_start_frame := roundi(
		float(resolved.get("loop_position", 0.0))
		* float(resolved.get("sample_rate", 0)))
	for ordinal in range(occurrences.size()):
		var occurrence: Dictionary = occurrences[ordinal]
		var frame := int(occurrence.get("frame", -1))
		if (
			String(occurrence.get("name", "")) == marker_name
			and frame >= loop_start_frame
			and frame < loop_end_frame
		):
			return {
				"frame": frame,
				"loop_epoch": horizon_loop_epoch + 1,
				"ordinal": ordinal,
			}
	return {}


func _capture_bgm_position() -> float:
	return float(_capture_bgm_state().get("position", 0.0))


func _capture_bgm_state() -> Dictionary:
	var target := BgmChannelState.normalize_snapshot_state(
		_bgm_channel.get("target_state", {}))
	if target.is_empty():
		return {}
	var current: Dictionary = _bgm_channel.get("current", {})
	var player: AudioStreamPlayer = current.get("player")
	if player == null or not is_instance_valid(player):
		return target
	var playback := current.get("marker_playback") as Object
	if playback == null or not is_instance_valid(playback):
		target["position"] = maxf(player.get_playback_position(), 0.0)
		return target
	var snapshot_value: Variant = playback.call("capture_marker_state")
	if not snapshot_value is Dictionary:
		return target
	var snapshot: Dictionary = snapshot_value
	var sample_rate := int(current.get("sample_rate", 0))
	if sample_rate <= 0:
		return target
	var phase := String(snapshot.get("phase", "none"))
	var horizon_frame := int(snapshot.get("horizon_frame", -1))
	var horizon_loop_epoch := int(snapshot.get("horizon_loop_epoch", -1))
	target["position"] = maxf(
		float(snapshot.get("playback_frame_cursor", 0)) / float(sample_rate), 0.0)
	var operation_id := int(
		snapshot.get(
			"queued_operation_id" if phase == "queued" else "active_operation_id",
			0,
		)
	)
	var marker_operations: Dictionary = _bgm_channel.get("marker_operations", {})
	var record: Dictionary = marker_operations.get(operation_id, {})
	var pending := record.get("pending") as BgmPendingMarkerMixState
	if phase == "queued" and pending != null:
		var queued_at_horizon := pending.at_restore_horizon(
			horizon_frame, horizon_loop_epoch)
		if queued_at_horizon == null:
			return target
		target["position"] = float(horizon_frame) / float(sample_rate)
		target["pending_marker_mix"] = queued_at_horizon.to_snapshot()
		return target
	if phase == "armed" and pending != null:
		var armed := pending.armed(
			int(snapshot.get("marker_frame", -1)),
			int(snapshot.get("marker_ordinal", -1)),
			int(snapshot.get("marker_loop_epoch", -1)),
			horizon_frame,
			horizon_loop_epoch,
		)
		if armed != null:
			target["position"] = float(horizon_frame) / float(sample_rate)
			target["pending_marker_mix"] = armed.to_snapshot()
		return target
	if phase in ["triggered", "none"]:
		var gains_value: Variant = snapshot.get("target_gains")
		var names: Array = current.get("stem_names", [])
		if gains_value is PackedFloat32Array and gains_value.size() == names.size():
			var physical_mix: Dictionary = {}
			for index in range(names.size()):
				physical_mix[String(names[index])] = float(gains_value[index])
			if BgmChannelState.validate_stem_mix(physical_mix, false, true):
				target["stem_mix"] = physical_mix
		target["pending_marker_mix"] = {}
	return target


func _create_bgm_voice(
	stream: AudioStream,
	asset: String,
	cue: String,
	loop: bool,
	position: float,
	loop_position: float,
	loop_end_position: float,
	level: float,
	stem_mix: Dictionary,
	stem_names: Array,
	resource_signature: Dictionary,
	marker_info: Dictionary = {},
	start_paused: bool = false,
) -> Dictionary:
	if _audio_admission_is_closed() or stream == null:
		return {}
	var player := AudioStreamPlayer.new()
	player.bus = "Master"
	player.stream = stream
	add_child(player)
	var voice := {
		"asset": asset, "cue": cue, "level": level, "loop": loop,
		"loop_position": loop_position, "loop_end_position": loop_end_position,
		"player": player,
		"stem_mix": stem_mix.duplicate(true),
		"stem_names": stem_names.duplicate(),
		"resource_signature": resource_signature.duplicate(true),
		"marker_capable": bool(marker_info.get("marker_capable", false)),
		"marker_table_fingerprint": String(
			marker_info.get("marker_table_fingerprint", "")),
		"sample_rate": int(marker_info.get("sample_rate", 0)),
		"track_fingerprint": String(marker_info.get("track_fingerprint", "")),
	}
	_set_bgm_stem_mix(stem_mix, voice)
	_set_bgm_voice_level(level, voice)
	player.finished.connect(_on_bgm_voice_finished.bind(voice), CONNECT_ONE_SHOT)
	player.play(position)
	# Godot resets stream_paused in play(). A pending marker restore keeps the
	# native startup gate closed across this call, so even a forced callback can
	# neither consume the command nor advance the cursor before this pause write.
	player.stream_paused = start_paused
	if bool(voice["marker_capable"]):
		var marker_playback := player.get_stream_playback()
		if (
			marker_playback == null
			or not marker_playback.has_method(&"arm_marker_mix")
			or not marker_playback.has_method(&"drain_marker_events")
		):
			_stop_bgm_voice(voice)
			return {}
		voice["marker_playback"] = marker_playback
		if (
			OS.is_debug_build()
			and _bgm_after_player_played_debug_hook.is_valid()
		):
			_bgm_after_player_played_debug_hook.call(player, marker_playback)
	return voice


func _bgm_voice_is_live(voice: Dictionary, asset: String, cue: String) -> bool:
	var player: AudioStreamPlayer = voice.get("player")
	return (
		String(voice.get("asset", "")) == asset
		and String(voice.get("cue", "")) == cue
		and player != null
		and is_instance_valid(player)
		and player.playing
		and player.stream != null
	)


func _set_bgm_voice_level(level: float, voice: Dictionary) -> void:
	voice["level"] = clampf(level, 0.0, 1.0)
	var player: AudioStreamPlayer = voice.get("player")
	if player == null or not is_instance_valid(player):
		return
	player.volume_db = _to_db(
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("bgm_volume", 0.8)
		* float(voice["level"]))


func _set_bgm_stem_mix(stem_mix: Dictionary, voice: Dictionary) -> void:
	voice["stem_mix"] = stem_mix.duplicate(true)
	var player: AudioStreamPlayer = voice.get("player")
	if player == null or not is_instance_valid(player):
		return
	var synchronized := player.stream as AudioStreamSynchronized
	if synchronized == null:
		return
	var stem_names: Array = voice.get("stem_names", [])
	if stem_names.size() != synchronized.stream_count:
		return
	for index in range(stem_names.size()):
		var stem_name := String(stem_names[index])
		synchronized.set_sync_stream_volume(
			index, _to_bgm_stem_db(float(stem_mix.get(stem_name, 0.0))))


func _to_bgm_stem_db(gain: float) -> float:
	# AudioStreamPlaybackSynchronized multiplies each child by db_to_linear().
	# A finite floor such as -80 dB leaks that child at 1e-4 linear gain; -INF
	# is the Godot 4.6 exact-silence representation and remains physical only.
	return -INF if gain <= 0.0 else linear_to_db(gain)


func _set_bgm_stem_mix_progress(
	progress: float,
	from_mix: Dictionary,
	to_mix: Dictionary,
	voice: Dictionary,
) -> void:
	var current: Dictionary = {}
	for stem_name: Variant in to_mix.keys():
		current[String(stem_name)] = lerpf(
			float(from_mix.get(stem_name, 0.0)),
			float(to_mix[stem_name]),
			clampf(progress, 0.0, 1.0),
		)
	_set_bgm_stem_mix(current, voice)


func _apply_bgm_volumes() -> void:
	for key: String in ["current", "outgoing"]:
		var voice: Dictionary = _bgm_channel.get(key, {})
		if not voice.is_empty():
			_set_bgm_voice_level(float(voice.get("level", 0.0)), voice)


func _stop_bgm_voice(voice_value: Variant) -> void:
	if not voice_value is Dictionary:
		return
	_invalidate_bgm_marker_arms(voice_value as Dictionary)
	var player: AudioStreamPlayer = (voice_value as Dictionary).get("player")
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream = null
	player.queue_free()


func _invalidate_bgm_marker_arms(voice: Dictionary) -> void:
	var playback := voice.get("marker_playback") as Object
	if playback != null and is_instance_valid(playback):
		playback.call("invalidate_marker_arms")


func _on_bgm_voice_finished(voice: Dictionary) -> void:
	if _bgm_capability == null or _bgm_channel.get("current", {}) != voice:
		return
	if bool(voice.get("loop", true)):
		return
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if not receipt.is_empty():
		var tween: Tween = _bgm_channel.get("tween")
		_bgm_channel["tween"] = null
		if tween != null and tween.is_valid():
			tween.kill()
		_emit_bgm_terminal(receipt, &"completed")
	_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
	_stop_bgm_voice(voice)
	_bgm_channel.clear()
	SignalBus.commit_bgm_natural_stop(self, _bgm_capability)


func _resolve_bgm_track(
	asset: String,
	cue: String,
	requested_stem_mix: Dictionary = {},
) -> Dictionary:
	var paths := _bgm_candidate_paths(asset)
	var existing: Array[String] = []
	for path: String in paths:
		if ResourceLoader.exists(path):
			existing.append(path)
	if existing.size() != 1:
		return {}
	var loaded := ResourceLoader.load(existing[0])
	if loaded is BgmTrackDefinition:
		return _prepare_bgm_definition(
			loaded as BgmTrackDefinition, cue, requested_stem_mix)
	if (
		not cue.is_empty()
		or not requested_stem_mix.is_empty()
		or not loaded is AudioStream
	):
		return {}
	return _prepare_raw_bgm_stream(loaded as AudioStream)


func _bgm_candidate_paths(asset: String) -> Array[String]:
	if (
		asset.is_empty() or asset.begins_with("/") or "\\" in asset
		or ".." in asset.split("/", false)
	):
		return []
	var extension := asset.get_extension().to_lower()
	if "://" in asset:
		return [asset] if extension in ["tres", "res", "ogg", "mp3", "wav"] else []
	if extension in ["tres", "res", "ogg", "mp3", "wav"]:
		return [StellaRuntime.bgm_path.path_join(asset)]
	if not extension.is_empty():
		return []
	var result: Array[String] = []
	for suffix: String in ["tres", "res", "ogg", "mp3", "wav"]:
		result.append(StellaRuntime.bgm_path.path_join("%s.%s" % [asset, suffix]))
	return result


func _prepare_bgm_definition(
	definition: BgmTrackDefinition,
	cue: String,
	requested_stem_mix: Dictionary = {},
) -> Dictionary:
	if definition == null:
		return {}
	var uses_single_stream := definition.stream != null
	var uses_stems := not definition.stems.is_empty()
	var uses_markers := not definition.markers.is_empty()
	if uses_single_stream == uses_stems:
		return {}
	if uses_markers and not uses_stems:
		return {}
	var sources: Array[AudioStream] = []
	var stem_names: Array[String] = []
	var default_stem_mix: Dictionary = {}
	if uses_single_stream:
		if not requested_stem_mix.is_empty():
			return {}
		sources.append(definition.stream)
	else:
		if (
			definition.stems.size() < 2
			or definition.stems.size() > AudioStreamSynchronized.MAX_STREAMS
		):
			return {}
		var seen_stems: Dictionary = {}
		for stem: BgmStemDefinition in definition.stems:
			if (
				stem == null
				or not BgmChannelState.is_valid_stem_name(stem.stem_name)
				or seen_stems.has(stem.stem_name)
				or stem.stream == null
				or not is_finite(stem.default_gain)
				or stem.default_gain < 0.0
				or stem.default_gain > 1.0
			):
				return {}
			seen_stems[stem.stem_name] = true
			stem_names.append(stem.stem_name)
			sources.append(stem.stream)
			default_stem_mix[stem.stem_name] = stem.default_gain
		if not _bgm_stem_streams_match(sources):
			return {}
	var length := sources[0].get_length()
	if not is_finite(length) or length <= 0.0:
		return {}
	var definition_loop_end := _resolve_bgm_loop_end(
		definition.loop_end_position, length)
	if not _bgm_marker_is_valid(
		definition.start_position, definition.loop_position,
		definition_loop_end, length):
		return {}
	var selected := {
		"loop": definition.loop,
		"start_position": definition.start_position,
		"loop_position": definition.loop_position,
		"loop_end_position": definition_loop_end,
		"uses_natural_loop_end": (
			definition.loop_end_position == BGM_NATURAL_LOOP_END),
	}
	var names: Dictionary = {}
	for cue_definition: BgmCueDefinition in definition.cues:
		var cue_loop_end := _resolve_bgm_loop_end(
			cue_definition.loop_end_position if cue_definition != null else NAN,
			length,
		)
		if (
			cue_definition == null
			or not BgmChannelState.is_valid_cue_name(cue_definition.cue_name, false)
			or names.has(cue_definition.cue_name)
			or not _bgm_marker_is_valid(
				cue_definition.start_position, cue_definition.loop_position,
				cue_loop_end, length)
		):
			return {}
		names[cue_definition.cue_name] = true
		if cue_definition.cue_name == cue:
			selected = {
				"loop": cue_definition.loop,
				"start_position": cue_definition.start_position,
				"loop_position": cue_definition.loop_position,
				"loop_end_position": cue_loop_end,
				"uses_natural_loop_end": (
					cue_definition.loop_end_position == BGM_NATURAL_LOOP_END),
			}
	if not cue.is_empty() and not names.has(cue):
		return {}
	if not _bgm_marker_is_valid(
		float(selected["start_position"]), float(selected["loop_position"]),
		float(selected["loop_end_position"]), length):
		return {}
	for source: AudioStream in sources:
		if not _bgm_marker_is_valid(
			float(selected["start_position"]),
			float(selected["loop_position"]),
			float(selected["loop_end_position"]),
			source.get_length(),
		):
			return {}
	var stem_mix := _resolve_bgm_stem_mix(
		stem_names, default_stem_mix, requested_stem_mix)
	if uses_stems and stem_mix.is_empty():
		return {}
	if uses_markers:
		var marker_prepared := _prepare_marker_bgm_stream(
			sources, stem_names, stem_mix, definition.markers, selected)
		if marker_prepared.is_empty():
			return {}
		selected.merge(marker_prepared, true)
		selected["stem_mix"] = stem_mix.duplicate(true)
		selected["stem_names"] = stem_names.duplicate()
		selected["resource_signature"] = {
			"marker_track_fingerprint": String(selected["track_fingerprint"]),
		}
		return selected
	var prepared_streams: Array[AudioStream] = []
	for source: AudioStream in sources:
		var stream := _duplicate_bgm_stream(
			source, bool(selected["loop"]),
			float(selected["loop_position"]),
			float(selected["loop_end_position"]),
			bool(selected["uses_natural_loop_end"]),
		)
		if stream == null:
			return {}
		prepared_streams.append(stream)
	if uses_single_stream:
		selected["stream"] = prepared_streams[0]
	else:
		var synchronized := AudioStreamSynchronized.new()
		synchronized.stream_count = prepared_streams.size()
		for index in range(prepared_streams.size()):
			synchronized.set_sync_stream(index, prepared_streams[index])
			synchronized.set_sync_stream_volume(
				index, _to_bgm_stem_db(float(stem_mix[stem_names[index]])))
		selected["stream"] = synchronized
	selected["stem_mix"] = stem_mix.duplicate(true)
	selected["stem_names"] = stem_names.duplicate()
	selected["resource_signature"] = _bgm_resource_signature(
		sources, stem_names, default_stem_mix, selected)
	selected["marker_capable"] = false
	return selected


func _prepare_marker_bgm_stream(
	sources: Array[AudioStream],
	stem_names: Array[String],
	stem_mix: Dictionary,
	markers: Array[BgmMarkerDefinition],
	selected: Dictionary,
) -> Dictionary:
	if not ClassDB.class_exists(&"StellaMarkerBgmStream"):
		push_error(
			"AudioPresenter: marker-capable BGM requires the Stella marker "
			+ "playback extension; build both native templates before "
			+ "import/export (tests/build_marker_bgm_native.sh)")
		return {}
	var stem_bytes: Array[PackedByteArray] = []
	var sampling_rate := 0
	for source_index in range(sources.size()):
		var source: AudioStream = sources[source_index]
		if not source is AudioStreamOggVorbis:
			return {}
		var ogg := source as AudioStreamOggVorbis
		if (
			ogg.packet_sequence == null
			or ogg.packet_sequence.sampling_rate <= 0
			or ogg.packet_sequence.packet_data.is_empty()
		):
			return {}
		if sampling_rate == 0:
			sampling_rate = ogg.packet_sequence.sampling_rate
		elif sampling_rate != ogg.packet_sequence.sampling_rate:
			return {}
		var bytes := BgmOggPacketEncoder.encode(
			ogg.packet_sequence.packet_data,
			ogg.packet_sequence.granule_positions,
			0x53540000 + source_index + 1,
		)
		if bytes.is_empty():
			return {}
		stem_bytes.append(bytes)
	var encoded_markers: Array = []
	var previous_frame := -1
	var names_at_frame: Dictionary = {}
	for marker: BgmMarkerDefinition in markers:
		if (
			marker == null
			or not BgmChannelState.is_valid_marker_label(marker.marker_name)
			or marker.sample_frame < previous_frame
		):
			return {}
		if marker.sample_frame != previous_frame:
			names_at_frame.clear()
		if names_at_frame.has(marker.marker_name):
			return {}
		names_at_frame[marker.marker_name] = true
		encoded_markers.append({
			"frame": marker.sample_frame,
			"name": marker.marker_name,
		})
		previous_frame = marker.sample_frame
	var loop_start_frame := roundi(float(selected["loop_position"]) * sampling_rate)
	var loop_end_frame := roundi(float(selected["loop_end_position"]) * sampling_rate)
	var gains := PackedFloat32Array()
	gains.resize(stem_names.size())
	for index in range(stem_names.size()):
		gains[index] = float(stem_mix[stem_names[index]])
	var stream_object := ClassDB.instantiate(&"StellaMarkerBgmStream")
	if stream_object == null:
		return {}
	var configured: Variant = stream_object.call("configure", {
		"initial_gains": gains,
		"loop": bool(selected["loop"]),
		"loop_end_frame": loop_end_frame,
		"loop_start_frame": loop_start_frame,
		"markers": encoded_markers,
		"schema_version": 1,
		"stem_names": PackedStringArray(stem_names),
		"stem_ogg_bytes": stem_bytes,
	})
	if configured != true:
		return {}
	var stream := stream_object as AudioStream
	if stream == null:
		return {}
	var source_sample_rate := int(stream_object.call("get_source_sample_rate"))
	var source_frame_count := int(stream_object.call("get_source_frame_count"))
	if source_sample_rate != sampling_rate or source_frame_count <= 0:
		return {}
	var marker_fingerprint := BgmMarkerFingerprint.marker_table(markers)
	var track_fingerprint := BgmMarkerFingerprint.track(
		stem_names, stem_bytes, source_sample_rate, source_frame_count,
		bool(selected["loop"]), loop_start_frame, loop_end_frame,
		marker_fingerprint,
	)
	if marker_fingerprint.is_empty() or track_fingerprint.is_empty():
		return {}
	return {
		"marker_capable": true,
		"marker_occurrences": encoded_markers.duplicate(true),
		"marker_table_fingerprint": marker_fingerprint,
		"sample_rate": source_sample_rate,
		"source_frame_count": source_frame_count,
		"stream": stream,
		"track_fingerprint": track_fingerprint,
	}


func _resolve_bgm_stem_mix(
	stem_names: Array[String],
	default_mix: Dictionary,
	requested_mix: Dictionary,
) -> Dictionary:
	if stem_names.is_empty():
		return {}
	if not BgmChannelState.validate_stem_mix(requested_mix, true):
		return {}
	var available: Dictionary = {}
	for stem_name: String in stem_names:
		available[stem_name] = true
	for stem_name: Variant in requested_mix.keys():
		if not available.has(stem_name):
			return {}
	var result: Dictionary = {}
	for stem_name: String in stem_names:
		result[stem_name] = (
			float(default_mix.get(stem_name, 1.0))
			if requested_mix.is_empty()
			else float(requested_mix.get(stem_name, 0.0))
		)
	return result if BgmChannelState.validate_stem_mix(
		result, false, true) else {}


func _bgm_stem_streams_match(sources: Array[AudioStream]) -> bool:
	if sources.size() < 2:
		return false
	var reference := sources[0]
	var reference_length := reference.get_length()
	if not _bgm_stream_type_is_supported(reference):
		return false
	for index in range(1, sources.size()):
		var candidate := sources[index]
		if (
			not _bgm_stream_type_is_supported(candidate)
			or candidate.get_class() != reference.get_class()
			or not is_finite(candidate.get_length())
			or candidate.get_length() != reference_length
		):
			return false
		if reference is AudioStreamWAV:
			var reference_wav := reference as AudioStreamWAV
			var candidate_wav := candidate as AudioStreamWAV
			if (
				candidate_wav.mix_rate != reference_wav.mix_rate
				or candidate_wav.stereo != reference_wav.stereo
				or candidate_wav.format != reference_wav.format
			):
				return false
	return true


func _bgm_resource_signature(
	sources: Array[AudioStream],
	stem_names: Array[String],
	default_stem_mix: Dictionary,
	selected: Dictionary,
) -> Dictionary:
	var stream_signatures: Array = []
	for source: AudioStream in sources:
		var stream_signature := {
			"class": source.get_class(),
			"length": source.get_length(),
			"resource_path": source.resource_path,
		}
		if source is AudioStreamWAV:
			var wav := source as AudioStreamWAV
			stream_signature["data_hash"] = hash(wav.data)
			stream_signature["format"] = wav.format
			stream_signature["mix_rate"] = wav.mix_rate
			stream_signature["stereo"] = wav.stereo
		elif source is AudioStreamMP3:
			stream_signature["data_hash"] = hash(
				(source as AudioStreamMP3).data)
		elif source is AudioStreamOggVorbis:
			var packet_sequence := (
				(source as AudioStreamOggVorbis).packet_sequence)
			if packet_sequence != null:
				stream_signature["granule_hash"] = hash(
					packet_sequence.granule_positions)
				stream_signature["packet_hash"] = hash(
					packet_sequence.packet_data)
				stream_signature["sampling_rate"] = (
					packet_sequence.sampling_rate)
		stream_signatures.append(stream_signature)
	return {
		"loop": bool(selected["loop"]),
		"loop_end_position": float(selected["loop_end_position"]),
		"loop_position": float(selected["loop_position"]),
		"start_position": float(selected["start_position"]),
		"stem_default_mix": default_stem_mix.duplicate(true),
		"stem_names": stem_names.duplicate(),
		"streams": stream_signatures,
	}


func _bgm_voice_matches_prepared(
	voice: Dictionary,
	prepared: Dictionary,
) -> bool:
	if voice.is_empty():
		return false
	var prepared_names: Array = prepared.get("stem_names", [])
	var live_names: Array = voice.get("stem_names", [])
	var prepared_mix: Dictionary = prepared.get("stem_mix", {})
	var live_mix: Dictionary = voice.get("stem_mix", {})
	return (
		live_names == prepared_names
		and _bgm_stem_schema_matches_mix(live_names, live_mix)
		and _bgm_stem_schema_matches_mix(prepared_names, prepared_mix)
		and (voice.get("resource_signature", {}) as Dictionary)
			== (prepared.get("resource_signature", {}) as Dictionary)
	)


func _bgm_stem_schema_matches_mix(
	stem_names: Array,
	stem_mix: Dictionary,
) -> bool:
	if stem_names.size() != stem_mix.size():
		return false
	for stem_name: Variant in stem_names:
		if not stem_mix.has(stem_name):
			return false
	return true


func _bgm_stream_type_is_supported(stream: AudioStream) -> bool:
	return (
		stream is AudioStreamOggVorbis
		or stream is AudioStreamMP3
		or stream is AudioStreamWAV
	)


func _prepare_raw_bgm_stream(source: AudioStream) -> Dictionary:
	if source == null:
		return {}
	var length := source.get_length()
	if not is_finite(length) or length <= 0.0:
		return {}
	var native_region := _native_bgm_loop_region(source, length)
	if native_region.is_empty():
		return {}
	var loop_position := float(native_region["loop_position"])
	var loop_end_position := float(native_region["loop_end_position"])
	var stream := _duplicate_raw_bgm_stream(source, loop_end_position)
	if stream == null:
		return {}
	return {
		"stream": stream, "loop": true,
		"start_position": 0.0, "loop_position": loop_position,
		"loop_end_position": loop_end_position,
		"stem_mix": {}, "stem_names": [],
		"resource_signature": _bgm_resource_signature(
			[source], [], {}, {
				"loop": true,
				"start_position": 0.0,
				"loop_position": loop_position,
				"loop_end_position": loop_end_position,
			}),
	}


func _bgm_marker_is_valid(
	start_position: float,
	loop_position: float,
	loop_end_position: float,
	length: float,
) -> bool:
	if (
		not is_finite(start_position)
		or not is_finite(loop_position)
		or not is_finite(loop_end_position)
		or not is_finite(length)
		or start_position < 0.0
	):
		return false
	# A disabled loop still carries a complete authored region. It is validated
	# identically but ignored by the duplicate stream so natural playback keeps
	# the entire physical tail.
	return (
		loop_position >= start_position
		and loop_position < loop_end_position
		and loop_end_position <= length
	)


func _resolve_bgm_loop_end(authored_end: float, length: float) -> float:
	if authored_end == BGM_NATURAL_LOOP_END:
		return length
	return authored_end if is_finite(authored_end) and authored_end >= 0.0 else NAN


func _native_bgm_loop_region(source: AudioStream, length: float) -> Dictionary:
	if source is AudioStreamOggVorbis:
		var ogg := source as AudioStreamOggVorbis
		return _native_compressed_bgm_loop_region(
			ogg.loop_offset, ogg.bpm, ogg.beat_count, length)
	if source is AudioStreamMP3:
		var mp3 := source as AudioStreamMP3
		return _native_compressed_bgm_loop_region(
			mp3.loop_offset, mp3.bpm, mp3.beat_count, length)
	if source is AudioStreamWAV:
		var wav := source as AudioStreamWAV
		if wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
			if wav.mix_rate <= 0:
				return {}
			var loop_position := float(wav.loop_begin) / float(wav.mix_rate)
			var loop_end_position := float(wav.loop_end) / float(wav.mix_rate)
			return {
				"loop_position": loop_position,
				"loop_end_position": loop_end_position,
			} if _bgm_marker_is_valid(
				0.0, loop_position, loop_end_position, length) else {}
		return {"loop_position": 0.0, "loop_end_position": length}
	return {}


func _native_compressed_bgm_loop_region(
	loop_position: float,
	bpm: float,
	beat_count: int,
	length: float,
) -> Dictionary:
	if (
		not is_finite(loop_position)
		or loop_position < 0.0
		or not is_finite(bpm)
		or bpm < 0.0
		or beat_count < 0
	):
		return {}
	var loop_end_position := length
	if beat_count > 0:
		if bpm <= 0.0:
			return {}
		loop_end_position = float(beat_count) * 60.0 / bpm
	return {
		"loop_position": loop_position,
		"loop_end_position": loop_end_position,
	} if _bgm_marker_is_valid(
		0.0, loop_position, loop_end_position, length) else {}


func _duplicate_bgm_stream(
	source: AudioStream,
	loop: bool,
	loop_position: float,
	loop_end_position: float,
	uses_natural_loop_end: bool,
) -> AudioStream:
	if source is AudioStreamOggVorbis:
		var stream := (source as AudioStreamOggVorbis).duplicate(true) as AudioStreamOggVorbis
		stream.loop = loop
		stream.loop_offset = loop_position if loop else 0.0
		stream.beat_count = 0
		stream.bpm = 0.0
		if (
			loop and not uses_natural_loop_end
			and not _configure_bgm_beat_loop_end(
				stream, loop_end_position, _bgm_stream_sample_rate(stream))
		):
			return null
		return stream
	if source is AudioStreamMP3:
		var stream := (source as AudioStreamMP3).duplicate(true) as AudioStreamMP3
		stream.loop = loop
		stream.loop_offset = loop_position if loop else 0.0
		stream.beat_count = 0
		stream.bpm = 0.0
		if (
			loop and not uses_natural_loop_end
			and not _configure_bgm_beat_loop_end(
				stream, loop_end_position, _bgm_stream_sample_rate(stream))
		):
			return null
		return stream
	if source is AudioStreamWAV:
		var stream := (source as AudioStreamWAV).duplicate(true) as AudioStreamWAV
		if stream.mix_rate <= 0:
			return null
		stream.loop_mode = (
			AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED)
		stream.loop_begin = int(round(loop_position * float(stream.mix_rate))) if loop else 0
		stream.loop_end = int(round(loop_end_position * float(stream.mix_rate))) if loop else 0
		if loop and (
			absf(float(stream.loop_begin) - loop_position * float(stream.mix_rate)) >= 1.0
			or absf(float(stream.loop_end) - loop_end_position * float(stream.mix_rate)) >= 1.0
		):
			return null
		return stream
	return null


func _duplicate_raw_bgm_stream(
	source: AudioStream,
	loop_end_position: float,
) -> AudioStream:
	if source is AudioStreamOggVorbis:
		var stream := (source as AudioStreamOggVorbis).duplicate(true) as AudioStreamOggVorbis
		stream.loop = true
		return stream
	if source is AudioStreamMP3:
		var stream := (source as AudioStreamMP3).duplicate(true) as AudioStreamMP3
		stream.loop = true
		return stream
	if source is AudioStreamWAV:
		var stream := (source as AudioStreamWAV).duplicate(true) as AudioStreamWAV
		if stream.mix_rate <= 0:
			return null
		if stream.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = 0
			stream.loop_end = int(round(loop_end_position * float(stream.mix_rate)))
		return stream
	return null


func _configure_bgm_beat_loop_end(
	stream: AudioStream,
	loop_end_position: float,
	sample_rate: int,
) -> bool:
	if (
		stream == null
		or not (stream is AudioStreamOggVorbis or stream is AudioStreamMP3)
		or not is_finite(loop_end_position)
		or loop_end_position <= 0.0
		or sample_rate <= 0
	):
		return false
	var requested_frames := loop_end_position * float(sample_rate)
	if (
		not is_finite(requested_frames)
		or requested_frames > BGM_MAX_SIGNED_MIXER_FRAMES
	):
		return false
	stream.set("beat_count", 1)
	stream.set("bpm", 60.0 / loop_end_position)
	var stored_beat_count := int(stream.get("beat_count"))
	var stored_bpm := float(stream.get("bpm"))
	if stored_beat_count != 1 or not is_finite(stored_bpm) or stored_bpm <= 0.0:
		return false
	var represented_frames := int(
		float(stored_beat_count) * float(sample_rate) * 60.0 / stored_bpm)
	return absf(
		float(represented_frames) - requested_frames) < 1.0


func _bgm_stream_sample_rate(stream: AudioStream) -> int:
	if stream is AudioStreamWAV:
		return (stream as AudioStreamWAV).mix_rate
	if stream is AudioStreamOggVorbis:
		var packet_sequence := (stream as AudioStreamOggVorbis).packet_sequence
		return packet_sequence.sampling_rate if packet_sequence != null else 0
	if stream is AudioStreamMP3:
		return _mp3_sample_rate((stream as AudioStreamMP3).data)
	return 0


func _mp3_sample_rate(data: PackedByteArray) -> int:
	var offset := 0
	if data.size() >= 10 and data.slice(0, 3).get_string_from_ascii() == "ID3":
		offset = 10
		for index in range(6, 10):
			if data[index] & 0x80:
				return 0
			offset += int(data[index]) << (7 * (9 - index))
	while offset + 4 <= data.size():
		var first := int(data[offset])
		var second := int(data[offset + 1])
		var third := int(data[offset + 2])
		if first == 0xff and (second & 0xe0) == 0xe0:
			var version_bits := (second >> 3) & 0x03
			var layer_bits := (second >> 1) & 0x03
			var bitrate_index := (third >> 4) & 0x0f
			var sample_rate_index := (third >> 2) & 0x03
			if (
				version_bits != 1
				and layer_bits == 1
				and bitrate_index > 0 and bitrate_index < 15
				and sample_rate_index < 3
			):
				var rates := {
					3: [44100, 48000, 32000],
					2: [22050, 24000, 16000],
					0: [11025, 12000, 8000],
				}
				return int((rates[version_bits] as Array)[sample_rate_index])
		offset += 1
	return 0


# ─── SE ───

func _on_se_play(asset: String):
	if _audio_admission_is_closed():
		return
	var stream = _load_audio(StellaRuntime.se_path, asset, ["ogg", "wav"])
	if stream == null:
		push_warning("AudioPresenter: SE not found: %s" % asset)
		return

	for player in _se_players:
		if not player.playing:
			player.stream = stream
			player.play()
			return

	_se_players[0].stream = stream
	_se_players[0].play()

# ─── Persistent named loop SE ───

func _on_loop_se_validate_requested(request: LoopSeOperationRequest) -> void:
	if _loop_se_capability == null or request == null or not request.is_target(self):
		return
	if _audio_admission_is_closed():
		SignalBus.reject_loop_se_request(
			request, self, _loop_se_capability, "audio presenter is quiescing")
		return
	var payload := request.get_payload()
	if not LoopSeChannelState.validate_operation(payload, false):
		SignalBus.reject_loop_se_request(
			request, self, _loop_se_capability, "invalid canonical operation")
		return
	var request_key := request.get_instance_id()
	var prepared := {"action": String(payload["action"])}
	if String(payload["action"]) == "play":
		var resolved := _resolve_loop_se_stream(String(payload["asset"]))
		if resolved.is_empty():
			SignalBus.reject_loop_se_request(
				request,
				self,
				_loop_se_capability,
				"asset '%s' is missing or is not a supported OGG/WAV stream"
					% String(payload["asset"]),
			)
			return
		prepared.merge(resolved)
	_loop_se_validation_cache[request_key] = prepared
	request.finished.connect(
		_cleanup_loop_se_validation.bind(request_key), CONNECT_ONE_SHOT)
	SignalBus.validate_loop_se_request(request, self, _loop_se_capability)


func _on_loop_se_accept_requested(request: LoopSeOperationRequest) -> void:
	if (
		_loop_se_capability == null
		or request == null
		or not _loop_se_validation_cache.has(request.get_instance_id())
	):
		return
	SignalBus.accept_loop_se_request(request, self, _loop_se_capability)


func _on_loop_se_apply_requested(request: LoopSeOperationRequest) -> void:
	if _loop_se_capability == null or request == null:
		return
	var prepared: Dictionary = _loop_se_validation_cache.get(
		request.get_instance_id(), {})
	if prepared.is_empty():
		return
	if not _apply_loop_se_operation(
		request.get_payload(), prepared, request.get_request_id(),
		request.get_force_cut()):
		return
	SignalBus.acknowledge_loop_se_apply(
		request, self, _loop_se_capability)


func _cleanup_loop_se_validation(request_key: int) -> void:
	_loop_se_validation_cache.erase(request_key)


func _apply_loop_se_operation(
	payload: Dictionary,
	prepared: Dictionary,
	request_id: int,
	force_cut: bool,
) -> bool:
	var channel_id := String(payload["channel"])
	var action := String(payload["action"])
	var fade_duration := float(payload["fade_duration"])
	if force_cut:
		fade_duration = 0.0
	if action == "stop":
		return _stop_loop_se_channel(channel_id, fade_duration, request_id)
	return _play_loop_se_channel(
		channel_id,
		String(payload["asset"]),
		float(payload["volume"]),
		float(payload["resume_position"]),
		prepared.get("stream") as AudioStream,
		fade_duration,
		request_id,
	)


func _play_loop_se_channel(
	channel_id: String,
	asset: String,
	volume: float,
	resume_position: float,
	stream: AudioStream,
	fade_duration: float,
	request_id: int,
) -> bool:
	if stream == null:
		return false
	var channel: Dictionary = _loop_se_channels.get(channel_id, {})
	var repaired_same_target := false
	if not channel.is_empty():
		var target_is_same := (
			bool(channel.get("target_active", false))
			and String(channel.get("target_asset", "")) == asset
			and float(channel.get("target_volume", -1.0)) == volume
		)
		if target_is_same:
			var active_receipt: Dictionary = channel.get("receipt", {})
			if StringName(active_receipt.get("action", &"")) == &"play":
				# The previous exact owner reaches its authored endpoint before this
				# positive batch observes the now-stable projection as synchronous.
				_complete_loop_se_receipt(channel_id, active_receipt)
				channel = _loop_se_channels.get(channel_id, {})
			if _loop_se_channel_is_live_aligned(channel, asset, volume):
				return true
			# Canonical equality alone is not enough: repair a stopped player or
			# otherwise stale projection using the stream preflighted for this batch.
			var current_voice: Dictionary = channel.get("current", {})
			var current_player: AudioStreamPlayer = current_voice.get("player")
			if current_player != null and is_instance_valid(current_player):
				resume_position = maxf(current_player.get_playback_position(), 0.0)
			_retire_loop_se_transition(channel_id, channel, &"superseded")
			_stop_loop_se_voice(channel.get("current", {}))
			_stop_loop_se_voice(channel.get("outgoing", {}))
			channel["current"] = {}
			channel["outgoing"] = {}
			repaired_same_target = true
		if not repaired_same_target:
			_retire_loop_se_transition(channel_id, channel, &"superseded")
		if not SignalBus.is_current_loop_se_operation_valid():
			return false
	else:
		channel = _new_loop_se_channel()
		_loop_se_channels[channel_id] = channel

	var current: Dictionary = channel.get("current", {})
	var same_asset := (
		not current.is_empty()
		and String(current.get("asset", "")) == asset
	)
	channel["target_active"] = true
	channel["target_asset"] = asset
	channel["target_volume"] = volume
	if same_asset:
		# Volume-only authored work keeps the exact player and playback cursor.
		# Any older crossfade outgoing voice was already retired above.
		if fade_duration <= 0.0:
			_set_loop_se_voice_level(volume, current)
			return true
		var receipt := _start_loop_se_receipt(
			channel_id, channel, request_id, &"play")
		if not _loop_se_receipt_is_current(channel_id, channel, receipt):
			return SignalBus.is_current_loop_se_operation_valid()
		var tween := create_tween()
		channel["tween"] = tween
		tween.tween_method(
			_set_loop_se_voice_level.bind(current),
			float(current.get("level", 0.0)),
			volume,
			fade_duration,
		)
		tween.finished.connect(
			_complete_loop_se_receipt.bind(channel_id, receipt), CONNECT_ONE_SHOT)
		return true

	var new_voice := _create_loop_se_voice(
		stream, asset, resume_position, 0.0 if fade_duration > 0.0 else volume)
	if new_voice.is_empty():
		return false
	channel["current"] = new_voice
	channel["outgoing"] = current
	if fade_duration <= 0.0:
		_stop_loop_se_voice(current)
		channel["outgoing"] = {}
		_set_loop_se_voice_level(volume, new_voice)
		return true
	var receipt := _start_loop_se_receipt(
		channel_id, channel, request_id, &"play")
	if not _loop_se_receipt_is_current(channel_id, channel, receipt):
		return SignalBus.is_current_loop_se_operation_valid()
	var tween := create_tween().set_parallel(true)
	channel["tween"] = tween
	tween.tween_method(
		_set_loop_se_voice_level.bind(new_voice),
		float(new_voice.get("level", 0.0)),
		volume,
		fade_duration,
	)
	if not current.is_empty():
		tween.tween_method(
			_set_loop_se_voice_level.bind(current),
			float(current.get("level", 0.0)),
			0.0,
			fade_duration,
		)
	tween.chain().tween_callback(
		_complete_loop_se_receipt.bind(channel_id, receipt))
	return true


func _stop_loop_se_channel(
	channel_id: String,
	fade_duration: float,
	request_id: int,
) -> bool:
	var channel: Dictionary = _loop_se_channels.get(channel_id, {})
	if channel.is_empty():
		return true
	if not bool(channel.get("target_active", false)):
		var active_receipt: Dictionary = channel.get("receipt", {})
		if StringName(active_receipt.get("action", &"")) == &"stop":
			# A repeated stop completes the old exact owner at the shared stopped
			# endpoint; this positive batch then needs no new Tween or receipt.
			_complete_loop_se_receipt(channel_id, active_receipt)
			return true
		_retire_loop_se_transition(channel_id, channel, &"superseded")
		_stop_loop_se_voice(channel.get("current", {}))
		_stop_loop_se_voice(channel.get("outgoing", {}))
		_loop_se_channels.erase(channel_id)
		return true
	_retire_loop_se_transition(channel_id, channel, &"superseded")
	if not SignalBus.is_current_loop_se_operation_valid():
		return false
	channel["target_active"] = false
	channel["target_asset"] = ""
	channel["target_volume"] = 1.0
	var current: Dictionary = channel.get("current", {})
	if current.is_empty() or fade_duration <= 0.0:
		_stop_loop_se_voice(current)
		_loop_se_channels.erase(channel_id)
		return true
	var receipt := _start_loop_se_receipt(
		channel_id, channel, request_id, &"stop")
	if not _loop_se_receipt_is_current(channel_id, channel, receipt):
		return SignalBus.is_current_loop_se_operation_valid()
	var tween := create_tween()
	channel["tween"] = tween
	tween.tween_method(
		_set_loop_se_voice_level.bind(current),
		float(current.get("level", 0.0)),
		0.0,
		fade_duration,
	)
	tween.finished.connect(
		_complete_loop_se_receipt.bind(channel_id, receipt), CONNECT_ONE_SHOT)
	return true


func _new_loop_se_channel() -> Dictionary:
	return {
		"current": {},
		"outgoing": {},
		"receipt": {},
		"target_active": false,
		"target_asset": "",
		"target_volume": 1.0,
		"tween": null,
	}


func _loop_se_channel_is_live_aligned(
	channel: Dictionary,
	asset: String,
	volume: float,
) -> bool:
	if (
		channel.is_empty()
		or not bool(channel.get("target_active", false))
		or String(channel.get("target_asset", "")) != asset
		or float(channel.get("target_volume", -1.0)) != volume
		or not (channel.get("receipt", {}) as Dictionary).is_empty()
		or not (channel.get("outgoing", {}) as Dictionary).is_empty()
		or channel.get("tween") != null
	):
		return false
	var current: Dictionary = channel.get("current", {})
	if (
		current.is_empty()
		or String(current.get("asset", "")) != asset
		or not is_equal_approx(float(current.get("level", -1.0)), volume)
	):
		return false
	var player: AudioStreamPlayer = current.get("player")
	return (
		player != null
		and is_instance_valid(player)
		and player.playing
		and player.stream != null
	)


func _create_loop_se_voice(
	stream: AudioStream,
	asset: String,
	resume_position: float,
	level: float,
) -> Dictionary:
	if _audio_admission_is_closed() or stream == null:
		return {}
	var player := AudioStreamPlayer.new()
	player.bus = "Master"
	player.stream = stream
	add_child(player)
	var voice := {
		"asset": asset,
		"level": level,
		"player": player,
	}
	_set_loop_se_voice_level(level, voice)
	player.play(_normalize_loop_se_position(stream, resume_position))
	return voice


func _set_loop_se_voice_level(level: float, voice: Dictionary) -> void:
	voice["level"] = clampf(level, 0.0, 1.0)
	var player: AudioStreamPlayer = voice.get("player")
	if player == null or not is_instance_valid(player):
		return
	player.volume_db = _to_db(
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("se_volume", 1.0)
		* float(voice["level"])
	)


func _apply_loop_se_volumes() -> void:
	for channel_value: Variant in _loop_se_channels.values():
		var channel: Dictionary = channel_value
		for voice_key: String in ["current", "outgoing"]:
			var voice: Dictionary = channel.get(voice_key, {})
			if not voice.is_empty():
				_set_loop_se_voice_level(float(voice.get("level", 0.0)), voice)


func _start_loop_se_receipt(
	channel_id: String,
	channel: Dictionary,
	request_id: int,
	action: StringName,
) -> Dictionary:
	var receipt := {
		"action": action,
		"generation": _loop_se_generation,
		"operation_request_id": request_id,
		"token": _next_loop_se_token,
	}
	_next_loop_se_token += 1
	channel["receipt"] = receipt
	SignalBus.loop_se_transition_receipt_started.emit(
		get_instance_id(),
		channel_id,
		int(receipt["token"]),
		request_id,
		int(receipt["generation"]),
	)
	return receipt


func _complete_loop_se_receipt(channel_id: String, receipt: Dictionary) -> void:
	var channel: Dictionary = _loop_se_channels.get(channel_id, {})
	if not _loop_se_receipt_is_current(channel_id, channel, receipt):
		return
	var tween: Tween = channel.get("tween")
	channel["tween"] = null
	if tween != null and tween.is_valid():
		tween.kill()
	var action := StringName(receipt.get("action", &""))
	if action == &"stop":
		_stop_loop_se_voice(channel.get("current", {}))
		_stop_loop_se_voice(channel.get("outgoing", {}))
		channel["current"] = {}
		channel["outgoing"] = {}
		_loop_se_channels.erase(channel_id)
	else:
		var current: Dictionary = channel.get("current", {})
		_set_loop_se_voice_level(
			float(channel.get("target_volume", 1.0)), current)
		_stop_loop_se_voice(channel.get("outgoing", {}))
		channel["outgoing"] = {}
	_emit_loop_se_terminal(channel, channel_id, receipt, &"completed")


func _retire_loop_se_transition(
	channel_id: String,
	channel: Dictionary,
	outcome: StringName,
) -> void:
	var tween: Tween = channel.get("tween")
	channel["tween"] = null
	if tween != null and tween.is_valid():
		tween.kill()
	# Only the canonical incoming survives a superseded crossfade. This retires
	# an older outgoing voice before a replacement can allocate another player.
	_stop_loop_se_voice(channel.get("outgoing", {}))
	channel["outgoing"] = {}
	var receipt: Dictionary = channel.get("receipt", {})
	if not receipt.is_empty():
		_emit_loop_se_terminal(channel, channel_id, receipt, outcome)


func _emit_loop_se_terminal(
	channel: Dictionary,
	channel_id: String,
	receipt: Dictionary,
	outcome: StringName,
) -> void:
	if channel.get("receipt", {}) != receipt:
		return
	channel["receipt"] = {}
	SignalBus.loop_se_transition_terminal.emit(
		get_instance_id(),
		channel_id,
		int(receipt.get("token", 0)),
		int(receipt.get("operation_request_id", 0)),
		int(receipt.get("generation", 0)),
		outcome,
	)


func _loop_se_receipt_is_current(
	channel_id: String,
	channel: Dictionary,
	receipt: Dictionary,
) -> bool:
	return (
		not channel.is_empty()
		and is_same(_loop_se_channels.get(channel_id), channel)
		and not receipt.is_empty()
		and channel.get("receipt", {}) == receipt
		and int(receipt.get("generation", -1)) == _loop_se_generation
	)


func _on_loop_se_transition_receipts_finish_requested(records: Array) -> void:
	for record_value: Variant in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if int(record.get("presenter_instance_id", 0)) != get_instance_id():
			continue
		var channel_id := String(record.get("channel_id", ""))
		var channel: Dictionary = _loop_se_channels.get(channel_id, {})
		var receipt: Dictionary = channel.get("receipt", {})
		if (
			int(receipt.get("token", 0)) != int(record.get("token", -1))
			or int(receipt.get("operation_request_id", 0))
				!= int(record.get("operation_request_id", -1))
			or int(receipt.get("generation", 0))
				!= int(record.get("generation", -1))
		):
			continue
		_complete_loop_se_receipt(channel_id, receipt)


func _on_loop_se_projection_reset_requested(epoch: int) -> void:
	if _loop_se_capability == null or epoch != SignalBus.current_loop_se_epoch():
		return
	_loop_se_generation += 1
	var channels := _loop_se_channels.duplicate()
	_loop_se_channels.clear()
	for channel_id_value: Variant in channels:
		var channel_id := String(channel_id_value)
		var channel: Dictionary = channels[channel_id_value]
		_retire_loop_se_transition(channel_id, channel, &"cancelled")
		_stop_loop_se_voice(channel.get("current", {}))
		_stop_loop_se_voice(channel.get("outgoing", {}))
	_loop_se_validation_cache.clear()


func _on_loop_se_state_apply_requested(
	channels: Dictionary,
	generation: int,
) -> void:
	if (
		_loop_se_capability == null
		or generation != SignalBus.current_loop_se_epoch()
		or not _loop_se_channels.is_empty()
	):
		return
	_project_loop_se_channels(channels, channels.keys())


func _on_loop_se_targets_state_apply_requested(
	channels: Dictionary,
	targets: Array,
	generation: int,
) -> void:
	if _loop_se_capability == null or generation != SignalBus.current_loop_se_epoch():
		return
	_project_loop_se_channels(channels, targets)


func _project_loop_se_channels(channels: Dictionary, targets: Array) -> void:
	var prepared: Dictionary = {}
	for target_value: Variant in targets:
		var channel_id := String(target_value)
		if not channels.has(channel_id):
			continue
		var state: Dictionary = channels[channel_id]
		var resolved := _resolve_loop_se_stream(String(state.get("asset", "")))
		if resolved.is_empty():
			push_error(
				"AudioPresenter: cannot project loop-SE channel '%s': missing or unsupported asset '%s'"
				% [channel_id, String(state.get("asset", ""))]
			)
			return
		prepared[channel_id] = resolved
	for target_value: Variant in targets:
		var channel_id := String(target_value)
		var old_channel: Dictionary = _loop_se_channels.get(channel_id, {})
		if not old_channel.is_empty():
			_retire_loop_se_transition(channel_id, old_channel, &"cancelled")
			_stop_loop_se_voice(old_channel.get("current", {}))
			_loop_se_channels.erase(channel_id)
		if not channels.has(channel_id):
			continue
		var state: Dictionary = channels[channel_id]
		var resolved: Dictionary = prepared[channel_id]
		var voice := _create_loop_se_voice(
			resolved.get("stream") as AudioStream,
			String(state["asset"]),
			float(state["position"]),
			float(state["volume"]),
		)
		if voice.is_empty():
			continue
		var channel := _new_loop_se_channel()
		channel["current"] = voice
		channel["target_active"] = true
		channel["target_asset"] = String(state["asset"])
		channel["target_volume"] = float(state["volume"])
		_loop_se_channels[channel_id] = channel


func _on_loop_se_state_capture_requested(
	request: LoopSeStateCaptureRequest,
) -> void:
	if _loop_se_capability == null:
		return
	SignalBus.resolve_loop_se_state_capture(
		request, self, _loop_se_capability, _capture_loop_se_positions())


func _capture_loop_se_positions() -> Dictionary:
	var positions: Dictionary = {}
	for channel_id_value: Variant in _loop_se_channels:
		var channel_id := String(channel_id_value)
		var channel: Dictionary = _loop_se_channels[channel_id_value]
		if not bool(channel.get("target_active", false)):
			continue
		var voice: Dictionary = channel.get("current", {})
		var player: AudioStreamPlayer = voice.get("player")
		if player != null and is_instance_valid(player):
			positions[channel_id] = maxf(player.get_playback_position(), 0.0)
	return positions


func _stop_loop_se_voice(voice_value: Variant) -> void:
	if not voice_value is Dictionary:
		return
	var voice: Dictionary = voice_value
	var player: AudioStreamPlayer = voice.get("player")
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream = null
	player.queue_free()


func _resolve_loop_se_stream(asset: String) -> Dictionary:
	var candidate_paths: Array[String] = []
	var extension := asset.get_extension().to_lower()
	if "://" in asset:
		if extension not in ["ogg", "wav"]:
			return {}
		candidate_paths.append(asset)
	else:
		if (
			asset.is_empty()
			or asset.begins_with("/")
			or "\\" in asset
			or ".." in asset.split("/", false)
		):
			return {}
		if extension in ["ogg", "wav"]:
			candidate_paths.append(StellaRuntime.se_path.path_join(asset))
		elif extension.is_empty():
			candidate_paths.append(StellaRuntime.se_path.path_join("%s.ogg" % asset))
			candidate_paths.append(StellaRuntime.se_path.path_join("%s.wav" % asset))
		else:
			return {}
	for path: String in candidate_paths:
		if not ResourceLoader.exists(path):
			continue
		var loaded := ResourceLoader.load(path)
		var prepared := _duplicate_loop_se_stream(loaded)
		if prepared != null:
			return {"path": path, "stream": prepared}
	return {}


func _duplicate_loop_se_stream(source: Resource) -> AudioStream:
	if source is AudioStreamOggVorbis:
		var stream := (source as AudioStreamOggVorbis).duplicate(true) as AudioStreamOggVorbis
		stream.loop = true
		return stream
	if source is AudioStreamWAV:
		var stream := (source as AudioStreamWAV).duplicate(true) as AudioStreamWAV
		if stream.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if stream.loop_end <= stream.loop_begin:
			stream.loop_begin = 0
			stream.loop_end = maxi(
				int(round(stream.get_length() * float(stream.mix_rate))), 1)
		return stream
	return null


func _normalize_loop_se_position(stream: AudioStream, position: float) -> float:
	var length := stream.get_length() if stream != null else 0.0
	if length <= 0.0:
		return 0.0
	return fposmod(maxf(position, 0.0), length)


# ─── Voice ───

func _create_voice_dsp_bus() -> bool:
	if not _voice_dsp_bus_name.is_empty():
		return AudioServer.get_bus_index(_voice_dsp_bus_name) >= 0
	var initial_bus := _stage_voice_dsp_chain(
		[], {}, _get_voice_target_db_for_character(""))
	if initial_bus.is_empty():
		return false
	_voice_dsp_bus_name = initial_bus
	return true


func _stage_voice_dsp_chain(
	effects_value: Variant,
	source: Dictionary,
	volume_db: float,
	layer_id: String = "",
) -> StringName:
	if not effects_value is Array:
		_voice_dsp_error(source, "prepared effect chain is malformed", layer_id)
		return &""
	var effects: Array = effects_value
	for effect_value: Variant in effects:
		if not effect_value is AudioEffect:
			_voice_dsp_error(
				source, "prepared effect is not an AudioEffect", layer_id)
			return &""

	# The detached bus is not reachable from the live voice player. Complete
	# installation and exact effect-count validation happen before replacement.
	_voice_dsp_bus_serial += 1
	var requested_name := StringName(
		"__stella_voice_dsp_%d_%d"
			% [get_instance_id(), _voice_dsp_bus_serial])
	if AudioServer.get_bus_index(requested_name) >= 0:
		_voice_dsp_error(
			source, "private staging bus identity is ambiguous", layer_id)
		return &""
	var previous_count := AudioServer.bus_count
	AudioServer.add_bus(previous_count)
	if AudioServer.bus_count != previous_count + 1:
		_voice_dsp_error(
			source, "private staging bus could not be allocated", layer_id)
		return &""
	AudioServer.set_bus_name(previous_count, requested_name)
	AudioServer.set_bus_send(previous_count, &"Master")
	AudioServer.set_bus_volume_db(previous_count, volume_db)
	var resolved_index := AudioServer.get_bus_index(requested_name)
	if resolved_index != previous_count:
		AudioServer.remove_bus(previous_count)
		_voice_dsp_error(
			source, "private staging bus identity is ambiguous", layer_id)
		return &""
	for effect_value: Variant in effects:
		AudioServer.add_bus_effect(
			resolved_index, effect_value as AudioEffect)
	if AudioServer.get_bus_effect_count(resolved_index) != effects.size():
		AudioServer.remove_bus(resolved_index)
		_voice_dsp_error(
			source, "complete private DSP chain could not be staged", layer_id)
		return &""
	return requested_name


func _set_voice_dsp_bus_volume(bus_name: StringName, volume_db: float) -> bool:
	if bus_name.is_empty():
		return false
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return false
	AudioServer.set_bus_volume_db(bus_index, volume_db)
	return true


func _release_voice_dsp_bus_named(bus_name: StringName) -> void:
	if bus_name.is_empty():
		return
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index >= 0:
		AudioServer.remove_bus(bus_index)


func _release_voice_dsp_bus() -> void:
	if _voice_dsp_bus_name.is_empty():
		return
	_release_voice_dsp_bus_named(_voice_dsp_bus_name)
	_voice_dsp_bus_name = &""


func _prepare_voice_dsp_chain(
	preset: String,
	source: Dictionary,
	layer_id: String = "",
) -> Dictionary:
	if preset.is_empty():
		return {"effects": [], "tail_seconds": 0.0}
	if not VoiceDspChainDefinition.is_logical_preset_id(preset):
		_voice_dsp_error(source, "preset id is not a Stella logical id", layer_id)
		return {}
	var candidate_paths := [
		StellaRuntime.voice_dsp_path.path_join("%s.tres" % preset),
		StellaRuntime.voice_dsp_path.path_join("%s.res" % preset),
	]
	var loaded: Resource
	for path: String in candidate_paths:
		if ResourceLoader.exists(path):
			loaded = ResourceLoader.load(path)
			break
	if not loaded is VoiceDspChainDefinition:
		_voice_dsp_error(
			source,
			"preset '%s' is missing or is not a VoiceDspChainDefinition"
				% preset,
			layer_id,
		)
		return {}
	var chain := (loaded as VoiceDspChainDefinition).duplicate(
		true) as VoiceDspChainDefinition
	if chain == null:
		_voice_dsp_error(
			source, "preset '%s' could not be detached" % preset, layer_id)
		return {}
	var errors := chain.validation_errors()
	if not errors.is_empty():
		_voice_dsp_error(
			source,
			"preset '%s' is invalid: %s" % [preset, "; ".join(errors)],
			layer_id,
		)
		return {}
	var native_effects: Array[AudioEffect] = []
	for effect_value: VoiceDspEffectDefinition in chain.effects:
		if effect_value is VoiceDspBandPassEffect:
			if not _append_band_pass_effects(
				native_effects, effect_value as VoiceDspBandPassEffect):
				_voice_dsp_error(
					source, "Godot band-pass primitives are unavailable", layer_id)
				return {}
		elif effect_value is VoiceDspDelayEffect:
			if not _append_delay_effect(
				native_effects, effect_value as VoiceDspDelayEffect):
				_voice_dsp_error(
					source, "Godot delay primitive is unavailable", layer_id)
				return {}
		else:
			_voice_dsp_error(
				source, "preset contains an unsupported primitive", layer_id)
			return {}
	return {
		"effects": native_effects,
		"tail_seconds": chain.tail_seconds,
	}


func _append_band_pass_effects(
	output: Array[AudioEffect],
	definition: VoiceDspBandPassEffect,
) -> bool:
	if (
		not ClassDB.class_exists("AudioEffectHighPassFilter")
		or not ClassDB.class_exists("AudioEffectLowPassFilter")
	):
		return false
	var lower := definition.center_hz - definition.bandwidth_hz * 0.5
	var upper := definition.center_hz + definition.bandwidth_hz * 0.5
	var high_pass := AudioEffectHighPassFilter.new()
	high_pass.cutoff_hz = lower
	high_pass.db = definition.order - 1 as AudioEffectFilter.FilterDB
	high_pass.resonance = 0.5
	var low_pass := AudioEffectLowPassFilter.new()
	low_pass.cutoff_hz = upper
	low_pass.db = definition.order - 1 as AudioEffectFilter.FilterDB
	low_pass.resonance = 0.5
	output.append(high_pass)
	output.append(low_pass)
	return true


func _append_delay_effect(
	output: Array[AudioEffect],
	definition: VoiceDspDelayEffect,
) -> bool:
	if not ClassDB.class_exists("AudioEffectDelay"):
		return false
	var delay := AudioEffectDelay.new()
	delay.dry = 1.0
	delay.tap1_active = definition.mix > 0.0
	delay.tap1_delay_ms = definition.time_ms
	delay.tap1_level_db = (
		linear_to_db(definition.mix) if definition.mix > 0.0 else -60.0)
	delay.tap1_pan = 0.0
	delay.tap2_active = false
	delay.feedback_active = definition.feedback > 0.0
	delay.feedback_delay_ms = definition.time_ms
	delay.feedback_level_db = (
		linear_to_db(definition.feedback)
		if definition.feedback > 0.0
		else -60.0
	)
	delay.feedback_lowpass = 16000.0
	output.append(delay)
	return true


func _clear_voice_dsp_chain() -> void:
	_clear_voice_dsp_chain_named(_voice_dsp_bus_name)


func _clear_voice_dsp_chain_named(bus_name: StringName) -> void:
	if bus_name.is_empty():
		return
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	for effect_index in range(
		AudioServer.get_bus_effect_count(bus_index) - 1, -1, -1):
		AudioServer.remove_bus_effect(bus_index, effect_index)


func _voice_dsp_error(
	source: Dictionary,
	detail: String,
	layer_id: String = "",
) -> void:
	var source_path := String(source.get("source_path", "<runtime>"))
	if source_path.is_empty():
		source_path = "<runtime>"
	var line := int(source.get("line", 0))
	var location := source_path
	if line > 0:
		location = "%s:%d" % [source_path, line]
	if layer_id.is_empty():
		push_error("AudioPresenter: voice DSP %s at %s" % [detail, location])
	else:
		push_error(
			"AudioPresenter: voice layer '%s' DSP %s at %s"
				% [layer_id, detail, location])

func _on_voice_playback_requested(request: VoicePlaybackRequest) -> void:
	if not SignalBus.voice_playback_request_is_pending(request):
		return
	if _audio_admission_is_closed():
		SignalBus.resolve_voice_playback_request(request, false)
		return
	if not request.is_current():
		SignalBus.resolve_voice_playback_request(request, false)
		return
	var staged_layers: Array = []
	for layer_value: Variant in request.get_layers():
		var layer: Dictionary = layer_value
		var asset := String(layer.get("asset", ""))
		var character := String(layer.get("character", ""))
		var dsp := String(layer.get("dsp", ""))
		var source: Dictionary = layer.get("source", {})
		var stream := _load_audio(StellaRuntime.voice_path, asset, ["ogg", "wav"])
		if stream == null:
			_voice_layer_error(source, String(layer.get("id", "")),
				"asset '%s' could not be resolved" % asset)
			_release_staged_voice_layers(staged_layers)
			SignalBus.resolve_voice_playback_request(request, false)
			return
		var layer_id := String(layer.get("id", ""))
		var prepared_dsp := _prepare_voice_dsp_chain(dsp, source, layer_id)
		if not dsp.is_empty() and prepared_dsp.is_empty():
			_release_staged_voice_layers(staged_layers)
			SignalBus.resolve_voice_playback_request(request, false)
			return
		var prepared_effects: Array = prepared_dsp.get("effects", [])
		var staged_bus := _stage_voice_dsp_chain(
			prepared_effects,
			source,
			_get_voice_target_db_for_character(character),
			layer_id,
		)
		if staged_bus.is_empty():
			_release_staged_voice_layers(staged_layers)
			SignalBus.resolve_voice_playback_request(request, false)
			return
		staged_layers.append({
			"id": layer_id,
			"asset": asset,
			"character": character,
			"dsp": dsp,
			"source": source.duplicate(true),
			"stream": stream,
			"effects": prepared_effects,
			"bus_name": staged_bus,
			"tail_seconds": float(prepared_dsp.get("tail_seconds", 0.0)),
		})
		if not request.is_current():
			_release_staged_voice_layers(staged_layers)
			SignalBus.resolve_voice_playback_request(request, false)
			return

	# Every stream and complete detached chain, including private staging buses,
	# validate before the previous voice is touched. A malformed or unavailable
	# member can never interrupt a valid live group or partially start siblings.
	# Physical lifecycle ownership is AudioPresenter-local. Dialogue ownership
	# decides whether this request may start, but later advance/hide transitions
	# must not make its legitimate physical FINISH look stale to low-level users.
	_voice_lifecycle_revision += 1
	var request_revision := _voice_lifecycle_revision

	# Retire the current token before publishing FINISHED. A listener may start a
	# replacement synchronously, and this outer request must not clear its state.
	if _voice_playback_token >= 0:
		_retire_active_voice(request_revision)

	# Stopping the previous clip is a public reentrancy boundary. If it SHOWed a
	# replacement, reject this retired request without touching replacement audio.
	if request_revision != _voice_lifecycle_revision \
		or not request.is_current():
		_release_staged_voice_layers(staged_layers)
		SignalBus.resolve_voice_playback_request(request, false)
		return

	# FINISHED is a synchronous public reentrancy boundary. Revalidate this exact
	# detached buses before consuming the request or replacing the active group.
	for staged_value: Variant in staged_layers:
		var staged: Dictionary = staged_value
		var staged_bus := StringName(staged.get("bus_name", &""))
		var staged_bus_index := AudioServer.get_bus_index(staged_bus)
		var staged_effects: Array = staged.get("effects", [])
		if (
			staged_bus_index < 0
			or AudioServer.get_bus_effect_count(staged_bus_index)
				!= staged_effects.size()
			or not _set_voice_dsp_bus_volume(
				staged_bus,
				_get_voice_target_db_for_character(
					String(staged.get("character", ""))))
		):
			_release_staged_voice_layers(staged_layers)
			_voice_layer_error(
				staged.get("source", {}), String(staged.get("id", "")),
				"private staged DSP chain lost authority")
			SignalBus.resolve_voice_playback_request(request, false)
			return
	# Settings never participate in resource validity. Snapshot physical projection
	# only after every synchronous retirement/reentry and final detached-chain
	# authority check, immediately before committing this accepted request.
	for staged_value: Variant in staged_layers:
		var staged: Dictionary = staged_value
		staged["enabled"] = _is_voice_character_enabled(
			String(staged.get("character", "")))

	var playback_token := SignalBus.resolve_voice_playback_request(request, true)
	if playback_token < 0:
		_release_staged_voice_layers(staged_layers)
		return
	var previous_bus := _voice_dsp_bus_name
	_voice_playback_token = playback_token
	_voice_playback_revision = request_revision
	_voice_request_owned = request.has_owner_validator()
	_voice_group_raw_eligible = false
	_voice_started_advance_serial = SignalBus.current_advance_dispatch_serial()
	var primary_claimed := false
	for staged_value: Variant in staged_layers:
		var staged: Dictionary = staged_value
		var staged_bus := StringName(staged.get("bus_name", &""))
		if not bool(staged.get("enabled", true)):
			_release_voice_dsp_bus_named(staged_bus)
			continue
		var layer_id := String(staged.get("id", ""))
		var player: AudioStreamPlayer
		var timer: Timer
		var primary := not primary_claimed
		if primary:
			primary_claimed = true
			player = _voice_player
			timer = _voice_dsp_tail_timer
			_voice_dsp_bus_name = staged_bus
			_current_voice_character = String(staged.get("character", ""))
			_voice_dsp_tail_seconds = float(staged.get("tail_seconds", 0.0))
			_voice_dsp_active = not String(staged.get("dsp", "")).is_empty()
		else:
			player = AudioStreamPlayer.new()
			timer = Timer.new()
			timer.one_shot = true
			add_child(player)
			add_child(timer)
			player.finished.connect(_on_voice_layer_stream_finished.bind(
				request_revision, playback_token, layer_id))
			timer.timeout.connect(_on_voice_layer_tail_timeout.bind(
				request_revision, playback_token, layer_id))
		player.bus = staged_bus
		player.volume_db = 0.0
		player.stream = staged.get("stream") as AudioStream
		_voice_layers[layer_id] = {
			"id": layer_id,
			"asset": String(staged.get("asset", "")),
			"character": String(staged.get("character", "")),
			"dsp": String(staged.get("dsp", "")),
			"source": (staged.get("source", {}) as Dictionary).duplicate(true),
			"bus_name": staged_bus,
			"tail_seconds": float(staged.get("tail_seconds", 0.0)),
			"player": player,
			"timer": timer,
			"primary": primary,
		}
		_voice_layer_order.append(layer_id)
	_voice_dsp_active = false
	for active_value: Variant in _voice_layers.values():
		if (
			active_value is Dictionary
			and not String((active_value as Dictionary).get("dsp", "")).is_empty()
		):
			_voice_dsp_active = true
			break
	if primary_claimed and previous_bus != _voice_dsp_bus_name:
		_release_voice_dsp_bus_named(previous_bus)
	if not primary_claimed:
		# Every disabled layer was still resource/DSP-preflighted. The accepted
		# group has no physical completion members and settles synchronously.
		_finish_voice_group(request_revision, playback_token)
		return
	_voice_group_raw_eligible = request.is_single_layer()
	for layer_id in _voice_layer_order:
		var layer: Dictionary = _voice_layers[layer_id]
		(layer.get("player") as AudioStreamPlayer).play()
	for layer_id in _voice_layer_order:
		if not _voice_playback_event_is_current(request_revision, playback_token):
			return
		var layer: Dictionary = _voice_layers[layer_id]
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.started(
			String(layer.get("character", "")),
			String(layer.get("asset", "")),
			playback_token,
			_voice_playback_event_is_current.bind(request_revision, playback_token),
			false,
			layer_id,
			_voice_group_raw_eligible,
		))


func _on_voice_playback_finished():
	if _voice_playback_token < 0 or _voice_layer_order.is_empty():
		return
	_on_voice_layer_stream_finished(
		_voice_playback_revision, _voice_playback_token, _voice_layer_order[0])


func _on_voice_dsp_tail_timeout() -> void:
	if _voice_playback_token < 0 or _voice_layer_order.is_empty():
		return
	_on_voice_layer_tail_timeout(
		_voice_playback_revision, _voice_playback_token, _voice_layer_order[0])


func _on_voice_layer_stream_finished(
	revision: int,
	playback_token: int,
	layer_id: String,
) -> void:
	if not _voice_layer_is_current(revision, playback_token, layer_id):
		return
	var layer: Dictionary = _voice_layers[layer_id]
	var tail_seconds := float(layer.get("tail_seconds", 0.0))
	if tail_seconds > 0.0:
		var timer := layer.get("timer") as Timer
		if timer != null:
			timer.start(tail_seconds)
		return
	_finish_voice_layer(revision, playback_token, layer_id)


func _on_voice_layer_tail_timeout(
	revision: int,
	playback_token: int,
	layer_id: String,
) -> void:
	if _voice_layer_is_current(revision, playback_token, layer_id):
		_finish_voice_layer(revision, playback_token, layer_id)


func _on_advance_requested():
	if SignalBus.current_advance_dispatch_was_claimed():
		return
	if _voice_playback_token >= 0:
		var continue_on_advance = StellaRuntime.get_setting("voice_continue_on_advance")
		# The advance pre-dispatch hook can finalize a typing line, whose public
		# FINISHED listener synchronously SHOWs and starts the replacement voice.
		# That replacement belongs to this dispatch serial and must survive the old
		# advance signal's ordinary listener tail.
		if (not continue_on_advance
			and _voice_started_advance_serial
				< SignalBus.current_advance_dispatch_serial()):
			_retire_active_voice(_voice_lifecycle_revision)


func _on_voice_lifecycle_boundary() -> void:
	if _voice_playback_token < 0:
		return
	# Unowned programmatic playback is independent from dialogue UI visibility.
	# Preserve only its established dry physical lifecycle. A processed playback
	# cannot continue the same token after its selected chain is removed.
	if not _voice_request_owned and _active_voice_group_is_dry_and_playing():
		return
	_voice_lifecycle_revision += 1
	_retire_active_voice(_voice_lifecycle_revision)


func _retire_active_voice(finished_revision: int) -> void:
	var finished_token := _voice_playback_token
	var emit_raw_lifecycle := _voice_group_raw_eligible
	_retire_voice_group_projection()
	_voice_playback_token = -1
	_voice_playback_revision = -1
	_voice_started_advance_serial = -1
	_voice_dsp_tail_seconds = 0.0
	_voice_dsp_active = false
	_voice_request_owned = false
	_voice_group_raw_eligible = false
	if finished_token >= 0:
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
			finished_token,
			_voice_finished_event_is_current.bind(finished_revision),
			false,
			emit_raw_lifecycle,
		))


func _finish_voice_playback(revision: int, playback_token: int) -> void:
	if _voice_playback_event_is_current(revision, playback_token):
		_retire_voice_group_projection()
		_finish_voice_group(revision, playback_token)


func _cancel_voice_dsp_tail() -> void:
	for layer_value: Variant in _voice_layers.values():
		if layer_value is Dictionary:
			var timer := (layer_value as Dictionary).get("timer") as Timer
			if timer != null:
				timer.stop()
	if _voice_dsp_tail_timer != null:
		_voice_dsp_tail_timer.stop()


func _release_staged_voice_layers(staged_layers: Array) -> void:
	for layer_value: Variant in staged_layers:
		if layer_value is Dictionary:
			_release_voice_dsp_bus_named(StringName(
				(layer_value as Dictionary).get("bus_name", &"")))


func _retire_voice_group_projection() -> void:
	for layer_id in _voice_layer_order.duplicate():
		var layer_value: Variant = _voice_layers.get(layer_id)
		if layer_value is Dictionary:
			_release_voice_layer_projection(layer_value as Dictionary)
	_voice_layers.clear()
	_voice_layer_order.clear()


func _release_voice_layer_projection(layer: Dictionary) -> void:
	var player := layer.get("player") as AudioStreamPlayer
	var timer := layer.get("timer") as Timer
	var primary := bool(layer.get("primary", false))
	if timer != null:
		timer.stop()
	if player != null:
		_retire_fixed_audio_player(player)
	var bus_name := StringName(layer.get("bus_name", &""))
	_clear_voice_dsp_chain_named(bus_name)
	if not primary:
		_release_voice_dsp_bus_named(bus_name)
		if player != null:
			player.queue_free()
		if timer != null:
			timer.queue_free()


func _finish_voice_layer(
	revision: int,
	playback_token: int,
	layer_id: String,
) -> void:
	if not _voice_layer_is_current(revision, playback_token, layer_id):
		return
	var layer: Dictionary = _voice_layers[layer_id]
	_release_voice_layer_projection(layer)
	_voice_layers.erase(layer_id)
	_voice_layer_order.erase(layer_id)
	_voice_dsp_active = false
	for remaining_value: Variant in _voice_layers.values():
		if (
			remaining_value is Dictionary
			and not String((remaining_value as Dictionary).get("dsp", "")).is_empty()
		):
			_voice_dsp_active = true
			break
	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.layer_finished(
		String(layer.get("character", "")),
		String(layer.get("asset", "")),
		playback_token,
		layer_id,
		_voice_playback_event_is_current.bind(revision, playback_token),
	))
	if not _voice_playback_event_is_current(revision, playback_token):
		return
	if _voice_layers.is_empty():
		_finish_voice_group(revision, playback_token)


func _finish_voice_group(revision: int, playback_token: int) -> void:
	if not _voice_playback_event_is_current(revision, playback_token):
		return
	var emit_raw_lifecycle := _voice_group_raw_eligible
	_voice_playback_token = -1
	_voice_playback_revision = -1
	_voice_started_advance_serial = -1
	_voice_dsp_tail_seconds = 0.0
	_voice_dsp_active = false
	_voice_request_owned = false
	_voice_group_raw_eligible = false
	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
		playback_token,
		_voice_finished_event_is_current.bind(revision),
		false,
		emit_raw_lifecycle,
	))


func _voice_layer_is_current(
	revision: int,
	playback_token: int,
	layer_id: String,
) -> bool:
	return (
		_voice_playback_event_is_current(revision, playback_token)
		and _voice_layers.has(layer_id)
	)


func _active_voice_group_is_dry_and_playing() -> bool:
	if _voice_layers.is_empty():
		return false
	for layer_value: Variant in _voice_layers.values():
		if not layer_value is Dictionary:
			return false
		var layer: Dictionary = layer_value
		var player := layer.get("player") as AudioStreamPlayer
		if not String(layer.get("dsp", "")).is_empty() \
			or player == null or not player.playing:
			return false
	return true


func _is_voice_character_enabled(character: String) -> bool:
	var enabled_by_character := StellaRuntime.get_setting("character_voice_enabled")
	return not (
		enabled_by_character is Dictionary
		and not bool((enabled_by_character as Dictionary).get(character, true))
	)


func _voice_layer_error(
	source: Dictionary,
	layer_id: String,
	detail: String,
) -> void:
	var source_path := String(source.get("source_path", "<runtime>"))
	if source_path.is_empty():
		source_path = "<runtime>"
	var line := int(source.get("line", 0))
	var location := source_path
	if line > 0:
		location = "%s:%d" % [source_path, line]
	push_error(
		"AudioPresenter: voice layer '%s' %s at %s"
			% [layer_id, detail, location])


func _voice_playback_event_is_current(
	revision: int,
	playback_token: int,
) -> bool:
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and revision == _voice_lifecycle_revision
		and revision == _voice_playback_revision
		and playback_token == _voice_playback_token
	)


func _voice_finished_event_is_current(revision: int) -> bool:
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and revision == _voice_lifecycle_revision
	)


# ─── Typed presentation-clip system audio ───

func _on_presentation_clip_validate_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		_presentation_clip_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_AUDIO)
	):
		return
	if _audio_admission_is_closed():
		SignalBus.reject_presentation_clip_request(
			request,
			self,
			_presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			"audio presenter is quiescing",
		)
		return
	var definition := _presentation_clip_definition_for(request)
	if definition == null:
		SignalBus.reject_presentation_clip_request(
			request,
			self,
			_presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			"clip definition is unavailable",
		)
		return
	var audio_choice_work_error := definition.bounded_audio_choice_work_error()
	if not audio_choice_work_error.is_empty():
		SignalBus.reject_presentation_clip_request(
			request,
			self,
			_presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			audio_choice_work_error,
		)
		return
	var players: Array[AudioStreamPlayer] = []
	var players_by_cue: Dictionary = {}
	var choice_candidates_by_cue: Dictionary = {}
	for cue_index in range(definition.cues.size()):
		if definition.cues[cue_index] is PresentationClipAudioChoiceCue:
			var choice_cue := (
				definition.cues[cue_index] as PresentationClipAudioChoiceCue)
			var candidate_records: Array = []
			for candidate_index in range(choice_cue.candidates.size()):
				var candidate := choice_cue.candidates[candidate_index]
				var settings_error := _presentation_clip_choice_settings_error(candidate)
				if not settings_error.is_empty():
					_release_detached_clip_players(players)
					SignalBus.reject_presentation_clip_request(
						request,
						self,
						_presentation_clip_participant_capability,
						PresentationClipOperationRequest.ROLE_AUDIO,
						_presentation_clip_choice_diagnostic(
							definition,
							cue_index,
							candidate_index,
							candidate,
							settings_error,
						),
					)
					return
				var stream := _load_audio(
					StellaRuntime.se_path if candidate.character.is_empty()
					else StellaRuntime.voice_path,
					candidate.asset,
					["ogg", "wav", "mp3"],
				)
				if stream == null:
					_release_detached_clip_players(players)
					SignalBus.reject_presentation_clip_request(
						request,
						self,
						_presentation_clip_participant_capability,
						PresentationClipOperationRequest.ROLE_AUDIO,
						_presentation_clip_choice_diagnostic(
							definition,
							cue_index,
							candidate_index,
							candidate,
							"asset '%s' could not be resolved" % candidate.asset,
						),
					)
					return
				candidate_records.append({
					"id": String(candidate.id),
					"asset": candidate.asset,
					"authored_enabled": candidate.authored_enabled,
					"character": candidate.character,
					"stream": stream,
				})
			choice_candidates_by_cue[cue_index] = candidate_records
			continue
		if not definition.cues[cue_index] is PresentationClipAudioCue:
			continue
		var cue := definition.cues[cue_index] as PresentationClipAudioCue
		var stream := _load_audio(
			StellaRuntime.se_path, cue.asset, ["ogg", "wav", "mp3"])
		if stream == null:
			_release_detached_clip_players(players)
			var definition_path := definition.resource_path
			if definition_path.is_empty():
				definition_path = "<embedded PresentationClipDefinition>"
			var provenance := ""
			if (
				not cue.authored_source_path.is_empty()
				and cue.authored_source_line > 0
			):
				provenance = " authored at %s:%d" % [
					cue.authored_source_path, cue.authored_source_line,
				]
			SignalBus.reject_presentation_clip_request(
				request,
				self,
				_presentation_clip_participant_capability,
				PresentationClipOperationRequest.ROLE_AUDIO,
				"%s cues[%d]%s asset '%s' could not be resolved"
					% [definition_path, cue_index, provenance, cue.asset],
			)
			return
		var player := AudioStreamPlayer.new()
		player.name = "PresentationClipAudio%d" % cue_index
		player.bus = &"Master"
		player.stream = stream
		players.append(player)
		players_by_cue[cue_index] = player
	_presentation_clip_prepared[request.get_instance_id()] = {
		"definition": definition,
		"players": players,
		"players_by_cue": players_by_cue,
		"choice_candidates_by_cue": choice_candidates_by_cue,
		"definition_fingerprint": definition.semantic_fingerprint(),
	}
	SignalBus.validate_presentation_clip_request(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _on_presentation_clip_accept_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		_presentation_clip_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_AUDIO)
		or not _presentation_clip_prepared.has(request.get_instance_id())
	):
		return
	SignalBus.accept_presentation_clip_request(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _on_presentation_clip_apply_readiness_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		_presentation_clip_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_AUDIO)
	):
		return
	var plan: Dictionary = _presentation_clip_prepared.get(
		request.get_instance_id(), {})
	if plan.is_empty():
		return
	var definition: PresentationClipDefinition = plan.get("definition")
	if (
		definition == null
		or String(plan.get("definition_fingerprint", ""))
			!= definition.semantic_fingerprint()
	):
		SignalBus.fail_presentation_clip_apply(
			request, self, _presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			"audio definition fingerprint changed before claim",
		)
		return
	for player_value: Variant in plan.get("players", []):
		var player := player_value as AudioStreamPlayer
		if player == null or not is_instance_valid(player) or player.is_inside_tree():
			return
	var choice_validation_error := _presentation_clip_choice_records_error(
		definition, plan.get("choice_candidates_by_cue", {}))
	if not choice_validation_error.is_empty():
		SignalBus.fail_presentation_clip_apply(
			request, self, _presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			choice_validation_error,
		)
		return
	SignalBus.mark_presentation_clip_apply_ready(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _on_presentation_clip_apply_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		_presentation_clip_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_AUDIO)
	):
		return
	var plan: Dictionary = _presentation_clip_prepared.get(
		request.get_instance_id(), {})
	_presentation_clip_prepared.erase(request.get_instance_id())
	if plan.is_empty():
		return
	var definition: PresentationClipDefinition = plan.get("definition")
	if (
		definition == null
		or String(plan.get("definition_fingerprint", ""))
			!= definition.semantic_fingerprint()
	):
		_release_detached_clip_players(plan.get("players", []))
		SignalBus.fail_presentation_clip_apply(
			request, self, _presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			"audio definition fingerprint changed during claim",
		)
		return
	var choice_validation_error := _presentation_clip_choice_records_error(
		definition, plan.get("choice_candidates_by_cue", {}))
	if not choice_validation_error.is_empty():
		_release_detached_clip_players(plan.get("players", []))
		SignalBus.fail_presentation_clip_apply(
			request, self, _presentation_clip_participant_capability,
			PresentationClipOperationRequest.ROLE_AUDIO,
			choice_validation_error,
		)
		return
	var players: Array = plan.get("players", [])
	for player_value: Variant in players:
		add_child(player_value as AudioStreamPlayer)
	_presentation_clip_claimed = {
		"request_id": request.get_request_id(),
		"generation": 0,
		"definition": plan.get("definition"),
		"players": players,
		"players_by_cue": (plan.get("players_by_cue", {}) as Dictionary).duplicate(),
		"choice_candidates_by_cue": (
			(plan.get("choice_candidates_by_cue", {}) as Dictionary).duplicate(true)),
		"choice_players_by_cue": {},
		"definition_fingerprint": plan.get("definition_fingerprint", ""),
	}
	_apply_presentation_clip_record_volumes(_presentation_clip_claimed)
	SignalBus.acknowledge_presentation_clip_apply(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _on_presentation_clip_publish_readiness_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		request == null
		or _presentation_clip_claimed.is_empty()
		or int(_presentation_clip_claimed.get("request_id", 0))
			!= request.get_request_id()
		or String(_presentation_clip_claimed.get("definition_fingerprint", ""))
			!= _presentation_clip_definition_fingerprint(request)
	):
		if request != null and not _presentation_clip_claimed.is_empty():
			SignalBus.fail_presentation_clip_apply(
				request, self, _presentation_clip_participant_capability,
				PresentationClipOperationRequest.ROLE_AUDIO,
				"audio definition fingerprint changed before final commit",
			)
		return
	SignalBus.mark_presentation_clip_publish_ready(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _run_presentation_clip_transaction_phase(
	request: PresentationClipOperationRequest,
	capability: RefCounted,
	phase: StringName,
) -> bool:
	var request_key := request.get_instance_id() if request != null else 0
	if (
		phase == &"abort"
		and request != null
		and capability == _presentation_clip_participant_capability
		and _presentation_clip_audio_transaction_is_current(request_key)
	):
		return _abort_presentation_clip_audio_transaction(request_key)
	if (
		request == null
		or capability == null
		or capability != _presentation_clip_participant_capability
		or not request.is_target(self, PresentationClipOperationRequest.ROLE_AUDIO)
	):
		return false
	match phase:
		&"hold":
			if (
				not _presentation_clip_transaction.is_empty()
				or _presentation_clip_claimed.is_empty()
				or int(_presentation_clip_claimed.get("request_id", 0))
					!= request.get_request_id()
				or String(_presentation_clip_claimed.get(
					"definition_fingerprint", ""))
					!= _presentation_clip_definition_fingerprint(request)
			):
				SignalBus.fail_presentation_clip_apply(
					request, self, _presentation_clip_participant_capability,
					PresentationClipOperationRequest.ROLE_AUDIO,
					"audio sealed definition changed before transaction hold",
				)
				return false
			var choice_plan_result := _presentation_clip_choice_plan_result(
				request, _presentation_clip_claimed)
			if not bool(choice_plan_result.get("ok", false)):
				SignalBus.fail_presentation_clip_apply(
					request, self, _presentation_clip_participant_capability,
					PresentationClipOperationRequest.ROLE_AUDIO,
					String(choice_plan_result.get(
						"error", "audio-choice private plan is invalid")),
				)
				return false
			var choice_plans: Array = choice_plan_result.get("plans", [])
			var choice_authority_held := false
			if not choice_plans.is_empty():
				var authority := StellaRuntime.presentation_clip_audio_choice_authority
				if authority == null or not authority.hold(request_key):
					SignalBus.fail_presentation_clip_apply(
						request, self, _presentation_clip_participant_capability,
						PresentationClipOperationRequest.ROLE_AUDIO,
						"Runtime audio-choice authority could not hold the clip transaction",
					)
					return false
				choice_authority_held = true
			_presentation_clip_transaction = {
				"request_key": request_key,
				"previous": _presentation_clip_audio,
				"committed": false,
				"choice_plans": choice_plans,
				"choice_authority_held": choice_authority_held,
			}
			return true
		&"commit":
			if not _presentation_clip_audio_transaction_is_current(request_key):
				return false
			if bool(_presentation_clip_transaction.get(
				"choice_authority_held", false)):
				var choice_result := (
					StellaRuntime.presentation_clip_audio_choice_authority.commit(
						request_key,
						_presentation_clip_transaction.get("choice_plans", []),
					))
				if not bool(choice_result.get("ok", false)):
					SignalBus.fail_presentation_clip_apply(
						request, self, _presentation_clip_participant_capability,
						PresentationClipOperationRequest.ROLE_AUDIO,
						String(choice_result.get(
							"error", "audio-choice selection failed")),
					)
					return false
				if not _install_selected_presentation_clip_choice_players(
					_presentation_clip_claimed,
					choice_result.get("selections", {}),
				):
					SignalBus.fail_presentation_clip_apply(
						request, self, _presentation_clip_participant_capability,
						PresentationClipOperationRequest.ROLE_AUDIO,
						"sealed audio-choice selection no longer matched its preflight",
					)
					return false
			_presentation_clip_audio = _presentation_clip_claimed
			_presentation_clip_claimed = {}
			_presentation_clip_transaction["committed"] = true
			return true
		&"finalize":
			return (
				_presentation_clip_audio_transaction_is_current(request_key)
				and bool(_presentation_clip_transaction.get("committed", false))
			)
		&"publish":
			if (
				not _presentation_clip_audio_transaction_is_current(request_key)
				or not bool(_presentation_clip_transaction.get("committed", false))
			):
				return false
			return true
		&"complete":
			if (
				not _presentation_clip_audio_transaction_is_current(request_key)
				or not bool(_presentation_clip_transaction.get("committed", false))
			):
				return false
			var previous: Dictionary = _presentation_clip_transaction.get(
				"previous", {})
			if (
				bool(_presentation_clip_transaction.get(
					"choice_authority_held", false))
				and not StellaRuntime.presentation_clip_audio_choice_authority.complete(
					request_key)
			):
				return false
			_presentation_clip_transaction.clear()
			_release_presentation_clip_audio_record(previous)
			return true
		&"abort":
			return _abort_presentation_clip_audio_transaction(request_key)
	return false


func _presentation_clip_definition_for(
	request: PresentationClipOperationRequest,
) -> PresentationClipDefinition:
	return SignalBus.presentation_clip_definition_for(
		request,
		self,
		_presentation_clip_participant_capability,
		PresentationClipOperationRequest.ROLE_AUDIO,
	)


func _presentation_clip_definition_fingerprint(
	request: PresentationClipOperationRequest,
) -> String:
	var definition := _presentation_clip_definition_for(request)
	return definition.semantic_fingerprint() if definition != null else ""


func _presentation_clip_audio_transaction_is_current(request_key: int) -> bool:
	return (
		request_key != 0
		and int(_presentation_clip_transaction.get("request_key", 0)) == request_key
	)


func _presentation_clip_choice_plan_result(
	request: PresentationClipOperationRequest,
	record: Dictionary,
) -> Dictionary:
	var plans: Array = []
	var definition: PresentationClipDefinition = record.get("definition")
	if definition == null:
		return {"ok": false, "plans": [], "error": "choice definition is missing"}
	var candidates_by_cue: Dictionary = record.get(
		"choice_candidates_by_cue", {})
	var choice_ordinals: Array[int] = []
	for cue_index in range(definition.cues.size()):
		if definition.cues[cue_index] is PresentationClipAudioChoiceCue:
			choice_ordinals.append(cue_index)
	if candidates_by_cue.size() != choice_ordinals.size():
		return {
			"ok": false,
			"plans": [],
			"error": "audio-choice private candidate map has the wrong cue count",
		}
	for cue_index: int in choice_ordinals:
		if not candidates_by_cue.has(cue_index):
			return {
				"ok": false,
				"plans": [],
				"error": "audio-choice private candidate map is missing cues[%d]" % cue_index,
			}
		var cue := definition.cues[cue_index] as PresentationClipAudioChoiceCue
		var records_value: Variant = candidates_by_cue[cue_index]
		if not records_value is Array or (records_value as Array).size() != cue.candidates.size():
			return {
				"ok": false,
				"plans": [],
				"error": "audio-choice private candidate count changed for cues[%d]" % cue_index,
			}
		var eligible_ids: Array = []
		for candidate_index in range(cue.candidates.size()):
			var candidate_resource := cue.candidates[candidate_index]
			var candidate_value: Variant = (records_value as Array)[candidate_index]
			if (
				candidate_resource == null
				or not _presentation_clip_choice_record_matches(
					candidate_resource, candidate_value)
			):
				return {
					"ok": false,
					"plans": [],
					"error": _presentation_clip_choice_diagnostic(
						definition, cue_index, candidate_index, candidate_resource,
						"private preflight record changed before commit"),
				}
			var candidate: Dictionary = candidate_value
			var settings_error := _presentation_clip_choice_settings_error(
				candidate_resource)
			if not settings_error.is_empty():
				return {
					"ok": false,
					"plans": [],
					"error": _presentation_clip_choice_diagnostic(
						definition, cue_index, candidate_index, candidate_resource,
						settings_error),
				}
			var character: String = candidate["character"]
			if (
				candidate["authored_enabled"] == true
				and (
					character.is_empty()
					or _is_voice_character_enabled(character)
				)
			):
				eligible_ids.append(candidate["id"])
		plans.append({
			"clip_asset": request.get_asset(),
			"cue_ordinal": cue_index,
			"eligible_ids": eligible_ids,
			"repeat_policy": String(cue.repeat_policy),
		})
	return {"ok": true, "plans": plans, "error": ""}


func _install_selected_presentation_clip_choice_players(
	record: Dictionary,
	selections: Dictionary,
) -> bool:
	var candidates_by_cue: Dictionary = record.get(
		"choice_candidates_by_cue", {})
	var installed: Dictionary = {}
	for cue_index_value: Variant in selections:
		var cue_index := int(cue_index_value)
		var selected_id := String(selections[cue_index_value])
		var selected: Dictionary = {}
		for candidate_value: Variant in candidates_by_cue.get(cue_index, []):
			if (
				candidate_value is Dictionary
				and String((candidate_value as Dictionary).get("id", ""))
					== selected_id
			):
				selected = candidate_value as Dictionary
				break
		if selected.is_empty() or not selected.get("stream") is AudioStream:
			_release_detached_clip_players(record.get("players", []))
			return false
		var player := AudioStreamPlayer.new()
		player.name = "PresentationClipAudioChoice%d" % cue_index
		player.bus = &"Master"
		player.stream = selected.get("stream") as AudioStream
		add_child(player)
		(record.get("players", []) as Array).append(player)
		installed[cue_index] = {
			"id": selected_id,
			"asset": String(selected.get("asset", "")),
			"character": String(selected.get("character", "")),
			"player": player,
			"triggered": false,
		}
	record["choice_players_by_cue"] = installed
	_apply_presentation_clip_record_volumes(record)
	return true


func _release_presentation_clip_choice_player(
	record: Dictionary,
	cue_index: int,
) -> void:
	var choices: Dictionary = record.get("choice_players_by_cue", {})
	var choice_record: Dictionary = choices.get(cue_index, {})
	if choice_record.is_empty():
		return
	choices.erase(cue_index)
	record["choice_players_by_cue"] = choices
	var player := choice_record.get("player") as AudioStreamPlayer
	var players: Array = record.get("players", [])
	players.erase(player)
	_release_detached_clip_players([player])


func _retire_untriggered_disabled_presentation_clip_choices(
	record: Dictionary,
) -> void:
	if record.is_empty():
		return
	var retire_ordinals: Array[int] = []
	for cue_index_value: Variant in (
		record.get("choice_players_by_cue", {}) as Dictionary):
		var choice_record: Dictionary = (
			record.get("choice_players_by_cue", {}) as Dictionary).get(
				cue_index_value, {})
		if bool(choice_record.get("triggered", false)):
			continue
		var character := String(choice_record.get("character", ""))
		if character.is_empty():
			continue
		var enabled_value: Variant = StellaRuntime.get_setting(
			"character_voice_enabled")
		if (
			enabled_value is Dictionary
			and (enabled_value as Dictionary).has(character)
			and (enabled_value as Dictionary)[character] is bool
			and not bool((enabled_value as Dictionary)[character])
		):
			retire_ordinals.append(int(cue_index_value))
	for cue_index: int in retire_ordinals:
		_release_presentation_clip_choice_player(record, cue_index)


func _presentation_clip_choice_records_error(
	definition: PresentationClipDefinition,
	candidates_by_cue_value: Variant,
) -> String:
	if not candidates_by_cue_value is Dictionary:
		return "audio-choice private candidate map must be a Dictionary"
	var candidates_by_cue: Dictionary = candidates_by_cue_value
	var choice_cue_count := 0
	for cue_value: PresentationClipCue in definition.cues:
		if cue_value is PresentationClipAudioChoiceCue:
			choice_cue_count += 1
	if candidates_by_cue.size() != choice_cue_count:
		return "audio-choice private candidate map has the wrong cue count"
	for cue_index in range(definition.cues.size()):
		if not definition.cues[cue_index] is PresentationClipAudioChoiceCue:
			continue
		var cue := definition.cues[cue_index] as PresentationClipAudioChoiceCue
		if not candidates_by_cue.has(cue_index):
			return "audio-choice private candidate map is missing cues[%d]" % cue_index
		var records_value: Variant = candidates_by_cue[cue_index]
		if not records_value is Array or (records_value as Array).size() != cue.candidates.size():
			return "audio-choice private candidate count changed for cues[%d]" % cue_index
		for candidate_index in range(cue.candidates.size()):
			var candidate := cue.candidates[candidate_index]
			if candidate == null:
				return _presentation_clip_choice_diagnostic(
					definition, cue_index, candidate_index, candidate,
					"candidate is null")
			var record_value: Variant = (records_value as Array)[candidate_index]
			if not record_value is Dictionary:
				return _presentation_clip_choice_diagnostic(
					definition, cue_index, candidate_index, candidate,
					"private preflight record is missing")
			if not _presentation_clip_choice_record_matches(candidate, record_value):
				return _presentation_clip_choice_diagnostic(
					definition, cue_index, candidate_index, candidate,
					"private preflight record changed before apply")
			var settings_error := _presentation_clip_choice_settings_error(candidate)
			if not settings_error.is_empty():
				return _presentation_clip_choice_diagnostic(
					definition, cue_index, candidate_index, candidate, settings_error)
	return ""


func _presentation_clip_choice_record_matches(
	candidate: PresentationClipAudioChoiceCandidate,
	record_value: Variant,
) -> bool:
	if candidate == null or not record_value is Dictionary:
		return false
	var record := record_value as Dictionary
	return (
		record.size() == 5
		and record.get("id") is String
		and record["id"] == String(candidate.id)
		and record.get("asset") is String
		and record["asset"] == candidate.asset
		and record.get("authored_enabled") is bool
		and record["authored_enabled"] == candidate.authored_enabled
		and record.get("character") is String
		and record["character"] == candidate.character
		and record.get("stream") is AudioStream
	)


func _presentation_clip_choice_settings_error(
	candidate: PresentationClipAudioChoiceCandidate,
) -> String:
	if candidate == null:
		return "candidate is null"
	var required_volume_keys := ["master_volume"]
	if candidate.character.is_empty():
		required_volume_keys.append("system_se_volume")
	else:
		required_volume_keys.append("voice_volume")
	for key: String in required_volume_keys:
		var value: Variant = StellaRuntime.get_setting(key)
		if not (value is int or value is float) or not is_finite(float(value)):
			return "authoritative setting '%s' must be a finite number" % key
	if candidate.character.is_empty():
		return ""
	var enabled_value: Variant = StellaRuntime.get_setting("character_voice_enabled")
	if not enabled_value is Dictionary:
		return "authoritative setting 'character_voice_enabled' must be a Dictionary"
	var enabled: Dictionary = enabled_value
	if enabled.has(candidate.character) and not enabled[candidate.character] is bool:
		return (
			"authoritative character_voice_enabled['%s'] must be a bool"
			% candidate.character)
	var volumes_value: Variant = StellaRuntime.get_setting("character_voice_volume")
	if not volumes_value is Dictionary:
		return "authoritative setting 'character_voice_volume' must be a Dictionary"
	var volumes: Dictionary = volumes_value
	if volumes.has(candidate.character):
		var volume: Variant = volumes[candidate.character]
		if not (volume is int or volume is float) or not is_finite(float(volume)):
			return (
				"authoritative character_voice_volume['%s'] must be a finite number"
				% candidate.character)
	return ""


func _presentation_clip_choice_diagnostic(
	definition: PresentationClipDefinition,
	cue_index: int,
	candidate_index: int,
	candidate: PresentationClipAudioChoiceCandidate,
	detail: String,
) -> String:
	var definition_path := definition.resource_path
	if definition_path.is_empty():
		definition_path = "<embedded PresentationClipDefinition>"
	var provenance := " authored at <unavailable>"
	if (
		candidate != null
		and not candidate.authored_source_path.is_empty()
		and candidate.authored_source_line > 0
	):
		provenance = " authored at %s:%d" % [
			candidate.authored_source_path, candidate.authored_source_line,
		]
	return "%s cues[%d] candidates[%d] id '%s'%s: %s" % [
		definition_path,
		cue_index,
		candidate_index,
		String(candidate.id) if candidate != null else "<null>",
		provenance,
		detail,
	]


func _abort_presentation_clip_audio_transaction(request_key: int = 0) -> bool:
	if _presentation_clip_transaction.is_empty():
		return true
	if (
		request_key != 0
		and not _presentation_clip_audio_transaction_is_current(request_key)
	):
		return false
	var transaction := _presentation_clip_transaction
	_presentation_clip_transaction = {}
	var authority_restored := true
	if bool(transaction.get("choice_authority_held", false)):
		authority_restored = (
			StellaRuntime.presentation_clip_audio_choice_authority.abort(
				int(transaction.get("request_key", 0))))
	if bool(transaction.get("committed", false)):
		var rejected := _presentation_clip_audio
		_presentation_clip_audio = transaction.get("previous", {})
		_release_presentation_clip_audio_record(rejected)
	else:
		_release_presentation_clip_claimed()
	if not authority_restored:
		push_error(
			"AudioPresenter: failed to restore presentation-clip audio-choice "
			+ "authority during transaction abort")
	return authority_restored


func _on_presentation_clip_audio_cue_requested(
	request_id: int,
	cue_index: int,
	generation: int,
) -> void:
	if (
		_presentation_clip_audio.is_empty()
		or int(_presentation_clip_audio.get("request_id", 0)) != request_id
		or generation <= 0
	):
		return
	var active_generation := int(
		_presentation_clip_audio.get("generation", 0))
	if active_generation == 0:
		_presentation_clip_audio["generation"] = generation
	elif active_generation != generation:
		return
	var players_by_cue: Dictionary = _presentation_clip_audio.get(
		"players_by_cue", {})
	var player := players_by_cue.get(cue_index) as AudioStreamPlayer
	if player == null:
		var choice_players: Dictionary = _presentation_clip_audio.get(
			"choice_players_by_cue", {})
		var choice_record: Dictionary = choice_players.get(cue_index, {})
		if choice_record.is_empty():
			return
		var character := String(choice_record.get("character", ""))
		if not character.is_empty() and not _is_voice_character_enabled(character):
			_release_presentation_clip_choice_player(
				_presentation_clip_audio, cue_index)
			return
		choice_record["triggered"] = true
		choice_players[cue_index] = choice_record
		_presentation_clip_audio["choice_players_by_cue"] = choice_players
		player = choice_record.get("player") as AudioStreamPlayer
	if player != null and is_instance_valid(player):
		player.play()


func _on_presentation_clip_retire_requested(
	request_id: int,
	generation: int,
	_outcome: StringName,
) -> void:
	if (
		_presentation_clip_audio.is_empty()
		or int(_presentation_clip_audio.get("request_id", 0)) != request_id
	):
		return
	var active_generation := int(
		_presentation_clip_audio.get("generation", 0))
	if active_generation not in [0, generation]:
		return
	_retire_presentation_clip_audio()


func _on_presentation_clip_projection_reset_requested(_epoch: int) -> void:
	_abort_presentation_clip_audio_transaction()
	_retire_presentation_clip_audio()
	_release_presentation_clip_claimed()
	_release_presentation_clip_prepared()


func _on_presentation_clip_request_settled(
	request: PresentationClipOperationRequest,
) -> void:
	if request == null:
		return
	var plan: Dictionary = _presentation_clip_prepared.get(
		request.get_instance_id(), {})
	_presentation_clip_prepared.erase(request.get_instance_id())
	if not plan.is_empty():
		_release_detached_clip_players(plan.get("players", []))
	if (
		not _presentation_clip_claimed.is_empty()
		and int(_presentation_clip_claimed.get("request_id", 0))
			== request.get_request_id()
	):
		_release_presentation_clip_claimed()


func _release_presentation_clip_prepared() -> void:
	var plans := _presentation_clip_prepared.values()
	_presentation_clip_prepared.clear()
	for plan_value: Variant in plans:
		_release_detached_clip_players(
			(plan_value as Dictionary).get("players", []))


func _release_detached_clip_players(players: Array) -> void:
	for player_value: Variant in players:
		var player := player_value as AudioStreamPlayer
		if player == null or not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
		if player.is_inside_tree():
			player.queue_free()
		else:
			player.free()


func _retire_presentation_clip_audio() -> void:
	if _presentation_clip_audio.is_empty():
		return
	var active := _presentation_clip_audio
	_presentation_clip_audio = {}
	_release_presentation_clip_audio_record(active)


func _release_presentation_clip_audio_record(record: Dictionary) -> void:
	if record.is_empty():
		return
	_release_detached_clip_players(record.get("players", []))


func _release_presentation_clip_claimed() -> void:
	if _presentation_clip_claimed.is_empty():
		return
	var claimed := _presentation_clip_claimed
	_presentation_clip_claimed = {}
	_release_detached_clip_players(claimed.get("players", []))


func _apply_presentation_clip_audio_volumes() -> void:
	if _presentation_clip_audio.is_empty():
		return
	_apply_presentation_clip_record_volumes(_presentation_clip_audio)


func _apply_presentation_clip_record_volumes(record: Dictionary) -> void:
	var definition: PresentationClipDefinition = (
		record.get("definition"))
	var players_by_cue: Dictionary = record.get("players_by_cue", {})
	if definition == null:
		return
	var settings_db := _to_db(
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("system_se_volume", 1.0))
	for cue_index_value: Variant in players_by_cue:
		var cue_index := int(cue_index_value)
		if (
			cue_index < 0
			or cue_index >= definition.cues.size()
			or not definition.cues[cue_index] is PresentationClipAudioCue
		):
			continue
		var player := players_by_cue[cue_index] as AudioStreamPlayer
		if player != null and is_instance_valid(player):
			player.volume_db = (
				(definition.cues[cue_index] as PresentationClipAudioCue).volume_db
				+ settings_db)
	for choice_value: Variant in (
		record.get("choice_players_by_cue", {}) as Dictionary).values():
		if not choice_value is Dictionary:
			continue
		var choice_record: Dictionary = choice_value
		var player := choice_record.get("player") as AudioStreamPlayer
		if player == null or not is_instance_valid(player):
			continue
		var character := String(choice_record.get("character", ""))
		player.volume_db = (
			_get_voice_target_db_for_character(character)
			if not character.is_empty() else settings_db)


# ─── System SE ───

func _on_choice_selected(_option_id: String):
	var select_se = StellaRuntime.config.se_select
	if select_se != "":
		_on_system_se_play(select_se)


func _on_system_se_play(asset: String):
	if _audio_admission_is_closed():
		return
	var stream = _load_audio(StellaRuntime.se_path, asset, ["ogg", "wav"])
	if stream == null:
		push_warning("AudioPresenter: System SE not found: %s" % asset)
		return

	_system_se_player.stream = stream
	_system_se_player.play()


# ─── Helpers ───

func _load_audio(base_path: String, asset: String, extensions: Array) -> AudioStream:
	for ext in extensions:
		var path = base_path + "%s.%s" % [asset, ext]
		if ResourceLoader.exists(path):
			return load(path)
	return null
