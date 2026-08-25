## Audio presenter — manages BGM, SE, Voice, and System SE playback.
class_name AudioPresenter extends Node

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
var _bgm_capability: RefCounted
var _bgm_channel: Dictionary = {}
var _bgm_validation_cache: Dictionary = {}
var _bgm_generation: int = 1
var _next_bgm_token: int = 1
var _loop_se_capability: RefCounted
var _loop_se_channels: Dictionary = {}
var _loop_se_validation_cache: Dictionary = {}
var _loop_se_generation: int = 1
var _next_loop_se_token: int = 1
var _shutdown_quiesced := false


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

	# Create SE player pool
	for i in range(_max_se_channels):
		var player = AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_se_players.append(player)

	# Create Voice player
	_voice_player = AudioStreamPlayer.new()
	_voice_player.bus = "Master"
	_voice_player.finished.connect(_on_voice_playback_finished)
	add_child(_voice_player)

	# Create System SE player
	_system_se_player = AudioStreamPlayer.new()
	_system_se_player.bus = "Master"
	add_child(_system_se_player)

	# Connect signals
	SignalBus.se_play.connect(_on_se_play)
	SignalBus.voice_playback_requested.connect(_on_voice_playback_requested)
	SignalBus.advance_requested.connect(_on_advance_requested)
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
	SignalBus.runtime_audio_shutdown_requested.connect(
		_on_runtime_audio_shutdown_requested)

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
		or _voice_playback_token >= 0
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
	var finished_revision := _voice_lifecycle_revision
	var finished_token := _voice_playback_token
	_retire_fixed_audio_player(_voice_player)
	_voice_playback_token = -1
	_voice_playback_revision = -1
	_voice_started_advance_serial = -1
	if finished_token >= 0:
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
			finished_token,
			_voice_finished_event_is_current.bind(finished_revision),
		))


func _retire_fixed_audio_player(player: AudioStreamPlayer) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream_paused = false
	player.stream = null


func _exit_tree() -> void:
	if _bgm_capability != null and _loop_se_capability != null:
		if not _shutdown_quiesced:
			SignalBus.commit_bgm_position(
				self, _bgm_capability, _capture_bgm_position())
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


func _process(_delta: float) -> void:
	if _voice_player.playing and _voice_player.stream:
		var pos = _voice_player.get_playback_position()
		var dur = _voice_player.stream.get_length()
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.progress(
			pos, dur, _voice_playback_token,
			_voice_playback_event_is_current.bind(
				_voice_playback_revision, _voice_playback_token),
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
		_voice_player.volume_db = _get_voice_target_db()

	if update_all or changed_key in ["master_volume", "system_se_volume"]:
		var sys_se_vol := _get_volume_setting("system_se_volume", 1.0)
		_system_se_player.volume_db = _to_db(master * sys_se_vol)


func _get_volume_setting(key: String, fallback: float) -> float:
	var value = StellaRuntime.get_setting(key)
	return fallback if value == null else float(value)


func _get_voice_target_db() -> float:
	var char_enabled = StellaRuntime.get_setting("character_voice_enabled")
	if char_enabled is Dictionary and not bool(char_enabled.get(_current_voice_character, true)):
		return -80.0

	var final_volume := (
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("voice_volume", 1.0)
	)
	var char_volume = StellaRuntime.get_setting("character_voice_volume")
	if char_volume is Dictionary:
		final_volume *= float(char_volume.get(_current_voice_character, 1.0))
	return _to_db(final_volume)


func _to_db(linear: float) -> float:
	if linear <= 0.0:
		return -80.0
	return linear_to_db(linear)


func _on_settings_changed(key: String, _value: Variant):
	if key in ["master_volume", "bgm_volume", "se_volume", "voice_volume",
			"system_se_volume", "character_voice_volume", "character_voice_enabled"]:
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
		prepared = _resolve_bgm_track(
			String(current_state.get("asset", "")),
			String(current_state.get("cue", "")),
			payload["stem_mix"] as Dictionary,
		)
		var current_voice: Dictionary = _bgm_channel.get("current", {})
		if (
			prepared.is_empty()
			or (prepared["stem_mix"] as Dictionary).is_empty()
			or not _bgm_voice_matches_prepared(current_voice, prepared)
		):
			SignalBus.reject_bgm_request(
				request,
				self,
				_bgm_capability,
				"the current BGM is not a compatible multi-stem track or the stem mix is invalid",
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
			return _mix_bgm(payload, prepared, fade_duration, request_id)
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
	)
	if new_voice.is_empty():
		return null
	var state := {
		"asset": asset,
		"cue": cue,
		"loop": bool(prepared["loop"]),
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
	):
		_complete_active_bgm_receipt()
		state = _bgm_channel.get("target_state", {})
		current = _bgm_channel.get("current", {})
		if state.is_empty() or current.is_empty():
			return null
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


func _retire_bgm_transition(outcome: StringName) -> void:
	if _bgm_channel.is_empty():
		_bgm_channel = _new_bgm_channel()
		return
	var tween: Tween = _bgm_channel.get("tween")
	_bgm_channel["tween"] = null
	if tween != null and tween.is_valid():
		tween.kill()
	_stop_bgm_voice(_bgm_channel.get("outgoing", {}))
	_bgm_channel["outgoing"] = {}
	var receipt: Dictionary = _bgm_channel.get("receipt", {})
	if not receipt.is_empty():
		_emit_bgm_terminal(receipt, outcome)


func _emit_bgm_terminal(receipt: Dictionary, outcome: StringName) -> void:
	if _bgm_channel.get("receipt", {}) != receipt:
		return
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
		and int(receipt.get("generation", -1)) == _bgm_generation
	)


