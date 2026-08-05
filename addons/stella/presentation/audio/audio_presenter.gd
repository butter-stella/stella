## Audio presenter — manages BGM, SE, Voice, and System SE playback.
extends Node

var _bgm_player: AudioStreamPlayer
var _se_players: Array = []
var _max_se_channels: int = 4
var _se_player_assets: Dictionary = {}
var _voice_player: AudioStreamPlayer
var _system_se_player: AudioStreamPlayer
var _current_voice_character: String = ""
var _bgm_tween: Tween


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
	SignalBus.voice_play.connect(_on_voice_play)
	SignalBus.advance_requested.connect(_on_advance_requested)
	SignalBus.settings_changed.connect(_on_settings_changed)
	SignalBus.system_se_play.connect(_on_system_se_play)
	SignalBus.choice_selected.connect(_on_choice_selected)

	_apply_volumes()


func _process(_delta: float) -> void:
	if _voice_player.playing and _voice_player.stream:
		var pos = _voice_player.get_playback_position()
		var dur = _voice_player.stream.get_length()
		SignalBus.voice_progress.emit(pos, dur)


# ─── Volume ───

func _apply_volumes():
	var master = StellaRuntime.get_setting("master_volume")
	if master == null:
		master = 1.0

	var bgm_vol = StellaRuntime.get_setting("bgm_volume")
	if bgm_vol == null:
		bgm_vol = 0.8
	_bgm_player.volume_db = _to_db(master * bgm_vol)

	var se_vol = StellaRuntime.get_setting("se_volume")
	if se_vol == null:
		se_vol = 1.0
	for player in _se_players:
		player.volume_db = _to_db(master * se_vol)

	var voice_vol = StellaRuntime.get_setting("voice_volume")
	if voice_vol == null:
		voice_vol = 1.0
	_voice_player.volume_db = _to_db(master * voice_vol)

	var sys_se_vol = StellaRuntime.get_setting("system_se_volume")
	if sys_se_vol == null:
		sys_se_vol = 1.0
	_system_se_player.volume_db = _to_db(master * sys_se_vol)


func _to_db(linear: float) -> float:
	if linear <= 0.0:
		return -80.0
	return linear_to_db(linear)


func _on_settings_changed(key: String, _value: Variant):
	if key in ["master_volume", "bgm_volume", "se_volume", "voice_volume",
			"system_se_volume", "character_voice_volume", "character_voice_enabled"]:
		_apply_volumes()


# ─── BGM ───

func _on_bgm_play(asset: String, fade_duration: float):
	var stream = _load_audio(StellaRuntime.bgm_path, asset, ["ogg", "mp3", "wav"])
	if stream == null:
		push_warning("AudioPresenter: BGM not found: %s" % asset)
		return

	# Work on a duplicate so changing loop metadata never mutates the cached
	# ResourceLoader instance shared by another player.
	stream = _with_loop_setting(stream, true)

	var master = StellaRuntime.get_setting("master_volume")
	if master == null:
		master = 1.0
	var bgm_vol = StellaRuntime.get_setting("bgm_volume")
	if bgm_vol == null:
		bgm_vol = 0.8
	var target_db = _to_db(master * bgm_vol)

	# Kill any running BGM tween to avoid concurrent coroutines
	if _bgm_tween and _bgm_tween.is_valid():
		_bgm_tween.kill()

	if fade_duration > 0 and _bgm_player.playing:
		var fade_out = create_tween()
		_bgm_tween = fade_out
		fade_out.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
		await fade_out.finished
		# If another bgm_play killed our tween, abort this coroutine
		if _bgm_tween != fade_out:
			return

	_bgm_player.stream = stream
	_bgm_player.volume_db = -80.0
	_bgm_player.play()
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(_bgm_player, "volume_db", target_db, fade_duration)


func _on_bgm_stop(fade_duration: float):
	if not _bgm_player.playing:
		return
	if _bgm_tween and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
	_bgm_tween.tween_callback(func(): _bgm_player.stop())


# ─── SE ───

func _on_se_play(asset: String, loop: bool):
	var stream = _load_audio(StellaRuntime.se_path, asset, ["ogg", "wav"])
	if stream == null:
		push_warning("AudioPresenter: SE not found: %s" % asset)
		return
	stream = _with_loop_setting(stream, loop)

	for player in _se_players:
		if not player.playing:
			player.stream = stream
			_se_player_assets[player] = asset
			player.play()
			return

	_se_players[0].stream = stream
	_se_player_assets[_se_players[0]] = asset
	_se_players[0].play()


func _on_se_stop(asset: String):
	for player in _se_players:
		if player.playing and _se_player_assets.get(player, "") == asset:
			player.stop()
			_se_player_assets.erase(player)


# ─── Voice ───

func _on_voice_play(asset: String, character: String = ""):
	_current_voice_character = character

	# Stop any currently playing voice
	if _voice_player.playing:
		_voice_player.stop()

	var stream = _load_audio(StellaRuntime.voice_path, asset, ["ogg", "wav"])
	if stream == null:
		push_warning("AudioPresenter: Voice not found: %s" % asset)
		return

	# Check per-character mute
	var char_enabled = StellaRuntime.get_setting("character_voice_enabled")
	if char_enabled is Dictionary and char_enabled.has(_current_voice_character):
		if not char_enabled[_current_voice_character]:
			return

	# Apply per-character volume if available
	var master = StellaRuntime.get_setting("master_volume")
	if master == null:
		master = 1.0
	var voice_vol = StellaRuntime.get_setting("voice_volume")
	if voice_vol == null:
		voice_vol = 1.0
	var final_vol = master * voice_vol

	var char_vol = StellaRuntime.get_setting("character_voice_volume")
	if char_vol is Dictionary and char_vol.has(_current_voice_character):
		final_vol *= char_vol[_current_voice_character]

	_voice_player.volume_db = _to_db(final_vol)
	_voice_player.stream = stream
	_voice_player.play()
	SignalBus.voice_started.emit(_current_voice_character, asset)


func _on_voice_playback_finished():
	SignalBus.voice_finished.emit()


func _on_advance_requested():
	if _voice_player.playing:
		var continue_on_advance = StellaRuntime.get_setting("voice_continue_on_advance")
		if not continue_on_advance:
			_voice_player.stop()
			# AudioStreamPlayer.stop() does NOT emit finished signal.
			# Manually emit voice_finished so _voice_playing flag gets cleared
			# and auto-play doesn't hang on await voice_finished.
			SignalBus.voice_finished.emit()


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


## Return a per-player stream whose loop flag matches the request.
## Compressed streams expose `loop: bool`, while WAV uses `loop_mode`.
func _with_loop_setting(stream: AudioStream, enabled: bool) -> AudioStream:
	var configured = stream.duplicate() as AudioStream
	if configured == null:
		configured = stream

	if configured is AudioStreamWAV:
		configured.loop_mode = (
			AudioStreamWAV.LOOP_FORWARD if enabled
			else AudioStreamWAV.LOOP_DISABLED
		)
	elif "loop" in configured:
		configured.loop = enabled

	return configured
