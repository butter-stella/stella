## Audio presenter — manages BGM, SE, Voice, and System SE playback.
extends Node

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
	SignalBus.se_stop.connect(_on_se_stop)
	SignalBus.voice_playback_requested.connect(_on_voice_playback_requested)
	SignalBus.advance_requested.connect(_on_advance_requested)
	SignalBus.settings_changed.connect(_on_settings_changed)
	SignalBus.system_se_play.connect(_on_system_se_play)
	SignalBus.choice_selected.connect(_on_choice_selected)

	_apply_volumes()


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

func _on_se_play(asset: String, _loop: bool):
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


func _on_se_stop(asset: String):
	for player in _se_players:
		if player.playing and player.stream and player.stream.resource_path.find(asset) != -1:
			player.stop()


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