func _on_bgm_transition_receipts_finish_requested(records: Array) -> void:
	for record_value: Variant in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if int(record.get("presenter_instance_id", 0)) != get_instance_id():
			continue
		var receipt: Dictionary = _bgm_channel.get("receipt", {})
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
	var resolved := _resolve_bgm_track(
		String(state["asset"]),
		String(state["cue"]),
		state["stem_mix"] as Dictionary,
	)
	var restored_position := float(state["position"])
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
	var level := float(state["volume"])
	var voice := _create_bgm_voice(
		resolved.get("stream") as AudioStream,
		String(state["asset"]), String(state["cue"]), bool(state["loop"]),
		restored_position, float(resolved["loop_position"]),
		float(resolved["loop_end_position"]), level,
		resolved.get("stem_mix", {}) as Dictionary,
		resolved.get("stem_names", []) as Array,
		resolved.get("resource_signature", {}) as Dictionary,
	)
	if voice.is_empty():
		return
	_bgm_channel = _new_bgm_channel()
	_bgm_channel["current"] = voice
	_bgm_channel["target_state"] = state.duplicate(true)
	if String(state["status"]) == "paused":
		(voice.get("player") as AudioStreamPlayer).stream_paused = true


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
	)
	if voice.is_empty():
		return
	_bgm_channel = _new_bgm_channel()
	_bgm_channel["current"] = voice
	_bgm_channel["target_state"] = {
		"asset": asset, "cue": "", "loop": bool(resolved["loop"]),
		"position": float(resolved["start_position"]), "status": "playing",
		"stem_mix": (resolved.get("stem_mix", {}) as Dictionary).duplicate(true),
		"volume": 1.0,
	}


func _on_bgm_state_capture_requested(request: BgmStateCaptureRequest) -> void:
	if _bgm_capability == null:
		return
	SignalBus.resolve_bgm_state_capture(
		request, self, _bgm_capability, _capture_bgm_position())


func _capture_bgm_position() -> float:
	var current: Dictionary = _bgm_channel.get("current", {})
	var player: AudioStreamPlayer = current.get("player")
	if player == null or not is_instance_valid(player):
		return float((_bgm_channel.get("target_state", {}) as Dictionary).get(
			"position", 0.0))
	return maxf(player.get_playback_position(), 0.0)


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
	}
	_set_bgm_stem_mix(stem_mix, voice)
	_set_bgm_voice_level(level, voice)
	player.finished.connect(_on_bgm_voice_finished.bind(voice), CONNECT_ONE_SHOT)
	player.play(position)
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
	var player: AudioStreamPlayer = (voice_value as Dictionary).get("player")
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream = null
	player.queue_free()


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
	if uses_single_stream == uses_stems:
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
	return selected


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

