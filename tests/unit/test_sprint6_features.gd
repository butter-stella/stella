extends GutTest
## Tests for Sprint 6.2: CG handler, effect handler, NVL/overlay mode, parallel handler.


# --- CgHandler ---

func test_cg_handler_type():
	var handler = CgHandler.new()
	assert_eq(handler.get_command_type(), "cg")


func test_cg_handler_show_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.cg_show.connect(func(a, m, t, d): received.append({"asset": a, "mode": m, "transition": t, "duration": d}))

	var handler = CgHandler.new()
	var cmd = CommandData.new()
	cmd.type = "cg"
	cmd.params = {"asset": "sakura_cg", "mode": "fullscreen", "transition": "fade", "duration": 0.5}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "sakura_cg")


func test_cg_handler_off_emits_hide():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.cg_hide.connect(func(t, d): received.append({"transition": t, "duration": d}))

	var handler = CgHandler.new()
	var cmd = CommandData.new()
	cmd.type = "cg"
	cmd.params = {"off": true, "transition": "fade", "duration": 0.5}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)


func test_cg_handler_defaults():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.cg_show.connect(func(a, m, t, d): received.append({"mode": m, "transition": t, "duration": d}))

	var handler = CgHandler.new()
	var cmd = CommandData.new()
	cmd.type = "cg"
	cmd.params = {"asset": "test_cg"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received[0]["mode"], "fullscreen")
	assert_eq(received[0]["transition"], "fade")
	assert_almost_eq(received[0]["duration"], 0.5, 0.01)


# --- EffectHandler ---

func test_effect_handler_type():
	var handler = EffectHandler.new()
	assert_eq(handler.get_command_type(), "effect")


func test_effect_handler_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.effect_requested.connect(func(t, p): received.append({"type": t, "params": p}))

	var handler = EffectHandler.new()
	var cmd = CommandData.new()
	cmd.type = "effect"
	cmd.params = {"effect_type": "shake"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["type"], "shake")


# --- NVL/Overlay mode in DSL parser ---

func test_nvl_mode_sets_dialogue_mode():
	var source = """@scene start
@nvl
「第一行。」
「第二行。」
@nvl off
sakura「普通对话。」"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")

	assert_eq(data.scenes[0].commands[0].get_string("mode"), "nvl")
	assert_eq(data.scenes[0].commands[1].get_string("mode"), "nvl")
	assert_eq(data.scenes[0].commands[2].get_string("mode"), "adv")


func test_overlay_mode_sets_dialogue_mode():
	var source = """@scene start
@overlay
「独白文字。」
@overlay off"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")

	assert_eq(data.scenes[0].commands[0].get_string("mode"), "overlay")


# --- DSL Parser for @cg, @effect ---

func test_dsl_parser_cg():
	var tokens = DslLexer.tokenize("@scene s\n@cg sakura_confession")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "cg")
	assert_eq(cmd.get_string("asset"), "sakura_confession")


func test_dsl_parser_cg_sd():
	var tokens = DslLexer.tokenize("@scene s\n@cg chibi_angry sd")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("mode"), "sd")


func test_dsl_parser_cg_off():
	var tokens = DslLexer.tokenize("@scene s\n@cg off")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_true(cmd.get_bool("off"))


func test_dsl_parser_effect():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "effect")
	assert_eq(cmd.get_string("effect_type"), "shake")


func test_dsl_parser_effect_off():
	var tokens = DslLexer.tokenize("@scene s\n@effect off")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_true(cmd.get_bool("off"))


# --- ParallelHandler ---

func test_parallel_handler_type():
	var handler = ParallelHandler.new()
	assert_eq(handler.get_command_type(), "parallel")


func test_dsl_parser_parallel():
	var source = """@scene start
@parallel
  @bg bg_sunset dissolve 1.0
  @show sakura smile center
@end"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "parallel")
	var sub_commands = cmd.params.get("commands", [])
	assert_eq(sub_commands.size(), 2)
	assert_eq(sub_commands[0].type, "bg")
	assert_eq(sub_commands[1].type, "char_show")
