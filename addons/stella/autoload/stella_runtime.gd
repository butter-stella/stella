## Framework entry point. Initializes engine, registers handlers, manages scene lifecycle.
## Registered as Autoload singleton — persists across scene changes.
extends Node

const CONFIG_PATH = "res://stella.cfg"
const LOCAL_CONFIG_PATH = "res://stella.local.cfg"
const DISABLE_LOCAL_CONFIG_ENV = "STELLA_DISABLE_LOCAL_CONFIG"
const DEFAULT_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const DEFAULT_TITLE_PACKED_SCENE: PackedScene = preload(
	"res://addons/stella/scenes/title.tscn"
)
const BOOTSTRAP_SCRIPT = "res://addons/stella/scenes/bootstrap.gd"
const DEFAULT_GAME_SCENE = "res://addons/stella/scenes/game.tscn"
const DEFAULT_SETTINGS_SCENE = "res://addons/stella/scenes/settings.tscn"
const DEFAULT_SAVE_LOAD_SCENE = "res://addons/stella/scenes/save_load.tscn"
const DEFAULT_BACKLOG_SCENE = "res://addons/stella/scenes/backlog.tscn"
const DEFAULT_FLOWCHART_SCENE = "res://addons/stella/scenes/flowchart.tscn"
const MAX_TITLE_TEXT_RESOURCE_BYTES = 8 * 1024 * 1024


## Parse serialized Variant values without evaluating them or handing malformed
## private source to Godot's resource parser. The grammar intentionally covers
## the canonical primitives/containers/constructors emitted by Godot 4.x text
## resources; an unsupported token makes the complete source fail preflight.
class _ResourceValueParser:
	var _text: String
	var _index: int = 0
	var _references: Array[Dictionary] = []


	func _init(text: String) -> void:
		_text = text


	func parse() -> Dictionary:
		_skip_ignored()
		var value := _parse_value()
		if not value.get("ok", false):
			return {"ok": false, "references": []}
		_skip_ignored()
		if _index != _text.length():
			return {"ok": false, "references": []}
		return {
			"ok": true,
			"references": _references,
		}


	func _parse_value() -> Dictionary:
		_skip_ignored()
		if _index >= _text.length():
			return {"ok": false}
		var character := _text[_index]
		if character == "\"":
			return _parse_string(false)
		if (
			character in ["&", "^"]
			and _index + 1 < _text.length()
			and _text[_index + 1] == "\""
		):
			return _parse_string(true)
		if character == "[":
			return _parse_array()
		if character == "{":
			return _parse_dictionary()
		if character == "+" or character == "-" or _is_digit(character):
			return _parse_number()
		if _is_identifier_start(character):
			return _parse_identifier_or_constructor()
		return {"ok": false}


	func _parse_string(has_prefix: bool) -> Dictionary:
		if has_prefix:
			_index += 1
		if _index >= _text.length() or _text[_index] != "\"":
			return {"ok": false}
		_index += 1
		var value_parts := PackedStringArray()
		while _index < _text.length():
			var character := _text[_index]
			_index += 1
			if character == "\"":
				return {
					"ok": true,
					"kind": "string",
					"value": "".join(value_parts),
				}
			if character == "\\":
				if _index >= _text.length():
					return {"ok": false}
				value_parts.append(_text[_index])
				_index += 1
				continue
			value_parts.append(character)
		return {"ok": false}


	func _parse_array() -> Dictionary:
		_index += 1
		var values: Array[Dictionary] = []
		_skip_ignored()
		if _consume("]"):
			return {"ok": true, "kind": "array", "values": values}
		while true:
			var value := _parse_value()
			if not value.get("ok", false):
				return {"ok": false}
			values.append(value)
			_skip_ignored()
			if _consume("]"):
				return {"ok": true, "kind": "array", "values": values}
			if not _consume(","):
				return {"ok": false}
			_skip_ignored()
			if _consume("]"):
				return {"ok": true, "kind": "array", "values": values}
		return {"ok": false}


	func _parse_dictionary() -> Dictionary:
		_index += 1
		var entries: Array[Dictionary] = []
		_skip_ignored()
		if _consume("}"):
			return {"ok": true, "kind": "dictionary", "entries": entries}
		while true:
			var key := _parse_value()
			if not key.get("ok", false):
				return {"ok": false}
			_skip_ignored()
			if not _consume(":"):
				return {"ok": false}
			var value := _parse_value()
			if not value.get("ok", false):
				return {"ok": false}
			entries.append({"key": key, "value": value})
			_skip_ignored()
			if _consume("}"):
				return {"ok": true, "kind": "dictionary", "entries": entries}
			if not _consume(","):
				return {"ok": false}
			_skip_ignored()
			if _consume("}"):
				return {"ok": true, "kind": "dictionary", "entries": entries}
		return {"ok": false}


	func _parse_number() -> Dictionary:
		var start := _index
		if _text[_index] in ["+", "-"]:
			_index += 1
		if _consume_word("inf") or _consume_word("nan"):
			return {"ok": true, "kind": "number"}
		var saw_digit := false
		if (
			_index + 1 < _text.length()
			and _text[_index] == "0"
			and _text[_index + 1].to_lower() == "x"
		):
			_index += 2
			var hex_start := _index
			while _index < _text.length() and _is_hex_digit(_text[_index]):
				_index += 1
			if _index == hex_start:
				return {"ok": false}
			return {"ok": true, "kind": "number"}
		while _index < _text.length() and _is_digit(_text[_index]):
			saw_digit = true
			_index += 1
		if _index < _text.length() and _text[_index] == ".":
			_index += 1
			while _index < _text.length() and _is_digit(_text[_index]):
				saw_digit = true
				_index += 1
		if not saw_digit:
			_index = start
			return {"ok": false}
		if _index < _text.length() and _text[_index].to_lower() == "e":
			_index += 1
			if _index < _text.length() and _text[_index] in ["+", "-"]:
				_index += 1
			var exponent_start := _index
			while _index < _text.length() and _is_digit(_text[_index]):
				_index += 1
			if _index == exponent_start:
				return {"ok": false}
		if (
			_index < _text.length()
			and _is_identifier_continue(_text[_index])
		):
			return {"ok": false}
		return {"ok": true, "kind": "number"}


	func _parse_identifier_or_constructor() -> Dictionary:
		var name := _parse_identifier()
		if name in ["true", "false"]:
			return {"ok": true, "kind": "bool"}
		if name == "null":
			return {"ok": true, "kind": "null"}
		if name in ["inf", "nan"]:
			return {"ok": true, "kind": "number"}

		_skip_horizontal_space()
		var generic := ""
		if _index < _text.length() and _text[_index] == "[":
			generic = _parse_generic_type_list()
			if generic.is_empty():
				return {"ok": false}
			_skip_horizontal_space()
		if not _consume("("):
			return {"ok": false}
		var arguments: Array[Dictionary] = []
		_skip_ignored()
		if not _consume(")"):
			while true:
				var argument := _parse_value()
				if not argument.get("ok", false):
					return {"ok": false}
				arguments.append(argument)
				_skip_ignored()
				if _consume(")"):
					break
				if not _consume(","):
					return {"ok": false}
				_skip_ignored()
				if _consume(")"):
					break
		if not _constructor_arguments_are_valid(name, generic, arguments):
			return {"ok": false}
		if name in ["ExtResource", "SubResource"]:
			_references.append({
				"kind": name,
				"id": arguments[0]["value"],
			})
		return {
			"ok": true,
			"kind": "constructor",
			"name": name,
			"arguments": arguments,
		}


	func _parse_generic_type_list() -> String:
		var start := _index
		var depth := 0
		while _index < _text.length():
			var character := _text[_index]
			if character == "[":
				depth += 1
			elif character == "]":
				depth -= 1
				if depth == 0:
					_index += 1
					return _text.substr(start, _index - start)
			elif not (
				character in [" ", "\t", "\r", "\n", ",", ".", "_"]
				or _is_digit(character)
				or character >= "A" and character <= "Z"
				or character >= "a" and character <= "z"
			):
				return ""
			_index += 1
		return ""


	func _constructor_arguments_are_valid(
		name: String,
		generic: String,
		arguments: Array[Dictionary],
	) -> bool:
		if not _constructor_is_known(name):
			return false
		if not generic.is_empty() and name not in ["Array", "Dictionary"]:
			return false
		if name in ["ExtResource", "SubResource"]:
			return (
				arguments.size() == 1
				and arguments[0].get("kind", "") == "string"
				and not String(arguments[0].get("value", "")).is_empty()
			)
		if name in ["NodePath", "String", "StringName"]:
			return (
				arguments.size() == 1
				and arguments[0].get("kind", "") == "string"
			)
		if name in ["Callable", "Signal"]:
			return arguments.is_empty()
		if name == "RID":
			return (
				arguments.is_empty()
				or _arguments_are_numbers(arguments, 1)
			)
		var exact_numeric_arity := {
			"Vector2": 2, "Vector2i": 2,
			"Vector3": 3, "Vector3i": 3,
			"Vector4": 4, "Vector4i": 4,
			"Rect2": 4, "Rect2i": 4,
			"Transform2D": 6,
			"Plane": 4,
			"Quaternion": 4,
			"AABB": 6,
			"Basis": 9,
			"Transform3D": 12,
			"Projection": 16,
		}
		if exact_numeric_arity.has(name):
			return _arguments_are_numbers(arguments, exact_numeric_arity[name])
		if name == "Color":
			return (
				_arguments_are_numbers(arguments, 4)
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "string"
				)
			)
		if name == "Array":
			return (
				arguments.is_empty()
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "array"
				)
			)
		if name == "Dictionary":
			return (
				arguments.is_empty()
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "dictionary"
				)
			)
		if name in [
			"PackedByteArray", "PackedInt32Array", "PackedInt64Array",
			"PackedFloat32Array", "PackedFloat64Array",
		]:
			return _arguments_are_numbers(arguments, arguments.size())
		if name == "PackedStringArray":
			return _arguments_have_kind(arguments, "string")
		var packed_numeric_width := {
			"PackedVector2Array": 2,
			"PackedVector3Array": 3,
			"PackedVector4Array": 4,
			"PackedColorArray": 4,
		}
		if packed_numeric_width.has(name):
			var width: int = packed_numeric_width[name]
			return (
				arguments.size() % width == 0
				and _arguments_are_numbers(arguments, arguments.size())
			)
		# Object()/EncodedObjectAsID() are not emitted for resource properties in
		# supported Stella scenes, and safely validating their class/property
		# semantics would require executing constructors. Reject them before the
		# Godot parser can echo malformed private tokens.
		return false


	func _arguments_are_numbers(
		arguments: Array[Dictionary],
		expected_count: int,
	) -> bool:
		if arguments.size() != expected_count:
			return false
		for argument: Dictionary in arguments:
			if argument.get("kind", "") != "number":
				return false
		return true


	func _arguments_have_kind(
		arguments: Array[Dictionary],
		expected_kind: String,
	) -> bool:
		for argument: Dictionary in arguments:
			if argument.get("kind", "") != expected_kind:
				return false
		return true


	func _constructor_is_known(name: String) -> bool:
		return name in [
			"AABB", "Array", "Basis", "Callable", "Color", "Dictionary",
			"EncodedObjectAsID", "ExtResource", "NodePath", "Object", "Plane",
			"Projection", "Quaternion", "Rect2", "Rect2i", "RID", "Signal",
			"String", "StringName", "SubResource", "Transform2D", "Transform3D",
			"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i",
			"PackedByteArray", "PackedInt32Array", "PackedInt64Array",
			"PackedFloat32Array", "PackedFloat64Array", "PackedStringArray",
			"PackedVector2Array", "PackedVector3Array", "PackedVector4Array",
			"PackedColorArray",
		]


	func _parse_identifier() -> String:
		var start := _index
		_index += 1
		while (
			_index < _text.length()
			and _is_identifier_continue(_text[_index])
		):
			_index += 1
		return _text.substr(start, _index - start)


	func _skip_ignored() -> void:
		while _index < _text.length():
			var character := _text[_index]
			if character in [" ", "\t", "\r", "\n"]:
				_index += 1
				continue
			if character == ";":
				while _index < _text.length() and _text[_index] != "\n":
					_index += 1
				continue
			break


	func _skip_horizontal_space() -> void:
		while _index < _text.length() and _text[_index] in [" ", "\t"]:
			_index += 1


	func _consume(expected: String) -> bool:
		if _index >= _text.length() or _text[_index] != expected:
			return false
		_index += 1
		return true


	func _consume_word(word: String) -> bool:
		if _text.substr(_index, word.length()).to_lower() != word:
			return false
		var end := _index + word.length()
		if end < _text.length() and _is_identifier_continue(_text[end]):
			return false
		_index = end
		return true


	func _is_digit(character: String) -> bool:
		return character >= "0" and character <= "9"


	func _is_hex_digit(character: String) -> bool:
		var lower := character.to_lower()
		return _is_digit(character) or lower >= "a" and lower <= "f"


	func _is_identifier_start(character: String) -> bool:
		return (
			character == "_"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
		)


	func _is_identifier_continue(character: String) -> bool:
		return _is_identifier_start(character) or _is_digit(character)

