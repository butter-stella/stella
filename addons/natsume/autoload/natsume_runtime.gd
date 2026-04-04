## Framework entry point. Initializes engine, registers handlers, manages scene lifecycle.
## Registered as Autoload singleton — persists across scene changes.
extends Node

const CONFIG_PATH = "res://natsume.cfg"
const DEFAULT_TITLE_SCENE = "res://addons/natsume/scenes/title.tscn"
const DEFAULT_GAME_SCENE = "res://addons/natsume/scenes/game.tscn"
const DEFAULT_SETTINGS_SCENE = "res://addons/natsume/scenes/settings.tscn"
const DEFAULT_SAVE_LOAD_SCENE = "res://addons/natsume/scenes/save_load.tscn"
const DEFAULT_BACKLOG_SCENE = "res://addons/natsume/scenes/backlog.tscn"

var engine: ScenarioEngine
var registry: CommandRegistry
var config: NatsumeConfig

## Subsystem instances
var save_manager: SaveManager
var settings_manager: SettingsManager
var backlog_manager: BacklogManager
var auto_play: AutoPlayController
var skip_controller: SkipController
var read_flags: ReadFlagManager
var game_state: GameStateMachine
var unlock_manager: UnlockManager
var presentation_state: PresentationState

## Resource base paths — populated from config, can be overridden manually.
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
var bgm_path: String = "res://audio/bgm/"
var se_path: String = "res://audio/se/"
var voice_path: String = "res://audio/voice/"

## Scene paths
var title_scene_path: String = ""

## Internal state
var _last_scenario_path: String = ""
var _current_overlay: Node = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		auto_save()


func _ready():
	# Load project config
	config = NatsumeConfig.new()
	config.load_from_path(CONFIG_PATH)
	_apply_config()

	save_manager = SaveManager.new()
	settings_manager = SettingsManager.new()
	settings_manager.load_settings()
	settings_manager.settings_changed.connect(func(key, val): SignalBus.settings_changed.emit(key, val))
	backlog_manager = BacklogManager.new()
	auto_play = AutoPlayController.new()
	skip_controller = SkipController.new()
	read_flags = ReadFlagManager.new()
	game_state = GameStateMachine.new()
	unlock_manager = UnlockManager.new()
	presentation_state = PresentationState.new()
	presentation_state.connect_signals()

	save_manager.register_provider(read_flags)
	save_manager.register_provider(unlock_manager)
	save_manager.register_provider(presentation_state)

	# Audio presenter — global, available in all scenes (title, game, overlays)
	var audio_script = load("res://addons/natsume/presentation/audio/audio_presenter.gd")
	if audio_script:
		var audio_node = Node.new()
		audio_node.name = "AudioPresenter"
		audio_node.set_script(audio_script)
		add_child(audio_node)

	registry = CommandRegistry.new()
	engine = ScenarioEngine.new()
	engine.registry = registry
	_register_handlers()

	# Bridge engine signals to SignalBus
	engine.scenario_started.connect(func(id): SignalBus.scenario_started_event.emit(id))
	engine.scenario_ended.connect(_on_scenario_ended)
	engine.scene_changed.connect(func(id): SignalBus.scene_changed_event.emit(id))

	# Wire dialogue to backlog
	SignalBus.show_dialogue.connect(_on_dialogue_for_backlog)

	# Play title BGM after AudioPresenter is ready
	if config.title_bgm != "":
		_play_title_bgm.call_deferred()


## Apply config values to runtime paths.
func _apply_config() -> void:
	if config.has_config_file:
		backgrounds_path = config.backgrounds_path
		characters_path = config.characters_path
		bgm_path = config.bgm_path
		se_path = config.se_path
		voice_path = config.voice_path

	if config.title_scene != "":
		title_scene_path = config.title_scene
	else:
		title_scene_path = DEFAULT_TITLE_SCENE


func _register_handlers():
	registry.register(DialogueHandler.new())
	registry.register(BgHandler.new())
	registry.register(CharShowHandler.new())
	registry.register(CharHideHandler.new())
	registry.register(CharExprHandler.new())
	registry.register(JumpHandler.new())
	registry.register(SetHandler.new())
	registry.register(ConditionHandler.new())
	registry.register(ChoiceHandler.new())
	registry.register(BgmHandler.new())
	registry.register(SeHandler.new())
	registry.register(VoiceHandler.new())
	registry.register(FadeHandler.new())
	registry.register(WaitHandler.new())
	registry.register(AnimHandler.new())
	registry.register(MoveHandler.new())
	registry.register(CgHandler.new())
	registry.register(EffectHandler.new())
	registry.register(CallHandler.new())
	var parallel_handler = ParallelHandler.new()
	parallel_handler._registry = registry
	registry.register(parallel_handler)


