## Framework entry point. Initializes engine, registers handlers, manages scene lifecycle.
## Registered as Autoload singleton — persists across scene changes.
extends Node

const CONFIG_PATH = "res://natsume.cfg"
const DEFAULT_TITLE_SCENE = "res://addons/natsume/scenes/title.tscn"
const DEFAULT_GAME_SCENE = "res://addons/natsume/scenes/game.tscn"

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


func _ready():
	# Load project config
	config = NatsumeConfig.new()
	config.load_from_path(CONFIG_PATH)
	_apply_config()

	save_manager = SaveManager.new()
	settings_manager = SettingsManager.new()
	settings_manager.load_settings()
	backlog_manager = BacklogManager.new()
	auto_play = AutoPlayController.new()
	skip_controller = SkipController.new()
	read_flags = ReadFlagManager.new()
	game_state = GameStateMachine.new()
	unlock_manager = UnlockManager.new()

	save_manager.register_provider(read_flags)
	save_manager.register_provider(unlock_manager)

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


## Apply config values to runtime paths.
func _apply_config() -> void:
	backgrounds_path = config.backgrounds_path
	characters_path = config.characters_path
	bgm_path = config.bgm_path
	se_path = config.se_path
	voice_path = config.voice_path

	if config.title_scene != "":
		title_scene_path = config.title_scene
	else:
		title_scene_path = DEFAULT_TITLE_SCENE

	if not config.has_config_file:
		# Check if paths were manually set (legacy bootstrap.gd pattern)
		# If so, don't overwrite them — but warn about migration
		if _paths_differ_from_defaults():
			push_warning("NatsumeRuntime: No natsume.cfg found. Consider creating one for configuration.")


func _paths_differ_from_defaults() -> bool:
	var default_config = NatsumeConfig.new()
	return (backgrounds_path != default_config.backgrounds_path
		or characters_path != default_config.characters_path
		or bgm_path != default_config.bgm_path
		or se_path != default_config.se_path
		or voice_path != default_config.voice_path)


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
	_start_scenario_internal(scenario_path)
	save_manager.load_save(slot_id)
	return true


## Continue from quick save (used by toolbar quick-load).
func continue_from_save(slot_id: int) -> bool:
	if _last_scenario_path == "" or not save_manager.has_save(slot_id):
		return false
	_start_scenario_internal(_last_scenario_path)
	save_manager.load_save(slot_id)
	return true


## Return to title screen.
func return_to_title() -> void:
	backlog_manager.clear()
	auto_play.stop()
	skip_controller.stop()
	game_state.transition_to(GameStateMachine.State.TITLE)
	if title_scene_path != "":
		get_tree().change_scene_to_file(title_scene_path)


## Legacy API — starts scenario in current scene (for testing).
func start_scenario(scenario_path: String) -> void:
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_start_scenario_internal(scenario_path)


func _start_scenario_internal(scenario_path: String) -> void:
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
	engine.run()


func _on_scenario_ended(id: String) -> void:
	SignalBus.scenario_ended_event.emit(id)
	# Auto return to title after scenario ends
	return_to_title()


func _on_dialogue_for_backlog(character: String, text: String, voice: String, _mode: String):
	backlog_manager.add_entry(character, text, voice)