var engine: ScenarioEngine
var registry: CommandRegistry
var config: StellaConfig

## Subsystem instances
var save_manager: SaveManager
var settings_manager: SettingsManager
var backlog_manager: BacklogManager
var choice_history_manager: ChoiceHistoryManager
var auto_play: AutoPlayController
var skip_controller: SkipController
var read_flags: ReadFlagManager
var game_state: GameStateMachine
var unlock_manager: UnlockManager
var presentation_state: PresentationState
var character_config_loader: CharacterConfigLoader
## Issue #97: flowchart subsystem
var flowchart_state: FlowchartState
var flowchart_visited: FlowchartVisitedState
var scenario_graph: ScenarioGraph

## Resource base paths — always mirrored from the resolved config snapshot.
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
var stage_assets_path: String = "res://art/stage/"
var bgm_path: String = "res://audio/bgm/"
var se_path: String = "res://audio/se/"
var voice_path: String = "res://audio/voice/"

## Scene paths
var title_scene_path: String = ""

## Internal state
var _last_scenario_path: String = ""
var _current_overlay: Node = null
var _return_to_title_pending: bool = false
var _navigation_generation: int = 0
var _navigation_kind: String = ""
var _navigation_scene_request_pending: bool = false
var _navigation_pending_scene_path: String = ""


func _init() -> void:
	# Autoload _ready() runs before the main scene enters the tree, but Godot has
	# already instantiated that scene by then. Resolve the immutable startup
	# snapshot in _init() so member initializers and _init() methods on a custom
	# main scene observe the final base + local values as well.
	var local_config_path := LOCAL_CONFIG_PATH
	if _is_implicit_local_config_disabled():
		local_config_path = ""
	config = _load_project_config(CONFIG_PATH, local_config_path)
	_apply_config()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		auto_save()


func _ready():
	save_manager = SaveManager.new()
	settings_manager = SettingsManager.new()
	settings_manager.load_settings()
	DisplayHelper.apply(settings_manager.settings)
	settings_manager.settings_changed.connect(func(key, val): SignalBus.settings_changed.emit(key, val))
	backlog_manager = BacklogManager.new()
	choice_history_manager = ChoiceHistoryManager.new()
	auto_play = AutoPlayController.new()
	skip_controller = SkipController.new()
	read_flags = ReadFlagManager.new()
	game_state = GameStateMachine.new()
	game_state.state_changed.connect(_on_state_changed)
	unlock_manager = UnlockManager.new()
	presentation_state = PresentationState.new()
	presentation_state.connect_signals()
	character_config_loader = CharacterConfigLoader.new()
	character_config_loader.set_base_path(characters_path)

	flowchart_state = FlowchartState.new()
	flowchart_visited = FlowchartVisitedState.new()

	save_manager.register_provider(read_flags)
	save_manager.register_provider(unlock_manager)
	save_manager.register_provider(presentation_state)
	# Flowchart state is per-save but the instance is a singleton on StellaRuntime
	# (unlike engine.context / variable_store which are recreated each scenario load).
	# Register once here; SaveManager deduplicates by provider_id.
	save_manager.register_provider(flowchart_state)
	# Flowchart visited is global/monotonic — restore_snapshot merges (union)
	# rather than overwrites, so loading old saves never loses progress.
	save_manager.register_provider(flowchart_visited)

	# Audio presenter — global, available in all scenes (title, game, overlays)
	var audio_script = load("res://addons/stella/presentation/audio/audio_presenter.gd")
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
	# Issue #97: detect chapter transitions for flowchart state tracking.
	engine.scene_changed.connect(_on_scene_changed_for_flowchart)

	# Runtime owns canonical Backlog capture directly from the typed request.
	# Presentation may subsequently enrich the same entry with custom effect names.
	SignalBus.dialogue_requested.connect(_on_dialogue_for_backlog)
	SignalBus.dialogue_backlog_effects_resolved.connect(
		_on_dialogue_backlog_effects_resolved)
	# Wire choice presentation to choice-history (rewind-to-previous-choice).
	SignalBus.choice_show.connect(_on_choice_for_history)

	# Play title BGM after AudioPresenter is ready
	if config.title_bgm != "":
		_play_title_bgm.call_deferred()


## Load the shared project config, then atomically apply an optional local
## override. Each call starts from defaults, so a removed local file cannot
## leave values behind from a previous resolution.
func _load_project_config(
	base_path: String = CONFIG_PATH,
	local_path: String = LOCAL_CONFIG_PATH,
) -> StellaConfig:
	var loaded_config := StellaConfig.new()
	if _config_source_exists(base_path):
		var base_error := loaded_config.load_from_path(base_path)
		if base_error != OK:
			_report_config_error(loaded_config)
			return loaded_config

	if _config_source_exists(local_path):
		var local_error := loaded_config.load_from_path(local_path)
		if local_error != OK:
			_report_config_error(loaded_config)
	return loaded_config


## Ordered source paths successfully committed to the startup configuration.
func get_applied_config_sources() -> PackedStringArray:
	if config == null:
		return PackedStringArray()
	return config.get_applied_sources()


## Return whether a source path exists, including a directory or dangling link
## at that path. Those are treated as present-but-unreadable and diagnosed.
func _config_source_exists(path: String) -> bool:
	if path == "":
		return false
	if FileAccess.file_exists(path):
		return true
	var absolute_path := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute_path):
		return true
	var parent_path := absolute_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_path):
		return false
	var parent := DirAccess.open(parent_path)
	return parent != null and parent.is_link(absolute_path.get_file())


func _report_config_error(failed_config: StellaConfig) -> void:
	var message := "StellaRuntime: failed to load config source %s (%s)" % [
		failed_config.last_error_source,
		error_string(failed_config.last_error),
	]
	if (
		failed_config.last_error_detail != ""
		and failed_config.last_error_detail != error_string(failed_config.last_error)
	):
		message += ": " + failed_config.last_error_detail
	push_error(message)


## Explicit opt-out for CI, tests, and other hermetic automation. Runtime
## behavior never depends on a particular test runner or script filename.
func _is_implicit_local_config_disabled() -> bool:
	if not OS.has_environment(DISABLE_LOCAL_CONFIG_ENV):
		return false
	var raw_value := OS.get_environment(DISABLE_LOCAL_CONFIG_ENV).strip_edges().to_lower()
	return raw_value not in ["", "0", "false", "no", "off"]


## Apply config values to runtime paths.
func _apply_config() -> void:
	backgrounds_path = config.backgrounds_path
	characters_path = config.characters_path
	stage_assets_path = config.stage_path
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
	registry.register(StageLayerHandler.new())
	registry.register(JumpHandler.new())
	registry.register(SetHandler.new())
	registry.register(ConditionHandler.new())
	registry.register(ChoiceHandler.new())
	registry.register(BgmHandler.new())
	registry.register(SeHandler.new())
	registry.register(VoiceHandler.new())
	registry.register(FadeHandler.new())
	registry.register(WaitHandler.new())
	registry.register(EffectHandler.new())
	registry.register(CallHandler.new())
	var parallel_handler = ParallelHandler.new()
	parallel_handler.set_registry(registry)
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
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return
	var destination := _load_navigation_scene(game_scene_path, "game")
	if destination.is_empty():
		return

	var navigation := _begin_navigation("start_game")
	if not await _enter_scene_and_confirm(
		destination,
		navigation,
		"game",
	):
		_finish_navigation(navigation)
		return
	if not _owns_navigation(navigation):
		return
	_cancel_active_gameplay()
	_close_current_overlay()
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_start_preparsed_scenario(scenario_data, scenario_path)
	_finish_navigation(navigation)


## Load a saved game — switch to game scene, restore state, run.
func load_game(slot_id: int, scenario_path: String = "", game_scene_path: String = "") -> bool:
	if scenario_path == "":
		scenario_path = config.scenario_path
	if game_scene_path == "":
		game_scene_path = _get_game_scene_path()
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = save_manager.read_save_data(slot_id, scenario_data)
	if save_data == null:
		return false
	var destination := _load_navigation_scene(game_scene_path, "game")
	if destination.is_empty():
		return false

	var navigation := _begin_navigation("load_game")
	if not await _enter_scene_and_confirm(
		destination,
		navigation,
		"game",
	):
		_finish_navigation(navigation)
		return false
	if not _owns_navigation(navigation):
		return false
	_cancel_active_gameplay()
	_close_current_overlay()
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_load_preparsed_scenario_and_restore(scenario_data, scenario_path, save_data)
	_finish_navigation(navigation)
	return true