## Resolve the game scene path — config override or built-in default.
func _get_game_scene_path() -> String:
	if config.game_scene != "":
		return config.game_scene
	return DEFAULT_GAME_SCENE


## Start a new game — switch to game scene, then run scenario.
func start_game(scenario_path: String = "", game_scene_path: String = "") -> void:
	_close_current_overlay()
	if scenario_path == "":
		scenario_path = config.scenario_path
	if game_scene_path == "":
		game_scene_path = _get_game_scene_path()

	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	get_tree().change_scene_to_file(game_scene_path)
	# Wait for scene to be ready before starting engine
	await get_tree().tree_changed
	await get_tree().process_frame
	_start_scenario_internal(scenario_path)


## Load a saved game — switch to game scene, restore state, run.
func load_game(slot_id: int, scenario_path: String = "", game_scene_path: String = "") -> bool:
	_close_current_overlay()
	if not save_manager.has_save(slot_id):
		return false
	if scenario_path == "":
		scenario_path = config.scenario_path
	if game_scene_path == "":
		game_scene_path = _get_game_scene_path()

	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	get_tree().change_scene_to_file(game_scene_path)
	await get_tree().tree_changed
	await get_tree().process_frame
	_load_scenario_and_restore(scenario_path, slot_id)
	return true


## Continue from a manual save slot.
## Works from both title screen (switches to game scene) and in-game (reloads in place).
func continue_from_save(slot_id: int) -> bool:
	if not save_manager.has_save(slot_id):
		return false
	var scenario_path = _last_scenario_path
	if scenario_path == "":
		scenario_path = config.scenario_path
	if scenario_path == "":
		return false
	_last_scenario_path = scenario_path

	# Determine if we're on the title screen (directly or via overlay opened from title)
	var from_title = _is_on_title_screen()

	if from_title:
		# From title screen: switch to game scene first.
		# Close overlay AFTER scene change — queue_free before change_scene_to_file
		# causes tree_changed to fire from overlay removal instead of scene swap,
		# so presenters aren't connected when restore signals emit.
		game_state.transition_to(GameStateMachine.State.PLAYING)
		get_tree().change_scene_to_file(_get_game_scene_path())
		await get_tree().tree_changed
		await get_tree().process_frame
		_close_current_overlay()
		_load_scenario_and_restore(scenario_path, slot_id)
		return true

	# In-game: reload in place
	_close_current_overlay()
	_reset_presentation()
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_load_scenario_and_restore(scenario_path, slot_id)
	return true


## Return to title screen.
func return_to_title() -> void:
	auto_save()
	_close_current_overlay()
	backlog_manager.clear()
	auto_play.stop()
	skip_controller.stop()
	game_state.transition_to(GameStateMachine.State.TITLE)
	if title_scene_path != "":
		get_tree().change_scene_to_file(title_scene_path)
	if config.title_bgm != "":
		_play_title_bgm()


## Legacy API — starts scenario in current scene (for testing).
func start_scenario(scenario_path: String) -> void:
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_start_scenario_internal(scenario_path)


func _start_scenario_internal(scenario_path: String) -> void:
	_prepare_scenario(scenario_path)
	presentation_state.clear()
	engine.run()


## Load scenario data and register providers, but do NOT run the engine.
func _prepare_scenario(scenario_path: String) -> void:
	var file = FileAccess.open(scenario_path, FileAccess.READ)
	if file == null:
		push_error("NatsumeRuntime: cannot open %s" % scenario_path)
		return
	var source = file.get_as_text()
	file.close()

	var tokens = DslLexer.tokenize(source)
	var scenario_id = scenario_path.get_file().get_basename()
	var data = DslParser.parse(tokens, scenario_id)

	engine.load_scenario(data)
	save_manager.register_provider(engine.context)
	save_manager.register_provider(engine.context.variable_store)


## Load scenario, restore snapshot, restore presentation, then run.
func _load_scenario_and_restore(scenario_path: String, slot_id: int) -> void:
	_prepare_scenario(scenario_path)
	save_manager.load_save(slot_id)
	presentation_state.emit_restore_signals()
	engine.run()


