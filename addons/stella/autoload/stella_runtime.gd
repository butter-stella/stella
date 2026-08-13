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
	var pending: Array[PackedScene] = [scene]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var current: PackedScene = pending.pop_back()
		if not current.can_instantiate():
			return false
		var identity := current.resource_path
		if identity == "":
			identity = str(current.get_instance_id())
		if visited.has(identity):
			continue
		visited[identity] = true

		var state := current.get_state()
		for node_index in state.get_node_count():
			var nested_scene := state.get_node_instance(node_index)
			if nested_scene != null:
				pending.append(nested_scene)
			for property_index in state.get_node_property_count(node_index):
				if state.get_node_property_name(node_index, property_index) != &"script":
					continue
				var script := state.get_node_property_value(
					node_index,
					property_index,
				) as Script
				if not _title_script_is_enterable(script):
					return false
	return true


func _title_script_is_enterable(script: Script) -> bool:
	if script == null:
		return true
	if not script.can_instantiate() or script.is_abstract():
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
	if path == "" or not ResourceLoader.exists(path, "PackedScene"):
		return null
	return load(path) as PackedScene


## Return to title screen. Destructive cleanup and state transition happen only
## after SceneTree accepts the resolved (or built-in fallback) scene.
func return_to_title() -> void:
	var title_scene := resolve_title_scene()
	if title_scene == null:
		push_error("StellaRuntime: built-in title scene is unavailable")
		return

	# Snapshot scene-owned providers while the outgoing scene is still alive.
	# change_scene_to_packed() synchronously removes it and runs _exit_tree(), so
	# saving after the request can capture teardown state instead of gameplay.
	auto_save()
	var scene_error := get_tree().change_scene_to_packed(title_scene)
	if scene_error != OK:
		push_error(
			(
				"StellaRuntime: failed to enter the configured title scene (%s); "
				+ "falling back to the built-in title scene"
			) % error_string(scene_error)
		)
		title_scene_path = DEFAULT_TITLE_SCENE
		title_scene = DEFAULT_TITLE_PACKED_SCENE
		if not _title_scene_is_enterable(title_scene):
			push_error("StellaRuntime: built-in title scene is not enterable")
			return
		scene_error = get_tree().change_scene_to_packed(title_scene)
		if scene_error != OK:
			push_error(
				"StellaRuntime: failed to enter the built-in title scene (%s)"
				% error_string(scene_error)
			)
			return

	_close_current_overlay()
	backlog_manager.clear()
	choice_history_manager.clear()
	auto_play.stop()
	skip_controller.stop()
	game_state.transition_to(GameStateMachine.State.TITLE)
	if config.title_bgm != "":
		_play_title_bgm()


## Legacy API — starts scenario in current scene (for testing).
func start_scenario(scenario_path: String) -> void:
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	_start_scenario_internal(scenario_path)


func _start_scenario_internal(scenario_path: String) -> void:
	_prepare_scenario(scenario_path)
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
func _prepare_scenario(scenario_path: String) -> void:
	var file = FileAccess.open(scenario_path, FileAccess.READ)
	if file == null:
		push_error("StellaRuntime: cannot open %s" % scenario_path)
		return
	var source = file.get_as_text()
	file.close()

	var tokens = DslLexer.tokenize(source)
	var scenario_id = scenario_path.get_file().get_basename()
	var data = DslParser.parse(tokens, scenario_id, scenario_path)
	# Surface parser diagnostics (issue #97). DslParser is intentionally silent
	# about console reporting; this is the integration point where parse-time
	# errors/warnings reach the developer.
	for d in data.diagnostics:
		var msg = "[%s] %s" % [scenario_id, d.get("message", "")]
		if d.get("level") == "error":
			push_error(msg)
		else:
			push_warning(msg)

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
func _load_scenario_and_restore(scenario_path: String, slot_id: int) -> void:
	_prepare_scenario(scenario_path)
	save_manager.load_save(slot_id)
	presentation_state.apply_to_presenters()
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
	SignalBus.scenario_ended_event.emit(id)
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
			presentation_state.apply_to_presenters()
			engine.run()
		return ok

	# In-game: reload in place
	_reset_presentation()
	_prepare_scenario(scenario_path)
	var ok = save_manager.quick_load()
	if ok:
		presentation_state.apply_to_presenters()
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
			presentation_state.apply_to_presenters()
			engine.run()
		return ok

	# In-game: reload in place
	_reset_presentation()
	_prepare_scenario(scenario_path)
	var ok = _load_continue(continue_type)
	if ok:
		presentation_state.apply_to_presenters()
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


## Show the flowchart overlay (issue #97 PR-D).
func show_flowchart() -> void:
	var scene_path = config.flowchart_scene if config.flowchart_scene != "" else DEFAULT_FLOWCHART_SCENE
	_open_overlay(scene_path)
	game_state.transition_to(GameStateMachine.State.FLOWCHART)


## Close the current overlay and return to previous state.
func close_overlay() -> void:
	if config.se_cancel != "":
		SignalBus.system_se_play.emit(config.se_cancel)
	_close_current_overlay()
	game_state.return_to_previous()


func _open_overlay(scene_path: String) -> void:
	if _current_overlay != null:
		push_warning("StellaRuntime: opening overlay while another is active — closing previous")
	_close_current_overlay()
	var scene = load(scene_path) as PackedScene
	if scene == null:
		push_error("StellaRuntime: cannot load overlay scene %s" % scene_path)
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
	var old_ctx = engine.context
	engine.context = new_ctx
	old_ctx.is_finished = true
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