## Continue from a manual save slot.
## Works from both title screen (switches to game scene) and in-game (reloads in place).
func continue_from_save(slot_id: int) -> bool:
	var scenario_path = _last_scenario_path
	if scenario_path == "":
		scenario_path = config.scenario_path
	if scenario_path == "":
		return false
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = save_manager.read_save_data(slot_id, scenario_data)
	if save_data == null:
		return false

	# Determine if we're on the title screen (directly or via overlay opened from title)
	var needs_game_scene := (
		_is_on_title_screen()
		or _navigation_scene_request_pending
		or _return_to_title_pending
	)
	var destination: Dictionary = {}
	if needs_game_scene:
		destination = _load_navigation_scene(_get_game_scene_path(), "game")
		if destination.is_empty():
			return false
	var navigation := _begin_navigation("continue_from_save")

	if needs_game_scene:
		# From title screen: switch to game scene first.
		# Close overlay after the confirmed scene change so its UI remains alive
		# while an invoked load transaction is pending.
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			return false
		_cancel_active_gameplay()
		_close_current_overlay()
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		_load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
		)
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	_cancel_active_gameplay()
	_close_current_overlay()
	_reset_presentation()
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_load_preparsed_scenario_and_restore(scenario_data, scenario_path, save_data)
	_finish_navigation(navigation)
	return true


## Begin one Runtime-owned navigation transaction. A later facade call always
## supersedes the previous owner; suspended continuations must verify this
## generation before mutating scenes, engine state, or configuration.
func _begin_navigation(kind: String) -> int:
	_navigation_generation += 1
	_navigation_kind = kind
	if engine != null and engine.context != null:
		engine.invalidate_current_run()
	if kind != "return_to_title":
		_return_to_title_pending = false
	return _navigation_generation


func _owns_navigation(generation: int) -> bool:
	return generation == _navigation_generation


func _finish_navigation(generation: int) -> void:
	if not _owns_navigation(generation):
		return
	_navigation_kind = ""
	_navigation_scene_request_pending = false
	_navigation_pending_scene_path = ""
	_return_to_title_pending = false


## Detach before aborting so a suspended old ScenarioEngine.run() observes its
## context-generation guard and cannot emit scenario_ended into the new owner.
func _cancel_active_gameplay() -> void:
	if engine == null or engine.context == null:
		return
	engine.cancel_current_run()
	SignalBus.engine_abort_requested.emit()


## Resolve UID destinations to their canonical resource path and load the
## PackedScene before a navigation generation supersedes any valid owner.
## A missing/unloadable destination therefore has no scene, state, overlay, or
## ScenarioEngine side effects.
func _load_navigation_scene(scene_path: String, description: String) -> Dictionary:
	var canonical_path := _canonical_resource_path(scene_path)
	if (
		canonical_path.is_empty()
		or not ResourceLoader.exists(canonical_path, "PackedScene")
	):
		push_error("StellaRuntime: %s scene is not available" % description)
		return {}
	var packed := _load_validated_scene(canonical_path)
	if packed == null:
		push_error("StellaRuntime: %s scene is not loadable" % description)
		return {}
	var resolved_path := packed.resource_path.simplify_path()
	if resolved_path.is_empty():
		resolved_path = canonical_path
	return {"scene": packed, "path": resolved_path}


func _canonical_resource_path(path: String) -> String:
	var normalized := path.simplify_path()
	if not normalized.begins_with("uid://"):
		return normalized
	var resource_uid := ResourceUID.text_to_id(normalized)
	if resource_uid == ResourceUID.INVALID_ID or not ResourceUID.has_id(resource_uid):
		return ""
	return ResourceUID.get_id_path(resource_uid).simplify_path()


func _enter_scene_and_confirm(
	destination: Dictionary,
	navigation: int,
	description: String,
) -> bool:
	if not await _await_navigation_scene_slot(navigation):
		return false
	var scene: PackedScene = destination.get("scene")
	var expected_path: String = destination.get("path", "")
	if scene == null or expected_path.is_empty():
		return false
	_navigation_scene_request_pending = true
	_navigation_pending_scene_path = expected_path
	var scene_error := get_tree().change_scene_to_packed(scene)
	if scene_error != OK:
		if _owns_navigation(navigation):
			_navigation_scene_request_pending = false
			_navigation_pending_scene_path = ""
			push_error(
				"StellaRuntime: failed to request the %s scene (%s)"
				% [description, error_string(scene_error)]
			)
		return false

	while _owns_navigation(navigation):
		await get_tree().scene_changed
		if not _owns_navigation(navigation):
			return false
		var current_scene := get_tree().current_scene
		if (
			current_scene != null
			and current_scene.scene_file_path.simplify_path() == expected_path
		):
			_navigation_scene_request_pending = false
			_navigation_pending_scene_path = ""
			return true
	return false


## SceneTree accepts one main-scene replacement at a time. When a newer facade
## supersedes an owner with a request already in flight, let that old request
## settle without letting its suspended continuation commit anything, then give
## the shared request slot to the new generation.
func _await_navigation_scene_slot(navigation: int) -> bool:
	if not _owns_navigation(navigation):
		return false
	if not _navigation_scene_request_pending:
		return true

	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or current_scene.scene_file_path.simplify_path()
			!= _navigation_pending_scene_path
	):
		await get_tree().scene_changed
		if not _owns_navigation(navigation):
			return false
	_navigation_scene_request_pending = false
	_navigation_pending_scene_path = ""
	return true


## Resolve the configured title scene with the built-in title as an atomic
## fallback. Both startup and return-to-title use this path so an invalid local
## override cannot leave the runtime in a title state while a game scene remains
## visible.
func resolve_title_scene(fallback_scene: PackedScene = null) -> PackedScene:
	var fallback := fallback_scene
	if fallback == null:
		fallback = DEFAULT_TITLE_PACKED_SCENE

	var configured_path := title_scene_path.simplify_path()
	var configured_scene := _load_title_scene(configured_path)
	if _title_scene_is_enterable(configured_scene):
		return configured_scene

	push_error(
		"StellaRuntime: [overrides].title_scene is not a loadable title scene; "
		+ "falling back to the built-in title scene"
	)
	title_scene_path = DEFAULT_TITLE_SCENE
	if _title_scene_is_enterable(fallback):
		return fallback
	push_error("StellaRuntime: built-in title scene is not enterable")
	return null


## Validate the complete packed tree before SceneTree accepts it. Empty scenes,
## abstract/invalid scripts, scripts whose effective _init requires arguments,
## and bootstrap behavior would otherwise fail or silently lose behavior only
## after a scene transition has already begun.
func _title_scene_is_enterable(scene: PackedScene) -> bool:
	if scene == null or not scene.can_instantiate():
		return false
	if (
		not scene.resource_path.is_empty()
		and not _title_scene_dependencies_are_available(scene.resource_path)
	):
		return false
	var pending: Array[Dictionary] = [{
		"scene": scene,
		"script_overrides": {},
	}]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		var current: PackedScene = entry["scene"]
		var incoming_script_overrides: Dictionary = entry["script_overrides"]
		if not current.can_instantiate():
			return false
		# SceneState exposes each inherited layer independently. Build the
		# effective script values by full relative NodePath so an outer layer's
		# `Child/script = null` (or safe replacement) shadows the base child's
		# serialized script just as PackedScene.instantiate() does.
		var effective_script_overrides := _title_scene_script_properties(
			current.get_state(),
		)
		for node_path: String in incoming_script_overrides:
			effective_script_overrides[node_path] = (
				incoming_script_overrides[node_path]
			)
		var identity := current.resource_path
		if identity == "":
			identity = str(current.get_instance_id())
		identity += ":scripts=%s" % _title_script_overrides_identity(
			effective_script_overrides,
		)
		if visited.has(identity):
			continue
		visited[identity] = true

		var state := current.get_state()
		for node_index in state.get_node_count():
			var node_path := String(state.get_node_path(node_index))
			var nested_scene := state.get_node_instance(node_index)
			var node_native_type := _title_node_native_type(
				state,
				node_index,
				nested_scene,
				{},
			)
			# A packed instance with a missing dependency degrades to an empty
			# node type instead of making PackedScene.can_instantiate() fail.
			if node_native_type == &"":
				return false
			if nested_scene != null:
				pending.append({
					"scene": nested_scene,
					"script_overrides": _title_nested_script_overrides(
						effective_script_overrides,
						node_path,
					),
				})
			if not effective_script_overrides.has(node_path):
				continue
			var script_value: Variant = effective_script_overrides[node_path]
			# An inherited scene may explicitly clear any inherited node script
			# with `script = null`. Missing external scripts are rejected earlier
			# by the recursive dependency preflight, so null is safe here.
			if script_value == null:
				continue
			if not script_value is Script:
				return false
			if not _title_script_is_enterable(
				script_value as Script,
				node_native_type,
			):
				return false
	return true


func _title_scene_script_properties(state: SceneState) -> Dictionary:
	var result: Dictionary = {}
	for node_index in state.get_node_count():
		for property_index in state.get_node_property_count(node_index):
			if state.get_node_property_name(node_index, property_index) != &"script":
				continue
			result[String(state.get_node_path(node_index))] = (
				state.get_node_property_value(node_index, property_index)
			)
	return result


func _title_nested_script_overrides(
	script_overrides: Dictionary,
	nested_node_path: String,
) -> Dictionary:
	if nested_node_path == ".":
		return script_overrides.duplicate()
	var result: Dictionary = {}
	var child_prefix := nested_node_path + "/"
	for override_path: String in script_overrides:
		if override_path == nested_node_path:
			result["."] = script_overrides[override_path]
		elif override_path.begins_with(child_prefix):
			result[override_path.substr(child_prefix.length())] = (
				script_overrides[override_path]
			)
	return result


func _title_script_overrides_identity(script_overrides: Dictionary) -> String:
	var paths: Array = script_overrides.keys()
	paths.sort()
	var parts := PackedStringArray()
	for override_path: String in paths:
		var value: Variant = script_overrides[override_path]
		var value_identity := "null"
		if value is Script:
			var script := value as Script
			value_identity = script.resource_path
			if value_identity.is_empty():
				value_identity = str(script.get_instance_id())
		elif value != null:
			value_identity = "invalid:%d" % typeof(value)
		parts.append("%s=%s" % [override_path, value_identity])
	return "|".join(parts).sha256_text()