func _on_voice_playback_requested(request: VoicePlaybackRequest) -> void:
	if not SignalBus.voice_playback_request_is_pending(request):
		return
	if _audio_admission_is_closed():
		SignalBus.resolve_voice_playback_request(request, false)
		return
	var asset := request.get_asset()
	var character := request.get_character()
	if not request.is_current():
		SignalBus.resolve_voice_playback_request(request, false)
		return
	# Physical lifecycle ownership is AudioPresenter-local. Dialogue ownership
	# decides whether this request may start, but later advance/hide transitions
	# must not make its legitimate physical FINISH look stale to low-level users.
	_voice_lifecycle_revision += 1
	var request_revision := _voice_lifecycle_revision

	# Retire the current token before publishing FINISHED. A listener may start a
	# replacement synchronously, and this outer request must not clear its state.
	if _voice_player.playing:
		var replaced_token := _voice_playback_token
		_voice_player.stop()
		_voice_playback_token = -1
		_voice_playback_revision = -1
		_voice_started_advance_serial = -1
		SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
			replaced_token,
			_voice_finished_event_is_current.bind(request_revision),
		))

	# Stopping the previous clip is a public reentrancy boundary. If it SHOWed a
	# replacement, reject this retired request without touching replacement audio.
	if request_revision != _voice_lifecycle_revision \
		or not request.is_current():
		SignalBus.resolve_voice_playback_request(request, false)
		return

	var stream = _load_audio(StellaRuntime.voice_path, asset, ["ogg", "wav"])
	if stream == null:
		push_warning("AudioPresenter: Voice not found: %s" % asset)
		SignalBus.resolve_voice_playback_request(request, false)
		return

	# Do not start a voice that is muted for this character. Live mute changes
	# keep playback position and use -80 dB so a later reset can unmute it.
	var char_enabled = StellaRuntime.get_setting("character_voice_enabled")
	if char_enabled is Dictionary and not bool(char_enabled.get(character, true)):
		SignalBus.resolve_voice_playback_request(request, false)
		return

	var playback_token := SignalBus.resolve_voice_playback_request(request, true)
	if playback_token < 0:
		return
	_current_voice_character = character
	_voice_playback_token = playback_token
	_voice_playback_revision = request_revision
	_voice_player.volume_db = _get_voice_target_db()
	_voice_player.stream = stream
	_voice_started_advance_serial = SignalBus.current_advance_dispatch_serial()
	_voice_player.play()
	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.started(
		_current_voice_character, asset,
		_voice_playback_token,
		_voice_playback_event_is_current.bind(
			_voice_playback_revision, _voice_playback_token),
	))


func _on_voice_playback_finished():
	var finished_token := _voice_playback_token
	var finished_revision := _voice_lifecycle_revision
	_voice_playback_token = -1
	_voice_playback_revision = -1
	_voice_started_advance_serial = -1
	SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
		finished_token,
		_voice_finished_event_is_current.bind(finished_revision),
	))


func _on_advance_requested():
	if _voice_player.playing:
		var continue_on_advance = StellaRuntime.get_setting("voice_continue_on_advance")
		# The advance pre-dispatch hook can finalize a typing line, whose public
		# FINISHED listener synchronously SHOWs and starts the replacement voice.
		# That replacement belongs to this dispatch serial and must survive the old
		# advance signal's ordinary listener tail.
		if (not continue_on_advance
			and _voice_started_advance_serial
				< SignalBus.current_advance_dispatch_serial()):
			var finished_token := _voice_playback_token
			var finished_revision := _voice_lifecycle_revision
			_voice_player.stop()
			_voice_playback_token = -1
			_voice_playback_revision = -1
			_voice_started_advance_serial = -1
			# AudioStreamPlayer.stop() does NOT emit finished signal.
			# Manually emit voice_finished so _voice_playing flag gets cleared
			# and auto-play doesn't hang on await voice_finished.
			SignalBus.emit_voice_playback_event(VoicePlaybackEvent.finished(
				finished_token,
				_voice_finished_event_is_current.bind(finished_revision),
			))


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
