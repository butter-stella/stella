## Framework entry point. Initializes engine, registers handlers, loads scenario.
## Registered as Autoload singleton.
extends Node

var engine: ScenarioEngine
var registry: CommandRegistry


func _ready():
	registry = CommandRegistry.new()
	engine = ScenarioEngine.new()
	engine.registry = registry
	_register_handlers()


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


func start_scenario(scenario_path: String) -> void:
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
	engine.run()