func _title_node_native_type(
	state: SceneState,
	node_index: int,
	nested_scene: PackedScene,
	visited: Dictionary,
) -> StringName:
	var native_type := state.get_node_type(node_index)
	if native_type != &"":
		return native_type
	if nested_scene == null:
		return _title_inherited_node_native_type(state, node_index, visited)
	return _title_scene_root_native_type(nested_scene, visited)


## Property-only entries in an inherited scene have neither a native type nor
## their own PackedScene. Resolve their type from the inherited root's effective
## node at the same path instead of treating a normal property override as a
## vanished dependency.
func _title_inherited_node_native_type(
	state: SceneState,
	node_index: int,
	visited: Dictionary,
) -> StringName:
	if state.get_node_count() == 0:
		return &""
	var inherited_root := state.get_node_instance(0)
	if inherited_root == null:
		return &""
	return _title_scene_node_native_type_at_path(
		inherited_root,
		state.get_node_path(node_index),
		visited,
	)


func _title_scene_node_native_type_at_path(
	scene: PackedScene,
	node_path: NodePath,
	visited: Dictionary,
) -> StringName:
	if scene == null or not scene.can_instantiate():
		return &""
	var identity := "%s:%s" % [scene.resource_path, node_path]
	if scene.resource_path.is_empty():
		identity = "%s:%s" % [scene.get_instance_id(), node_path]
	if visited.has(identity):
		return &""
	visited[identity] = true

	var state := scene.get_state()
	for candidate_index in state.get_node_count():
		if state.get_node_path(candidate_index) != node_path:
			continue
		return _title_node_native_type(
			state,
			candidate_index,
			state.get_node_instance(candidate_index),
			visited,
		)

	# The immediate base may itself be inherited and only serialize overrides.
	# Follow that root chain with the same relative path.
	if state.get_node_count() > 0:
		var inherited_root := state.get_node_instance(0)
		if inherited_root != null:
			return _title_scene_node_native_type_at_path(
				inherited_root,
				node_path,
				visited,
			)
	return &""


func _title_scene_root_native_type(
	scene: PackedScene,
	visited: Dictionary,
) -> StringName:
	if scene == null or not scene.can_instantiate():
		return &""
	var identity := scene.resource_path
	if identity.is_empty():
		identity = str(scene.get_instance_id())
	if visited.has(identity):
		return &""
	visited[identity] = true

	var state := scene.get_state()
	if state.get_node_count() == 0:
		return &""
	return _title_node_native_type(
		state,
		0,
		state.get_node_instance(0),
		visited,
	)


func _title_script_is_enterable(
	script: Script,
	node_native_type: StringName,
) -> bool:
	if script == null or not script.can_instantiate() or script.is_abstract():
		return false
	var script_native_type := script.get_instance_base_type()
	if (
		script_native_type == &""
		or not ClassDB.is_parent_class(node_native_type, script_native_type)
	):
		return false

	var current := script
	while current != null:
		if current.resource_path.simplify_path() == BOOTSTRAP_SCRIPT:
			return false
		current = current.get_base_script()

	# get_script_method_list() returns the effective override first, followed by
	# inherited methods. A child that does not override _init therefore exposes
	# its inherited constructor here, while a no-argument override remains valid.
	for method: Dictionary in script.get_script_method_list():
		if method.get("name", &"") != &"_init":
			continue
		var arguments: Array = method.get("args", [])
		var default_arguments: Array = method.get("default_args", [])
		return arguments.size() <= default_arguments.size()
	return true


func _load_title_scene(path: String) -> PackedScene:
	return _load_validated_scene(path)


## One side-effect-free preflight for every configured scene destination.
## Godot may return an instantiable degraded PackedScene after dropping a
## missing Script/nested resource, so `can_instantiate()` alone is insufficient.
func _load_validated_scene(path: String) -> PackedScene:
	var canonical_path := _canonical_resource_path(path)
	if (
		canonical_path.is_empty()
		or not ResourceLoader.exists(canonical_path, "PackedScene")
		or not _title_scene_dependencies_are_available(canonical_path)
	):
		return null
	var scene := ResourceLoader.load(canonical_path, "PackedScene") as PackedScene
	if not _title_scene_is_enterable(scene):
		return null
	return scene


## Recursively verify that every external resource referenced by a candidate
## title still exists. Godot can otherwise load a degraded PackedScene while
## silently replacing a missing script or nested instance with null.
func _title_scene_dependencies_are_available(path: String) -> bool:
	var pending: Array[String] = [path.simplify_path()]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var current_path: String = pending.pop_back()
		if visited.has(current_path):
			continue
		visited[current_path] = true
		if not ResourceLoader.exists(current_path):
			return false
		var dependency_result := _read_text_resource_dependencies(current_path)
		if not dependency_result.get("ok", false):
			return false
		for dependency: Dictionary in dependency_result["dependencies"]:
			var dependency_path: String = dependency["path"]
			var declared_type: String = dependency["type"]
			if (
				dependency_path.is_empty()
				or not ResourceLoader.exists(dependency_path)
				or (
					not declared_type.is_empty()
					and not _text_resource_declares_type(
					dependency_path,
					declared_type,
				)
				)
			):
				return false
			pending.append(dependency_path)
	return true


## Read the header and ext_resource declarations without invoking Godot's text
## resource parser. ResourceLoader.get_dependencies()/load() echo malformed
## source tokens and private paths to stderr; this strict metadata preflight
## rejects unsupported/unloadable text before those APIs can see it.
func _read_text_resource_dependencies(path: String) -> Dictionary:
	var extension := path.get_extension().to_lower()
	if extension not in ["tscn", "tres"]:
		return _structured_resource_dependencies(path)
	var file := FileAccess.open(path, FileAccess.READ)
	# Export remaps source-looking paths to binary resources that are loadable
	# through ResourceLoader but intentionally unavailable through FileAccess.
	if file == null:
		return _structured_resource_dependencies(path)
	if file.get_length() > MAX_TITLE_TEXT_RESOURCE_BYTES:
		return {"ok": false, "dependencies": []}
	var bytes := file.get_buffer(file.get_length())
	var read_error := file.get_error()
	file.close()
	if read_error not in [OK, ERR_FILE_EOF]:
		return {"ok": false, "dependencies": []}
	if bytes.is_empty():
		return {"ok": false, "dependencies": []}
	# Only explicit Godot binary resource magic may enter the structured loader
	# path. A malformed text file that starts with whitespace/comment data must
	# stay in the side-effect-free parser below; otherwise ResourceLoader can
	# echo its private source tokens and paths while reporting parse failures.
	if _resource_bytes_have_binary_magic(bytes):
		return _structured_resource_dependencies(path)
	if bytes.has(0):
		return {"ok": false, "dependencies": []}
	var text_bytes := bytes
	if (
		bytes.size() >= 3
		and bytes[0] == 0xEF
		and bytes[1] == 0xBB
		and bytes[2] == 0xBF
	):
		text_bytes = bytes.slice(3)
	var text := text_bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != text_bytes:
		return {"ok": false, "dependencies": []}
	if not text.is_empty() and text.unicode_at(0) == 0xFEFF:
		text = text.substr(1)
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	if lines.is_empty():
		return {"ok": false, "dependencies": []}
	var expected_header := "gd_scene" if extension == "tscn" else "gd_resource"
	var header_line_index := -1
	var header_text := ""
	for line_index in lines.size():
		var candidate := _strip_resource_comment(lines[line_index]).strip_edges()
		if candidate.is_empty():
			continue
		header_line_index = line_index
		header_text = candidate
		break
	if header_line_index < 0:
		return {"ok": false, "dependencies": []}
	var header := _parse_resource_tag(header_text)
	if not header.get("ok", false) or header.get("name", "") != expected_header:
		return {"ok": false, "dependencies": []}

	var dependencies: Array[Dictionary] = []
	var ext_resource_ids: Dictionary = {}
	var sub_resource_ids: Dictionary = {}
	var resource_references: Array[Dictionary] = []
	if not _append_resource_tag_references(header, resource_references):
		return {"ok": false, "dependencies": []}
	var saw_body_tag := false
	var assignment_state: Dictionary = {}
	for line_index in range(header_line_index + 1, lines.size()):
		var raw_line: String = lines[line_index]
		if not assignment_state.is_empty():
			assignment_state["value_parts"].append(raw_line)
			if not _scan_resource_value_fragment(raw_line, assignment_state):
				return {"ok": false, "dependencies": []}
			if assignment_state.get("complete", false):
				if not _append_resource_value_references(
					"\n".join(assignment_state["value_parts"]),
					resource_references,
				):
					return {"ok": false, "dependencies": []}
				assignment_state = {}
			continue

		var stripped := _strip_resource_comment(raw_line).strip_edges()
		if stripped.is_empty():
			continue
		if stripped.begins_with("["):
			var tag := _parse_resource_tag(stripped)
			if not tag.get("ok", false):
				return {"ok": false, "dependencies": []}
			if not _append_resource_tag_references(tag, resource_references):
				return {"ok": false, "dependencies": []}
			if tag["name"] == "ext_resource":
				if saw_body_tag:
					return {"ok": false, "dependencies": []}
				var attributes: Dictionary = tag["attributes"]
				var declared_type: String = attributes.get("type", "")
				var resource_id: String = attributes.get("id", "")
				var dependency_path := _resource_dependency_path_from_attributes(
					attributes,
				)
				if (
					declared_type.is_empty()
					or resource_id.is_empty()
					or ext_resource_ids.has(resource_id)
					or dependency_path.is_empty()
				):
					return {"ok": false, "dependencies": []}
				ext_resource_ids[resource_id] = true
				dependencies.append({
					"path": dependency_path,
					"type": declared_type,
				})
			else:
				saw_body_tag = true
				if tag["name"] == "sub_resource":
					var sub_id: String = tag["attributes"].get("id", "")
					if sub_id.is_empty() or sub_resource_ids.has(sub_id):
						return {"ok": false, "dependencies": []}
					sub_resource_ids[sub_id] = true
			continue
		if not saw_body_tag:
			return {"ok": false, "dependencies": []}
		assignment_state = _begin_resource_assignment(stripped)
		if not assignment_state.get("ok", false):
			return {"ok": false, "dependencies": []}
		if assignment_state.get("complete", false):
			if not _append_resource_value_references(
				"\n".join(assignment_state["value_parts"]),
				resource_references,
			):
				return {"ok": false, "dependencies": []}
			assignment_state = {}
	if not _resource_references_are_declared(
		resource_references,
		ext_resource_ids,
		sub_resource_ids,
	):
		return {"ok": false, "dependencies": []}
	return {
		"ok": saw_body_tag and assignment_state.is_empty(),
		"dependencies": dependencies,
	}


