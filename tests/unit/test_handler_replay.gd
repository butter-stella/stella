extends GutTest
## Tests for handler behavior in replay mode (context.is_replay = true).
##
## Replay mode contract:
## - Await-based handlers (dialogue/wait/fade/anim/move) skip awaits.
## - Audio/dialogue handlers (voice/se/dialogue/bgm) skip emit (no playback
##   or display during replay).
## - Visual state handlers (bg/char_*/bgm) mutate PresentationState directly
##   instead of emitting, so the in-game presenters don't animate.
## - Logic handlers (set/jump/condition/call) execute normally.


var _context: ScenarioContext
var _bus: Node
var _pres_state: PresentationState


func before_each():
	var scenario = ScenarioData.new()
	scenario.id = "test"
	var scene = SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_context = ScenarioContext.new(scenario)
	_context.variable_store = VariableStore.new()
	_context.is_replay = true
	_pres_state = PresentationState.new()
	_context.presentation_state = _pres_state
	_bus = get_tree().root.get_node("SignalBus")


func _build_cmd(type: String, params: Dictionary = {}) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


# ─── Skip-only handlers (no emit, no PresentationState impact) ───

func test_dialogue_handler_in_replay_skips_emit_and_await():
	var handler = DialogueHandler.new()
	var received: Array = []
	var cb = func(c, segs, m): received.append([c, segs, m])
	_bus.show_dialogue.connect(cb)

	var cmd = _build_cmd("dialogue", {"character": "a", "text": "hi"})
	# Must complete WITHOUT any advance_requested — proves no await happens.
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 0, "no show_dialogue during replay")
	_bus.show_dialogue.disconnect(cb)


func test_wait_handler_in_replay_skips_await():
	var handler = WaitHandler.new()
	# Click mode would normally block forever waiting for advance_requested.
	var cmd = _build_cmd("wait", {"mode": "click"})
	await handler.execute(cmd, _context)
	# Just reaching here proves no await blocked.
	pass_test("wait handler returned without blocking")


func test_voice_handler_in_replay_skips_emit():
	var handler = VoiceHandler.new()
	var received: Array = []
	var cb = func(a, c): received.append([a, c])
	_bus.voice_play.connect(cb)
	await handler.execute(_build_cmd("voice", {"asset": "v1"}), _context)
	assert_eq(received.size(), 0)
	_bus.voice_play.disconnect(cb)


func test_se_handler_in_replay_skips_emit():
	var handler = SeHandler.new()
	var received: Array = []
	var cb = func(_a, _l): received.append(true)
	_bus.se_play.connect(cb)
	await handler.execute(_build_cmd("se", {"asset": "s1"}), _context)
	assert_eq(received.size(), 0)
	_bus.se_play.disconnect(cb)


func test_fade_handler_in_replay_skips_emit():
	var handler = FadeHandler.new()
	var received: Array = []
	var cb = func(_d, _du): received.append(true)
	_bus.fade_requested.connect(cb)
	await handler.execute(_build_cmd("fade", {"direction": "out"}), _context)
	assert_eq(received.size(), 0)
	_bus.fade_requested.disconnect(cb)


func test_anim_handler_in_replay_skips_emit():
	var handler = AnimHandler.new()
	var received: Array = []
	var cb = func(_c, _a, _i): received.append(true)
	_bus.char_anim_requested.connect(cb)
	await handler.execute(_build_cmd("char_anim", {"character": "a", "anim": "shake"}), _context)
	assert_eq(received.size(), 0)
	_bus.char_anim_requested.disconnect(cb)


# ─── PresentationState-mirroring handlers ───

func test_bg_handler_in_replay_mutates_state_no_emit():
	var handler = BgHandler.new()
	var received: Array = []
	var cb = func(_a, _t, _d): received.append(true)
	_bus.bg_changed.connect(cb)

	await handler.execute(_build_cmd("bg", {"asset": "park.png"}), _context)

	assert_eq(received.size(), 0, "no bg_changed signal during replay")
	assert_eq(_pres_state.current_bg, "park.png")
	_bus.bg_changed.disconnect(cb)