## Check if we're on the title screen — either directly or via an overlay opened from title.
func _is_on_title_screen() -> bool:
	if game_state.current_state == GameStateMachine.State.TITLE:
		return true
	# Overlay states opened from title: previous_state is TITLE
	var overlay_states = [
		GameStateMachine.State.SAVE_LOAD,
		GameStateMachine.State.SETTINGS,
		GameStateMachine.State.BACKLOG,
	]
	if game_state.current_state in overlay_states:
		return game_state.previous_state == GameStateMachine.State.TITLE
	return false


## Reset current presentation state (for in-scene reload).
func _reset_presentation() -> void:
	SignalBus.char_hide.emit("all")
	SignalBus.bgm_stop.emit(0.0)
	SignalBus.hide_dialogue.emit()
	presentation_state.clear()


func _on_scenario_ended(id: String) -> void:
	SignalBus.scenario_ended_event.emit(id)
	# Auto return to title after scenario ends
	return_to_title()


func _on_dialogue_for_backlog(character: String, text: String, voice: String, _mode: String):
	backlog_manager.add_entry(character, text, voice)


# ─── Facade API: Save/Load ───

## Quick save (separate from manual save slots).
func quick_save() -> void:
	save_manager.quick_save()


## Quick load (separate from manual save slots).
## Works from both title screen (switches to game scene) and in-game (reloads in place).
func quick_load() -> bool:
	if not save_manager.has_quick_save():
		return false
	var scenario_path = _last_scenario_path
	if scenario_path == "":
		scenario_path = config.scenario_path
	if scenario_path == "":
		return false
	_last_scenario_path = scenario_path

	# From title screen: need to switch to game scene first
	# Close overlay AFTER scene ready — same reason as continue_from_save.
	if game_state.current_state == GameStateMachine.State.TITLE:
		game_state.transition_to(GameStateMachine.State.PLAYING)
		get_tree().change_scene_to_file(_get_game_scene_path())
		await get_tree().tree_changed
		await get_tree().process_frame
		_close_current_overlay()
		_prepare_scenario(scenario_path)
		var ok = save_manager.quick_load()
		if ok:
			presentation_state.emit_restore_signals()
			engine.run()
		return ok

	# In-game: reload in place
	_reset_presentation()
	_prepare_scenario(scenario_path)
	var ok = save_manager.quick_load()
	if ok:
		presentation_state.emit_restore_signals()
		engine.run()
	return ok


## Whether a quick save exists.
func has_quick_save() -> bool:
	return save_manager.has_quick_save()


## Delete the quick save.
func delete_quick_save() -> void:
	save_manager.delete_quick_save()


## Auto save (triggered on game interruption — return to title, app close).
func auto_save() -> void:
	if game_state.current_state != GameStateMachine.State.PLAYING:
		return
	save_manager.auto_save()


## Whether an auto save exists.
func has_auto_save() -> bool:
	return save_manager.has_auto_save()


## Delete the auto save.
func delete_auto_save() -> void:
	save_manager.delete_auto_save()


## Whether any continue save (quick or auto) exists.
func has_continue_save() -> bool:
	return save_manager.has_quick_save() or save_manager.has_auto_save()


## Continue game — load the newest save between quick save and auto save.
## Works from title screen (switches scene) and in-game (reloads in place).
func continue_game() -> bool:
	var continue_type = save_manager.get_latest_continue_type()
	if continue_type == "":
		return false

	var scenario_path = _last_scenario_path
	if scenario_path == "":
		scenario_path = config.scenario_path
	if scenario_path == "":
		return false
	_last_scenario_path = scenario_path

	# From title screen: switch to game scene first
	# Close overlay AFTER scene ready — same reason as continue_from_save.
	if game_state.current_state == GameStateMachine.State.TITLE:
		game_state.transition_to(GameStateMachine.State.PLAYING)
		get_tree().change_scene_to_file(_get_game_scene_path())
		await get_tree().tree_changed
		await get_tree().process_frame
		_close_current_overlay()
		_prepare_scenario(scenario_path)
		var ok = _load_continue(continue_type)
		if ok:
			presentation_state.emit_restore_signals()
			engine.run()
		return ok

	# In-game: reload in place
	_reset_presentation()
	_prepare_scenario(scenario_path)
	var ok = _load_continue(continue_type)
	if ok:
		presentation_state.emit_restore_signals()
		engine.run()
	return ok


## Load from the appropriate continue save type.
func _load_continue(continue_type: String) -> bool:
	if continue_type == "quick":
		return save_manager.quick_load()
	elif continue_type == "auto":
		return save_manager.auto_load()
	return false


