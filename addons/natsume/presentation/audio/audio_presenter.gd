## Audio presenter — manages BGM and SE playback using AudioStreamPlayers.
extends Node

var _bgm_player: AudioStreamPlayer
var _se_players: Array = []
var _max_se_channels: int = 4


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

	SignalBus.bgm_play.connect(_on_bgm_play)
	SignalBus.bgm_stop.connect(_on_bgm_stop)
	SignalBus.se_play.connect(_on_se_play)
	SignalBus.se_stop.connect(_on_se_stop)


func _on_bgm_play(asset: String, fade_duration: float):
	var base = NatsumeRuntime.bgm_path
	var path = base + "%s.ogg" % asset
	var stream = load(path)
	if stream == null:
		path = base + "%s.mp3" % asset
		stream = load(path)
	if stream == null:
		push_warning("AudioPresenter: BGM not found: %s" % asset)
		return

	if fade_duration > 0 and _bgm_player.playing:
		var tween = create_tween()
		tween.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
		await tween.finished

	_bgm_player.stream = stream
	_bgm_player.volume_db = -80.0
	_bgm_player.play()
	var tween = create_tween()
	tween.tween_property(_bgm_player, "volume_db", 0.0, fade_duration)


func _on_bgm_stop(fade_duration: float):
	if not _bgm_player.playing:
		return
	var tween = create_tween()
	tween.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
	tween.tween_callback(func(): _bgm_player.stop())


func _on_se_play(asset: String, _loop: bool):
	var base = NatsumeRuntime.se_path
	var path = base + "%s.ogg" % asset
	var stream = load(path)
	if stream == null:
		path = base + "%s.wav" % asset
		stream = load(path)
	if stream == null:
		push_warning("AudioPresenter: SE not found: %s" % asset)
		return

	# Find available SE player
	for player in _se_players:
		if not player.playing:
			player.stream = stream
			player.play()
			return

	# All channels busy, use first one
	_se_players[0].stream = stream
	_se_players[0].play()


func _on_se_stop(asset: String):
	for player in _se_players:
		if player.playing and player.stream and player.stream.resource_path.find(asset) != -1:
			player.stop()