func _resource_bytes_have_binary_magic(bytes: PackedByteArray) -> bool:
	if bytes.size() < 4:
		return false
	# Godot binary resources begin with RSCC (compressed) or RSRC. Do not infer
	# binary format from an arbitrary non-'[' first byte.
	return (
		bytes[0] == 0x52 # R
		and bytes[1] == 0x53 # S
		and bytes[2] in [0x43, 0x52] # C/R
		and bytes[3] == 0x43 # C
	)


func _append_resource_tag_references(
	tag: Dictionary,
	references: Array[Dictionary],
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted_attributes: Dictionary = tag.get("quoted_attributes", {})
	for key: String in attributes:
		if quoted_attributes.get(key, false):
			continue
		if not _append_resource_value_references(
			String(attributes[key]),
			references,
		):
			return false
	return true


func _append_resource_value_references(
	value: String,
	references: Array[Dictionary],
) -> bool:
	var parsed := _ResourceValueParser.new(value).parse()
	if not parsed.get("ok", false):
		return false
	for reference: Dictionary in parsed.get("references", []):
		references.append(reference)
	return true


func _resource_references_are_declared(
	references: Array[Dictionary],
	ext_resource_ids: Dictionary,
	sub_resource_ids: Dictionary,
) -> bool:
	for reference: Dictionary in references:
		var resource_id: String = reference.get("id", "")
		match reference.get("kind", ""):
			"ExtResource":
				if not ext_resource_ids.has(resource_id):
					return false
			"SubResource":
				if not sub_resource_ids.has(resource_id):
					return false
			_:
				return false
	return true


func _structured_resource_dependencies(path: String) -> Dictionary:
	var dependencies: Array[Dictionary] = []
	for raw_dependency: String in ResourceLoader.get_dependencies(path):
		var dependency_path := _resource_dependency_path(raw_dependency)
		var declared_type := _resource_dependency_type(raw_dependency)
		if dependency_path.is_empty():
			return {"ok": false, "dependencies": []}
		dependencies.append({
			"path": dependency_path,
			"type": declared_type,
		})
	return {"ok": true, "dependencies": dependencies}


func _parse_resource_tag(line: String) -> Dictionary:
	if not line.begins_with("[") or not line.ends_with("]"):
		return {"ok": false}
	var content := line.substr(1, line.length() - 2)
	var index := 0
	while index < content.length() and content[index] not in [" ", "\t"]:
		index += 1
	var tag_name := content.substr(0, index)
	if tag_name.is_empty():
		return {"ok": false}
	var attributes := {}
	var quoted_attributes := {}
	while index < content.length():
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if index >= content.length():
			break
		var key_start := index
		while (
			index < content.length()
			and content[index] not in [" ", "\t", "="]
		):
			index += 1
		var key := content.substr(key_start, index - key_start)
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if key.is_empty() or index >= content.length() or content[index] != "=":
			return {"ok": false}
		index += 1
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if index >= content.length():
			return {"ok": false}
		if content[index] == "\"":
			quoted_attributes[key] = true
			index += 1
			var value := ""
			var closed := false
			while index < content.length():
				var character := content[index]
				if character == "\\":
					index += 1
					if index >= content.length():
						return {"ok": false}
					value += content[index]
					index += 1
					continue
				if character == "\"":
					index += 1
					closed = true
					break
				value += character
				index += 1
			if not closed:
				return {"ok": false}
			attributes[key] = value
		else:
			quoted_attributes[key] = false
			var value_start := index
			index = _resource_tag_value_end(content, index)
			if index < 0:
				return {"ok": false}
			var raw_value := content.substr(value_start, index - value_start)
			if raw_value.is_empty():
				return {"ok": false}
			attributes[key] = raw_value
	return {
		"ok": true,
		"name": tag_name,
		"attributes": attributes,
		"quoted_attributes": quoted_attributes,
	}


func _resource_tag_value_end(content: String, start: int) -> int:
	var stack: Array[String] = []
	var in_string := false
	var escaped := false
	var index := start
	while index < content.length():
		var character := content[index]
		if in_string:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			index += 1
			continue
		if character == "\"":
			in_string = true
		elif character in ["(", "[", "{"]:
			stack.append(character)
		elif character in [")", "]", "}"]:
			if stack.is_empty() or not _resource_delimiters_match(
				stack.back(),
				character,
			):
				return -1
			stack.pop_back()
		elif character in [" ", "\t"] and stack.is_empty():
			break
		index += 1
	if in_string or not stack.is_empty():
		return -1
	return index


func _strip_resource_comment(line: String) -> String:
	var in_string := false
	var escaped := false
	for index in line.length():
		var character := line[index]
		if in_string:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			continue
		if character == "\"":
			in_string = true
		elif character == ";":
			return line.substr(0, index)
	return line


## Validate serialized Variant structure without evaluating it or passing raw
## private source to Godot's parser. Values may span lines (typed arrays,
## dictionaries, and literal strings), so keep a small delimiter/string state
## until the complete assignment has closed.
func _begin_resource_assignment(line: String) -> Dictionary:
	var equals_index := line.find("=")
	if equals_index <= 0 or line.substr(0, equals_index).strip_edges().is_empty():
		return {"ok": false}
	var value := line.substr(equals_index + 1).strip_edges()
	if value.is_empty():
		return {"ok": false}

	var state := {
		"ok": true,
		"complete": false,
		"kind": "",
		"value_parts": PackedStringArray([value]),
		"stack": [],
		"in_string": false,
		"escaped": false,
	}
	if value.begins_with("\""):
		state["kind"] = "string"
		state["in_string"] = true
		if not _scan_resource_value_fragment(value.substr(1), state):
			return {"ok": false}
		return state
	if value.begins_with("&\"") or value.begins_with("^\""):
		state["kind"] = "string"
		state["in_string"] = true
		if not _scan_resource_value_fragment(value.substr(2), state):
			return {"ok": false}
		return state

	var container_start := _resource_container_start(value)
	if container_start >= 0:
		state["kind"] = "container"
		if not _scan_resource_value_fragment(
			value.substr(container_start),
			state,
		):
			return {"ok": false}
		return state

	if _resource_scalar_is_valid(value):
		state["kind"] = "scalar"
		state["complete"] = true
		return state
	# A bare unknown identifier is a common malformed-resource failure, and
	# Godot includes that identifier verbatim in its parser error. Reject it here.
	return {"ok": false}


func _resource_container_start(value: String) -> int:
	if value[0] in ["[", "{", "("]:
		return 0
	var open_index := value.find("(")
	if open_index <= 0:
		return -1
	var prefix := value.substr(0, open_index).strip_edges()
	var base_name := prefix.get_slice("[", 0).strip_edges()
	if not _resource_constructor_is_known(base_name):
		return -1
	var generic_depth := 0
	for character in prefix:
		if character == "[":
			generic_depth += 1
		elif character == "]":
			generic_depth -= 1
			if generic_depth < 0:
				return -1
		elif not (
			character == "_"
			or character == ","
			or character == "."
			or character == " "
			or character == "\t"
			or character >= "0" and character <= "9"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
		):
			return -1
	if generic_depth != 0:
		return -1
	return open_index


func _resource_constructor_is_known(name: String) -> bool:
	return (
		name in [
			"AABB", "Array", "Basis", "Callable", "Color", "Dictionary",
			"EncodedObjectAsID", "ExtResource", "NodePath", "Object", "Plane",
			"Projection", "Quaternion", "Rect2", "Rect2i", "RID", "Signal",
			"String", "StringName", "SubResource", "Transform2D", "Transform3D",
		]
		or name.begins_with("Packed")
		or name.begins_with("Vector")
	)


func _resource_scalar_is_valid(value: String) -> bool:
	if value in ["true", "false", "null", "inf", "+inf", "-inf", "nan"]:
		return true
	return value.is_valid_int() or value.is_valid_float()


func _scan_resource_value_fragment(
	fragment: String,
	state: Dictionary,
) -> bool:
	var kind: String = state["kind"]
	var stack: Array = state["stack"]
	var in_string: bool = state["in_string"]
	var escaped: bool = state["escaped"]
	for index in fragment.length():
		var character := fragment[index]
		if in_string:
			if escaped:
				escaped = false
				continue
			if character == "\\":
				escaped = true
				continue
			if character != "\"":
				continue
			in_string = false
			if kind == "string":
				if not _resource_value_tail_is_empty(fragment, index + 1):
					return false
				state["complete"] = true
				state["in_string"] = false
				state["escaped"] = false
				return true
			continue

		if character == ";":
			break
		if character == "\"":
			in_string = true
			continue
		if character in ["(", "[", "{"]:
			stack.append(character)
			continue
		if character in [")", "]", "}"]:
			if stack.is_empty() or not _resource_delimiters_match(
				stack.back(),
				character,
			):
				return false
			stack.pop_back()
			if stack.is_empty():
				if not _resource_value_tail_is_empty(fragment, index + 1):
					return false
				state["complete"] = true
				state["stack"] = stack
				state["in_string"] = false
				state["escaped"] = false
				return true

	# A physical newline consumes a trailing escape inside a literal multiline
	# string; the first character on the next line is not escaped by that slash.
	if in_string and escaped:
		escaped = false
	state["stack"] = stack
	state["in_string"] = in_string
	state["escaped"] = escaped
	return true


func _resource_value_tail_is_empty(fragment: String, start: int) -> bool:
	for index in range(start, fragment.length()):
		var character := fragment[index]
		if character in [" ", "\t"]:
			continue
		return character == ";"
	return true


func _resource_delimiters_match(opening: String, closing: String) -> bool:
	return (
		opening == "(" and closing == ")"
		or opening == "[" and closing == "]"
		or opening == "{" and closing == "}"
	)


func _resource_dependency_path_from_attributes(attributes: Dictionary) -> String:
	var uid_text: String = attributes.get("uid", "")
	if uid_text.begins_with("uid://"):
		var dependency_uid := ResourceUID.text_to_id(uid_text)
		if dependency_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(dependency_uid):
			return ResourceUID.get_id_path(dependency_uid).simplify_path()
	return String(attributes.get("path", "")).simplify_path()


func _resource_dependency_type(raw_dependency: String) -> String:
	var fields := raw_dependency.split("::", true)
	if fields.size() >= 2:
		return fields[1]
	return ""


func _text_resource_declares_type(path: String, declared_type: String) -> bool:
	if declared_type.is_empty():
		return false
	var extension := path.get_extension().to_lower()
	if extension == "tscn":
		return ClassDB.is_parent_class("PackedScene", declared_type)
	if extension == "tres":
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			var remapped_resource := ResourceLoader.load(path, declared_type)
			return (
				remapped_resource != null
				and remapped_resource.is_class(declared_type)
			)
		if file.get_length() > MAX_TITLE_TEXT_RESOURCE_BYTES:
			return false
		var first_byte := file.get_8()
		file.seek(0)
		if first_byte != 0x5B:
			file.close()
			var binary_resource := ResourceLoader.load(path, declared_type)
			return (
				binary_resource != null
				and binary_resource.is_class(declared_type)
			)
		var first_line := file.get_line().strip_edges()
		file.close()
		var header := _parse_resource_tag(first_line)
		if not header.get("ok", false) or header.get("name", "") != "gd_resource":
			return false
		var actual_type: String = header["attributes"].get("type", "")
		if (
			not actual_type.is_empty()
			and ClassDB.is_parent_class(actual_type, declared_type)
		):
			return true
		var script_class: String = header["attributes"].get(
			"script_class",
			"",
		)
		return _script_class_inherits(script_class, declared_type)
	var loaded_resource := ResourceLoader.load(path, declared_type)
	return loaded_resource != null and loaded_resource.is_class(declared_type)


func _script_class_inherits(
	actual_class: String,
	declared_class: String,
) -> bool:
	if actual_class.is_empty() or declared_class.is_empty():
		return false
	var base_by_class: Dictionary = {}
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		var global_name: String = entry.get("class", "")
		if not global_name.is_empty():
			base_by_class[global_name] = String(entry.get("base", ""))

	var current := actual_class
	var visited: Dictionary = {}
	while not current.is_empty() and not visited.has(current):
		if current == declared_class:
			return true
		visited[current] = true
		if base_by_class.has(current):
			current = base_by_class[current]
			continue
		if ClassDB.class_exists(current):
			return ClassDB.is_parent_class(current, declared_class)
		break
	return false


func _resource_dependency_path(raw_dependency: String) -> String:
	var fields := raw_dependency.split("::", true)
	# Imported/exported resources may report UID::type::fallback-path. A valid
	# UID follows resource relocation, while the serialized fallback can be
	# stale. Prefer the registry's canonical path and use the fallback only when
	# that UID is unavailable (including stripped/older PCK metadata).
	if not fields.is_empty() and fields[0].begins_with("uid://"):
		var dependency_uid := ResourceUID.text_to_id(fields[0])
		if dependency_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(dependency_uid):
			var canonical_path := ResourceUID.get_id_path(dependency_uid)
			if (
				not canonical_path.is_empty()
				and ResourceLoader.exists(canonical_path)
			):
				return canonical_path.simplify_path()
	if fields.size() >= 3 and not fields[2].is_empty():
		return fields[2].simplify_path()
	if fields.is_empty():
		return ""
	return fields[0].simplify_path()


## Return to title screen. The whole transaction is deferred so this API is
## safe from a scene root's _ready(), where the parent is still busy. Cleanup
## and TITLE state are committed only after SceneTree.scene_changed confirms
## the resolved (or built-in fallback) scene became current_scene.
func return_to_title() -> void:
	if _return_to_title_pending:
		return
	var navigation := _begin_navigation("return_to_title")
	_return_to_title_pending = true
	_return_to_title_transaction.call_deferred(navigation)


func _return_to_title_transaction(navigation: int) -> void:
	if not _owns_navigation(navigation):
		return
	var title_scene := resolve_title_scene()
	if title_scene == null:
		push_error("StellaRuntime: built-in title scene is unavailable")
		_finish_navigation(navigation)
		return

	# Snapshot scene-owned providers while the outgoing scene is still alive.
	# The deferred transaction still runs before change_scene_to_packed() removes
	# it, so saving after the request cannot capture teardown state.
	auto_save()
	var entered_title := await _enter_title_scene_and_confirm(
		title_scene,
		"configured",
		navigation,
	)
	if not _owns_navigation(navigation):
		return
	var title_path := title_scene.resource_path.simplify_path()
	if not entered_title and title_path != DEFAULT_TITLE_SCENE:
		push_error(
			"StellaRuntime: failed to enter the configured title scene; "
			+ "falling back to the built-in title scene"
		)
		title_scene_path = DEFAULT_TITLE_SCENE
		title_scene = DEFAULT_TITLE_PACKED_SCENE
		if not _title_scene_is_enterable(title_scene):
			push_error("StellaRuntime: built-in title scene is not enterable")
			_finish_navigation(navigation)
			return
		entered_title = await _enter_title_scene_and_confirm(
			title_scene,
			"built-in",
			navigation,
		)
		if not _owns_navigation(navigation):
			return
	if not entered_title:
		push_error("StellaRuntime: failed to enter the built-in title scene")
		_finish_navigation(navigation)
		return

	_cancel_active_gameplay()
	_close_current_overlay()
	backlog_manager.clear()
	choice_history_manager.clear()
	auto_play.stop()
	skip_controller.stop()
	game_state.transition_to(GameStateMachine.State.TITLE)
	if config.title_bgm != "":
		_play_title_bgm()
	_finish_navigation(navigation)


func _enter_title_scene_and_confirm(
	title_scene: PackedScene,
	description: String,
	navigation: int,
) -> bool:
	return await _enter_scene_and_confirm(
		{
			"scene": title_scene,
			"path": title_scene.resource_path.simplify_path(),
		},
		navigation,
		"%s title" % description,
	)


## Legacy API — starts scenario in current scene (for testing).
func start_scenario(scenario_path: String) -> void:
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return
	var navigation := _begin_navigation("start_scenario")
	if not await _await_navigation_scene_slot(navigation):
		return
	if not _owns_navigation(navigation):
		return
	_cancel_active_gameplay()
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_start_preparsed_scenario(scenario_data, scenario_path)
	_finish_navigation(navigation)


func _start_scenario_internal(scenario_path: String) -> void:
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return
	_start_preparsed_scenario(scenario_data, scenario_path)


func _start_preparsed_scenario(
	scenario_data: ScenarioData,
	scenario_path: String,
) -> void:
	_install_scenario(scenario_data, scenario_path)
	SignalBus.reset_stage_visuals()
	presentation_state.clear()
	engine.run()


## Load scenario data and register providers, but do NOT run the engine.
##
## Always clears the backlog: every entry into a scenario (start_game,
## load_game, continue_from_save, quick_load — both from-title and in-game)
## funnels through here, so this is the single chokepoint that guarantees
## the previous playthrough's history doesn't bleed into the new one
## (which would otherwise let stale (scene, command) positions silently
## match new entries via the cursor's known-path branch).
func _parse_scenario(scenario_path: String) -> ScenarioData:
	var file = FileAccess.open(scenario_path, FileAccess.READ)
	if file == null:
		push_error("StellaRuntime: cannot open %s" % scenario_path)
		return null
	var source = file.get_as_text()
	file.close()

	var tokens = DslLexer.tokenize(source)
	var scenario_id = scenario_path.get_file().get_basename()
	var data = DslParser.parse(tokens, scenario_id, scenario_path)
	data.source_identity = ScenarioData.make_source_identity(scenario_path)
	# Surface parser diagnostics (issue #97). DslParser is intentionally silent
	# about console reporting; this is the integration point where parse-time
	# errors/warnings reach the developer.
	for d in data.diagnostics:
		var msg = "[%s] %s" % [scenario_id, d.get("message", "")]
		if d.get("level") == "error":
			push_error(msg)
		else:
			push_warning(msg)
	return data


func _prepare_scenario(scenario_path: String) -> bool:
	var data := _parse_scenario(scenario_path)
	if data == null:
		return false
	_install_scenario(data, scenario_path)
	return true


func _install_scenario(data: ScenarioData, scenario_path: String) -> void:
	var scenario_id := data.id

	engine.load_scenario(data)
	save_manager.register_provider(engine.context)
	save_manager.register_provider(engine.context.variable_store)
	backlog_manager.clear()
	choice_history_manager.clear()

	# Issue #97: build scenario graph and prepare flowchart state for new run.
	scenario_graph = ScenarioGraphBuilder.build(data)
	for d in scenario_graph.diagnostics:
		var msg = "[%s graph] %s" % [scenario_id, d.get("message", "")]
		if d.get("level") == "error":
			push_error(msg)
		else:
			push_warning(msg)
	flowchart_state.clear()
	# Capture INITIAL_SNAPSHOT immediately after scenario load, before
	# engine.run() mutates any state. A scenario always starts from an explicitly
	# empty presentation; title visuals or a previous playthrough must never leak
	# into the fallback used for an unvisited chapter.
	var initial_snapshot := _capture_rollback_snapshot()
	initial_snapshot["presentation_state"] = {
		"bg": "",
		"stage_layers": {},
		"bgm": "",
	}
	flowchart_state.initial_snapshot = initial_snapshot


## Load scenario, restore snapshot, restore presentation, then run.
func _load_preparsed_scenario_and_restore(
	scenario_data: ScenarioData,
	scenario_path: String,
	save_data: Dictionary,
) -> void:
	_install_scenario(scenario_data, scenario_path)
	save_manager.restore_data(save_data)
	presentation_state.apply_to_presenters()
	engine.run()


func _load_scenario_and_restore(scenario_path: String, slot_id: int) -> bool:
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = save_manager.read_save_data(slot_id, scenario_data)
	if save_data == null:
		return false
	_load_preparsed_scenario_and_restore(scenario_data, scenario_path, save_data)
	return true


## Check if we're on the title screen — either directly or via an overlay opened from title.
func _is_on_title_screen() -> bool:
	if game_state.current_state == GameStateMachine.State.TITLE:
		return true
	# Overlay states opened from title: previous_state is TITLE
	var overlay_states = [
		GameStateMachine.State.SAVE_LOAD,
		GameStateMachine.State.SETTINGS,
		GameStateMachine.State.BACKLOG,
		GameStateMachine.State.FLOWCHART,
	]
	if game_state.current_state in overlay_states:
		return game_state.previous_state == GameStateMachine.State.TITLE
	return false


## Reset current presentation state (for in-scene reload).
func _reset_presentation() -> void:
	SignalBus.effect_requested.emit("off", {})
	SignalBus.reset_stage_visuals()
	SignalBus.bgm_stop.emit(0.0)
	SignalBus.hide_dialogue.emit()
	presentation_state.clear()
	# Backlog is runtime-only state (not in save snapshots) — clear it on
	# load/restart so the previous run's history doesn't bleed into the new one.
	backlog_manager.clear()
	choice_history_manager.clear()


func _on_state_changed(from_state: int, _to_state: int) -> void:
	# Leaving PLAYING state: stop auto-play and skip
	if from_state == GameStateMachine.State.PLAYING:
		auto_play.stop()
		skip_controller.stop()


func _on_scenario_ended(id: String) -> void:
	if engine == null or not engine.is_emitting_active_scenario_end():
		return
	SignalBus.scenario_ended_event.emit(id)
	# The public bridge is itself reentrant. A listener may start a replacement
	# navigation, which invalidates this run while the engine is still inside
	# scenario_ended.emit(). Do not let the retired callback append a title
	# navigation after that newer owner has already taken over.
	if not engine.is_emitting_active_scenario_end():
		return
	# Auto return to title after scenario ends
	return_to_title()


## Issue #97: called on every engine.scene_changed. Detects chapter
## transitions and updates flowchart state + visited tracking.
func _on_scene_changed_for_flowchart(scene_id: String) -> void:
	if engine == null or engine.context == null:
		return
	if engine.context.scenario_data == null:
		return
	var scene = engine.context.scenario_data.get_scene(scene_id)
	if scene == null or scene.chapter_id == "":
		return

	var new_chapter_id = scene.chapter_id
	var old_chapter_id = flowchart_state.get_current_chapter_id()

	if new_chapter_id == old_chapter_id:
		return  # Still inside the same chapter — no transition.

	# Chapter transition detected.
	# Pass new_chapter_id as the override so the captured snapshot's
	# chapter_id field reflects the chapter the player will be IN after
	# restore, not the old one (flowchart_state.current_path hasn't been
	# updated yet at this point).
	var snapshot = _capture_rollback_snapshot(new_chapter_id)
	flowchart_state.enter_chapter(new_chapter_id, snapshot)
	flowchart_visited.mark_chapter_visited(new_chapter_id)

	# Mark traversed edge(s). We know old→new chapter but not HOW (jump /
	# choice / sequential / call). Conservatively mark ALL edges between the
	# two chapters. This is slightly inaccurate for the "two choice options to
	# the same chapter" case (both marked visited when only one was taken),
	# but correct for all other topologies. PR-D can refine with richer engine
	# signals if needed (e.g. choice_selected carrying option label).
	if old_chapter_id != "" and scenario_graph != null:
		for edge in scenario_graph.get_outgoing_edges(old_chapter_id):
			if edge.target_chapter_id == new_chapter_id:
				flowchart_visited.mark_edge_visited(edge.get_edge_id())


func _on_dialogue_for_backlog(
	request: DialogueRequest,
	effect_names: Array = [],
) -> void:
	if engine == null or engine.context == null:
		return
	backlog_manager.add_entry(
		request.get_character(),
		request.get_segments(),
		request.get_command_uid(),
		_capture_rollback_snapshot,
		effect_names,
		request.get_entry_id(),
	)


func _on_dialogue_backlog_effects_resolved(
	request: DialogueRequest,
	effect_names: Array,
) -> void:
	if effect_names.is_empty():
		return
	backlog_manager.enrich_entry(
		request.get_entry_id(), request.get_segments(), effect_names)


## Capture a rollback snapshot every time ChoiceHandler surfaces a menu.
## Fired synchronously from ChoiceHandler.execute() before the await, so
## engine.context.current_command_index still points AT the choice command
## — meaning the snapshot, once restored, re-enters that same choice.
func _on_choice_for_history(_prompt: String, _options: Array) -> void:
	if engine == null or engine.context == null:
		return
	var cmd = engine.context.current_command()
	var uid: int = -1
	if cmd != null:
		uid = cmd.uid
	choice_history_manager.record(uid, _capture_rollback_snapshot)


## Capture a lightweight snapshot for rollback paths (backlog jump,
## flowchart jump, choice rewind — all three delegate to
## _restore_runtime_from_snapshot when applying).
##
## Excluded from this snapshot — these are monotonic / cross-playthrough
## persistent and MUST NOT be rolled back when navigating history:
##   - read_flags (already excluded by not being captured here)
##   - unlock_manager (CG/scene/BGM unlock progress)
##   - voice_bookmark_manager
##   - VariableStore.Scope.GLOBAL (issue #98 — captured via the scoped
##     capture_scenario_scope() helper, not the full capture_snapshot())
##
## `chapter_override`: when a caller is capturing during a chapter
## transition (see _on_scene_changed_for_flowchart), the chapter that's
## about to become current is passed explicitly — flowchart_state hasn't
## been updated yet at that moment, so `get_current_chapter_id()` would
## return the wrong (previous) chapter. Default empty string falls back
## to flowchart_state's current value, which is correct for mid-chapter
## captures (backlog entry, choice menu).
func _capture_rollback_snapshot(chapter_override: String = "") -> Dictionary:
	var snap: Dictionary = {}
	if engine and engine.context:
		snap["scenario_context"] = engine.context.capture_snapshot()
		if engine.context.variable_store:
			snap["variable_store"] = engine.context.variable_store.capture_scenario_scope()
	if presentation_state:
		snap["presentation_state"] = presentation_state.capture_snapshot()
	# Chapter id is used by _restore_runtime_from_snapshot to keep the
	# flowchart line in sync with the restored engine position — crucial
	# for cross-chapter rewinds (otherwise current_path grows on every
	# rewind as scene_changed re-appends the "new" chapter).
	if flowchart_state:
		if chapter_override != "":
			snap["chapter_id"] = chapter_override
		else:
			snap["chapter_id"] = flowchart_state.get_current_chapter_id()
	return snap


# ─── Facade API: Save/Load ───

## Quick save (separate from manual save slots).
func quick_save() -> void:
	save_manager.quick_save()


## Quick load (separate from manual save slots).
## Works from both title screen (switches to game scene) and in-game (reloads in place).
func quick_load() -> bool:
	var scenario_path = _last_scenario_path
	if scenario_path == "":
		scenario_path = config.scenario_path
	if scenario_path == "":
		return false
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = save_manager.read_quick_save_data(scenario_data)
	if save_data == null:
		return false

	var needs_game_scene := (
		_is_on_title_screen()
		or _navigation_scene_request_pending
		or _return_to_title_pending
	)
	var destination: Dictionary = {}
	if needs_game_scene:
		destination = _load_navigation_scene(_get_game_scene_path(), "game")
		if destination.is_empty():
			return false
	var navigation := _begin_navigation("quick_load")

	# From title or while superseding another scene request, explicitly assert
	# the game destination before restoring providers and starting the engine.
	if needs_game_scene:
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			return false
		_cancel_active_gameplay()
		_close_current_overlay()
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		_load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
		)
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	_cancel_active_gameplay()
	_reset_presentation()
	_last_scenario_path = scenario_path
	_load_preparsed_scenario_and_restore(scenario_data, scenario_path, save_data)
	_finish_navigation(navigation)
	return true


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
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = _read_continue_data(continue_type, scenario_data)
	if save_data == null:
		return false

	var needs_game_scene := (
		_is_on_title_screen()
		or _navigation_scene_request_pending
		or _return_to_title_pending
	)
	var destination: Dictionary = {}
	if needs_game_scene:
		destination = _load_navigation_scene(_get_game_scene_path(), "game")
		if destination.is_empty():
			return false
	var navigation := _begin_navigation("continue_game")

	# From title or while superseding another scene request, explicitly assert
	# the game destination before restoring providers and starting the engine.
	if needs_game_scene:
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			return false
		_cancel_active_gameplay()
		_close_current_overlay()
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		_load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
		)
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	_cancel_active_gameplay()
	_reset_presentation()
	_last_scenario_path = scenario_path
	_load_preparsed_scenario_and_restore(scenario_data, scenario_path, save_data)
	_finish_navigation(navigation)
	return true