## Save to a specific slot.
func save(slot_id: int) -> void:
	save_manager.save(slot_id)


## Check if a save exists in a slot.
func has_save(slot_id: int) -> bool:
	return save_manager.has_save(slot_id)


## Delete a save slot.
func delete_save(slot_id: int) -> void:
	save_manager.delete_save(slot_id)


## Get list of occupied save slot IDs.
func get_save_list() -> Array:
	return save_manager.get_save_list()


# ─── Facade API: Playback Control ───

## Toggle auto-play mode. Stops skip if activating auto-play.
func toggle_auto_play() -> void:
	auto_play.toggle()
	if auto_play.is_active:
		skip_controller.stop()


## Toggle skip mode. Stops auto-play if activating skip.
func toggle_skip() -> void:
	skip_controller.toggle()
	if skip_controller.is_active:
		auto_play.stop()


## Whether auto-play is currently active.
func is_auto_playing() -> bool:
	return auto_play.is_active


## Whether skip mode is currently active.
func is_skipping() -> bool:
	return skip_controller.is_active


# ─── Facade API: UI Overlays ───

## Show the backlog overlay.
func show_backlog() -> void:
	var scene_path = config.backlog_scene if config.backlog_scene != "" else DEFAULT_BACKLOG_SCENE
	_open_overlay(scene_path)
	game_state.transition_to(GameStateMachine.State.BACKLOG)


## Show the save/load overlay.
func show_save_load(mode: String = "save") -> void:
	var scene_path = config.save_load_scene if config.save_load_scene != "" else DEFAULT_SAVE_LOAD_SCENE
	_open_overlay(scene_path)
	if _current_overlay and _current_overlay.has_method("set_mode"):
		_current_overlay.set_mode(mode)
	game_state.transition_to(GameStateMachine.State.SAVE_LOAD)


## Show the settings overlay.
func show_settings() -> void:
	var scene_path = config.settings_scene if config.settings_scene != "" else DEFAULT_SETTINGS_SCENE
	_open_overlay(scene_path)
	game_state.transition_to(GameStateMachine.State.SETTINGS)


## Close the current overlay and return to previous state.
func close_overlay() -> void:
	if config.se_cancel != "":
		SignalBus.system_se_play.emit(config.se_cancel)
	_close_current_overlay()
	game_state.return_to_previous()


func _open_overlay(scene_path: String) -> void:
	if _current_overlay != null:
		push_warning("NatsumeRuntime: opening overlay while another is active — closing previous")
	_close_current_overlay()
	var scene = load(scene_path) as PackedScene
	if scene == null:
		push_error("NatsumeRuntime: cannot load overlay scene %s" % scene_path)
		return
	_current_overlay = scene.instantiate()
	# Add as CanvasLayer child so it renders above game content
	var overlay_layer = CanvasLayer.new()
	overlay_layer.layer = 10
	overlay_layer.name = "OverlayLayer"
	overlay_layer.add_child(_current_overlay)
	add_child(overlay_layer)


func _close_current_overlay() -> void:
	if _current_overlay != null:
		var layer = _current_overlay.get_parent()
		_current_overlay = null
		if layer != null:
			layer.queue_free()


# ─── Facade API: Backlog ───

## Get dialogue history entries.
func get_backlog() -> Array:
	return backlog_manager.get_entries()


# ─── Facade API: Settings ───

## Get a setting value by key.
func get_setting(key: String) -> Variant:
	var val = settings_manager.settings.get(key)
	if val == null and not key in settings_manager.settings.to_dict():
		push_warning("NatsumeRuntime.get_setting: unknown key '%s'" % key)
	return val


## Set a setting value by key.
func set_setting(key: String, value: Variant) -> void:
	settings_manager.set_value(key, value)


## Persist settings to disk.
func save_settings() -> void:
	settings_manager.save()


## Reset all settings to defaults.
func reset_settings() -> void:
	settings_manager.reset_to_default()


func _play_title_bgm() -> void:
	SignalBus.bgm_play.emit(config.title_bgm, 1.0)


## Play a system sound effect (UI clicks, confirmations, etc.)
func play_system_se(asset: String) -> void:
	SignalBus.system_se_play.emit(asset)


## Get save metadata for a slot (timestamp, etc). Returns empty dict if no save.
func get_save_metadata(slot_id: int) -> Dictionary:
	return save_manager.get_save_metadata(slot_id)
