## Framework entry point. Initializes engine, registers handlers, manages scene lifecycle.
## Registered as Autoload singleton — persists across scene changes.
extends Node

signal _navigation_scene_slot_settled

const CONFIG_PATH = "res://stella.cfg"
const LOCAL_CONFIG_PATH = "res://stella.local.cfg"
const DISABLE_LOCAL_CONFIG_ENV = "STELLA_DISABLE_LOCAL_CONFIG"
const DISABLE_IMPLICIT_SETTINGS_LOAD_ENV = "STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD"
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
const DIALOGUE_PRESENTER_SCRIPT: Script = preload(
	"res://addons/stella/presentation/dialogue/dialogue_presenter.gd")
const AUDIO_SHUTDOWN_MAX_PROCESS_FRAMES := 120
const AUDIO_MIX_ROLLOVER_EPSILON := 0.000000001
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
var presentation_director: PresentationDirector
var presentation_clip_audio_choice_authority: PresentationClipAudioChoiceAuthority
var movie_presenter: MoviePresenter
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
var voice_dsp_path: String = "res://audio/voice_dsp/"
var presentation_clips_path: String = "res://presentation/clips/"
var movies_path: String = "res://video/movies/"
var presentation_clip_resource_budget_bytes: int = 512 * 1024 * 1024
var presentation_clip_max_viewport_pixels: int = 3840 * 2160
var presentation_clip_audio_choice_seed: int = 0

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
var _navigation_scene_slot_serial_counter: int = 0
var _navigation_scene_slot_active_serial: int = 0
var _navigation_scene_slot_accepted: bool = false
var _navigation_scene_slot_navigation: int = 0
var _navigation_scene_slot_suspension: RefCounted
var _navigation_scene_slot_context: ScenarioContext
var _navigation_scene_slot_suspension_retired: bool = false
var _navigation_scene_slot_run_retired: bool = false
# Exact broadcast receipts. Each serial owns one creator reservation plus any
# waiter leases registered before settlement. A settled result is immutable and
# is erased only after every pre-existing consumer has copied it.
var _navigation_scene_slot_results: Dictionary = {}
var _navigation_scene_change_override: Callable
var _navigation_projection_committed: bool = false
var _navigation_runtime_ownership_generation: int = 0
var _navigation_presentation_reset_generation: int = 0
var _navigation_run_suspension: RefCounted
var _navigation_run_suspension_generation: int = 0
var _navigation_run_suspension_context: ScenarioContext
var _navigation_run_suspension_retired: bool = false
var _navigation_blocking_presentation_waiter_cancelled: bool = false
var _navigation_run_requires_fresh_dispatch: bool = false
var _navigation_retired_run_context: ScenarioContext
var _navigation_recovery_wait_generation: int = 0
var _navigation_recovery_wait_slot_serial: int = 0
var _text_resource_inspector := TextResourceInspector.new()
var _last_published_chapter_id := ""
var _last_published_chapter_title := ""
var _last_published_chapter_context: ScenarioContext
var _last_published_chapter_navigation := 0
var _publishing_current_chapter := false
var _chapter_republish_pending := false
var _emitting_chapter_id := ""
var _emitting_chapter_title := ""
var _stage_registrar_authority := RefCounted.new()
var _dialogue_clear_registrar_authority := RefCounted.new()
var _dialogue_avatar_registrar_authority := RefCounted.new()
var _chapter_indicator_registrar_authority := RefCounted.new()
var _loop_se_registrar_authority := RefCounted.new()
var _bgm_registrar_authority := RefCounted.new()
var _presentation_clip_registrar_authority := RefCounted.new()
var _movie_registrar_authority := RefCounted.new()
var _quit_requested := false
var _quit_exit_code := 0
var _quit_completion_started := false
var _choice_session_serial: int = 0
var _active_choice_session: int = -1
var _active_choice_auto_suspension: bool = false
var _choice_presentation_dispatch_stack: Array[int] = []
var _active_recollection_playback: ScenarioPlaybackContext
var _active_recollection_context: ScenarioContext


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
	if not SignalBus.configure_stage_registrar(_stage_registrar_authority):
		push_error("StellaRuntime: Stage presenter registrar authority conflict")
	if not SignalBus.configure_dialogue_clear_registrar(
		_dialogue_clear_registrar_authority):
		push_error("StellaRuntime: dialogue clear registrar authority conflict")
	if not SignalBus.configure_dialogue_avatar_registrar(
		_dialogue_avatar_registrar_authority):
		push_error("StellaRuntime: dialogue avatar registrar authority conflict")
	if not SignalBus.configure_chapter_indicator_registrar(
		_chapter_indicator_registrar_authority):
		push_error("StellaRuntime: chapter indicator registrar authority conflict")
	if not SignalBus.configure_loop_se_registrar(_loop_se_registrar_authority):
		push_error("StellaRuntime: loop-SE registrar authority conflict")
	if not SignalBus.configure_bgm_registrar(_bgm_registrar_authority):
		push_error("StellaRuntime: BGM registrar authority conflict")
	if not SignalBus.configure_presentation_clip_registrar(
		_presentation_clip_registrar_authority):
		push_error("StellaRuntime: presentation-clip registrar authority conflict")
	if not SignalBus.configure_movie_registrar(_movie_registrar_authority):
		push_error("StellaRuntime: movie registrar authority conflict")


## Composition-owned admission keeps the cross-layer Bus free of concrete
## Presentation dependencies while preventing arbitrary signal listeners from
## enlarging the chapter-indicator quorum.
func _register_stage_presenter(presenter: Object) -> RefCounted:
	if not presenter is StagePresenter:
		return null
	return SignalBus.register_stage_presenter(
		presenter,
		_stage_registrar_authority,
		Callable(presenter, "_run_sealed_stage_transaction_phase"),
	)


func _unregister_stage_presenter(
	presenter: Object,
	capability: RefCounted,
) -> void:
	SignalBus.unregister_stage_presenter(
		presenter,
		capability,
		_stage_registrar_authority,
	)


func _register_dialogue_clear_presenter(presenter: Object) -> RefCounted:
	if (
		presenter == null
		or not presenter is Control
		or presenter.get_script() != DIALOGUE_PRESENTER_SCRIPT
	):
		return null
	return SignalBus.register_dialogue_clear_presenter(
		presenter, _dialogue_clear_registrar_authority)


func _unregister_dialogue_clear_presenter(
	presenter: Object,
	capability: RefCounted,
) -> void:
	SignalBus.unregister_dialogue_clear_presenter(
		presenter,
		capability,
		_dialogue_clear_registrar_authority,
	)


func _register_dialogue_avatar_presenter(presenter: Object) -> RefCounted:
	if (
		presenter == null
		or not presenter is Control
		or presenter.get_script() != DIALOGUE_PRESENTER_SCRIPT
	):
		return null
	return SignalBus.register_dialogue_avatar_presenter(
		presenter, _dialogue_avatar_registrar_authority)


func _unregister_dialogue_avatar_presenter(
	presenter: Object,
	capability: RefCounted,
) -> void:
	SignalBus.unregister_dialogue_avatar_presenter(
		presenter,
		capability,
		_dialogue_avatar_registrar_authority,
	)


func _register_presentation_clip_dialogue_participant(
	presenter: Object,
) -> RefCounted:
	if (
		presenter == null
		or not presenter is Control
		or presenter.get_script() != DIALOGUE_PRESENTER_SCRIPT
	):
		return null
	return SignalBus.register_presentation_clip_composition_participant(
		presenter,
		PresentationClipOperationRequest.ROLE_DIALOGUE,
		_presentation_clip_registrar_authority,
		Callable(presenter, "_run_presentation_clip_transaction_phase"),
	)


func _register_presentation_clip_audio_participant(
	presenter: Object,
) -> RefCounted:
	if not presenter is AudioPresenter:
		return null
	return SignalBus.register_presentation_clip_composition_participant(
		presenter,
		PresentationClipOperationRequest.ROLE_AUDIO,
		_presentation_clip_registrar_authority,
		Callable(presenter, "_run_presentation_clip_transaction_phase"),
	)


func _unregister_presentation_clip_composition_participant(
	presenter: Object,
	capability: RefCounted,
	role: StringName,
) -> bool:
	return SignalBus.unregister_presentation_clip_composition_participant(
		presenter,
		capability,
		role,
		_presentation_clip_registrar_authority,
	)


func _register_chapter_indicator_presenter(presenter: Object) -> RefCounted:
	if not presenter is ChapterIndicatorPresenter:
		return null
	return SignalBus.register_chapter_indicator_presenter(
		presenter, _chapter_indicator_registrar_authority)


func _unregister_chapter_indicator_presenter(
	presenter: Object,
	capability: RefCounted,
) -> void:
	SignalBus.unregister_chapter_indicator_presenter(
		presenter,
		capability,
		_chapter_indicator_registrar_authority,
	)


func _register_audio_presenter(presenter: Object) -> Dictionary:
	if not presenter is AudioPresenter:
		return {}
	return SignalBus.register_audio_presenter(
		presenter,
		_loop_se_registrar_authority,
		_bgm_registrar_authority,
	)


func _unregister_audio_presenter(
	presenter: Object,
	loop_se_capability: RefCounted,
	bgm_capability: RefCounted,
) -> bool:
	return SignalBus.unregister_audio_presenter(
		presenter,
		loop_se_capability,
		bgm_capability,
		_loop_se_registrar_authority,
		_bgm_registrar_authority,
	)


func _register_presentation_clip_presenter(presenter: Object) -> RefCounted:
	if not presenter is PresentationClipPresenter:
		return null
	return SignalBus.register_presentation_clip_presenter(
		presenter,
		_presentation_clip_registrar_authority,
		Callable(presenter, "_run_presentation_clip_transaction_phase"),
		Callable(presenter, "_claim_active_input_finish"),
		Callable(presenter, "_has_active_projection"),
	)