## Load from the appropriate continue save type.
func _load_continue(continue_type: String) -> bool:
	if continue_type == "quick":
		return save_manager.quick_load()
	elif continue_type == "auto":
		return save_manager.auto_load()
	return false


func _read_continue_data(
	continue_type: String,
	scenario_data: ScenarioData = null,
) -> Variant:
	if continue_type == "quick":
		return save_manager.read_quick_save_data(scenario_data)
	if continue_type == "auto":
		return save_manager.read_auto_save_data(scenario_data)
	return null


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


# ─── Facade API: Named Stage Layers ───

## Apply an atomic batch of named-stage operations. Each operation uses the
## same schema as the `stage_layer` CommandData payload: action, id,
## properties, transition, and duration.
func apply_stage_operations(
	operations: Array,
	force_cut: bool = false,
) -> void:
	var authored_operations: Array = []
	for raw_operation in operations:
		if raw_operation is Dictionary:
			var operation: Dictionary = raw_operation
			var layer_id := String(operation.get("id", "")).strip_edges()
			var authored_operation := operation.duplicate(true)
			authored_operation["id"] = layer_id
			authored_operations.append(authored_operation)
		else:
			authored_operations.append(raw_operation)
	if authored_operations.is_empty() and not operations.is_empty():
		return
	SignalBus.emit_stage_operations(
		authored_operations.duplicate(true),
		force_cut,
	)


