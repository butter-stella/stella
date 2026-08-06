extends GutTest
## Tests for POC command handlers — verifying signal emission and behavior.


var _registry: CommandRegistry
var _context: ScenarioContext
var _bus: Node


func before_each():
	_registry = CommandRegistry.new()
	# Create a minimal scenario for context
	var scenario = ScenarioData.new()
	scenario.id = "test"
	var scene = SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_context = ScenarioContext.new(scenario)
	# Get the autoloaded SignalBus
	_bus = get_tree().root.get_node("SignalBus")


func _build_cmd(type: String, params: Dictionary = {}) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


# --- DialogueHandler ---

func test_dialogue_handler_emits_signal():
	var handler = DialogueHandler.new()
	var received: Array = []
	_bus.show_dialogue.connect(func(c, segs, m):
		received.append({"character": c, "segments": segs, "mode": m})
	)

	var cmd = _build_cmd("dialogue", {
		"character": "sakura",
		"text": "Hello!",
		"voice": "voice_001",
		"mode": "adv",
	})

	# Complete advance immediately so handler doesn't block
	_bus.advance_requested.emit.call_deferred()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["segments"].size(), 1)
	assert_eq(received[0]["segments"][0]["text"], "Hello!")
	assert_eq(received[0]["segments"][0]["voice"], "voice_001")


func test_dialogue_handler_defaults():
	var handler = DialogueHandler.new()
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, segs, m):
		received.append({"mode": m, "voice": segs[0]["voice"]})
	)

	var cmd = _build_cmd("dialogue", {"text": "Narration"})
	_bus.advance_requested.emit.call_deferred()
	await handler.execute(cmd, _context)

	assert_eq(received[0]["mode"], "adv")
	assert_eq(received[0]["voice"], "")


func test_dialogue_handler_passes_segments_through():
	var handler = DialogueHandler.new()
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, segs, _m): received.append(segs))

	var segments = [
		{"text": "一", "voice": "v1", "expression": "sad"},
		{"text": "二", "voice": "v2", "expression": "happy"},
	]
	var cmd = _build_cmd("dialogue", {
		"character": "sakura",
		"text": "一二",
		"voice": "v1",
		"mode": "adv",
		"segments": segments,
	})

	_bus.advance_requested.emit.call_deferred()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0].size(), 2)
	assert_eq(received[0][0]["voice"], "v1")
	assert_eq(received[0][1]["expression"], "happy")


func test_dialogue_handler_scopes_compiled_presentation_without_changing_signal_shape():
	var handler = DialogueHandler.new()
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, _segments, mode):
		received.append({
			"mode": mode,
			"profile": _bus.current_dialogue_presentation_profile(),
			"declarative": _bus.current_dialogue_uses_declarative_presentation(),
		})
	)
	var cmd = _build_cmd("dialogue", {
		"text": "Configured",
		"mode": "nvl",
		"declarative_presentation": true,
		"presentation_profile": {"line_spacing": 8},
	})

	_bus.advance_requested.emit.call_deferred()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["mode"], "nvl")
	assert_eq(received[0]["profile"], {"line_spacing": 8})
	assert_true(received[0]["declarative"])
	assert_eq(_bus.current_dialogue_presentation_profile(), {},
		"profile metadata must not leak past synchronous signal dispatch")


# --- BgHandler ---

func test_bg_handler_emits_signal():
	var handler = BgHandler.new()
	var received: Array = []
	_bus.bg_changed.connect(func(a, t, d): received.append({"asset": a, "transition": t, "duration": d}))

	var cmd = _build_cmd("bg", {"asset": "bg_school", "transition": "fade", "duration": 0.8})
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "bg_school")
	assert_eq(received[0]["transition"], "fade")
	assert_almost_eq(received[0]["duration"], 0.8, 0.001)


func test_bg_handler_defaults():
	var handler = BgHandler.new()
	var received: Array = []
	_bus.bg_changed.connect(func(a, t, d): received.append({"transition": t, "duration": d}))

	var cmd = _build_cmd("bg", {"asset": "bg_school"})
	await handler.execute(cmd, _context)

	assert_eq(received[0]["transition"], "fade")
	assert_almost_eq(received[0]["duration"], 0.5, 0.001)


# --- CharShowHandler ---

func test_char_show_handler_emits_signal():
	var handler = CharShowHandler.new()
	var received: Array = []
	_bus.char_show.connect(func(c, e, p): received.append({"character": c, "expression": e, "position": p}))

	var cmd = _build_cmd("char_show", {"character": "sakura", "expression": "smile", "position": "left"})
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["expression"], "smile")
	assert_eq(received[0]["position"], "left")


func test_char_show_handler_defaults():
	var handler = CharShowHandler.new()
	var received: Array = []
	_bus.char_show.connect(func(c, e, p): received.append({"expression": e, "position": p}))

	var cmd = _build_cmd("char_show", {"character": "sakura"})
	await handler.execute(cmd, _context)

	assert_eq(received[0]["expression"], "default")
	assert_eq(received[0]["position"], "center")


# --- CharHideHandler ---

func test_char_hide_handler_emits_signal():
	var handler = CharHideHandler.new()
	var received: Array = []
	_bus.char_hide.connect(func(c): received.append(c))

	var cmd = _build_cmd("char_hide", {"character": "sakura"})
	await handler.execute(cmd, _context)

	assert_eq(received, ["sakura"])


# --- CharExprHandler ---

func test_char_expr_handler_emits_signal():
	var handler = CharExprHandler.new()
	var received: Array = []
	_bus.char_expression_changed.connect(func(c, e): received.append({"character": c, "expression": e}))

	var cmd = _build_cmd("char_expr", {"character": "sakura", "expression": "sad"})
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["expression"], "sad")


# --- JumpHandler ---

func test_jump_handler_sets_pending_jump():
	var handler = JumpHandler.new()
	var cmd = _build_cmd("jump", {"target": "ending"})
	await handler.execute(cmd, _context)
	assert_eq(_context.pending_jump, "ending")


# --- SetHandler ---

func test_set_handler_assigns_variable():
	var store = VariableStore.new()
	_context.variable_store = store
	var handler = SetHandler.new()

	var cmd = _build_cmd("set", {"var": "talked", "value": true})
	await handler.execute(cmd, _context)

	assert_true(store.get_var("talked"))


func test_set_handler_increment():
	var store = VariableStore.new()
	store.set_var("score", 10)
	_context.variable_store = store
	var handler = SetHandler.new()

	var cmd = _build_cmd("set", {"var": "score", "value": 5, "op": "+="})
	await handler.execute(cmd, _context)

	assert_eq(store.get_var("score"), 15)


# --- ConditionHandler ---

func test_condition_handler_jumps_to_then():
	var store = VariableStore.new()
	store.set_var("affection", 10)
	_context.variable_store = store
	var handler = ConditionHandler.new()

	var cmd = _build_cmd("condition", {"if": "affection >= 10", "then_jump": "good_end", "else_jump": "bad_end"})
	await handler.execute(cmd, _context)

	assert_eq(_context.pending_jump, "good_end")


func test_condition_handler_jumps_to_else():
	var store = VariableStore.new()
	store.set_var("affection", 5)
	_context.variable_store = store
	var handler = ConditionHandler.new()

	var cmd = _build_cmd("condition", {"if": "affection >= 10", "then_jump": "good_end", "else_jump": "bad_end"})
	await handler.execute(cmd, _context)

	assert_eq(_context.pending_jump, "bad_end")