func test_char_show_handler_in_replay_mutates_state():
	var handler = CharShowHandler.new()
	var received: Array = []
	var cb = func(_c, _e, _p): received.append(true)
	_bus.char_show.connect(cb)

	await handler.execute(_build_cmd("char_show", {
		"character": "sakura", "expression": "smile", "position": "left",
	}), _context)

	assert_eq(received.size(), 0)
	assert_true(_pres_state.visible_characters.has("sakura"))
	assert_eq(_pres_state.visible_characters["sakura"]["expression"], "smile")
	assert_eq(_pres_state.visible_characters["sakura"]["position"], "left")
	_bus.char_show.disconnect(cb)


func test_char_hide_handler_in_replay_mutates_state():
	_pres_state.visible_characters = {"a": {"expression": "x", "position": "y"}}
	var handler = CharHideHandler.new()
	await handler.execute(_build_cmd("char_hide", {"character": "a"}), _context)
	assert_false(_pres_state.visible_characters.has("a"))


func test_char_expr_handler_in_replay_mutates_state():
	_pres_state.visible_characters = {"a": {"expression": "old", "position": "c"}}
	var handler = CharExprHandler.new()
	await handler.execute(_build_cmd("char_expr", {
		"character": "a", "expression": "new",
	}), _context)
	assert_eq(_pres_state.visible_characters["a"]["expression"], "new")


func test_move_handler_in_replay_mutates_state_no_emit():
	_pres_state.visible_characters = {"a": {"expression": "x", "position": "left"}}
	var handler = MoveHandler.new()
	var received: Array = []
	var cb = func(_c, _p, _d): received.append(true)
	_bus.char_move_requested.connect(cb)
	await handler.execute(_build_cmd("char_move", {
		"character": "a", "position": "right",
	}), _context)
	assert_eq(received.size(), 0)
	assert_eq(_pres_state.visible_characters["a"]["position"], "right")
	_bus.char_move_requested.disconnect(cb)


func test_bgm_handler_in_replay_mutates_state_no_emit():
	var handler = BgmHandler.new()
	var received: Array = []
	var cb = func(_a, _f): received.append(true)
	_bus.bgm_play.connect(cb)
	await handler.execute(_build_cmd("bgm", {"asset": "track1"}), _context)
	assert_eq(received.size(), 0)
	assert_eq(_pres_state.current_bgm, "track1")
	_bus.bgm_play.disconnect(cb)


func test_bgm_stop_handler_in_replay_mutates_state():
	_pres_state.current_bgm = "old"
	var handler = BgmHandler.new()
	await handler.execute(_build_cmd("bgm", {"off": true}), _context)
	assert_eq(_pres_state.current_bgm, "")


# ─── Logic handlers must still execute ───

func test_set_handler_executes_normally_in_replay():
	var handler = SetHandler.new()
	await handler.execute(_build_cmd("set", {"var": "x", "value": 42}), _context)
	assert_eq(_context.variable_store.get_var("x"), 42)


func test_jump_handler_executes_normally_in_replay():
	var handler = JumpHandler.new()
	await handler.execute(_build_cmd("jump", {"target": "ending"}), _context)
	assert_eq(_context.pending_jump, "ending")


# ─── Normal mode unchanged ───

func test_bg_handler_in_normal_mode_emits():
	_context.is_replay = false
	var handler = BgHandler.new()
	var received: Array = []
	var cb = func(a, _t, _d): received.append(a)
	_bus.bg_changed.connect(cb)
	await handler.execute(_build_cmd("bg", {"asset": "x.png"}), _context)
	assert_eq(received.size(), 1)
	assert_eq(received[0], "x.png")
	_bus.bg_changed.disconnect(cb)