func show_stage_layer(
	layer_id: String,
	properties: Dictionary,
	transition: String = "cut",
	duration: float = 0.0,
) -> void:
	_emit_stage_operation(
		"show", layer_id, properties, transition, duration
	)


func update_stage_layer(
	layer_id: String,
	properties: Dictionary,
	transition: String = "cut",
	duration: float = 0.0,
) -> void:
	_emit_stage_operation(
		"update", layer_id, properties, transition, duration
	)


func hide_stage_layer(
	layer_id: String,
	transition: String = "cut",
	duration: float = 0.0,
) -> void:
	_emit_stage_operation("hide", layer_id, {}, transition, duration)


func remove_stage_layer(
	layer_id: String,
	transition: String = "cut",
	duration: float = 0.0,
) -> void:
	_emit_stage_operation("remove", layer_id, {}, transition, duration)


func clear_stage_layers(
	transition: String = "cut",
	duration: float = 0.0,
) -> void:
	_emit_stage_operation("clear", "", {}, transition, duration)


func _emit_stage_operation(
	action: String,
	layer_id: String,
	properties: Dictionary,
	transition: String,
	duration: float,
) -> void:
	if action != "clear" and layer_id.strip_edges() == "":
		push_warning("StellaRuntime: stage operation requires a layer id")
		return
	apply_stage_operations([{
		"action": action,
		"id": layer_id,
		"properties": properties.duplicate(true),
		"transition": transition,
		"duration": duration,
	}])


# ─── Facade API: UI Overlays ───

## Show the backlog overlay.
func show_backlog() -> void:
	if not config.backlog:
		return
	var scene_path = config.backlog_scene if config.backlog_scene != "" else DEFAULT_BACKLOG_SCENE
	if _open_overlay(scene_path):
		game_state.transition_to(GameStateMachine.State.BACKLOG)


## Show the save/load overlay.
func show_save_load(mode: String = "save") -> void:
	var scene_path = config.save_load_scene if config.save_load_scene != "" else DEFAULT_SAVE_LOAD_SCENE
	if _open_overlay(scene_path):
		if _current_overlay and _current_overlay.has_method("set_mode"):
			_current_overlay.set_mode(mode)
		game_state.transition_to(GameStateMachine.State.SAVE_LOAD)