func _unregister_presentation_clip_presenter(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	return SignalBus.unregister_presentation_clip_presenter(
		presenter, capability, _presentation_clip_registrar_authority)


func _register_movie_presenter(presenter: Object) -> RefCounted:
	if not presenter is MoviePresenter:
		return null
	var capability := SignalBus.register_movie_presenter(
		presenter,
		_movie_registrar_authority,
		Callable(presenter, "_claim_active_input_finish"),
		Callable(presenter, "_has_active_projection"),
		Callable(presenter, "_discard_recovery_state"),
		Callable(presenter, "_apply_restore_state"),
		Callable(presenter, "_prepare_rollback_state"),
		Callable(presenter, "_apply_rollback_state"),
		Callable(presenter, "_release_rollback_plan"),
	)
	if capability != null:
		movie_presenter = presenter
	return capability


func _unregister_movie_presenter(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	var removed := SignalBus.unregister_movie_presenter(
		presenter, capability, _movie_registrar_authority)
	if removed and movie_presenter == presenter:
		movie_presenter = null
	return removed


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		auto_save()
		request_quit()
	elif (
		what == NOTIFICATION_TRANSLATION_CHANGED
		and engine != null
		and _navigation_kind.is_empty()
	):
		_publish_current_chapter(engine.context, true)


## Product shutdown boundary for title actions, explicit performance-mode quit,
## and OS close. AudioStreamPlayer.stop() is not a synchronous retirement
## boundary in Godot 4.6.1, so quit is deferred until the unique AudioPresenter
## has quiesced and AudioServer reports a subsequent real mix rollover.
func request_quit(exit_code: int = 0) -> void:
	if not _begin_quit_request(exit_code):
		return
	_complete_graceful_quit.call_deferred()


func _begin_quit_request(exit_code: int) -> bool:
	if _quit_requested:
		return false
	_quit_requested = true
	_quit_exit_code = exit_code
	return true


func _complete_graceful_quit() -> void:
	if _quit_completion_started:
		return
	_quit_completion_started = true
	SignalBus.reset_movie_presentation()
	if not await _await_runtime_audio_quiesce():
		_fail_graceful_quit(
			"StellaRuntime: AudioPresenter did not acknowledge graceful shutdown")
		return
	if not await _await_audio_mix_boundary():
		_fail_graceful_quit(
			"StellaRuntime: no bounded AudioServer mix boundary during graceful shutdown")
		return
	get_tree().quit(_quit_exit_code)


func _fail_graceful_quit(message: String) -> void:
	push_error(message)
	get_tree().quit(_quit_exit_code if _quit_exit_code != 0 else 1)


func _await_runtime_audio_quiesce(
	max_process_frames: int = AUDIO_SHUTDOWN_MAX_PROCESS_FRAMES,
) -> bool:
	for frame_index: int in range(max_process_frames + 1):
		if SignalBus.quiesce_runtime_audio_for_shutdown():
			return true
		if frame_index == max_process_frames:
			break
		await get_tree().process_frame
	return false


func _await_audio_mix_boundary(
	max_process_frames: int = AUDIO_SHUTDOWN_MAX_PROCESS_FRAMES,
	mix_time_reader: Callable = Callable(),
	driver_name_override: Variant = null,
) -> bool:
	var driver_name := (
		AudioServer.get_driver_name()
		if driver_name_override == null
		else String(driver_name_override)
	)
	if driver_name.strip_edges().is_empty() or max_process_frames <= 0:
		return false
	var previous := _read_audio_mix_time(mix_time_reader)
	if not _audio_mix_time_is_valid(previous):
		return false
	for _frame_index: int in range(max_process_frames):
		await get_tree().process_frame
		var current := _read_audio_mix_time(mix_time_reader)
		if not _audio_mix_time_is_valid(current):
			return false
		if current < previous - AUDIO_MIX_ROLLOVER_EPSILON:
			# Audio-thread playback deletion becomes visible to ObjectDB/resource
			# cleanup on the main thread. Give that cleanup one explicit process
			# boundary after the observed mix before asking SceneTree to terminate.
			await get_tree().process_frame
			return true
		previous = current
	return false


func _read_audio_mix_time(mix_time_reader: Callable) -> float:
	var value: Variant = (
		mix_time_reader.call()
		if mix_time_reader.is_valid()
		else AudioServer.get_time_since_last_mix()
	)
	if not value is float and not value is int:
		return NAN
	return float(value)


func _audio_mix_time_is_valid(value: float) -> bool:
	return is_finite(value) and value >= 0.0


func _ready():
	get_tree().auto_accept_quit = false
	# Main-scene replacement is settled only by this central observer. It is
	# connected before any framework scene work so a destination root's _ready()
	# cannot make path equality masquerade as a completed SceneTree handoff.
	get_tree().scene_changed.connect(_on_navigation_scene_changed)
	save_manager = SaveManager.new()
	settings_manager = SettingsManager.new()
	if config.settings_schema_path != "":
		var schema_error := settings_manager.configure_project_schema(
			config.settings_schema_path)
		if schema_error != OK:
			push_error(
				"StellaRuntime: failed to load project settings schema %s at %s: %s"
				% [
					settings_manager.last_error_source,
					settings_manager.last_error_field,
					settings_manager.last_error_detail,
				])
	if not _is_implicit_settings_load_disabled():
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
	presentation_clip_audio_choice_authority = (
		PresentationClipAudioChoiceAuthority.new(
			presentation_clip_audio_choice_seed))
	presentation_director = PresentationDirector.new(
		presentation_state,
		func() -> bool: return skip_controller.is_active,
		func() -> void: skip_controller.stop(),
	)
	if not SignalBus.configure_presentation_clip_input_boundary(
		_presentation_clip_registrar_authority,
		Callable(presentation_director, "consume_active_presentation_clip_input"),
	):
		push_error("StellaRuntime: presentation-clip input authority conflict")
	if not SignalBus.configure_movie_input_boundary(
		_movie_registrar_authority,
		Callable(presentation_director, "consume_active_movie_input"),
	):
		push_error("StellaRuntime: movie input authority conflict")
	skip_controller.active_changed.connect(
		presentation_director.on_skip_active_changed)
	character_config_loader = CharacterConfigLoader.new()
	character_config_loader.set_base_path(characters_path)

	flowchart_state = FlowchartState.new()
	flowchart_visited = FlowchartVisitedState.new()

	save_manager.register_provider(read_flags)
	save_manager.register_provider(unlock_manager)
	save_manager.register_provider(presentation_state)
	save_manager.register_provider(presentation_clip_audio_choice_authority)
	# Flowchart state is per-save but the instance is a singleton on StellaRuntime
	# (unlike engine.context / variable_store which are recreated each scenario load).
	# Register once here; SaveManager deduplicates by provider_id.
	save_manager.register_provider(flowchart_state)
	# Flowchart visited is global/monotonic — restore_snapshot merges (union)
	# rather than overwrites, so loading old saves never loses progress.
	save_manager.register_provider(flowchart_visited)

	# Audio presenter — global, available in all scenes (title, game, overlays)
	var audio_node := AudioPresenter.new()
	audio_node.name = "AudioPresenter"
	add_child(audio_node)
	var clip_node := PresentationClipPresenter.new()
	clip_node.name = "PresentationClipPresenter"
	add_child(clip_node)
	movie_presenter = MoviePresenter.new()
	movie_presenter.name = "MoviePresenter"
	add_child(movie_presenter)

	registry = CommandRegistry.new()
	engine = ScenarioEngine.new()
	engine.registry = registry
	_register_handlers()

	# Bridge engine signals to SignalBus
	engine.scenario_started.connect(func(id): SignalBus.scenario_started_event.emit(id))
	engine.scenario_ended.connect(_on_scenario_ended)
	engine.scene_changed.connect(func(id): SignalBus.scene_changed_event.emit(id))
	engine.scene_changed.connect(_on_scene_changed_for_chapter_presentation)
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


## Hermetic automation can skip only the startup read of user://settings.json.
## Explicit load/save calls remain available and exercise the same production
## SettingsManager contract.
func _is_implicit_settings_load_disabled() -> bool:
	if not OS.has_environment(DISABLE_IMPLICIT_SETTINGS_LOAD_ENV):
		return false
	var raw_value := OS.get_environment(
		DISABLE_IMPLICIT_SETTINGS_LOAD_ENV).strip_edges().to_lower()
	return raw_value not in ["", "0", "false", "no", "off"]


## Apply config values to runtime paths.
func _apply_config() -> void:
	backgrounds_path = config.backgrounds_path
	characters_path = config.characters_path
	stage_assets_path = config.stage_path
	bgm_path = config.bgm_path
	se_path = config.se_path
	voice_path = config.voice_path
	voice_dsp_path = config.voice_dsp_path
	presentation_clips_path = config.presentation_clips_path
	movies_path = config.movies_path
	presentation_clip_resource_budget_bytes = (
		config.presentation_clip_resource_budget_bytes)
	presentation_clip_max_viewport_pixels = (
		config.presentation_clip_max_viewport_pixels)
	presentation_clip_audio_choice_seed = (
		config.presentation_clip_audio_choice_seed)
	if presentation_clip_audio_choice_authority != null:
		presentation_clip_audio_choice_authority.set_configured_seed(
			presentation_clip_audio_choice_seed)

	if config.title_scene != "":
		title_scene_path = config.title_scene
	else:
		title_scene_path = DEFAULT_TITLE_SCENE


func _register_handlers():
	_register_dialogue_handler()
	registry.register(ChapterIndicatorHandler.new(presentation_director))
	registry.register(BgHandler.new())
	registry.register(StageLayerHandler.new(presentation_director))
	registry.register(StageBatchHandler.new(
		presentation_director, presentation_state))
	registry.register(PresentationBatchHandler.new(
		presentation_director, presentation_state))
	registry.register(PresentationClipHandler.new(presentation_director))
	registry.register(RecollectionExitHandler.new())
	registry.register(JumpHandler.new())
	registry.register(SetHandler.new())
	registry.register(ConditionHandler.new())
	registry.register(ChoiceHandler.new(
		_begin_choice_policy_session,
		_resolve_choice_policy_session,
		_cancel_choice_policy_session,
		_is_choice_policy_session_current,
		_publish_choice_policy_session,
	))
	registry.register(SeHandler.new())
	registry.register(VoiceHandler.new())
	registry.register(FadeHandler.new())
	_register_wait_handler()
	registry.register(EffectHandler.new())
	registry.register(CallHandler.new())
	var parallel_handler = ParallelHandler.new()
	parallel_handler.set_registry(registry)
	registry.register(parallel_handler)


## Register a fresh handler when the composition root replaces read history.
func _register_dialogue_handler() -> void:
	registry.register(DialogueHandler.new(read_flags))


## Register a fresh handler against the current Runtime-owned Skip lifecycle.
func _register_wait_handler() -> void:
	registry.register(WaitHandler.new(
		skip_controller,
		Callable(presentation_director,
			"current_skip_activation_was_claimed_by_presentation"),
	))


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

	var navigation := _begin_navigation("start_game", true)
	if not _owns_navigation(navigation):
		return
	if not await _enter_scene_and_confirm(
		destination,
		navigation,
		"game",
	):
		_finish_navigation(navigation)
		return
	if not _owns_navigation(navigation):
		return
	if not _cancel_active_gameplay(navigation):
		return
	_close_current_overlay()
	if not _owns_navigation(navigation):
		return
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation(navigation):
		return
	if not _start_preparsed_scenario(scenario_data, scenario_path, navigation):
		return
	_finish_navigation(navigation)


## Start one scenario in recollection/gallery playback. The explicit caller
## continuation must be a valid zero-argument Callable and must outlive any
## scene replaced by this entry. It is never serialized.
func start_recollection(
	scenario_path: String,
	return_continuation: Callable,
	game_scene_path: String = "",
) -> bool:
	if scenario_path.is_empty():
		push_error(
			"StellaRuntime: recollection scenario path is missing at <entry>")
		return false
	if not ScenarioPlaybackContext.continuation_is_valid(return_continuation):
		push_error(
			"StellaRuntime: recollection return continuation must be a valid zero-argument Callable at %s:entry"
			% scenario_path)
		return false
	if game_scene_path.is_empty():
		game_scene_path = _get_game_scene_path()
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var destination := _load_navigation_scene(game_scene_path, "recollection game")
	if destination.is_empty():
		return false
	var playback := ScenarioPlaybackContext.recollection(return_continuation)
	var navigation := _begin_navigation("start_recollection", true)
	if not _owns_navigation(navigation):
		return false
	if not await _enter_scene_and_confirm(
		destination,
		navigation,
		"recollection game",
	):
		_finish_navigation(navigation)
		return false
	if not _owns_navigation(navigation):
		return false
	if not _cancel_active_gameplay(navigation):
		return false
	_close_current_overlay()
	if not _owns_navigation(navigation):
		return false
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation(navigation):
		return false
	if not _start_preparsed_scenario(
		scenario_data,
		scenario_path,
		navigation,
		playback,
	):
		return false
	_finish_navigation(navigation)
	return true


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
	var movie_restore_ticket := _prepare_movie_restore_from_save(save_data)
	if movie_restore_ticket <= 0:
		return false
	var destination := _load_navigation_scene(game_scene_path, "game")
	if destination.is_empty():
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	var navigation := _begin_navigation("load_game", true)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not await _enter_scene_and_confirm(
		destination,
		navigation,
		"game",
	):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_finish_navigation(navigation)
		return false
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _cancel_active_gameplay(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_close_current_overlay()
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _load_preparsed_scenario_and_restore(
		scenario_data, scenario_path, save_data, navigation, movie_restore_ticket):
		return false
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
	var movie_restore_ticket := _prepare_movie_restore_from_save(save_data)
	if movie_restore_ticket <= 0:
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
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
	var navigation := _begin_navigation("continue_from_save", needs_game_scene)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	if needs_game_scene:
		# From title screen: switch to game scene first.
		# Close overlay after the confirmed scene change so its UI remains alive
		# while an invoked load transaction is pending.
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_discard_prepared_movie_restore(movie_restore_ticket)
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _cancel_active_gameplay(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_close_current_overlay()
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
			navigation,
			movie_restore_ticket,
		):
			return false
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	if not _cancel_active_gameplay(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_close_current_overlay()
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _load_preparsed_scenario_and_restore(
		scenario_data, scenario_path, save_data, navigation, movie_restore_ticket):
		return false
	_finish_navigation(navigation)
	return true


func _prepare_movie_restore_from_save(save_data: Dictionary) -> int:
	var raw_presentation: Variant = save_data.get("presentation_state", {})
	if not raw_presentation is Dictionary:
		return 0
	return _prepare_movie_restore_from_presentation(raw_presentation as Dictionary)


func _prepare_movie_restore_from_presentation(snapshot: Dictionary) -> int:
	if not snapshot.has("movie"):
		push_error("StellaRuntime: current presentation snapshot is missing movie state")
		return 0
	var state: Variant = snapshot["movie"]
	if not MovieChannelState.validate_snapshot_state(state, false):
		push_error("StellaRuntime: invalid movie restore state")
		return 0
	if movie_presenter == null or not is_instance_valid(movie_presenter):
		push_error("StellaRuntime: MoviePresenter is unavailable for restore preflight")
		return 0
	var ticket := movie_presenter.prepare_restore_state(
		(state as Dictionary).duplicate(true))
	if ticket <= 0:
		push_error(
			"StellaRuntime: movie resource changed or cannot satisfy saved playback state")
		return 0
	return ticket


func _arm_prepared_movie_restore(ticket: int, state: Dictionary) -> bool:
	if ticket <= 0 or movie_presenter == null or not is_instance_valid(movie_presenter):
		return false
	if state.is_empty():
		return movie_presenter.discard_restore_state(ticket)
	return movie_presenter.arm_restore_state(ticket, state)


func _discard_prepared_movie_restore(ticket: int) -> void:
	if (
		ticket > 0
		and movie_presenter != null
		and is_instance_valid(movie_presenter)
	):
		movie_presenter.discard_restore_state(ticket)


func _adopt_restored_movie(context: ScenarioContext) -> bool:
	if presentation_state == null or presentation_state.current_movie.is_empty():
		return true
	if context == null or not context.is_runtime_owner_current():
		return false
	if presentation_director.has_active_movie_owner(context):
		return true
	var state := presentation_state.current_movie
	var payload := {
		"action": "play",
		"asset": String(state["asset"]),
		"loop": bool(state["loop"]),
		"skippable": bool(state["skippable"]),
	}
	var source := {
		"source_path": (
			context.scenario_data.source_path
			if context.scenario_data != null else ""),
		"scenario_id": (
			context.scenario_data.id if context.scenario_data != null else ""),
		"line": 0,
	}
	var request := presentation_director.submit(
		[MoviePresentationOperation.new(payload, source)],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context,
		source,
	)
	return (
		request != null
		and request.is_settled()
		and request.get_outcome() == PresentationBatchRequest.Outcome.COMPLETED
	)


## Begin one Runtime-owned navigation transaction. A later facade call always
## supersedes the previous owner; suspended continuations must verify this
## generation before mutating scenes, engine state, or configuration.
func _begin_navigation(kind: String, defer_scene_ownership: bool = false) -> int:
	# A deferred scene navigation may be started synchronously by the reset of an
	# older pre-submit navigation. Transfer that exact same-context suspension so
	# a rejected nested SceneTree call can CAS-resume the original run generation;
	# re-suspending an already suspended generation would strand its coroutine.
	var transfer_suspension := (
		defer_scene_ownership
		and _navigation_run_suspension != null
		and not _navigation_run_suspension_retired
		and engine != null
		and engine.context == _navigation_run_suspension_context
	)
	var inherit_retired_run := (
		defer_scene_ownership
		and _navigation_run_suspension != null
		and _navigation_run_suspension_retired
		and engine != null
		and engine.context == _navigation_run_suspension_context
	)
	var inherited_retired_context := _navigation_run_suspension_context
	# Claim the public facade generation before any discard can retire an old
	# execution session and synchronously call back into Runtime. A navigation
	# started from that cancellation signal is newer and must remain the winner.
	_navigation_generation += 1
	var navigation := _navigation_generation
	_navigation_kind = kind
	if not transfer_suspension and not inherit_retired_run:
		_discard_navigation_run_suspension()
		if not _owns_navigation(navigation):
			return navigation
	_navigation_recovery_wait_generation = 0
	_navigation_projection_committed = false
	_navigation_runtime_ownership_generation = (
		navigation if (transfer_suspension or inherit_retired_run) else 0)
	_navigation_presentation_reset_generation = 0
	if transfer_suspension:
		_navigation_run_suspension_generation = navigation
	elif inherit_retired_run:
		# The predecessor already submitted its SceneTree handoff. Transfer the
		# exact retired capability so the newest owner can reactivate this Context
		# only after the accepted slot settles; never revive the old coroutine.
		_navigation_run_suspension_generation = navigation
		_navigation_run_suspension_context = inherited_retired_context
	_navigation_run_requires_fresh_dispatch = (
		_navigation_run_requires_fresh_dispatch
		if (transfer_suspension or inherit_retired_run)
		else false
	)
	_navigation_retired_run_context = (
		inherited_retired_context
		if (transfer_suspension or inherit_retired_run)
		else null
	)
	if kind != "return_to_title":
		_return_to_title_pending = false
	if not defer_scene_ownership:
		_acquire_navigation_runtime_ownership(navigation, true)
	return navigation


## Retire execution before any presentation cancellation can wake a blocking
## Handler. Scene-changing transactions use a reversible suspension before the
## SceneTree call because that call may synchronously remove the outgoing scene.
func _acquire_navigation_runtime_ownership(
	navigation: int,
	reset_presentation: bool,
	reversible: bool = false,
) -> bool:
	if not _owns_navigation(navigation):
		return false
	if not _navigation_suspension_context_is_current(navigation):
		_retire_navigation_business_owner_after_context_replacement(navigation)
		return false
	var expected_context := engine.context if engine != null else null
	if _navigation_runtime_ownership_generation != navigation:
		if reversible and expected_context != null:
			var suspension := engine.suspend_current_run()
			if suspension == null:
				return false
			_navigation_run_suspension = suspension
			_navigation_run_suspension_generation = navigation
			_navigation_run_suspension_context = expected_context
			_navigation_run_suspension_retired = false
			_navigation_blocking_presentation_waiter_cancelled = false
		elif engine != null and expected_context != null:
			engine.invalidate_current_run()
		_navigation_runtime_ownership_generation = navigation
	if not _owns_navigation(navigation):
		return false
	if not reset_presentation:
		return true
	var projection_was_already_reset := (
		_navigation_presentation_reset_generation == navigation)
	_navigation_presentation_reset_generation = navigation
	# Publish the cancellation fact to the transferable suspension record before
	# reset emits. A nested deferred navigation may synchronously fail and recover
	# inside that signal; it must fresh-run rather than revive any cancelled
	# blocking presentation Handler.
	var suspended_context := _navigation_run_suspension_context
	if reversible and presentation_state != null and not projection_was_already_reset:
		presentation_state.current_movie = SignalBus.capture_movie_state()
	var had_blocking_waiter := (
		presentation_director != null
		and presentation_director.has_blocking_waiter(suspended_context)
	)
	if _navigation_run_suspension_generation == navigation:
		_navigation_blocking_presentation_waiter_cancelled = (
			_navigation_blocking_presentation_waiter_cancelled
			or had_blocking_waiter
		)
	var cancelled_blocking_waiter := (
		presentation_director.cancel_blocking_waiters(
			suspended_context,
			reversible,
		)
		if presentation_director != null
		else false
	)
	if _navigation_run_suspension_generation == navigation:
		_navigation_blocking_presentation_waiter_cancelled = (
			_navigation_blocking_presentation_waiter_cancelled
			or cancelled_blocking_waiter
		)
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return false
	SignalBus.reset_stage_visuals()
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return false
	SignalBus.reset_presentation_clip()
	SignalBus.reset_movie_presentation(reversible)
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return false
	SignalBus.reset_chapter_indicator_presentation()
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return false
	# Navigation may still be rejected after this provisional reset. Preserve the
	# physical cursors so the retained canonical projection can be restored, then
	# retire every old AudioPresenter tween/receipt under the same lifecycle.
	if presentation_state != null:
		presentation_state.loop_se_channels = LoopSeChannelState.with_positions(
			presentation_state.loop_se_channels,
			SignalBus.capture_loop_se_positions(),
		)
	SignalBus.reset_loop_se_presentation()
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return false
	return true


func _navigation_reset_owner_survived(
	navigation: int,
	expected_context: ScenarioContext,
) -> bool:
	if _owns_navigation_context(navigation, expected_context):
		return true
	_discard_navigation_run_suspension(navigation)
	if (
		_owns_navigation(navigation)
		and (engine.context if engine != null else null) != expected_context
	):
		_retire_navigation_business_owner_after_context_replacement(navigation)
	return false


func _discard_navigation_run_suspension(navigation: int = -1) -> bool:
	if (
		navigation >= 0
		and _navigation_run_suspension_generation != navigation
	):
		return false
	var suspension := _navigation_run_suspension
	var suspension_generation := _navigation_run_suspension_generation
	var suspension_context := _navigation_run_suspension_context
	var suspension_was_retired := _navigation_run_suspension_retired
	var previously_required_fresh := _navigation_run_requires_fresh_dispatch
	var previous_retired_context := _navigation_retired_run_context
	if suspension != null:
		if engine == null:
			return false
		# Publish retirement to a nested deferred navigation before the engine's
		# session-scoped cancellation signal can reenter this composition root.
		if not suspension_was_retired:
			_navigation_run_suspension_retired = true
			_navigation_run_requires_fresh_dispatch = (
				suspension_context != null
				and not suspension_context.is_finished
			)
			_navigation_retired_run_context = (
				suspension_context
				if _navigation_run_requires_fresh_dispatch
				else null
			)
		var discarded := (
			engine.discard_retired_run(suspension)
			if suspension_was_retired
			else engine.discard_suspended_run(suspension)
		)
		if not discarded:
			# A reentrant owner may have transferred or consumed the capability. Do
			# not revert/clear its record; only an unchanged owner treats CAS failure
			# as a hard failure.
			if (
				_navigation_run_suspension != suspension
				or _navigation_run_suspension_generation != suspension_generation
				or _navigation_run_suspension_context != suspension_context
			):
				return true
			_navigation_run_suspension_retired = suspension_was_retired
			_navigation_run_requires_fresh_dispatch = previously_required_fresh
			_navigation_retired_run_context = previous_retired_context
			if engine.context == suspension_context:
				return false
	if (
		_navigation_run_suspension == suspension
		and _navigation_run_suspension_generation == suspension_generation
		and _navigation_run_suspension_context == suspension_context
	):
		_clear_navigation_run_suspension_record()
	return true


func _clear_navigation_run_suspension_record() -> void:
	_navigation_run_suspension = null
	_navigation_run_suspension_generation = 0
	_navigation_run_suspension_context = null
	_navigation_run_suspension_retired = false
	_navigation_blocking_presentation_waiter_cancelled = false


func _owns_navigation(generation: int) -> bool:
	return generation == _navigation_generation


func _owns_navigation_context(
	generation: int,
	expected_context: ScenarioContext,
) -> bool:
	return (
		_owns_navigation(generation)
		and (engine.context if engine != null else null) == expected_context
	)


func _navigation_suspension_context_is_current(navigation: int) -> bool:
	return (
		_navigation_run_suspension_generation != navigation
		or (
			(engine.context if engine != null else null)
			== _navigation_run_suspension_context
		)
	)


## Reserve the one Runtime-owned SceneTree replacement slot immediately before
## change_scene_to_packed(). The record is provisional until that API returns
## OK; nested facade calls can wait for this exact serial without inferring
## settlement from current_scene, which is already replaced during _ready().
func _open_navigation_scene_slot(
	navigation: int,
	expected_path: String,
) -> int:
	if _navigation_scene_request_pending or expected_path.is_empty():
		return 0
	_navigation_scene_slot_serial_counter += 1
	var serial := _navigation_scene_slot_serial_counter
	_navigation_scene_slot_results[serial] = {
		"settled": false,
		"success": false,
		"creator_claimed": false,
		"creator_released": false,
		"waiter_count": 0,
		"broadcasting": false,
	}
	_navigation_scene_slot_active_serial = serial
	_navigation_scene_slot_accepted = false
	_navigation_scene_slot_navigation = navigation
	_navigation_scene_slot_suspension = _navigation_run_suspension
	_navigation_scene_slot_context = _navigation_run_suspension_context
	_navigation_scene_slot_suspension_retired = (
		_navigation_run_suspension_retired)
	if _navigation_scene_slot_context == null and engine != null:
		_navigation_scene_slot_context = engine.context
	_navigation_scene_slot_run_retired = (
		_navigation_run_requires_fresh_dispatch
		and _navigation_scene_slot_context != null
		and not _navigation_scene_slot_context.is_finished
		and _navigation_scene_slot_context == _navigation_retired_run_context
	)
	_navigation_scene_request_pending = true
	_navigation_pending_scene_path = expected_path
	return serial


## A synchronous SceneTree rejection never creates an accepted receipt. Release
## only that provisional candidate and leave the navigation suspension intact;
## a same-transaction fallback may submit another candidate before the caller's
## final _finish_navigation() performs exactly one recovery.
func _abort_navigation_scene_slot(serial: int) -> bool:
	if (
		serial <= 0
		or serial != _navigation_scene_slot_active_serial
		or _navigation_scene_slot_accepted
	):
		return false
	_settle_navigation_scene_slot(serial, false)
	_release_navigation_scene_receipt_creator(serial)
	return true


## Seal an accepted SceneTree handoff. This permanently retires the captured
## run token even when a synchronous teardown callback already transferred the
## business navigation generation to a newer facade call.
func _accept_navigation_scene_slot(serial: int) -> bool:
	if (
		serial <= 0
		or serial != _navigation_scene_slot_active_serial
		or _navigation_scene_slot_accepted
	):
		return false
	_navigation_scene_slot_accepted = true
	var expected_context := _navigation_scene_slot_context
	if not _commit_navigation_scene_handoff(serial):
		# SceneTree has already accepted this exact slot. A failed execution-token
		# seal is therefore an owner-loss terminal, not a candidate rejection that
		# configured-title fallback may retry under the same business generation.
		_retire_navigation_business_owner_after_context_replacement(
			_navigation_scene_slot_navigation)
		return false
	# Session retirement can synchronously install a fresh Context without
	# changing this older caller's local slot serial. The SceneTree receipt stays
	# accepted, but the stale business tail must not cancel or replace that owner.
	if (engine.context if engine != null else null) != expected_context:
		_retire_navigation_business_owner_after_context_replacement(
			_navigation_scene_slot_navigation)
		return false
	return true


func _retire_navigation_business_owner_after_context_replacement(
	stale_navigation: int,
) -> void:
	# A nested Runtime facade already owns its newer generation and performs its
	# own cleanup. Only direct engine Context replacement needs an anonymous
	# generation bump so configured-title fallback and other outer caller tails
	# fail their ordinary _owns_navigation() guards immediately.
	if _navigation_generation != stale_navigation:
		return
	_navigation_generation += 1
	_navigation_kind = ""
	_return_to_title_pending = false
	_navigation_projection_committed = false
	_navigation_runtime_ownership_generation = 0
	_navigation_presentation_reset_generation = 0
	_clear_navigation_run_suspension_record()
	_navigation_run_requires_fresh_dispatch = false
	_navigation_retired_run_context = null
	_navigation_recovery_wait_generation = 0
	_navigation_recovery_wait_slot_serial = 0


func _commit_navigation_scene_handoff(serial: int) -> bool:
	if serial != _navigation_scene_slot_active_serial:
		return false
	var retained_context := _navigation_scene_slot_context
	var suspension := _navigation_scene_slot_suspension
	var suspension_was_retired := (
		_navigation_scene_slot_suspension_retired)
	var runtime_record_matches := (
		_navigation_run_suspension_context == retained_context
		and (
			(
				suspension != null
				and _navigation_run_suspension == suspension
			)
			or (
				suspension == null
				and _navigation_run_suspension == null
				and _navigation_run_suspension_generation > 0
			)
		)
	)
	if suspension != null:
		# Mark Runtime's transferable record before the engine emits the
		# session-scoped cancellation. A synchronous listener that starts a newer
		# deferred navigation must inherit the retired capability, not treat it as
		# a resumable pre-submit pause.
		if runtime_record_matches and not suspension_was_retired:
			_navigation_run_suspension_retired = true
		if (
			engine == null
			or (
				not suspension_was_retired
				and not engine.discard_suspended_run(suspension)
			)
		):
			if runtime_record_matches:
				_navigation_run_suspension_retired = suspension_was_retired
			# A nested context replacement can legitimately retire the old token
			# first. It owns recovery from that point; never overwrite its state.
			if engine == null or engine.context == retained_context:
				return false
		suspension_was_retired = true
	_navigation_scene_slot_suspension_retired = suspension_was_retired
	# discard_suspended_run() retires the old execution session and emits its
	# scoped cancellation synchronously. Recheck every owner after that public
	# boundary before publishing a transferable Runtime record; a nested context
	# replacement has already invalidated this slot capability.
	runtime_record_matches = (
		engine != null
		and engine.context == retained_context
		and _navigation_run_suspension == suspension
		and _navigation_run_suspension_context == retained_context
	)
	_navigation_scene_slot_run_retired = (
		retained_context != null
		and not retained_context.is_finished
		and engine != null
		and engine.context == retained_context
	)
	if runtime_record_matches:
		_navigation_run_suspension = suspension
		_navigation_run_suspension_generation = _navigation_generation
		_navigation_run_suspension_context = retained_context
		_navigation_run_suspension_retired = suspension_was_retired
	if (
		_navigation_scene_slot_run_retired
		and engine != null
		and engine.context == retained_context
	):
		_navigation_run_requires_fresh_dispatch = true
		_navigation_retired_run_context = retained_context
	elif runtime_record_matches and retained_context != null:
		# Finished Contexts still retain the exact capability so a failed latest
		# navigation can reactivate canonical ownership and cut-project metadata,
		# but they must never start a second scenario lifecycle.
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = retained_context
	elif runtime_record_matches:
		_clear_navigation_run_suspension_record()
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = null
	return true


## Accepted slots are released only by _on_navigation_scene_changed(). The
## synchronous-error path above is the sole exception because it never became
## an accepted SceneTree receipt. State is marked settled before listeners wake.
func _settle_navigation_scene_slot(serial: int, success: bool) -> void:
	if serial != _navigation_scene_slot_active_serial:
		return
	var receipt_value: Variant = _navigation_scene_slot_results.get(serial)
	if not receipt_value is Dictionary:
		return
	var receipt: Dictionary = receipt_value
	if bool(receipt.get("settled", false)):
		return
	receipt["settled"] = true
	receipt["success"] = success
	_navigation_scene_slot_active_serial = 0
	_navigation_scene_slot_accepted = false
	_navigation_scene_slot_navigation = 0
	_navigation_scene_slot_suspension = null
	_navigation_scene_slot_context = null
	_navigation_scene_slot_suspension_retired = false
	_navigation_scene_slot_run_retired = false
	_navigation_scene_request_pending = false
	_navigation_pending_scene_path = ""
	receipt["broadcasting"] = true
	_navigation_scene_slot_settled.emit()
	receipt["broadcasting"] = false
	_cleanup_navigation_scene_receipt(serial, receipt)


func _on_navigation_scene_changed() -> void:
	if (
		not _navigation_scene_request_pending
		or not _navigation_scene_slot_accepted
		or _navigation_scene_slot_active_serial <= 0
	):
		return
	var serial := _navigation_scene_slot_active_serial
	var expected_path := _navigation_pending_scene_path
	var current_scene := get_tree().current_scene
	var succeeded := (
		current_scene != null
		and current_scene.scene_file_path.simplify_path() == expected_path
	)
	_settle_navigation_scene_slot(serial, succeeded)


func _await_navigation_scene_receipt(
	serial: int,
	consume_creator_reservation: bool = false,
) -> bool:
	if serial <= 0 or not _navigation_scene_slot_results.has(serial):
		return false
	var receipt_value: Variant = _navigation_scene_slot_results.get(serial)
	if not receipt_value is Dictionary:
		return false
	var receipt: Dictionary = receipt_value
	# Only the unique creator reservation may read a receipt that settled before
	# its caller reached await. Every other consumer must have registered a lease
	# while the receipt was still pending; unknown/expired serials fail closed.
	if consume_creator_reservation:
		if (
			bool(receipt.get("creator_released", false))
			or bool(receipt.get("creator_claimed", false))
		):
			return false
		receipt["creator_claimed"] = true
	elif bool(receipt.get("settled", false)):
		return false
	receipt["waiter_count"] = int(receipt.get("waiter_count", 0)) + 1
	while not bool(receipt.get("settled", false)):
		await _navigation_scene_slot_settled
	var success := bool(receipt.get("success", false))
	receipt["waiter_count"] = maxi(
		int(receipt.get("waiter_count", 0)) - 1, 0)
	if consume_creator_reservation:
		receipt["creator_released"] = true
	_cleanup_navigation_scene_receipt(serial, receipt)
	return success


func _release_navigation_scene_receipt_creator(serial: int) -> bool:
	var receipt_value: Variant = _navigation_scene_slot_results.get(serial)
	if not receipt_value is Dictionary:
		return false
	var receipt: Dictionary = receipt_value
	if bool(receipt.get("creator_released", false)):
		return false
	receipt["creator_released"] = true
	_cleanup_navigation_scene_receipt(serial, receipt)
	return true


func _cleanup_navigation_scene_receipt(
	serial: int,
	receipt: Dictionary,
) -> void:
	if (
		bool(receipt.get("settled", false))
		and bool(receipt.get("creator_released", false))
		and int(receipt.get("waiter_count", 0)) == 0
		and not bool(receipt.get("broadcasting", false))
		and _navigation_scene_slot_results.get(serial) == receipt
	):
		_navigation_scene_slot_results.erase(serial)


func _finish_navigation(generation: int) -> void:
	if not _owns_navigation(generation):
		return
	# A nested deferred navigation can adopt the base suspension and then fail
	# during destination resolution, before it submits any SceneTree request.
	# Recover that original run exactly as a synchronous scene-call rejection;
	# accepted requests already discarded the token and never enter this branch.
	if (
		_navigation_run_suspension_generation == generation
		and not _navigation_projection_committed
	):
		if _navigation_scene_request_pending:
			if _navigation_recovery_wait_generation != generation:
				_navigation_recovery_wait_generation = generation
				_navigation_recovery_wait_slot_serial = (
					_navigation_scene_slot_active_serial)
				_finish_navigation_after_scene_slot(
					generation,
					_navigation_recovery_wait_slot_serial,
				)
			return
		if (
			engine != null
			and engine.context != _navigation_run_suspension_context
		):
			# Session-retirement listeners may install an exact fresh Context without
			# entering another Runtime facade. Its setter already invalidated the old
			# engine token; after the accepted slot settles, drop only the stale
			# Runtime record and never reproject/cancel that fresh semantic owner.
			_clear_navigation_run_suspension_record()
			_navigation_run_requires_fresh_dispatch = false
			_navigation_retired_run_context = null
			_navigation_projection_committed = true
		elif not _recover_rejected_scene_navigation(generation):
			if _owns_navigation(generation):
				push_error(
					"StellaRuntime: rejected navigation could not restore its "
					+ "suspended scenario owner"
				)
			return
		if not _owns_navigation(generation):
			return
	_discard_navigation_run_suspension(generation)
	var restore_retained_projection := not _navigation_projection_committed
	var presentation_was_reset := (
		_navigation_presentation_reset_generation == generation)
	_navigation_kind = ""
	_return_to_title_pending = false
	_navigation_projection_committed = false
	_navigation_runtime_ownership_generation = 0
	_navigation_presentation_reset_generation = 0
	_navigation_run_requires_fresh_dispatch = false
	_navigation_retired_run_context = null
	_navigation_recovery_wait_generation = 0
	_navigation_recovery_wait_slot_serial = 0
	# Failed navigation keeps the old context and restores the visual reset.
	# Successful flows already projected before engine.run(); reapplying here
	# could cancel the first command's in-flight fade.
	if restore_retained_projection and presentation_was_reset:
		SignalBus.reset_and_apply_loop_se_state(
			presentation_state.loop_se_channels
			if presentation_state != null
			else {}
		)
		var restored_movie := SignalBus.reset_and_apply_movie_state(
			presentation_state.current_movie
			if presentation_state != null
			else {}
		)
		if restored_movie:
			_adopt_restored_movie(engine.context if engine != null else null)
		else:
			push_error(
				"StellaRuntime: rejected navigation movie recovery apply failed")
		_apply_chapter_presentation(engine.context if engine != null else null)
	elif presentation_was_reset:
		# Winning navigation never consumes the reversible physical recovery lease.
		# Release it at the transaction commit boundary so a long movie resource is
		# not pinned after title/new-game replacement.
		SignalBus.discard_movie_recovery_state()


func _finish_navigation_after_scene_slot(
	generation: int,
	slot_serial: int,
) -> void:
	await _await_navigation_scene_receipt(slot_serial)
	if (
		not _owns_navigation(generation)
		or _navigation_recovery_wait_generation != generation
		or _navigation_recovery_wait_slot_serial != slot_serial
	):
		return
	_navigation_recovery_wait_generation = 0
	_navigation_recovery_wait_slot_serial = 0
	_finish_navigation(generation)


## Detach before aborting so a suspended old ScenarioEngine.run() observes its
## context-generation guard and cannot emit scenario_ended into the new owner.
func _cancel_active_gameplay(navigation: int = -1) -> bool:
	if navigation < 0:
		navigation = _navigation_generation
	if not _owns_navigation(navigation):
		return false
	if engine == null or engine.context == null:
		return true
	if _navigation_kind != "recollection_return":
		_cancel_recollection_for_replacement(engine.context)
	var retired_abort_connections := _capture_engine_abort_connections()
	var retired_choice_session := _begin_choice_hard_boundary()
	engine.cancel_current_run()
	# Normal cancellation deliberately detaches the old Context. Every following
	# public abort callback is a reentrant boundary: if it installs a fresh
	# owner, this retired caller must stop before any later mutation.
	if not _owns_navigation(navigation) or engine.context != null:
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	_notify_retired_engine_abort_connections(retired_abort_connections)
	if not _owns_navigation(navigation) or engine.context != null:
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	_finish_choice_hard_boundary(true)
	return _owns_navigation(navigation) and engine.context == null


func _cancel_recollection_for_replacement(
	expected_context: ScenarioContext,
) -> void:
	if (
		expected_context == null
		or expected_context != _active_recollection_context
		or _active_recollection_playback == null
	):
		return
	_active_recollection_playback.cancel()
	_active_recollection_playback = null
	_active_recollection_context = null


func _recollection_source_location(
	context: ScenarioContext,
	line_override: int = -1,
) -> String:
	var source_path := "<programmatic-scenario>"
	if (
		context != null
		and context.scenario_data != null
		and not context.scenario_data.source_path.is_empty()
	):
		source_path = context.scenario_data.source_path
	var line := line_override
	if line < 0 and context != null:
		line = context.recollection_exit_line
	if line > 0:
		return "%s:%d" % [source_path, line]
	return "%s:end" % source_path


func _is_recollection_context_active() -> bool:
	return (
		engine != null
		and engine.context != null
		and engine.context.is_recollection_playback()
	)


## True only while the current ScenarioContext was entered through the public
## recollection facade. A context whose caller was superseded remains a
## recollection context until its winning replacement detaches it, so save and
## rollback stay fail-closed during that handoff.
func is_recollection_playing() -> bool:
	return (
		_is_recollection_context_active()
		and engine.context == _active_recollection_context
		and _active_recollection_playback != null
	)


## User-owned early return. Natural scenario exhaustion and the DSL command
## call the same exact-once implementation from _on_scenario_ended().
func return_from_recollection() -> bool:
	if not is_recollection_playing():
		return false
	var context := _active_recollection_context
	var line := 0
	var command := context.current_command() if context != null else null
	if command != null:
		line = command.declared_line
	return _complete_recollection_return(context, line)


func _complete_recollection_return(
	context: ScenarioContext,
	line_override: int = -1,
) -> bool:
	if (
		context == null
		or context != _active_recollection_context
		or _active_recollection_playback == null
		or context.playback_context != _active_recollection_playback
	):
		return false
	var playback := _active_recollection_playback
	var location := _recollection_source_location(context, line_override)
	if not playback.try_begin_return():
		return false

	# No project callback runs until this exact Runtime generation has retired
	# Core and all live presentation owners. Any synchronous cleanup reentry that
	# installs a newer navigation cancels this continuation without touching it.
	var navigation := _begin_navigation("recollection_return", true)
	if not _owns_navigation(navigation):
		playback.cancel()
		return false
	if not _acquire_navigation_runtime_ownership(navigation, false):
		playback.cancel()
		return false
	if not _cancel_active_gameplay(navigation):
		playback.cancel()
		if _active_recollection_playback == playback:
			_active_recollection_playback = null
			_active_recollection_context = null
		push_error(
			"StellaRuntime: recollection return cleanup lost ownership at %s"
			% location)
		return false
	if not presentation_clip_audio_choice_authority.clear_to_unstarted():
		playback.cancel()
		if _active_recollection_playback == playback:
			_active_recollection_playback = null
			_active_recollection_context = null
		push_error(
			"StellaRuntime: recollection audio-choice cleanup failed at %s"
			% location)
		return false
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	_close_current_overlay()
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	SignalBus.reset_loop_se_presentation()
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	if not _reset_presentation(navigation, null, true):
		playback.cancel()
		if _active_recollection_playback == playback:
			_active_recollection_playback = null
			_active_recollection_context = null
		push_error(
			"StellaRuntime: recollection presentation cleanup failed at %s"
			% location)
		return false
	backlog_manager.clear()
	choice_history_manager.clear()
	auto_play.stop()
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	skip_controller.stop()
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	game_state.transition_to(GameStateMachine.State.PAUSED)
	if not _owns_navigation_context(navigation, null):
		playback.cancel()
		return false
	_active_recollection_playback = null
	_active_recollection_context = null
	_navigation_projection_committed = true
	_finish_navigation(navigation)

	# The target can become invalid after a valid entry (for example because its
	# owner scene was freed). Cleanup above still completed deterministically;
	# fail closed here without invoking any other destination.
	if not playback.complete_return():
		push_error(
			"StellaRuntime: recollection return continuation is no longer valid at %s"
			% location)
		return false
	return true


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
	# SceneTree can synchronously remove the outgoing scene before this call
	# returns. Suspend execution and cancel its exact indicator barrier first so
	# scene-owned Presenter exit callbacks can never resume the old run.
	if not _acquire_navigation_runtime_ownership(navigation, true, true):
		return false
	# No extension-visible boundary exists between this provisional receipt and
	# the SceneTree call. A reentrant teardown callback waits for its exact serial
	# even though current_scene may already be the destination during _ready().
	var slot_serial := _open_navigation_scene_slot(
		navigation,
		expected_path,
	)
	if slot_serial <= 0:
		return false
	var slot_context := _navigation_scene_slot_context
	var scene_error := _request_navigation_scene_change(scene)
	if scene_error != OK:
		_abort_navigation_scene_slot(slot_serial)
		if _owns_navigation(navigation):
			push_error(
				"StellaRuntime: failed to request the %s scene (%s)"
				% [description, error_string(scene_error)]
			)
		# Candidate rejection is not the transaction boundary. A configured title
		# candidate may retry the built-in scene under the same exact suspension;
		# single-candidate callers funnel through _finish_navigation() instead.
		return false
	# An accepted handoff permanently retires the suspended old coroutine. The
	# Context itself stays available for autosave until the winning transaction
	# installs/detaches its replacement after scene confirmation.
	if not _accept_navigation_scene_slot(slot_serial):
		_release_navigation_scene_receipt_creator(slot_serial)
		return false
	if not _owns_navigation(navigation):
		_release_navigation_scene_receipt_creator(slot_serial)
		return false
	var entered_expected_scene := await _await_navigation_scene_receipt(
		slot_serial, true)
	# The destination's _ready() runs before SceneTree.scene_changed. It may
	# install a fresh semantic Context directly, without claiming a Runtime
	# navigation generation. The accepted receipt still settles centrally, but
	# this older business transaction must retire before it can cancel that owner
	# or treat the replacement as an ordinary configured-candidate rejection.
	if (engine.context if engine != null else null) != slot_context:
		_retire_navigation_business_owner_after_context_replacement(navigation)
		return false
	return _owns_navigation(navigation) and entered_expected_scene


func _request_navigation_scene_change(scene: PackedScene) -> Error:
	if _navigation_scene_change_override.is_valid():
		return int(_navigation_scene_change_override.call(scene))
	return get_tree().change_scene_to_packed(scene)


## A fully preflighted scene request can still be rejected synchronously by
## SceneTree. Restore the retained cut projection first. If reset did not wake
## a chapter Handler, compare-and-swap resumes the original waiter generation;
## otherwise that coroutine already exited and exactly one fresh run starts at
## the unchanged cursor. These two recovery paths are deliberately exclusive.
func _recover_rejected_scene_navigation(navigation: int) -> bool:
	if (
		not _owns_navigation(navigation)
		or _navigation_run_suspension_generation != navigation
	):
		return false
	var retained_context := _navigation_run_suspension_context
	var suspension := _navigation_run_suspension
	var suspension_is_retired := _navigation_run_suspension_retired
	var requires_fresh_dispatch := (
		_navigation_blocking_presentation_waiter_cancelled
		or _navigation_run_requires_fresh_dispatch
	)
	if not _owns_navigation_context(navigation, retained_context):
		_discard_navigation_run_suspension(navigation)
		return false
	if retained_context == null:
		_clear_navigation_run_suspension_record()
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = null
		if not _apply_retained_presentation(null):
			return false
		_navigation_projection_committed = true
		return true

	# A synchronous rejection that never retired/woke the old execution session
	# must CAS-resume it before any public projection callback. Otherwise an
	# adversarial advance/select listener could finish the paused waiter while its
	# owner is false, after which restoring only the generation would strand it.
	if not requires_fresh_dispatch and not suspension_is_retired:
		if suspension == null or not engine.resume_suspended_run(suspension):
			return false
		_clear_navigation_run_suspension_record()
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = null
		if not _apply_retained_presentation(retained_context):
			# Metadata listeners may legitimately complete the restored waiter. The
			# exact cursor guard then rejects this outer projection tail while the
			# same navigation/context continues under its next semantic owner; that is
			# successful recovery, not a failed CAS or a reason to reproject stale UI.
			if _owns_navigation_context(navigation, retained_context):
				_navigation_projection_committed = true
				return true
			return false
		if not _owns_navigation_context(navigation, retained_context):
			return false
		_navigation_projection_committed = true
		return true

	# Retired/fresh recovery deliberately projects while Context execution is
	# still revoked. Same-stack compatibility listeners therefore cannot consume
	# the fresh owner; exact reactivation and one new run happen only afterward.
	if not _apply_retained_presentation(retained_context):
		return false
	if not _owns_navigation_context(navigation, retained_context):
		return false
	if retained_context.is_finished:
		# A completed Context has no semantic run to recreate. Restore exact
		# canonical ownership (when an accepted handoff retired it), keep the cut
		# projection above, and deliberately emit no scenario lifecycle signals.
		if suspension != null:
			var restored_finished_owner := (
				engine.reactivate_retired_run(suspension)
				if suspension_is_retired
				else engine.resume_suspended_run(suspension)
			)
			if not restored_finished_owner:
				return false
		_clear_navigation_run_suspension_record()
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = null
		_navigation_projection_committed = true
		return true
	if requires_fresh_dispatch:
		if suspension == null:
			return false
		if not suspension_is_retired:
			if not engine.discard_suspended_run(suspension):
				return false
			_navigation_run_suspension_retired = true
		if not engine.reactivate_retired_run(suspension):
			return false
		_clear_navigation_run_suspension_record()
		_navigation_run_requires_fresh_dispatch = false
		_navigation_retired_run_context = null
		engine.run()
		if not _owns_navigation_context(navigation, retained_context):
			return false
		_navigation_projection_committed = true
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
		if not _navigation_suspension_context_is_current(navigation):
			_retire_navigation_business_owner_after_context_replacement(
				navigation)
			return false
		return true
	var slot_serial := _navigation_scene_slot_active_serial
	await _await_navigation_scene_receipt(slot_serial)
	if not _owns_navigation(navigation):
		return false
	if not _navigation_suspension_context_is_current(navigation):
		_retire_navigation_business_owner_after_context_replacement(navigation)
		return false
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
			if (
				node_native_type == &""
				or not ClassDB.class_exists(node_native_type)
				or not ClassDB.is_parent_class(node_native_type, &"Node")
			):
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
			result["./" + override_path.substr(child_prefix.length())] = (
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
	var target_path := String(state.get_node_path(node_index))
	var owning_scene: PackedScene = null
	var owning_path := ""
	# An editable child override of an ordinary nested PackedScene is serialized
	# as a property-only entry in the outer scene. Resolve it relative to the
	# nearest owning instance, not relative to node 0 (which is the ordinary
	# outer root in this case).
	for candidate_index in state.get_node_count():
		var candidate_scene := state.get_node_instance(candidate_index)
		if candidate_scene == null:
			continue
		var candidate_path := String(state.get_node_path(candidate_index))
		if (
			candidate_path == "."
			or not target_path.begins_with(candidate_path + "/")
			or candidate_path.length() <= owning_path.length()
		):
			continue
		owning_scene = candidate_scene
		owning_path = candidate_path
	if owning_scene != null:
		var relative_path := target_path.substr(owning_path.length() + 1)
		return _title_scene_node_native_type_at_path(
			owning_scene,
			NodePath("./" + relative_path),
			visited,
		)
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
	var pending: Array[Dictionary] = [{
		"path": path.simplify_path(),
		"expected_type": "PackedScene",
	}]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var current: Dictionary = pending.pop_back()
		var current_path: String = current["path"]
		var expected_type: String = current["expected_type"]
		var identity := "%s::%s" % [current_path, expected_type]
		if visited.has(identity):
			continue
		visited[identity] = true
		if not ResourceLoader.exists(current_path):
			return false
		var inspection := _text_resource_inspector.inspect(
			current_path,
			expected_type,
		)
		if not inspection.ok or not inspection.matches_expected_type:
			return false
		for dependency: Dictionary in inspection.dependencies:
			var dependency_path: String = dependency["path"]
			var declared_type: String = dependency["type"]
			if (
				dependency_path.is_empty()
				or not ResourceLoader.exists(dependency_path)
			):
				return false
			pending.append({
				"path": dependency_path,
				"expected_type": declared_type,
			})
	return true


## Compatibility bridge for focused Runtime integration tests. Production
## callers consume the inspector's typed result in the dependency traversal.
func _read_text_resource_dependencies(path: String) -> Dictionary:
	return _text_resource_inspector.inspect(path).to_dictionary()


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
	var navigation := _begin_navigation("return_to_title", true)
	if not _owns_navigation(navigation):
		return
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
	if not _cancel_active_gameplay(navigation):
		return
	if not presentation_clip_audio_choice_authority.clear_to_unstarted():
		push_error(
			"StellaRuntime: presentation-clip audio-choice transaction remained active "
			+ "after gameplay retirement")
		return
	var expected_context := engine.context if engine != null else null
	SignalBus.reset_loop_se_presentation()
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return
	presentation_state.clear()
	SignalBus.reset_and_apply_stage_state({})
	if not _navigation_reset_owner_survived(navigation, expected_context):
		return
	if not _apply_chapter_presentation(null) or not _owns_navigation(navigation):
		return
	_navigation_projection_committed = true
	_close_current_overlay()
	if not _owns_navigation(navigation):
		return
	backlog_manager.clear()
	choice_history_manager.clear()
	auto_play.stop()
	if not _owns_navigation(navigation):
		return
	skip_controller.stop()
	if not _owns_navigation(navigation):
		return
	game_state.transition_to(GameStateMachine.State.TITLE)
	if not _owns_navigation(navigation):
		return
	if config.title_bgm != "":
		_play_title_bgm()
		if not _owns_navigation(navigation):
			return
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
	var navigation := _begin_navigation("start_scenario", true)
	if not _owns_navigation(navigation):
		return
	if not await _await_navigation_scene_slot(navigation):
		return
	if not _owns_navigation(navigation):
		return
	if not _acquire_navigation_runtime_ownership(
		navigation,
		false,
		true,
	):
		return
	if not _owns_navigation(navigation):
		return
	if not _cancel_active_gameplay(navigation):
		return
	_last_scenario_path = scenario_path
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation(navigation):
		return
	if not _start_preparsed_scenario(scenario_data, scenario_path, navigation):
		return
	_finish_navigation(navigation)


func _start_scenario_internal(scenario_path: String) -> void:
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return
	_start_preparsed_scenario(
		scenario_data, scenario_path, _navigation_generation)


func _start_preparsed_scenario(
	scenario_data: ScenarioData,
	scenario_path: String,
	navigation: int,
	playback_context: ScenarioPlaybackContext = null,
) -> bool:
	if not _owns_navigation(navigation):
		return false
	if not presentation_clip_audio_choice_authority.start_fresh_run():
		push_error("StellaRuntime: presentation-clip audio-choice seed initialization failed")
		return false
	_install_scenario(scenario_data, scenario_path, playback_context)
	var expected_context := engine.context if engine != null else null
	if not _owns_navigation_context(navigation, expected_context):
		return false
	if presentation_director != null:
		presentation_director.cancel_all()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_stage_visuals()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_presentation_clip()
	SignalBus.reset_movie_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_chapter_indicator_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_loop_se_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	presentation_state.clear()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	if not _apply_chapter_presentation(expected_context):
		return false
	if not _owns_navigation_context(navigation, expected_context):
		return false
	_navigation_projection_committed = true
	engine.run()
	return _owns_navigation_context(navigation, expected_context)


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
	if not presentation_clip_audio_choice_authority.start_fresh_run():
		return false
	_install_scenario(data, scenario_path)
	return true


func _install_scenario(
	data: ScenarioData,
	scenario_path: String,
	playback_context: ScenarioPlaybackContext = null,
) -> void:
	var scenario_id := data.id

	# Invalidate semantic policy only when this call itself replaces an execution
	# owner. Normal start_scenario() already detached any prior owner and must keep
	# independently authored Auto/Skip intent so the first presentation command
	# can observe it. Controller signals and the presentation HIDE are delayed
	# until a stale handler has disconnected.
	var replaces_execution_owner := (
		(engine != null and engine.context != null)
		or is_choice_active()
	)
	var retired_abort_connections: Array[Dictionary] = []
	if replaces_execution_owner:
		retired_abort_connections = _capture_engine_abort_connections()
		_begin_choice_hard_boundary()
	engine.load_scenario(data)
	var installed_playback := (
		playback_context
		if playback_context != null
		else ScenarioPlaybackContext.story()
	)
	if not engine.context.set_playback_context(installed_playback):
		push_error(
			"StellaRuntime: invalid scenario playback context at %s:entry"
			% scenario_path)
		engine.context.request_cancellation()
	_active_recollection_playback = (
		installed_playback if installed_playback.is_recollection() else null)
	_active_recollection_context = (
		engine.context if installed_playback.is_recollection() else null)
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
		"bgm": {},
		"movie": {},
		"loop_se_channels": {},
		"dialogue_visibility": {
			"surface": true,
			"quick_menu": true,
		},
		"dialogue_content": PresentationState._inactive_dialogue_content(),
		"dialogue_avatar": DialogueAvatarState.default_state(),
	}
	flowchart_state.initial_snapshot = initial_snapshot
	# Context ownership is canonical; notify only the pre-transfer abort audience
	# without broadcasting the retired boundary to replacement handlers.
	if replaces_execution_owner:
		_notify_retired_engine_abort_connections(retired_abort_connections)
		_finish_choice_hard_boundary(true)


## Load scenario, restore snapshot, restore presentation, then run.
func _load_preparsed_scenario_and_restore(
	scenario_data: ScenarioData,
	scenario_path: String,
	save_data: Dictionary,
	navigation: int,
	movie_restore_ticket: int,
) -> bool:
	if movie_restore_ticket <= 0 or not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	var saved_choice_initial := (
		PresentationClipAudioChoiceAuthority.initial_playthrough_snapshot(
			save_data.get(PresentationClipAudioChoiceAuthority.PROVIDER_ID, {})))
	if saved_choice_initial.is_empty():
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not presentation_clip_audio_choice_authority.restore_snapshot(
		saved_choice_initial):
		push_error(
			"StellaRuntime: presentation-clip audio-choice initial checkpoint restore failed")
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_install_scenario(scenario_data, scenario_path)
	var expected_context := engine.context if engine != null else null
	if not _owns_navigation_context(navigation, expected_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	# Installing the replacement context first transfers engine ownership away
	# from an active dialogue. The following hard HIDE may abort its Presenter
	# activation, but the stale run can no longer report normal scenario_ended.
	if not _reset_presentation(navigation, expected_context, true):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not save_manager.restore_data(save_data):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	flowchart_state.initial_snapshot[
		PresentationClipAudioChoiceAuthority.PROVIDER_ID] = saved_choice_initial
	if not _owns_navigation_context(navigation, expected_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _arm_prepared_movie_restore(
		movie_restore_ticket, presentation_state.current_movie):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not presentation_state.apply_to_presenters(
		_runtime_dialogue_visibility_binding(expected_context)
	):
		return false
	if not _owns_navigation_context(navigation, expected_context):
		return false
	if not _adopt_restored_movie(expected_context):
		return false
	if not _apply_chapter_presentation(expected_context):
		return false
	if not _owns_navigation_context(navigation, expected_context):
		return false
	_navigation_projection_committed = true
	engine.run()
	return _owns_navigation_context(navigation, expected_context)


func _load_scenario_and_restore(scenario_path: String, slot_id: int) -> bool:
	var scenario_data := _parse_scenario(scenario_path)
	if scenario_data == null:
		return false
	var save_data: Variant = save_manager.read_save_data(slot_id, scenario_data)
	if save_data == null:
		return false
	var movie_restore_ticket := _prepare_movie_restore_from_save(save_data)
	if movie_restore_ticket <= 0:
		return false
	return _load_preparsed_scenario_and_restore(
		scenario_data,
		scenario_path,
		save_data,
		_navigation_generation,
		movie_restore_ticket,
	)


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


## Reset current presentation state (for in-scene reload). Every presentation
## signal is synchronously reentrant, so an older cleanup stops as soon as a
## newer navigation/context owner appears.
func _reset_presentation(
	navigation: int = -1,
	expected_context: ScenarioContext = null,
	choice_boundary_already_published: bool = false,
) -> bool:
	if navigation < 0:
		navigation = _navigation_generation
		expected_context = engine.context if engine != null else null
	if not _owns_navigation_context(navigation, expected_context):
		return false
	if (
		engine != null
		and expected_context != null
		and presentation_director != null
		and engine.context == expected_context
		and presentation_director.has_blocking_waiter(expected_context)
	):
		engine.invalidate_current_run()
	SignalBus.effect_requested.emit("off", {})
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_stage_visuals()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_presentation_clip()
	SignalBus.reset_movie_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.reset_chapter_indicator_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	presentation_state.current_bgm.clear()
	SignalBus.reset_bgm_presentation()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	SignalBus.hide_dialogue.emit()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	# A live semantic Choice must be retired only after its execution owner has
	# transferred. Callers that have not completed that boundary fail closed
	# instead of clearing sibling presentation while leaving the modal owner live.
	if not choice_boundary_already_published and is_choice_active():
		push_error(
			"StellaRuntime: presentation reset requires retired choice ownership")
		return false
	if not choice_boundary_already_published:
		SignalBus.choice_hide.emit()
		if not _owns_navigation_context(navigation, expected_context):
			return false
	presentation_state.clear()
	presentation_state.apply_to_presenters({})
	if not _owns_navigation_context(navigation, expected_context):
		return false
	if presentation_director != null:
		presentation_director.cancel_all()
	if not _owns_navigation_context(navigation, expected_context):
		return false
	presentation_state.apply_to_presenters({})
	if not _owns_navigation_context(navigation, expected_context):
		return false
	# Backlog is runtime-only state (not in save snapshots) — clear it on
	# load/restart so the previous run's history doesn't bleed into the new one.
	backlog_manager.clear()
	choice_history_manager.clear()
	return _owns_navigation_context(navigation, expected_context)


func _chapter_for_context(context: ScenarioContext) -> ChapterData:
	if context == null or context.scenario_data == null:
		return null
	var scene := context.current_scene()
	if scene == null or scene.chapter_id.is_empty():
		return null
	return context.scenario_data.get_chapter(scene.chapter_id)


func _publish_current_chapter(
	context: ScenarioContext,
	force: bool = false,
) -> void:
	var chapter := _chapter_for_context(context)
	var chapter_id := chapter.id if chapter != null else ""
	var title := ""
	if chapter != null and not chapter.display_name.is_empty():
		title = tr(chapter.display_name)
	if (
		not force
		and chapter_id == _last_published_chapter_id
		and title == _last_published_chapter_title
		and context == _last_published_chapter_context
	):
		return
	_last_published_chapter_id = chapter_id
	_last_published_chapter_title = title
	_last_published_chapter_context = context
	_last_published_chapter_navigation = _navigation_generation
	if _publishing_current_chapter:
		if chapter_id != _emitting_chapter_id or title != _emitting_chapter_title:
			_chapter_republish_pending = true
		# A nested navigation must publish its metadata before it projects state or
		# starts its first command. SignalBus's owner stack makes the suspended
		# outer tail stale; the outermost loop republishes the final value once more
		# so even compatibility listeners end on the newest metadata.
		_emit_current_chapter_owned(
			chapter_id,
			title,
			context,
			_navigation_generation,
		)
		return

	_publishing_current_chapter = true
	while true:
		_chapter_republish_pending = false
		_emitting_chapter_id = _last_published_chapter_id
		_emitting_chapter_title = _last_published_chapter_title
		var emitting_chapter_id := _emitting_chapter_id
		var emitting_chapter_title := _emitting_chapter_title
		var expected_context := _last_published_chapter_context
		var expected_navigation := _last_published_chapter_navigation
		_emit_current_chapter_owned(
			emitting_chapter_id,
			emitting_chapter_title,
			expected_context,
			expected_navigation,
		)
		if (
			_last_published_chapter_id != emitting_chapter_id
			or _last_published_chapter_title != emitting_chapter_title
		):
			_chapter_republish_pending = true
		if not _chapter_republish_pending:
			break
	_publishing_current_chapter = false


func _emit_current_chapter_owned(
	chapter_id: String,
	title: String,
	expected_context: ScenarioContext,
	expected_navigation: int,
) -> bool:
	return SignalBus.emit_current_chapter_changed(
		chapter_id,
		title,
		func() -> bool:
			return (
				expected_navigation == _navigation_generation
				and (engine.context if engine != null else null) == expected_context
				and _last_published_chapter_id == chapter_id
				and _last_published_chapter_title == title
			),
	)


func _apply_chapter_presentation(context: ScenarioContext) -> bool:
	var navigation := _navigation_generation
	var expected_context := engine.context if engine != null else null
	if context != expected_context:
		return false
	var expected_scene_index := (
		context.current_scene_index if context != null else -1)
	var expected_command_index := (
		context.current_command_index if context != null else -1)
	var expected_pending_jump := (
		context.pending_jump if context != null else "")
	var expected_finished := context.is_finished if context != null else true
	var expected_execution_owner := (
		context.is_runtime_owner_current() if context != null else false)
	_publish_current_chapter(context, true)
	# The public metadata event is synchronously reentrant. A listener may start
	# navigation or replace/detach the context; its newer projection must win.
	if (
		navigation != _navigation_generation
		or (engine.context if engine != null else null) != expected_context
		or (
			context != null
			and (
				context.current_scene_index != expected_scene_index
				or context.current_command_index != expected_command_index
				or context.pending_jump != expected_pending_jump
				or context.is_finished != expected_finished
				or context.is_runtime_owner_current() != expected_execution_owner
			)
		)
	):
		return false
	SignalBus.apply_chapter_indicator_state(
		context.chapter_indicator_visible if context != null else false)
	return (
		navigation == _navigation_generation
		and (engine.context if engine != null else null) == expected_context
	)


func _apply_retained_presentation(context: ScenarioContext) -> bool:
	var navigation := _navigation_generation
	var expected_context := engine.context if engine != null else null
	if context != expected_context:
		return false
	if not presentation_state.apply_to_presenters(
		_runtime_dialogue_visibility_binding(context)
	):
		return false
	if (
		presentation_state != null
		and not presentation_state.current_movie.is_empty()
		and not _adopt_restored_movie(context)
	):
		return false
	if (
		navigation != _navigation_generation
		or (engine.context if engine != null else null) != expected_context
	):
		return false
	return _apply_chapter_presentation(context)


func _runtime_dialogue_visibility_binding(
	context: ScenarioContext,
) -> Dictionary:
	var default_binding := {
		"profile_name": "",
		"profile": {},
		"provenance": {},
		"surface_groups": ["dialogue_surface"],
		"quick_menu_groups": ["quick_menu"],
	}
	if context == null:
		return {
			"current": default_binding.duplicate(true),
			"default": default_binding.duplicate(true),
			"nvl_entries": [],
		}
	var current := default_binding.duplicate(true)
	var profile := context.resolve_current_dialogue_profile()
	if not profile.is_empty():
		current["profile"] = profile.duplicate(true)
		current["surface_groups"] = (
			profile.get("surface_groups", current["surface_groups"]) as Array
		).duplicate()
		current["quick_menu_groups"] = (
			profile.get("quick_menu_groups", current["quick_menu_groups"]) as Array
		).duplicate()
	var provenance := context.resolve_current_dialogue_profile_provenance()
	current["profile_name"] = String(context.current_dialogue_profile_name)
	current["provenance"] = provenance.duplicate(true)
	var nvl_entries: Array = []
	for entry_value: Variant in context.nvl_page_entries:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		var entry_profile_name := String(entry.get("profile_name", ""))
		var entry_profile := (
			context.scenario_data.get_dialogue_profile(entry_profile_name)
			if context.scenario_data != null and not entry_profile_name.is_empty()
			else {}
		)
		var entry_provenance := (
			context.scenario_data.get_dialogue_profile_provenance(entry_profile_name)
			if context.scenario_data != null and not entry_profile_name.is_empty()
			else {}
		)
		nvl_entries.append({
			"profile_name": entry_profile_name,
			"profile": entry_profile.duplicate(true),
			"provenance": entry_provenance.duplicate(true),
			"surface_groups": (
				entry_profile.get("surface_groups", default_binding["surface_groups"]) as Array
			).duplicate(),
			"quick_menu_groups": (
				entry_profile.get("quick_menu_groups", default_binding["quick_menu_groups"]) as Array
			).duplicate(),
		})
	return {
		"current": current,
		"default": default_binding.duplicate(true),
		"nvl_entries": nvl_entries,
	}


func _on_scene_changed_for_chapter_presentation(_scene_id: String) -> void:
	_publish_current_chapter(engine.context if engine != null else null)


func _on_state_changed(from_state: int, _to_state: int) -> void:
	# Leaving PLAYING state: stop auto-play and skip
	if from_state == GameStateMachine.State.PLAYING:
		auto_play.stop()
		skip_controller.stop()


func _on_scenario_ended(id: String) -> void:
	if engine == null or not engine.is_emitting_active_scenario_end():
		return
	var ended_context := engine.context
	SignalBus.scenario_ended_event.emit(id)
	# The public bridge is itself reentrant. A listener may start a replacement
	# navigation, which invalidates this run while the engine is still inside
	# scenario_ended.emit(). Do not let the retired callback append a title
	# navigation after that newer owner has already taken over.
	if not engine.is_emitting_active_scenario_end():
		return
	if ended_context != null and ended_context.is_recollection_playback():
		_complete_recollection_return(ended_context)
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
	var snapshot = _capture_flowchart_chapter_snapshot(scene_id, new_chapter_id)
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
	presentation_state.record_dialogue_content(request, engine.context)
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
	var snap := _capture_runtime_checkpoint()
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


func _capture_runtime_checkpoint() -> Dictionary:
	var snap: Dictionary = {}
	if engine and engine.context:
		snap["scenario_context"] = engine.context.capture_snapshot()
		if engine.context.variable_store:
			snap["variable_store"] = (
				engine.context.variable_store.capture_scenario_scope()
			)
	if presentation_state:
		snap["presentation_state"] = _capture_effective_presentation_snapshot()
	if presentation_clip_audio_choice_authority:
		snap[PresentationClipAudioChoiceAuthority.PROVIDER_ID] = (
			presentation_clip_audio_choice_authority.capture_snapshot())
	return snap


func _capture_effective_presentation_snapshot() -> Dictionary:
	var snapshot := presentation_state.capture_snapshot()
	if engine == null or engine.context == null:
		return snapshot
	var command := engine.context.current_command()
	if command == null or command.type != "presentation_batch":
		return snapshot
	var params := command.params if command.params is Dictionary else {}
	var operations: Array = params.get("operations", [])
	if operations.is_empty():
		return snapshot
	var stage_layers := (
		snapshot.get("stage_layers", {}) as Dictionary
	).duplicate(true)
	var visibility := (
		snapshot.get(
			"dialogue_visibility",
			DialogueVisibilityState.default_state(),
		) as Dictionary
	).duplicate(true)
	var loop_se_channels := (
		snapshot.get("loop_se_channels", {}) as Dictionary
	).duplicate(true)
	var stage_payloads: Array = []
	var visibility_payloads: Array = []
	var loop_se_payloads: Array = []
	for operation_value: Variant in operations:
		if not operation_value is Dictionary:
			continue
		var operation: Dictionary = operation_value
		var kind := String(operation.get("kind", "")).strip_edges()
		var payload: Variant = operation.get("payload", {})
		if not payload is Dictionary:
			continue
		if kind == "stage":
			stage_payloads.append((payload as Dictionary).duplicate(true))
		elif kind == "dialogue_visibility":
			visibility_payloads.append((payload as Dictionary).duplicate(true))
		elif kind == "loop_se":
			loop_se_payloads.append((payload as Dictionary).duplicate(true))
	if not stage_payloads.is_empty():
		snapshot["stage_layers"] = StageLayerState.reduce(
			stage_layers,
			stage_payloads,
			false,
		)
	if not visibility_payloads.is_empty():
		snapshot["dialogue_visibility"] = DialogueVisibilityState.reduce(
			visibility,
			visibility_payloads,
			false,
		)
	if not loop_se_payloads.is_empty():
		snapshot["loop_se_channels"] = LoopSeChannelState.reduce(
			loop_se_channels,
			loop_se_payloads,
			false,
		)
	return snapshot


func _capture_flowchart_chapter_snapshot(
	scene_id: String,
	chapter_id: String,
) -> Dictionary:
	var snapshot := _capture_runtime_checkpoint()
	snapshot["chapter_id"] = chapter_id
	if engine == null or engine.context == null:
		return snapshot
	var scenario_data := engine.context.scenario_data
	if scenario_data == null:
		return snapshot
	var entry_scene_id := scene_id
	var chapter := scenario_data.get_chapter(chapter_id)
	if chapter != null:
		var resolved_entry_scene_id := chapter.get_entry_scene_id()
		if not resolved_entry_scene_id.is_empty():
			entry_scene_id = resolved_entry_scene_id
	_normalize_flowchart_chapter_snapshot(
		snapshot,
		scenario_data,
		entry_scene_id,
		chapter_id,
	)
	return snapshot


func _normalize_flowchart_chapter_snapshot(
	snapshot: Dictionary,
	scenario_data: ScenarioData,
	scene_id: String,
	chapter_id: String,
) -> void:
	if scenario_data == null:
		return
	var scene_index := -1
	for index in range(scenario_data.scenes.size()):
		var candidate: SceneData = scenario_data.scenes[index]
		if candidate != null and candidate.id == scene_id:
			scene_index = index
			break
	if scene_index < 0:
		return
	var scenario_snapshot := (
		snapshot.get("scenario_context", {}) as Dictionary
	).duplicate(true)
	scenario_snapshot["scene_index"] = scene_index
	scenario_snapshot["command_index"] = 0
	scenario_snapshot["is_finished"] = false
	snapshot["scenario_context"] = scenario_snapshot
	snapshot["chapter_id"] = chapter_id


func _refresh_current_flowchart_chapter_snapshot_for_save() -> void:
	if flowchart_state == null or engine == null or engine.context == null:
		return
	var scenario_data := engine.context.scenario_data
	if scenario_data == null:
		return
	var chapter_id := flowchart_state.get_current_chapter_id()
	if chapter_id.is_empty():
		return
	var scene := engine.context.current_scene()
	if scene == null:
		return
	flowchart_state.chapter_snapshots[chapter_id] = (
		_capture_flowchart_chapter_snapshot(scene.id, chapter_id)
	)


# ─── Facade API: Save/Load ───

func _movie_save_admitted() -> bool:
	if SignalBus.movie_save_boundary_is_stable():
		return true
	push_warning(
		"SaveManager: save rejected during an unresolved native movie terminal boundary")
	return false

## Quick save (separate from manual save slots).
func quick_save() -> void:
	if _is_recollection_context_active():
		push_warning(
			"StellaRuntime: quick save is unavailable during recollection playback")
		return
	if not _movie_save_admitted():
		return
	_refresh_current_flowchart_chapter_snapshot_for_save()
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
	var movie_restore_ticket := _prepare_movie_restore_from_save(save_data)
	if movie_restore_ticket <= 0:
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
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
	var navigation := _begin_navigation("quick_load", needs_game_scene)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	# From title or while superseding another scene request, explicitly assert
	# the game destination before restoring providers and starting the engine.
	if needs_game_scene:
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_discard_prepared_movie_restore(movie_restore_ticket)
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _cancel_active_gameplay(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_close_current_overlay()
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
			navigation,
			movie_restore_ticket,
		):
			return false
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	if not _cancel_active_gameplay(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_last_scenario_path = scenario_path
	if not _load_preparsed_scenario_and_restore(
		scenario_data, scenario_path, save_data, navigation, movie_restore_ticket):
		return false
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
	if _is_recollection_context_active():
		push_warning(
			"StellaRuntime: auto save is unavailable during recollection playback")
		return
	if not _movie_save_admitted():
		return
	_refresh_current_flowchart_chapter_snapshot_for_save()
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
	var movie_restore_ticket := _prepare_movie_restore_from_save(save_data)
	if movie_restore_ticket <= 0:
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
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
	var navigation := _begin_navigation("continue_game", needs_game_scene)
	if not _owns_navigation(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	# From title or while superseding another scene request, explicitly assert
	# the game destination before restoring providers and starting the engine.
	if needs_game_scene:
		if not await _enter_scene_and_confirm(
			destination,
			navigation,
			"game",
		):
			_discard_prepared_movie_restore(movie_restore_ticket)
			_finish_navigation(navigation)
			return false
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _cancel_active_gameplay(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_close_current_overlay()
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		_last_scenario_path = scenario_path
		game_state.transition_to(GameStateMachine.State.PLAYING)
		if not _owns_navigation(navigation):
			_discard_prepared_movie_restore(movie_restore_ticket)
			return false
		if not _load_preparsed_scenario_and_restore(
			scenario_data,
			scenario_path,
			save_data,
			navigation,
			movie_restore_ticket,
		):
			return false
		_finish_navigation(navigation)
		return true

	# In-game: reload in place
	if not _cancel_active_gameplay(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_last_scenario_path = scenario_path
	if not _load_preparsed_scenario_and_restore(
		scenario_data, scenario_path, save_data, navigation, movie_restore_ticket):
		return false
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
	if _is_recollection_context_active():
		push_warning(
			"StellaRuntime: manual save is unavailable during recollection playback")
		return
	if not _movie_save_admitted():
		return
	_refresh_current_flowchart_chapter_snapshot_for_save()
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


## Internal playback gate: user intent remains active while a choice-owned
## suspension temporarily prevents automatic progression.
func is_auto_play_effective() -> bool:
	return auto_play.is_effective()


## Whether skip mode is currently active.
func is_skipping() -> bool:
	return skip_controller.is_active


# ─── Facade API: Current Chapter ───

## Stable authored chapter identity derived from the live execution cursor.
func get_current_chapter_id() -> String:
	var chapter := _chapter_for_context(
		engine.context if engine != null else null)
	return chapter.id if chapter != null else ""


## TranslationServer-resolved current chapter title.
func get_current_chapter_title() -> String:
	var chapter := _chapter_for_context(
		engine.context if engine != null else null)
	if chapter == null or chapter.display_name.is_empty():
		return ""
	return tr(chapter.display_name)


## Authored target visibility, independent of transient visual ownership. During
## navigation the retained context remains canonical until replacement commits.
func is_chapter_indicator_visible() -> bool:
	return (
		engine != null
		and engine.context != null
		and engine.context.chapter_indicator_visible
	)


# ─── Internal Choice Playback Policy ───

## Whether an authored choice currently owns modal scenario input.
func is_choice_active() -> bool:
	return _active_choice_session >= 0


## ChoiceHandler installs policy ownership before publishing choice_show. The
## settings are intentionally read exactly once here; menu-time changes apply
## only to the next choice.
func _begin_choice_policy_session() -> int:
	# ScenarioEngine dispatch is serial. Reject a malformed concurrent choice
	# instead of letting it transfer or retire ownership that still belongs to the
	# current handler.
	if _active_choice_session >= 0:
		push_warning("StellaRuntime: rejected concurrent choice policy session")
		return -1
	# Capture the independent pair before either controller emits a synchronous
	# state edge; listeners cannot turn one choice into a mixed-policy snapshot.
	var pause_auto := bool(get_setting("auto_play_pause_on_choice"))
	var stop_skip := bool(get_setting("skip_stop_on_choice"))
	_choice_session_serial += 1
	var session_id := _choice_session_serial
	_active_choice_session = session_id
	_active_choice_auto_suspension = pause_auto
	if _active_choice_auto_suspension:
		auto_play.acquire_suspension(session_id)
	# Controller signals are synchronous. A lifecycle listener can replace the
	# execution owner and install a fresh choice before this call resumes; never
	# let the retired begin tail stop playback on behalf of that new generation.
	if stop_skip and _active_choice_session == session_id:
		skip_controller.stop()
	# Return the generation allocated to this caller, not mutable global state.
	# Its handler can then fail stale without cancelling a reentrant replacement.
	return session_id


## Release only the exact current generation after its selected option effects
## have committed. A positive effective edge deliberately does not start any
## old dialogue tail; the next command establishes fresh playback ownership.
func _resolve_choice_policy_session(session_id: int) -> bool:
	if session_id < 0 or session_id != _active_choice_session:
		return false
	_active_choice_session = -1
	var had_auto_suspension := _active_choice_auto_suspension
	_active_choice_auto_suspension = false
	if had_auto_suspension:
		auto_play.release_suspension(session_id)
	# A release edge may synchronously install a replacement choice. The old
	# handler committed successfully, but its untyped HIDE must then be skipped.
	return _active_choice_session < 0


## Cancellation is fail-closed: invalidate ownership first, stop both user
## playback intents, then release the retired choice's suspension.
func _cancel_choice_policy_session(session_id: int) -> bool:
	if session_id < 0 or session_id != _active_choice_session:
		return false
	_active_choice_session = -1
	var had_auto_suspension := _active_choice_auto_suspension
	_active_choice_auto_suspension = false
	auto_play.stop()
	skip_controller.stop()
	if had_auto_suspension:
		auto_play.release_suspension(session_id)
	# Return-to-title keeps the retired Context available until SceneTree confirms
	# the destination. Its accepted handoff has already revoked execution owner,
	# but publishing the public untyped HIDE here would expose that retained old
	# Context to synchronous listeners. _cancel_active_gameplay() publishes the
	# deferred HIDE after it detaches Context.
	if (
		_navigation_kind == "return_to_title"
		and engine != null
		and engine.context != null
		and not engine.context.is_runtime_owner_current()
	):
		return false
	# Controller callbacks may synchronously SHOW a replacement generation.
	# Returning false suppresses only the retired handler's public HIDE.
	return _active_choice_session < 0


func _is_choice_policy_session_current(session_id: int) -> bool:
	return session_id >= 0 and session_id == _active_choice_session


## Keep the public choice_show payload while attaching an internal occurrence
## owner to the synchronous dispatch stack. If a listener replaces the context
## and publishes a fresh built-in choice recursively, later listeners in the
## outer emission can reject that stale tail before mutating presentation.
func _publish_choice_policy_session(
	session_id: int,
	prompt: String,
	options: Array,
) -> bool:
	if not _is_choice_policy_session_current(session_id):
		return false
	_choice_presentation_dispatch_stack.append(session_id)
	SignalBus.choice_show.emit(prompt, options)
	var completed_session := _choice_presentation_dispatch_stack.pop_back()
	return (
		completed_session == session_id
		and _is_choice_policy_session_current(session_id)
	)


## Presenters call this at the beginning of a choice_show callback. An empty
## stack is a direct extension emission; occurrence ownership for that path
## remains outside this internal built-in guard.
func is_choice_presentation_dispatch_current() -> bool:
	if _choice_presentation_dispatch_stack.is_empty():
		return true
	return _is_choice_policy_session_current(
		_choice_presentation_dispatch_stack.back())


## Snapshot the pre-transfer abort audience before ownership changes. Context-aware
## handlers normally disconnect during ScenarioEngine.context replacement; the
## remaining snapshot members are persistent presenters or extensions owned by
## the retired run. A handler installed synchronously by
## the replacement context is intentionally absent from this generation.
func _capture_engine_abort_connections() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_connection in SignalBus.engine_abort_requested.get_connections():
		if raw_connection is Dictionary:
			var connection: Dictionary = raw_connection
			result.append(connection.duplicate())
	return result


func _notify_retired_engine_abort_connections(
	connections: Array[Dictionary],
) -> void:
	for connection in connections:
		var callback: Callable = connection.get("callable", Callable())
		if (
			not callback.is_valid()
			or not SignalBus.engine_abort_requested.is_connected(callback)
		):
			continue
		var flags := int(connection.get("flags", 0))
		if flags & CONNECT_DEFERRED:
			callback.call_deferred()
		else:
			callback.call()
		if (
			flags & CONNECT_ONE_SHOT
			and SignalBus.engine_abort_requested.is_connected(callback)
		):
			SignalBus.engine_abort_requested.disconnect(callback)


## Phase one of a hard boundary is deliberately signal-free. Callers must next
## replace or clear ScenarioEngine.context so the old ChoiceHandler loses owner
## status and disconnects before controller/HIDE callbacks can reenter.
func _begin_choice_hard_boundary() -> int:
	var retired_session := _active_choice_session
	_active_choice_session = -1
	_active_choice_auto_suspension = false
	return retired_session


## When a synchronous replacement takes ownership before phase two, this stale
## boundary may release only its own exact Auto token. The replacement owns all
## controller intent and presentation decisions from that point onward.
func _release_retired_choice_boundary_token(retired_session: int) -> void:
	if retired_session >= 0:
		auto_play.release_suspension(retired_session)


## Phase two runs only after the execution owner changed. Preserve at most a
## fresh choice token installed synchronously by the replacement context, clear
## every retired/orphan token, then fail-close both playback intents. Publishing
## HIDE last prevents a stale selection callback from completing the old run.
func _finish_choice_hard_boundary(publish_hide: bool) -> void:
	# Stop intent while the retired pause still suppresses effective progression;
	# clearing tokens first would publish a transient true edge to extensions.
	auto_play.stop()
	skip_controller.stop()
	if _active_choice_session >= 0 and _active_choice_auto_suspension:
		auto_play.clear_suspensions_except(_active_choice_session)
	else:
		auto_play.clear_suspensions()
	# A replacement context may synchronously enter a fresh choice while the old
	# context is cancelling or a controller edge is delivered. Its SHOW already
	# replaces the retired visual; an untyped stale HIDE must not target it.
	if publish_hide and _active_choice_session < 0:
		SignalBus.choice_hide.emit()


# ─── Facade API: Named Stage Layers ───

## Apply an atomic batch of named-stage operations. Each operation uses the
## same schema as the `stage_layer` CommandData payload: action, id,
## properties, transition, transition_params, and duration.
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
	var canonical_batch := true
	for operation_value: Variant in authored_operations:
		if not StageLayerState.validate_operation(operation_value, false):
			canonical_batch = false
			break
	if not canonical_batch:
		# Preserve the public void Facade's exact failed request notification,
		# but let Bus own the single warning/report. Its schema gate runs before
		# the projection ingress gate, so an invalid custom-looking spelling can
		# never reach a listener or be mistaken for a typed provider request.
		SignalBus.emit_stage_operations(
			authored_operations.duplicate(true), force_cut)
		return
	var requires_typed_transition := false
	for operation_value: Variant in authored_operations:
		if not operation_value is Dictionary:
			continue
		var kind := String((operation_value as Dictionary).get(
			"transition", "cut")).strip_edges().to_lower()
		if StageTransitionSpec.is_projection_effect(kind):
			requires_typed_transition = true
			break
	if requires_typed_transition:
		var context := engine.context if engine != null else null
		if (
			presentation_director == null
			or context == null
			or not context.is_runtime_owner_current()
		):
			push_error(
				"StellaRuntime: projection Stage transitions require a current scenario owner")
			return
		var source := {
			"source_path": (
				context.scenario_data.source_path
				if context.scenario_data != null else ""),
			"scenario_id": (
				context.scenario_data.id if context.scenario_data != null else ""),
			"line": 0,
		}
		var typed_operations: Array[PresentationOperation] = []
		for operation_value: Variant in authored_operations:
			if not operation_value is Dictionary:
				push_error("StellaRuntime: invalid Stage operation in typed facade batch")
				return
			typed_operations.append(StagePresentationOperation.new(
				(operation_value as Dictionary).duplicate(true), source))
		presentation_director.submit(
			typed_operations,
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			context,
			source,
			force_cut,
		)
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
	transition_params: Dictionary = {},
) -> void:
	_emit_stage_operation(
		"show", layer_id, properties, transition, duration, transition_params
	)


func update_stage_layer(
	layer_id: String,
	properties: Dictionary,
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> void:
	_emit_stage_operation(
		"update", layer_id, properties, transition, duration, transition_params
	)


func hide_stage_layer(
	layer_id: String,
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> void:
	_emit_stage_operation(
		"hide", layer_id, {}, transition, duration, transition_params)


func remove_stage_layer(
	layer_id: String,
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> void:
	_emit_stage_operation(
		"remove", layer_id, {}, transition, duration, transition_params)


func clear_stage_layers(
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> void:
	_emit_stage_operation(
		"clear", "", {}, transition, duration, transition_params)


func _emit_stage_operation(
	action: String,
	layer_id: String,
	properties: Dictionary,
	transition: String,
	duration: float,
	transition_params: Dictionary,
) -> void:
	if action != "clear" and layer_id.strip_edges() == "":
		push_warning("StellaRuntime: stage operation requires a layer id")
		return
	apply_stage_operations([{
		"action": action,
		"id": layer_id,
		"properties": properties.duplicate(true),
		"transition": transition,
		"transition_params": transition_params.duplicate(true),
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
## 3. Restore scenario_context + scenario-scope vars from the snapshot.
##    Scope-only var restore keeps Scope.GLOBAL intact.
## 4. If override_scene_id is non-empty, set_scene to it AFTER the snapshot
##    restore. Used by flowchart jump where the snapshot position and the
##    chapter entry can differ and we want to be safe against mismatch.
## 5. Register the new context as a save provider BEFORE swapping it in.
##    Otherwise an autosave triggered by NOTIFICATION_WM_CLOSE_REQUEST in
##    the window between swap and register would serialize an inconsistent
##    mix (old context provider + new presentation_state).
## 6. Swap engine.context, which first asks the retired context generation to
##    cancel all blocking handlers. Then notify only the pre-transfer audience
##    captured before transfer; listeners installed by a synchronous replacement
##    are not part of the retired generation's abort.
##    Ownership transfer happens before any hard presentation boundary so a
##    synchronous Presenter abort cannot make the stale run report scenario_ended.
## 7. Reset visuals to a clean slate. The canonical BGM reset is then replaced
##    by restore_snapshot. fade("in",0) drops any
##    lingering screen-fade overlay.
## 8. Restore presentation_state and apply_to_presenters, snapping visuals to
##    the restored state before the target command is re-dispatched.
## 9. engine.run() — the new owner picks up the restored context.
func _restore_runtime_from_snapshot(
	snap: Dictionary,
	override_scene_id: String = "",
) -> bool:
	if engine == null or engine.context == null:
		return false
	if engine.context.is_recollection_playback():
		push_warning(
			"StellaRuntime: rollback is unavailable during recollection playback")
		return false
	var raw_choice_snapshot: Variant = snap.get(
		PresentationClipAudioChoiceAuthority.PROVIDER_ID, null)
	if not PresentationClipAudioChoiceAuthority.validate_playthrough_snapshot(
		raw_choice_snapshot):
		return false
	var retained_context := engine.context
	var raw_presentation: Variant = snap.get("presentation_state", {})
	if not raw_presentation is Dictionary:
		return false
	var presentation_snapshot: Dictionary = raw_presentation
	var dialogue_content: Variant = presentation_snapshot.get(
		"dialogue_content",
		PresentationState._inactive_dialogue_content(),
	)
	if (
		not PresentationState._validate_dialogue_content(dialogue_content, false)
		or not PresentationState.dialogue_content_profiles_exist(
			dialogue_content as Dictionary,
			retained_context.scenario_data,
		)
	):
		return false
	var movie_restore_ticket := _prepare_movie_restore_from_presentation(
		presentation_snapshot)
	if movie_restore_ticket <= 0:
		return false
	# Every rollback facade invocation owns a distinct generation. A synchronous
	# state/reset listener may start another rollback; only that newest call may
	# build, install, or run a replacement Context.
	var navigation := _begin_navigation("rollback", true)
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	# The facade has already accepted a validated snapshot, but its destructive
	# continuation must wait for the exact accepted SceneTree receipt. This keeps
	# restored SHOW events in the winning scene instead of publishing headlessly
	# from a choice-hide callback during destination _ready().
	if not await _await_navigation_scene_slot(navigation):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _acquire_navigation_runtime_ownership(
		navigation,
		false,
		true,
	):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	_close_current_overlay()
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	game_state.transition_to(GameStateMachine.State.PLAYING)
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	var scenario_data = retained_context.scenario_data
	var new_ctx = ScenarioContext.new(scenario_data)
	new_ctx.variable_store = retained_context.variable_store

	new_ctx.restore_snapshot(snap.get("scenario_context", {}))
	new_ctx.variable_store.restore_scenario_scope(snap.get("variable_store", {}))
	if override_scene_id != "":
		new_ctx.set_scene(override_scene_id)

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
	if not _owns_navigation_context(navigation, retained_context):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false

	save_manager.register_provider(new_ctx)
	save_manager.register_provider(new_ctx.variable_store)
	var retired_abort_connections := _capture_engine_abort_connections()
	var retired_choice_session := _begin_choice_hard_boundary()
	engine.replace_context(new_ctx)
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	_notify_retired_engine_abort_connections(retired_abort_connections)
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false

	SignalBus.reset_stage_visuals()
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	SignalBus.reset_presentation_clip()
	SignalBus.reset_movie_presentation()
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	if not presentation_clip_audio_choice_authority.restore_snapshot(
		raw_choice_snapshot as Dictionary):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	SignalBus.reset_chapter_indicator_presentation()
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	presentation_state.current_bgm.clear()
	SignalBus.reset_bgm_presentation()
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	SignalBus.hide_dialogue.emit()
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		_release_retired_choice_boundary_token(retired_choice_session)
		return false
	_finish_choice_hard_boundary(true)
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	SignalBus.fade_requested.emit("in", 0.0)
	if not _owns_navigation_context(navigation, new_ctx):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	presentation_state.clear()
	presentation_state.restore_snapshot(presentation_snapshot)
	if not _arm_prepared_movie_restore(
		movie_restore_ticket, presentation_state.current_movie):
		_discard_prepared_movie_restore(movie_restore_ticket)
		return false
	if not presentation_state.apply_to_presenters(
		_runtime_dialogue_visibility_binding(new_ctx)
	):
		return false
	if not _owns_navigation_context(navigation, new_ctx):
		return false
	if not _adopt_restored_movie(new_ctx):
		return false
	if not _apply_chapter_presentation(new_ctx):
		return false
	if not _owns_navigation_context(navigation, new_ctx):
		return false

	_navigation_projection_committed = true
	engine.run()
	if not _owns_navigation_context(navigation, new_ctx):
		return false
	_finish_navigation(navigation)
	return _owns_navigation_context(navigation, new_ctx)


## Jump to a backlog entry. Restores that entry's snapshot directly —
## scenario position, variables, and presentation state are all rewound
## to exactly the moment that dialogue was first displayed. Backlog history
## is preserved (cursor moves but no truncate); divergence is detected
## automatically when the player next adds an entry that doesn't match
## the recorded path.
func jump_from_backlog(index: int) -> bool:
	if engine == null or engine.context == null:
		return false
	if engine.context.is_recollection_playback():
		return false
	var info = backlog_manager.peek_jump(index)
	if info.is_empty():
		return false
	if not _rollback_snapshot_has_valid_audio_choice(info.get("snapshot")):
		return false
	if not backlog_manager.commit_jump(index):
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
	if engine.context.is_recollection_playback():
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
	if engine.context.is_recollection_playback():
		return false
	var cur_cmd = engine.context.current_command()
	var cur_uid: int = -1
	if cur_cmd != null:
		cur_uid = cur_cmd.uid
	var info = choice_history_manager.peek_previous(cur_uid)
	if info.is_empty():
		return false
	if not _rollback_snapshot_has_valid_audio_choice(info.get("snapshot")):
		return false
	if not choice_history_manager.commit_previous(cur_uid):
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
	if engine.context.is_recollection_playback():
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
	if not _rollback_snapshot_has_valid_audio_choice(snap):
		return false

	# Update flowchart line (truncate or reset).
	flowchart_state.jump_to(chapter_id)

	# Delegate the restore pipeline. Pass entry_scene_id as the override so
	# set_scene runs after restore_snapshot — defending against a snapshot-
	# context mismatch where the captured scene_index disagrees with the
	# chapter entry scene.
	_restore_runtime_from_snapshot(snap, entry_scene_id)
	return true


func _rollback_snapshot_has_valid_audio_choice(raw_snapshot: Variant) -> bool:
	return (
		raw_snapshot is Dictionary
		and PresentationClipAudioChoiceAuthority.validate_playthrough_snapshot(
			(raw_snapshot as Dictionary).get(
				PresentationClipAudioChoiceAuthority.PROVIDER_ID, null))
	)


# ─── Facade API: Settings ───

## Get a setting value by key.
func get_setting(key: String) -> Variant:
	return settings_manager.get_value(key)


## Set a setting value by key.
func set_setting(key: String, value: Variant) -> bool:
	return settings_manager.set_value(key, value)


## Read the declarative definition used by project settings UI.
func get_setting_definition(key: String) -> Dictionary:
	return settings_manager.get_definition(key)


## Registered built-in keys followed by sorted project-defined keys.
func get_registered_settings() -> PackedStringArray:
	return settings_manager.get_registered_keys()


## Persist settings to disk.
func save_settings() -> Error:
	return settings_manager.save()


## Reset all settings to defaults.
func reset_settings() -> void:
	settings_manager.reset_to_default()
	DisplayHelper.apply(settings_manager.settings)


func _play_title_bgm() -> void:
	presentation_state.current_bgm.clear()
	SignalBus.apply_title_bgm_cut(config.title_bgm)


## Play a system sound effect (UI clicks, confirmations, etc.)
func play_system_se(asset: String) -> void:
	SignalBus.system_se_play.emit(asset)


## Get save metadata for a slot (timestamp, etc). Returns empty dict if no save.
func get_save_metadata(slot_id: int) -> Dictionary:
	return save_manager.get_save_metadata(slot_id)
