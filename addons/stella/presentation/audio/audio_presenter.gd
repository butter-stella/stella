## Audio presenter — manages BGM, SE, Voice, and System SE playback.
class_name AudioPresenter extends Node

enum BgmTweenPurpose { NONE, SWITCH_FADE_OUT, FADE_IN, STOP_FADE_OUT }

var _bgm_player: AudioStreamPlayer
var _se_players: Array = []
var _max_se_channels: int = 4
var _voice_player: AudioStreamPlayer
var _system_se_player: AudioStreamPlayer
var _current_voice_character: String = ""
var _voice_started_advance_serial: int = -1
var _voice_playback_token: int = -1
var _voice_lifecycle_revision: int = 0
var _voice_playback_revision: int = -1
var _bgm_tween: Tween
var _bgm_tween_purpose: int = BgmTweenPurpose.NONE
var _loop_se_capability: RefCounted
var _loop_se_channels: Dictionary = {}
var _loop_se_validation_cache: Dictionary = {}
var _loop_se_generation: int = 1
var _next_loop_se_token: int = 1


func _ready():
	# Create BGM player
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = "Master"
	add_child(_bgm_player)

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
	SignalBus.bgm_play.connect(_on_bgm_play)
	SignalBus.bgm_stop.connect(_on_bgm_stop)
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

	_apply_volumes()
	_loop_se_capability = StellaRuntime._register_loop_se_presenter(self)
	if _loop_se_capability != null:
		SignalBus.announce_loop_se_presenter_registered(
			self, _loop_se_capability)


func _exit_tree() -> void:
	if _loop_se_capability == null:
		return
	SignalBus.commit_loop_se_positions(
		self, _loop_se_capability, _capture_loop_se_positions())
	# Presenter replacement retires only the old projection generation. The
	# canonical channel state survives and the replacement receives one cut
	# projection after it acquires the Runtime-owned capability.
	SignalBus.reset_loop_se_presentation()
	StellaRuntime._unregister_loop_se_presenter(self, _loop_se_capability)
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
		var bgm_target_db := _get_bgm_target_db()
		# A fade-in captures its target when created. End it before applying a live
		# setting so that it cannot later restore the old target. Fade-outs keep
		# heading to silence; a switch computes the new track's target after it ends.
		if _bgm_tween_purpose == BgmTweenPurpose.FADE_IN:
			_cancel_bgm_tween()
		if _bgm_tween_purpose == BgmTweenPurpose.NONE:
			_bgm_player.volume_db = bgm_target_db

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


func _get_bgm_target_db() -> float:
	return _to_db(
		_get_volume_setting("master_volume", 1.0)
		* _get_volume_setting("bgm_volume", 0.8)
	)


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

func _on_bgm_play(asset: String, fade_duration: float):
	var stream = _load_audio(StellaRuntime.bgm_path, asset, ["ogg", "mp3"])
	if stream == null:
		push_warning("AudioPresenter: BGM not found: %s" % asset)
		return

	# Enable looping — AudioStreamOggVorbis / AudioStreamMP3 default to loop=false.
	if "loop" in stream:
		stream.loop = true

	# Kill any running BGM tween to avoid concurrent coroutines
	_cancel_bgm_tween()

	if fade_duration > 0 and _bgm_player.playing:
		var fade_out = create_tween()
		_bgm_tween = fade_out
		_bgm_tween_purpose = BgmTweenPurpose.SWITCH_FADE_OUT
		fade_out.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
		await fade_out.finished
		# If another bgm_play killed our tween, abort this coroutine
		if _bgm_tween != fade_out:
			return
		_bgm_tween = null
		_bgm_tween_purpose = BgmTweenPurpose.NONE

	_bgm_player.stream = stream
	_bgm_player.volume_db = -80.0
	_bgm_player.play()
	_start_bgm_fade_in(fade_duration)


func _start_bgm_fade_in(duration: float) -> void:
	_cancel_bgm_tween()
	var target_db := _get_bgm_target_db()
	if duration <= 0.0:
		_bgm_player.volume_db = target_db
		return

	var fade_in := create_tween()
	_bgm_tween = fade_in
	_bgm_tween_purpose = BgmTweenPurpose.FADE_IN
	fade_in.tween_property(_bgm_player, "volume_db", target_db, duration)
	fade_in.finished.connect(func() -> void:
		if _bgm_tween == fade_in:
			_bgm_tween = null
			_bgm_tween_purpose = BgmTweenPurpose.NONE
	, CONNECT_ONE_SHOT)


func _on_bgm_stop(fade_duration: float):
	if not _bgm_player.playing:
		return
	_cancel_bgm_tween()
	_bgm_tween = create_tween()
	_bgm_tween_purpose = BgmTweenPurpose.STOP_FADE_OUT
	_bgm_tween.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
	var fade_out := _bgm_tween
	_bgm_tween.tween_callback(func() -> void:
		if _bgm_tween == fade_out:
			_bgm_player.stop()
			_bgm_tween = null
			_bgm_tween_purpose = BgmTweenPurpose.NONE
	)


func _cancel_bgm_tween() -> void:
	if _bgm_tween and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_bgm_tween = null
	_bgm_tween_purpose = BgmTweenPurpose.NONE


# ─── SE ───

func _on_se_play(asset: String):
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
	if stream == null:
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
