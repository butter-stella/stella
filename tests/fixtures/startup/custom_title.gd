extends Node

const EXPECTED_SCENE = "res://tests/fixtures/startup/custom_title.tscn"
const EXPECTED_TITLE = "Synthetic Startup Probe"
const EXPECTED_SCENARIO = (
	"res://tests/fixtures/scenarios/dialogue/presentation_profile.stla"
)
const EXPECTED_CHARACTERS_PATH = "res://tests/fixtures/startup/characters/"
const EXPECTED_STAGE_PATH = "res://tests/fixtures/stage/"
const EXPECTED_SE_PATH = "res://examples/demo/audio/se/"
const EXPECTED_GAME_SCENE = "res://tests/fixtures/startup/game.tscn"
const EXPECTED_OVERLAY = "StartupProbeOverlay"
const EXPECTED_CANCEL_SE = "se_cancel"


func _ready() -> void:
	var failures := PackedStringArray()
	if get_tree().current_scene != self or scene_file_path != EXPECTED_SCENE:
		failures.append("custom title is not the first current scene")
	if StellaRuntime.config.game_title != EXPECTED_TITLE:
		failures.append("resolved game title did not reach the title consumer")
	if StellaRuntime.config.scenario_path != EXPECTED_SCENARIO:
		failures.append("resolved scenario did not reach the first scene")
	if (
		not StellaRuntime.config.cg_gallery
		or StellaRuntime.config.backlog
		or StellaRuntime.config.save_slots != 3
	):
		failures.append("resolved feature flags did not reach the first scene")

	var expected_sources := PackedStringArray([
		"res://stella.cfg",
		"res://stella.local.cfg",
	])
	if StellaRuntime.get_applied_config_sources() != expected_sources:
		failures.append("applied source order does not include base then local")

	if StellaRuntime.characters_path != EXPECTED_CHARACTERS_PATH:
		failures.append("resolved characters path was not applied")
	var character_config = StellaRuntime.character_config_loader.get_config("probe")
	if character_config.resolve_avatar_asset("default") != "startup_probe_avatar":
		failures.append("CharacterConfigLoader did not consume the local characters path")
	if StellaRuntime.stage_assets_path != EXPECTED_STAGE_PATH:
		failures.append("resolved stage path was not applied")
	var stage_presenter := StagePresenter.new()
	var stage_texture := stage_presenter._load_stage_texture("stage:redraw_source.png")
	if stage_texture == null or stage_texture.resource_path != EXPECTED_STAGE_PATH + "redraw_source.png":
		failures.append("StagePresenter did not consume the local stage path")
	stage_presenter.free()

	if StellaRuntime._get_game_scene_path() != EXPECTED_GAME_SCENE:
		failures.append("resolved game scene did not reach the first scene")
	var game_scene := load(EXPECTED_GAME_SCENE) as PackedScene
	if game_scene == null:
		failures.append("configured game scene is not loadable")
	else:
		var game_instance := game_scene.instantiate()
		if game_instance == null:
			failures.append("configured game scene cannot be instantiated")
		else:
			game_instance.free()

	if StellaRuntime.se_path != EXPECTED_SE_PATH:
		failures.append("resolved SE path was not applied")
	if StellaRuntime.config.se_cancel != EXPECTED_CANCEL_SE:
		failures.append("resolved system SE was not applied")

	StellaRuntime.show_settings()
	var overlay := StellaRuntime.get_node_or_null("OverlayLayer/%s" % EXPECTED_OVERLAY)
	if overlay == null or not overlay.get_meta("startup_probe", false):
		failures.append("settings overlay consumer did not load the configured scene")
	StellaRuntime.close_overlay()

	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	var system_se_player: AudioStreamPlayer = null
	if audio_presenter != null:
		system_se_player = audio_presenter.get("_system_se_player") as AudioStreamPlayer
	if (
		system_se_player == null
		or system_se_player.stream == null
		or system_se_player.stream.resource_path
		!= EXPECTED_SE_PATH + EXPECTED_CANCEL_SE + ".wav"
	):
		failures.append("AudioPresenter did not consume the configured system SE")
	if system_se_player != null:
		system_se_player.stop()
		system_se_player.stream = null

	# Tear down the probe player explicitly and give AudioServer / queued overlay
	# cleanup one frame before quitting.
	if system_se_player != null:
		system_se_player.queue_free()
	_finish_after_teardown.call_deferred(failures)


func _finish_after_teardown(failures: PackedStringArray) -> void:
	await get_tree().create_timer(0.1).timeout
	_finish_probe(failures)


func _finish_probe(failures: PackedStringArray) -> void:
	var marker_path := OS.get_environment("STELLA_STARTUP_PROBE_MARKER")
	if marker_path == "":
		failures.append("STELLA_STARTUP_PROBE_MARKER is not set")

	if not failures.is_empty():
		for failure: String in failures:
			push_error("Startup probe: " + failure)
		get_tree().quit(1)
		return

	var marker := FileAccess.open(marker_path, FileAccess.WRITE)
	if marker == null:
		push_error("Startup probe: cannot create the requested marker")
		get_tree().quit(1)
		return
	marker.store_string("ok\n")
	marker.close()
	get_tree().quit()