## Show the settings overlay.
func show_settings() -> void:
	var scene_path = config.settings_scene if config.settings_scene != "" else DEFAULT_SETTINGS_SCENE
	if _open_overlay(scene_path):
		game_state.transition_to(GameStateMachine.State.SETTINGS)


## Show the flowchart overlay (issue #97 PR-D).
func show_flowchart() -> void:
	var scene_path = config.flowchart_scene if config.flowchart_scene != "" else DEFAULT_FLOWCHART_SCENE
	if _open_overlay(scene_path):
		game_state.transition_to(GameStateMachine.State.FLOWCHART)


## Close the current overlay and return to previous state.
func close_overlay() -> void:
	if config.se_cancel != "":
		SignalBus.system_se_play.emit(config.se_cancel)
	_close_current_overlay()
	game_state.return_to_previous()


func _open_overlay(scene_path: String) -> bool:
	var destination := _load_navigation_scene(scene_path, "overlay")
	if destination.is_empty():
		return false
	var scene: PackedScene = destination["scene"]
	var overlay := scene.instantiate()
	if overlay == null:
		push_error("StellaRuntime: overlay scene could not be instantiated")
		return false
	if _current_overlay != null:
		push_warning("StellaRuntime: opening overlay while another is active — closing previous")
		_close_current_overlay()
	_current_overlay = overlay
	# Add as CanvasLayer child so it renders above game content
	var overlay_layer = CanvasLayer.new()
	overlay_layer.layer = 10
	overlay_layer.name = "OverlayLayer"
	overlay_layer.add_child(_current_overlay)
	add_child(overlay_layer)
	return true


func _close_current_overlay() -> void:
	var overlay := _current_overlay
	_current_overlay = null
	if not is_instance_valid(overlay):
		return
	var layer := overlay.get_parent()
	if is_instance_valid(layer):
		layer.queue_free()


# ─── Facade API: CG Gallery ───

## Record a CG unlock when the project has enabled its gallery feature.
## UnlockManager remains registered as a save provider while disabled so
## existing progress survives a temporary feature opt-out.
func unlock_cg(cg_id: String) -> bool:
	if not config.cg_gallery:
		return false
	if cg_id.is_empty():
		push_warning("StellaRuntime.unlock_cg: cg_id must not be empty")
		return false
	unlock_manager.unlock("cg", cg_id)
	return true


## Disabled galleries expose no CG progress through the public facade.
func is_cg_unlocked(cg_id: String) -> bool:
	if not config.cg_gallery:
		return false
	return unlock_manager.is_unlocked("cg", cg_id)


## Return a copy so UI code cannot mutate the persisted provider state.
func get_unlocked_cgs() -> Array:
	if not config.cg_gallery:
		return []
	return unlock_manager.get_unlocked("cg").duplicate()


# ─── Facade API: Backlog ───

## Get dialogue history entries.
func get_backlog() -> Array:
	return backlog_manager.get_entries()


## Shared rollback pipeline for all "jump to a captured snapshot" paths:
## backlog jump, choice history jump, and flowchart chapter jump. Each of
## those features looks up a snapshot in its own storage, then delegates
## here to perform the actual restore. Centralizing the pipeline keeps the
## rollback contract (issue #98 — Scope.GLOBAL must survive) in one place.
##
## Pipeline stages, in order:
## 1. Close any overlay + transition to PLAYING state.
## 2. Build a fresh ScenarioContext that reuses the old VariableStore
##    instance — dropping the store would lose Scope.GLOBAL (#98).
## 3. Reset visuals to a clean slate. bgm_stop triggers the PresentationState
##    signal listener; restore_snapshot then overwrites it. fade("in",0) drops
##    any lingering screen-fade overlay.
## 4. Restore scenario_context + scenario-scope vars + presentation_state
##    from the snapshot. Scope-only var restore so Scope.GLOBAL stays intact.
## 5. If override_scene_id is non-empty, set_scene to it AFTER the snapshot
##    restore. Used by flowchart jump where the snapshot position and the
##    chapter entry can differ and we want to be safe against mismatch.
## 6. apply_to_presenters — snap visuals to the restored state in one shot
##    before engine.run() re-dispatches the target command.
## 7. Register the new context as a save provider BEFORE swapping it in.
##    Otherwise an autosave triggered by NOTIFICATION_WM_CLOSE_REQUEST in
##    the window between swap and register would serialize an inconsistent
##    mix (old context provider + new presentation_state).
## 8. Swap engine.context, mark the old ctx finished (belt-and-braces in
##    case the old loop is between iterations), and emit
##    engine_abort_requested. Every blocking handler (dialogue/wait/choice)
##    races against this signal via CommandHandler.await_with_abort, so a
##    single emit cancels them all regardless of which native signal each
##    was waiting on.
## 9. engine.run() — new loop picks up the restored context.
func _restore_runtime_from_snapshot(snap: Dictionary, override_scene_id: String = "") -> void:
	_close_current_overlay()
	game_state.transition_to(GameStateMachine.State.PLAYING)

	var scenario_data = engine.context.scenario_data
	var new_ctx = ScenarioContext.new(scenario_data)
	new_ctx.variable_store = engine.context.variable_store

	SignalBus.reset_stage_visuals()
	SignalBus.bgm_stop.emit(0.0)
	SignalBus.hide_dialogue.emit()
	SignalBus.fade_requested.emit("in", 0.0)
	presentation_state.clear()

	new_ctx.restore_snapshot(snap.get("scenario_context", {}))
	new_ctx.variable_store.restore_scenario_scope(snap.get("variable_store", {}))
	if override_scene_id != "":
		new_ctx.set_scene(override_scene_id)
	presentation_state.restore_snapshot(snap.get("presentation_state", {}))
	presentation_state.apply_to_presenters()

	# Sync the flowchart trajectory to match the restored engine position.
	# Without this, a cross-chapter rewind leaves current_path ending on a
	# stale chapter — and the subsequent scene_changed event re-appends the
	# "new" chapter on top, causing current_path to grow with every rewind.
	# Skipped for snapshots missing chapter_id (e.g. initial_snapshot
	# captured before any chapter was entered — jump_from_flowchart handles
	# that case with its own explicit flowchart_state.jump_to() call).
	var chapter_at_capture: String = snap.get("chapter_id", "")
	if chapter_at_capture != "" and flowchart_state != null:
		flowchart_state.jump_to(chapter_at_capture)

	save_manager.register_provider(new_ctx)
	save_manager.register_provider(new_ctx.variable_store)
	engine.replace_context(new_ctx)
	SignalBus.engine_abort_requested.emit()

	engine.run()


## Jump to a backlog entry. Restores that entry's snapshot directly —
## scenario position, variables, and presentation state are all rewound
## to exactly the moment that dialogue was first displayed. Backlog history
## is preserved (cursor moves but no truncate); divergence is detected
## automatically when the player next adds an entry that doesn't match
## the recorded path.
func jump_from_backlog(index: int) -> bool:
	if engine == null or engine.context == null:
		return false
	var info = backlog_manager.jump_to(index)
	if info.is_empty():
		return false
	_restore_runtime_from_snapshot(info["snapshot"])
	return true


## True if there's a previous-choice snapshot the player can rewind to
## from the current position. Used by the toolbar to enable/disable the
## "回选项" button — calling jump_to_previous_choice() without this check
## is still safe (returns false as a no-op) but the button should visibly
## reflect whether it would do anything.
func can_jump_to_previous_choice() -> bool:
	if engine == null or engine.context == null:
		return false
	var cur_cmd = engine.context.current_command()
	var cur_uid: int = -1
	if cur_cmd != null:
		cur_uid = cur_cmd.uid
	return choice_history_manager.has_previous(cur_uid)


## Rewind execution to the most recent @choice menu — the "回到上一选项"
## toolbar action. When the player is currently parked on a choice menu
## (awaiting selection), "previous" means the choice BEFORE this one; when
## they've already made a selection and progressed, "previous" means the
## choice they just walked past. Returns false when there's no such
## snapshot available.
func jump_to_previous_choice() -> bool:
	if engine == null or engine.context == null:
		return false
	var cur_cmd = engine.context.current_command()
	var cur_uid: int = -1
	if cur_cmd != null:
		cur_uid = cur_cmd.uid
	var info = choice_history_manager.pop_previous(cur_uid)
	if info.is_empty():
		return false
	_restore_runtime_from_snapshot(info["snapshot"])
	return true


## Jump to a chapter from the flowchart UI (issue #97).
##
## Restores the snapshot that was captured when the player last entered the
## target chapter (or INITIAL_SNAPSHOT if never visited — author debug mode).
## Updates flowchart_state.current_path: truncates if target is on the current
## line, resets if off-line.
##
## Returns false if the chapter doesn't exist in the graph, has no entry scene,
## or the engine is not running. Callers should check scenario_graph.is_deadlocked()
## before offering the jump to the user (deadlocked chapters are technically
## jumpable but the player would get stuck again immediately).
func jump_from_flowchart(chapter_id: String) -> bool:
	if engine == null or engine.context == null:
		return false
	if scenario_graph == null:
		return false

	var target_chapter = scenario_graph.get_chapter(chapter_id)
	if target_chapter == null:
		return false

	var entry_scene_id = target_chapter.get_entry_scene_id()
	if entry_scene_id == "":
		return false

	# Get the rollback snapshot for this chapter (visited → their entry snapshot;
	# unvisited → initial_snapshot from the start of the scenario).
	var snap = flowchart_state.get_snapshot_for_chapter(chapter_id)

	# Update flowchart line (truncate or reset).
	flowchart_state.jump_to(chapter_id)

	# Delegate the restore pipeline. Pass entry_scene_id as the override so
	# set_scene runs after restore_snapshot — defending against a snapshot-
	# context mismatch where the captured scene_index disagrees with the
	# chapter entry scene.
	_restore_runtime_from_snapshot(snap, entry_scene_id)
	return true


# ─── Facade API: Settings ───

## Get a setting value by key.
func get_setting(key: String) -> Variant:
	var val = settings_manager.settings.get(key)
	if val == null and not key in settings_manager.settings.to_dict():
		push_warning("StellaRuntime.get_setting: unknown key '%s'" % key)
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
	DisplayHelper.apply(settings_manager.settings)


func _play_title_bgm() -> void:
	SignalBus.bgm_play.emit(config.title_bgm, 1.0)


## Play a system sound effect (UI clicks, confirmations, etc.)
func play_system_se(asset: String) -> void:
	SignalBus.system_se_play.emit(asset)


## Get save metadata for a slot (timestamp, etc). Returns empty dict if no save.
func get_save_metadata(slot_id: int) -> Dictionary:
	return save_manager.get_save_metadata(slot_id)
