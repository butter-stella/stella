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


func test_dsl_parser_effect_shake_with_params():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake 15 0.4")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "effect")
	assert_eq(cmd.get_string("effect_type"), "shake")
	assert_almost_eq(cmd.get_float("intensity"), 15.0, 0.001)
	assert_almost_eq(cmd.get_float("duration"), 0.4, 0.001)


func test_dsl_parser_effect_shake_defaults():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "effect")
	assert_eq(cmd.get_string("effect_type"), "shake")
	# Defaults should apply when user omits numeric params.
	assert_almost_eq(cmd.get_float("intensity"), 10.0, 0.001)
	assert_almost_eq(cmd.get_float("duration"), 0.3, 0.001)


func test_dsl_parser_effect_flash_with_params():
	var tokens = DslLexer.tokenize("@scene s\n@effect flash red 0.25")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "effect")
	assert_eq(cmd.get_string("effect_type"), "flash")
	assert_eq(cmd.get_string("color"), "red")
	assert_almost_eq(cmd.get_float("duration"), 0.25, 0.001)


func test_dsl_parser_effect_flash_defaults():
	var tokens = DslLexer.tokenize("@scene s\n@effect flash")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("effect_type"), "flash")
	assert_eq(cmd.get_string("color"), "white")
	assert_almost_eq(cmd.get_float("duration"), 0.2, 0.001)


func test_dsl_parser_effect_flash_hex_color():
	var tokens = DslLexer.tokenize("@scene s\n@effect flash #ff0000 0.25")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("color"), "#ff0000")
	assert_almost_eq(cmd.get_float("duration"), 0.25, 0.001)


func test_dsl_parser_effect_rejects_overflow_duration_as_safe_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake 1 1e309")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 0.0)
	var diagnostic := _find_effect_diagnostic(data, "error", "shake duration must be finite")
	assert_false(diagnostic.is_empty(), "overflow must produce an author-facing error")
	assert_eq(diagnostic.get("line"), 2)


func test_dsl_parser_effect_rejects_nan_duration_as_safe_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake 1 NaN")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 0.0)
	assert_false(
		_find_effect_diagnostic(data, "error", "@effect shake duration must be").is_empty()
	)


func test_dsl_parser_effect_rejects_inf_duration_as_safe_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect flash white INF")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 0.0)
	assert_false(
		_find_effect_diagnostic(data, "error", "@effect flash duration must be").is_empty()
	)


func test_dsl_parser_effect_rejects_invalid_intensity_as_safe_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake strong 1.0")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("intensity"), 0.0)
	assert_eq(cmd.get_float("duration"), 0.0)
	assert_false(
		_find_effect_diagnostic(data, "error", "shake intensity must be a finite number").is_empty()
	)


func test_dsl_parser_effect_negative_duration_is_an_error_and_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect flash white -0.5")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 0.0)
	assert_false(
		_find_effect_diagnostic(data, "error", "flash duration must be non-negative").is_empty()
	)


func test_dsl_parser_effect_zero_duration_is_a_valid_explicit_noop():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake 10 0")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 0.0)
	assert_true(_find_effect_diagnostic(data, "error", "@effect shake").is_empty())


func test_dsl_parser_effect_preserves_huge_finite_duration():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake 10 1e300")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("duration"), 1.0e300)
	assert_true(is_finite(cmd.get_float("duration")))
	assert_true(_find_effect_diagnostic(data, "error", "@effect shake").is_empty())


func test_dsl_parser_effect_normalizes_negative_shake_intensity_with_warning():
	var tokens = DslLexer.tokenize("@scene s\n@effect shake -12 0.5")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_float("intensity"), 12.0)
	assert_eq(cmd.get_float("duration"), 0.5)
	assert_false(
		_find_effect_diagnostic(data, "warning", "shake intensity is negative").is_empty()
	)


func _find_effect_diagnostic(data: ScenarioData, level: String, substring: String) -> Dictionary:
	for diagnostic in data.diagnostics:
		if diagnostic.get("level") == level and substring in str(diagnostic.get("message", "")):
			return diagnostic
	return {}


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
