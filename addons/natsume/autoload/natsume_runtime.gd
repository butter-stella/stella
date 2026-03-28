## Framework entry point. Initializes engine, registers handlers, loads scenario.
## Registered as Autoload singleton.
extends Node

var engine: ScenarioEngine
var registry: CommandRegistry

## Subsystem instances — exposed for UI to interact with.
var save_manager: SaveManager
var settings_manager: SettingsManager
var backlog_manager: BacklogManager
var auto_play: AutoPlayController
var skip_controller: SkipController
var read_flags: ReadFlagManager
var game_state: GameStateMachine
var unlock_manager: UnlockManager

## Resource base paths — configure these before starting a scenario.
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
var bgm_path: String = "res://audio/bgm/"
var se_path: String = "res://audio/se/"
var voice_path: String = "res://audio/voice/"


func _ready():
	# Core subsystems
	save_manager = SaveManager.new()
	settings_manager = SettingsManager.new()
	settings_manager.load_settings()
	backlog_manager = BacklogManager.new()
	auto_play = AutoPlayController.new()
	skip_controller = SkipController.new()
	read_flags = ReadFlagManager.new()
	game_state = GameStateMachine.new()
	unlock_manager = UnlockManager.new()

	# Register snapshot providers
	save_manager.register_provider(read_flags)
	save_manager.register_provider(unlock_manager)

	# Engine
	registry = CommandRegistry.new()
	engine = ScenarioEngine.new()
	engine.registry = registry
	_register_handlers()

	# Bridge engine signals to SignalBus
	engine.scenario_started.connect(func(id): SignalBus.scenario_started_event.emit(id))
	engine.scenario_ended.connect(func(id): SignalBus.scenario_ended_event.emit(id))
	engine.scene_changed.connect(func(id): SignalBus.scene_changed_event.emit(id))

	# Wire dialogue to backlog
	SignalBus.show_dialogue.connect(_on_dialogue_for_backlog)


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
	registry.register(CallHandler.new())
	registry.register(CgHandler.new())
	registry.register(EffectHandler.new())
	var parallel_handler = ParallelHandler.new()
	parallel_handler._registry = registry
	registry.register(parallel_handler)


func start_scenario(scenario_path: String) -> void:
	_last_scenario_path = scenario_path
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

	# Register engine context as snapshot provider
	save_manager.register_provider(engine.context)
	save_manager.register_provider(engine.context.variable_store)

	game_state.transition_to(GameStateMachine.State.PLAYING)
	engine.run()


## The last loaded scenario path — needed for continue/load to re-parse and resume.
var _last_scenario_path: String = ""


func continue_from_save(slot_id: int) -> bool:
	if _last_scenario_path == "" or not save_manager.has_save(slot_id):
		return false

	# Re-parse the scenario
	var file = FileAccess.open(_last_scenario_path, FileAccess.READ)
	if file == null:
		return false
	var source = file.get_as_text()
	file.close()

	var tokens = DslLexer.tokenize(source)
	var scenario_id = _last_scenario_path.get_file().get_basename()
	var data = DslParser.parse(tokens, scenario_id)

	engine.load_scenario(data)

	# Re-register new context as snapshot provider (load_scenario creates a new context)
	save_manager.register_provider(engine.context)
	save_manager.register_provider(engine.context.variable_store)

	# Restore saved state into the new context
	save_manager.load_save(slot_id)

	game_state.transition_to(GameStateMachine.State.PLAYING)
	engine.run()
	return true


func _on_dialogue_for_backlog(character: String, text: String, voice: String, _mode: String):
	backlog_manager.add_entry(character, text, voice)
