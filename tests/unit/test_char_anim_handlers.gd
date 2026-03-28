extends GutTest
## Tests for AnimHandler and MoveHandler.


func test_anim_handler_type():
	var handler = AnimHandler.new()
	assert_eq(handler.get_command_type(), "char_anim")


func test_anim_handler_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.char_anim_requested.connect(func(c, a, i): received.append({"character": c, "anim": a, "intensity": i}))

	var handler = AnimHandler.new()
	var cmd = CommandData.new()
	cmd.type = "char_anim"
	cmd.params = {"character": "sakura", "anim": "jump", "intensity": "normal"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["anim"], "jump")
	assert_eq(received[0]["intensity"], "normal")


func test_anim_handler_defaults():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.char_anim_requested.connect(func(c, a, i): received.append({"intensity": i}))

	var handler = AnimHandler.new()
	var cmd = CommandData.new()
	cmd.type = "char_anim"
	cmd.params = {"character": "sakura", "anim": "shake"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received[0]["intensity"], "normal")


func test_move_handler_type():
	var handler = MoveHandler.new()
	assert_eq(handler.get_command_type(), "char_move")


func test_move_handler_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.char_move_requested.connect(func(c, p, d): received.append({"character": c, "position": p, "duration": d}))

	var handler = MoveHandler.new()
	var cmd = CommandData.new()
	cmd.type = "char_move"
	cmd.params = {"character": "sakura", "position": "right", "duration": 0.5}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["position"], "right")


func test_move_handler_defaults():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.char_move_requested.connect(func(c, p, d): received.append({"duration": d}))

	var handler = MoveHandler.new()
	var cmd = CommandData.new()
	cmd.type = "char_move"
	cmd.params = {"character": "sakura", "position": "left"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_almost_eq(received[0]["duration"], 0.5, 0.01)


func test_dsl_parser_anim():
	var tokens = DslLexer.tokenize("@scene s\n@anim sakura jump")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "char_anim")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("anim"), "jump")


func test_dsl_parser_anim_with_intensity():
	var tokens = DslLexer.tokenize("@scene s\n@anim sakura shake strong")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("intensity"), "strong")


func test_dsl_parser_move():
	var tokens = DslLexer.tokenize("@scene s\n@move sakura right 0.3")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "char_move")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("position"), "right")
	assert_almost_eq(cmd.get_float("duration"), 0.3, 0.01)
