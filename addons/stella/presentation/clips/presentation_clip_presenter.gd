## Runtime-owned projector for one declarative animated presentation clip.
##
## AnimationPlayer owns authored timeline time. This presenter only observes
## its position to dispatch already-preflighted ordered cues and project sealed
## particle work; it never reconstructs authored time with timers or polling.
class_name PresentationClipPresenter extends CanvasLayer

const TURN_SHADER_PATH := (
	"res://addons/stella/presentation/clips/shaders/presentation_clip_turn.gdshader")
const DEFINITION_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_definition.gd")
const CUE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_cue.gd")
const STATE_CUE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_state_cue.gd")
const AUDIO_CUE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_audio_cue.gd")
const AUDIO_CHOICE_CUE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_audio_choice_cue.gd")
const AUDIO_CHOICE_CANDIDATE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_audio_choice_candidate.gd")
const PARTICLE_LAYER_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_particle_layer.gd")
const PARTICLE_MIX_SHADER := preload(
	"res://addons/stella/presentation/clips/shaders/presentation_clip_particle_mix.gdshader")
const PARTICLE_ADD_SHADER := preload(
	"res://addons/stella/presentation/clips/shaders/presentation_clip_particle_add.gdshader")
const PARTICLE_SUB_SHADER := preload(
	"res://addons/stella/presentation/clips/shaders/presentation_clip_particle_sub.gdshader")
const PARTICLE_MUL_SHADER := preload(
	"res://addons/stella/presentation/clips/shaders/presentation_clip_particle_mul.gdshader")
const ALLOWED_DEFINITION_SCRIPTS := [
	DEFINITION_SCRIPT_PATH,
	CUE_SCRIPT_PATH,
	STATE_CUE_SCRIPT_PATH,
	AUDIO_CUE_SCRIPT_PATH,
	AUDIO_CHOICE_CUE_SCRIPT_PATH,
	AUDIO_CHOICE_CANDIDATE_SCRIPT_PATH,
	PARTICLE_LAYER_SCRIPT_PATH,
]
const MAX_DEPENDENCY_DEPTH := 128
const MAX_DEPENDENCY_RESOURCES := 1024
const MAX_SCENE_STATE_DEPTH := 128
const MAX_SCENE_STATE_WORK := PresentationClipDefinition.MAX_SCENE_NODES * 4
## Sealed event payload uses six PackedFloat64Array channels (48 bytes/event).
## MultiMesh 2D transform + vertex color is 12 floats (48 bytes/instance).
## Both reserve 64 bytes for alignment. Each layer additionally reserves 64 KiB
## for its six packed-array headers, one MultiMesh, one CanvasItem, and material.
const PARTICLE_EVENT_RESERVATION_BYTES := 64
const PARTICLE_INSTANCE_RESERVATION_BYTES := 64
const PARTICLE_LAYER_OWNER_RESERVATION_BYTES := 65536
const PARTICLE_CURVE_KEY_BYTES := 16
const PARTICLE_HASH_DENOMINATOR := 2147483648.0

var _participant_capability: RefCounted
var _prepared_plans: Dictionary = {}
var _claimed: Dictionary = {}
var _active: Dictionary = {}
var _presentation_clip_transaction: Dictionary = {}
var _generation := 1
var _token_serial := 0
var _exiting := false
var _reserved_resource_bytes := 0


func _ready() -> void:
	layer = PresentationLayerOrder.FULLSCREEN_MEDIA
	_participant_capability = StellaRuntime._register_presentation_clip_presenter(self)
	if _participant_capability == null:
		push_error("PresentationClipPresenter could not join the Runtime registry")
		return
	SignalBus.presentation_clip_prepare_requested.connect(_on_prepare_requested)
	SignalBus.presentation_clip_validate_requested.connect(_on_validate_requested)
	SignalBus.presentation_clip_accept_requested.connect(_on_accept_requested)
	SignalBus.presentation_clip_apply_readiness_requested.connect(
		_on_apply_readiness_requested)
	SignalBus.presentation_clip_apply_requested.connect(_on_apply_requested)
	SignalBus.presentation_clip_publish_readiness_requested.connect(
		_on_publish_readiness_requested)
	SignalBus.presentation_clip_finish_requested.connect(_on_finish_requested)
	SignalBus.presentation_clip_projection_reset_requested.connect(
		_on_projection_reset_requested)
	SignalBus.presentation_clip_request_settled.connect(_on_request_settled)
	set_process(false)


func _exit_tree() -> void:
	_exiting = true
	_release_all_prepared()
	_abort_presentation_clip_transaction()
	_release_claimed()
	_retire_active(&"cancelled")
	if _participant_capability != null:
		StellaRuntime._unregister_presentation_clip_presenter(
			self, _participant_capability)
	_participant_capability = null


func _on_prepare_requested(request: PresentationClipOperationRequest) -> void:
	if _participant_capability == null or request == null:
		return
	if SignalBus.has_active_movie_projection():
		SignalBus.reject_presentation_clip_definition(
			request,
			self,
			_participant_capability,
			"a movie owns the mutually exclusive full-screen media surface",
		)
		return
	var result := _resolve_definition_result(request.get_asset())
	var definition: PresentationClipDefinition = result.get("definition")
	if definition == null:
		SignalBus.reject_presentation_clip_definition(
			request,
			self,
			_participant_capability,
			String(result.get("error", "clip definition could not be resolved")),
		)
		return
	var audio_choice_work_error := definition.bounded_audio_choice_work_error()
	if not audio_choice_work_error.is_empty():
		SignalBus.reject_presentation_clip_definition(
			request,
			self,
			_participant_capability,
			"clip '%s' definition: %s" % [
				request.get_asset(), audio_choice_work_error,
			],
		)
		return
	SignalBus.prepare_presentation_clip_definition(
		request, self, _participant_capability, definition)


func _has_active_projection(capability: RefCounted) -> bool:
	return capability == _participant_capability and not _active.is_empty()


func _on_validate_requested(request: PresentationClipOperationRequest) -> void:
	if (
		_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
	):
		return
	var plan := _prepare_plan(_sealed_definition(request))
	if not bool(plan.get("valid", false)):
		SignalBus.reject_presentation_clip_request(
			request,
			self,
			_participant_capability,
			PresentationClipOperationRequest.ROLE_VISUAL,
			"clip '%s' definition: %s" % [
				request.get_asset(), String(plan.get("error", "clip preflight failed")),
			],
		)
		return
	var snapshot_error := _attach_under_snapshot(plan)
	if not snapshot_error.is_empty():
		_release_plan(plan)
		SignalBus.reject_presentation_clip_request(
			request,
			self,
			_participant_capability,
			PresentationClipOperationRequest.ROLE_VISUAL,
			"clip '%s' definition: %s" % [request.get_asset(), snapshot_error],
		)
		return
	_prepared_plans[request.get_instance_id()] = plan
	SignalBus.validate_presentation_clip_request(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _on_accept_requested(request: PresentationClipOperationRequest) -> void:
	if (
		_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
		or not _prepared_plans.has(request.get_instance_id())
	):
		return
	SignalBus.accept_presentation_clip_request(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _on_apply_readiness_requested(
	request: PresentationClipOperationRequest,
) -> void:
	var plan: Dictionary = (
		_prepared_plans.get(request.get_instance_id(), {})
		if request != null else {})
	if request != null and SignalBus.has_active_movie_projection():
		SignalBus.fail_presentation_clip_apply(
			request,
			self,
			_participant_capability,
			PresentationClipOperationRequest.ROLE_VISUAL,
			"a movie claimed the mutually exclusive full-screen media surface after clip preflight",
		)
		return
	if (
		_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
		or not _plan_is_installable(plan)
	):
		if request != null and not plan.is_empty():
			SignalBus.fail_presentation_clip_apply(
				request, self, _participant_capability,
				PresentationClipOperationRequest.ROLE_VISUAL,
				"visual definition fingerprint or sealed scene plan changed before claim",
			)
		return
	SignalBus.mark_presentation_clip_apply_ready(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _on_apply_requested(request: PresentationClipOperationRequest) -> void:
	if (
		_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
	):
		return
	var plan: Dictionary = _prepared_plans.get(request.get_instance_id(), {})
	_prepared_plans.erase(request.get_instance_id())
	if SignalBus.has_active_movie_projection():
		_release_plan(plan)
		SignalBus.fail_presentation_clip_apply(
			request,
			self,
			_participant_capability,
			PresentationClipOperationRequest.ROLE_VISUAL,
			"a movie claimed the mutually exclusive full-screen media surface during clip apply",
		)
		return
	if not _plan_is_installable(plan):
		_release_plan(plan)
		SignalBus.fail_presentation_clip_apply(
			request, self, _participant_capability,
			PresentationClipOperationRequest.ROLE_VISUAL,
			"visual definition fingerprint or sealed scene plan changed during claim",
		)
		return
	var request_id := request.get_request_id()
	var definition: PresentationClipDefinition = plan["definition"]
	var scene_root: Node = plan["scene_root"]
	var animation_player: AnimationPlayer = plan["animation_player"]
	var input_blocker := Control.new()
	input_blocker.name = "PresentationClipInputBlocker"
	input_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	input_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	input_blocker.visible = false
	add_child(input_blocker)
	var clip_viewport := SubViewport.new()
	clip_viewport.name = "PresentationClipSurface"
	clip_viewport.size = plan.get("viewport_size", Vector2i.ZERO)
	clip_viewport.transparent_bg = true
	clip_viewport.disable_3d = true
	clip_viewport.use_hdr_2d = false
	clip_viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	clip_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	clip_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	input_blocker.add_child(clip_viewport)
	var visual_group := CanvasGroup.new()
	visual_group.name = "PresentationClipVisual"
	visual_group.fit_margin = 0.0
	visual_group.clear_margin = 0.0
	clip_viewport.add_child(visual_group)
	visual_group.add_child(scene_root)
	_apply_clip_fit(
		visual_group,
		definition.logical_viewport_size,
		plan.get("viewport_size", Vector2i.ZERO),
		definition.fit_mode,
	)
	var particle_root := Node2D.new()
	particle_root.name = "PresentationClipParticles"
	visual_group.add_child(particle_root)
	var particle_projections := _install_particle_projections(
		plan.get("particle_schedules", []),
		particle_root,
		definition.logical_viewport_size,
		plan.get("viewport_size", Vector2i.ZERO),
		definition.fit_mode,
	)
	var material := ShaderMaterial.new()
	material.shader = load(TURN_SHADER_PATH) as Shader
	material.set_shader_parameter("clip_texture", clip_viewport.get_texture())
	material.set_shader_parameter("under_texture", plan.get("under_texture"))
	var projector := ColorRect.new()
	projector.name = "PresentationClipProjector"
	projector.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	projector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	projector.material = material
	input_blocker.add_child(projector)
	_claimed = {
		"request_id": request_id,
		"token": 0,
		"generation": 0,
		"definition": definition,
		"scene_root": scene_root,
		"animation_player": animation_player,
		"input_blocker": input_blocker,
		"clip_viewport": clip_viewport,
		"visual_group": visual_group,
		"particle_root": particle_root,
		"particle_projections": particle_projections,
		"projector": projector,
		"under_texture": plan.get("under_texture"),
		"material": material,
		"next_cue": 0,
		"state_projections": [],
		"phase": &"playing",
		"transition_tween": null,
		"definition_fingerprint": plan.get("definition_fingerprint", ""),
		"resource_bytes": int(plan.get("resource_bytes", 0)),
	}
	SignalBus.acknowledge_presentation_clip_apply(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _on_publish_readiness_requested(
	request: PresentationClipOperationRequest,
) -> void:
	if (
		_participant_capability == null
		or request == null
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
		or _claimed.is_empty()
		or int(_claimed.get("request_id", 0)) != request.get_request_id()
		or String(_claimed.get("definition_fingerprint", ""))
			!= _sealed_definition_fingerprint(request)
	):
		if request != null and not _claimed.is_empty():
			SignalBus.fail_presentation_clip_apply(
				request, self, _participant_capability,
				PresentationClipOperationRequest.ROLE_VISUAL,
				"visual definition fingerprint changed before final commit",
			)
		return
	SignalBus.mark_presentation_clip_publish_ready(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _run_presentation_clip_transaction_phase(
	request: PresentationClipOperationRequest,
	capability: RefCounted,
	phase: StringName,
) -> bool:
	var request_key := request.get_instance_id() if request != null else 0
	if (
		phase == &"abort"
		and request != null
		and capability == _participant_capability
		and _clip_transaction_is_current(request_key)
	):
		return _abort_presentation_clip_transaction(request_key)
	if (
		request == null
		or capability == null
		or capability != _participant_capability
		or not request.is_target(
			self, PresentationClipOperationRequest.ROLE_VISUAL)
	):
		return false
	match phase:
		&"hold":
			if (
				not _presentation_clip_transaction.is_empty()
				or _claimed.is_empty()
				or int(_claimed.get("request_id", 0)) != request.get_request_id()
				or String(_claimed.get("definition_fingerprint", ""))
					!= _sealed_definition_fingerprint(request)
			):
				SignalBus.fail_presentation_clip_apply(
					request, self, _participant_capability,
					PresentationClipOperationRequest.ROLE_VISUAL,
					"visual sealed definition changed before transaction hold",
				)
				return false
			_presentation_clip_transaction = {
				"request_key": request_key,
				"previous": _active,
				"committed": false,
			}
			return true
		&"commit":
			if not _clip_transaction_is_current(request_key):
				return false
			_active = _claimed
			_claimed = {}
			_generation += 1
			_active["generation"] = _generation
			_presentation_clip_transaction["committed"] = true
			return true
		&"finalize":
			return (
				_clip_transaction_is_current(request_key)
				and bool(_presentation_clip_transaction.get("committed", false))
			)
		&"publish":
			if (
				not _clip_transaction_is_current(request_key)
				or not bool(_presentation_clip_transaction.get("committed", false))
			):
				return false
			_prepare_active_publication(request)
			return _active_identity_is_current(
				request.get_request_id(), int(_active.get("generation", 0)))
		&"complete":
			if (
				not _clip_transaction_is_current(request_key)
				or not bool(_presentation_clip_transaction.get("committed", false))
			):
				return false
			var previous: Dictionary = _presentation_clip_transaction.get(
				"previous", {})
			_presentation_clip_transaction.clear()
			_retire_visual_record(previous, &"superseded", true)
			_complete_active_publication(request)
			return true
		&"abort":
			return _abort_presentation_clip_transaction(request_key)
	return false


func _sealed_definition(
	request: PresentationClipOperationRequest,
) -> PresentationClipDefinition:
	return SignalBus.presentation_clip_definition_for(
		request,
		self,
		_participant_capability,
		PresentationClipOperationRequest.ROLE_VISUAL,
	)


func _sealed_definition_fingerprint(
	request: PresentationClipOperationRequest,
) -> String:
	var definition := _sealed_definition(request)
	return definition.semantic_fingerprint() if definition != null else ""


func _prepare_active_publication(request: PresentationClipOperationRequest) -> void:
	if _active.is_empty():
		return
	var definition: PresentationClipDefinition = _active["definition"]
	var animation_player: AnimationPlayer = _active["animation_player"]
	var request_id := request.get_request_id()
	var generation := int(_active["generation"])
	animation_player.animation_finished.connect(
		_on_animation_finished.bind(request_id, generation), CONNECT_ONE_SHOT)
	animation_player.play(definition.animation_name)
	animation_player.advance(0.0)
	if not _active_identity_is_current(request_id, generation):
		return


func _complete_active_publication(request: PresentationClipOperationRequest) -> void:
	if _active.is_empty():
		return
	var definition: PresentationClipDefinition = _active["definition"]
	var animation_player: AnimationPlayer = _active["animation_player"]
	var request_id := request.get_request_id()
	var generation := int(_active["generation"])
	_project_active_particles(animation_player.current_animation_position)
	if not _active_identity_is_current(request_id, generation):
		return
	(_active["input_blocker"] as Control).visible = true
	if request.get_force_cut() and definition.skippable:
		_dispatch_due_cues(
			animation_player.get_animation(definition.animation_name).length,
			false,
		)
		if not _active_identity_is_current(request_id, generation):
			return
		animation_player.seek(
			animation_player.get_animation(definition.animation_name).length, true)
		if not _active_identity_is_current(request_id, generation):
			return
		_retire_active(&"completed")
		return
	_token_serial += 1
	_active["token"] = _token_serial
	SignalBus.presentation_clip_transition_receipt_started.emit(
		get_instance_id(), _token_serial, request_id, generation)
	if not _active_identity_is_current(request_id, generation):
		return
	set_process(true)
	_start_transition(false)
	if not _active_identity_is_current(request_id, generation):
		return
	_dispatch_due_cues(0.0)


func _clip_transaction_is_current(request_key: int) -> bool:
	return (
		request_key != 0
		and int(_presentation_clip_transaction.get("request_key", 0)) == request_key
	)


func _abort_presentation_clip_transaction(request_key: int = 0) -> bool:
	if _presentation_clip_transaction.is_empty():
		return true
	if request_key != 0 and not _clip_transaction_is_current(request_key):
		return false
	var transaction := _presentation_clip_transaction
	_presentation_clip_transaction = {}
	if bool(transaction.get("committed", false)):
		var rejected := _active
		_active = transaction.get("previous", {})
		_retire_visual_record(rejected, &"cancelled", false)
	else:
		_release_claimed()
	return true


func _process(_delta: float) -> void:
	if _active.is_empty():
		set_process(false)
		return
	var player: AnimationPlayer = _active.get("animation_player")
	if player == null or not is_instance_valid(player):
		_retire_active(&"cancelled")
		return
	var request_id := int(_active.get("request_id", 0))
	var generation := int(_active.get("generation", 0))
	_dispatch_due_cues(player.current_animation_position)
	if not _active_identity_is_current(request_id, generation):
		return
	_project_active_state_cues(player.current_animation_position)
	if not _active_identity_is_current(request_id, generation):
		return
	_project_active_particles(player.current_animation_position)


func _on_animation_finished(
	animation_name: StringName,
	request_id: int,
	generation: int,
) -> void:
	if not _active_identity_is_current(request_id, generation):
		return
	var definition: PresentationClipDefinition = _active["definition"]
	if animation_name != definition.animation_name:
		return
	_dispatch_due_cues(
		(_active["animation_player"] as AnimationPlayer).current_animation_length)
	if not _active_identity_is_current(request_id, generation):
		return
	_project_active_state_cues(
		(_active["animation_player"] as AnimationPlayer).current_animation_length)
	if not _active_identity_is_current(request_id, generation):
		return
	_project_active_particles(
		(_active["animation_player"] as AnimationPlayer).current_animation_length)
	if not _active_identity_is_current(request_id, generation):
		return
	_cut_particle_projections(_active, &"cut")
	if not _active_identity_is_current(request_id, generation):
		return
	if definition.exit_transition == &"turn" and definition.exit_duration > 0.0:
		_active["phase"] = &"exiting"
		_start_transition(true)
	else:
		_retire_active(&"completed")


func _start_transition(exiting: bool) -> void:
	if _active.is_empty():
		return
	var previous_tween := _active.get("transition_tween") as Tween
	if previous_tween != null and previous_tween.is_valid():
		previous_tween.kill()
	_active["transition_tween"] = null
	var definition: PresentationClipDefinition = _active["definition"]
	var kind := definition.exit_transition if exiting else definition.entry_transition
	var duration := definition.exit_duration if exiting else definition.entry_duration
	var material: ShaderMaterial = _active["material"]
	material.set_shader_parameter("exiting", exiting)
	material.set_shader_parameter("progress", 1.0 if kind == &"cut" else 0.0)
	if kind == &"cut" or duration <= 0.0:
		if exiting:
			_retire_active(&"completed")
		return
	var request_id := int(_active["request_id"])
	var generation := int(_active["generation"])
	var tween := create_tween()
	_active["transition_tween"] = tween
	tween.tween_method(
		func(value: float) -> void:
			if _active_identity_is_current(request_id, generation):
				material.set_shader_parameter("progress", value),
		0.0,
		1.0,
		duration,
	)
	tween.finished.connect(
		func() -> void:
			if not _active_identity_is_current(request_id, generation):
				return
			_active["transition_tween"] = null
			if exiting:
				_retire_active(&"completed"),
		CONNECT_ONE_SHOT,
	)


func _dispatch_due_cues(position: float, include_audio: bool = true) -> void:
	if _active.is_empty() or StringName(_active.get("phase")) != &"playing":
		return
	var request_id := int(_active.get("request_id", 0))
	var generation := int(_active.get("generation", 0))
	var definition: PresentationClipDefinition = _active["definition"]
	var next_cue := int(_active.get("next_cue", 0))
	while (
		next_cue < definition.cues.size()
		and definition.cues[next_cue].offset_seconds <= position + 0.000001
	):
		var cue: PresentationClipCue = definition.cues[next_cue]
		var claimed_ordinal := next_cue
		next_cue += 1
		_active["next_cue"] = next_cue
		if cue is PresentationClipAudioCue or cue is PresentationClipAudioChoiceCue:
			if include_audio:
				SignalBus.presentation_clip_audio_cue_requested.emit(
					request_id, claimed_ordinal, generation)
		elif cue is PresentationClipStateCue:
			var state_cue := cue as PresentationClipStateCue
			var scene_root: Node = _active["scene_root"]
			var player := scene_root.get_node(
				state_cue.animation_player_path) as AnimationPlayer
			var projections: Array = _active.get("state_projections", [])
			for projection_index in range(projections.size() - 1, -1, -1):
				if (
					(projections[projection_index] as Dictionary).get("player")
					== player
				):
					projections.remove_at(projection_index)
			projections.append({
				"player": player,
				"animation_name": state_cue.animation_name,
				"offset_seconds": state_cue.offset_seconds,
				"ordinal": claimed_ordinal,
			})
			_active["state_projections"] = projections
			player.callback_mode_process = (
				AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL)
			player.play(state_cue.animation_name)
			if not _active_identity_is_current(request_id, generation):
				return
			_project_state_record(
				projections.back() as Dictionary, position)
		if not _active_identity_is_current(request_id, generation):
			return


func _project_active_state_cues(position: float) -> void:
	if _active.is_empty():
		return
	var request_id := int(_active.get("request_id", 0))
	var generation := int(_active.get("generation", 0))
	for projection_value: Variant in (
		_active.get("state_projections", []) as Array):
		_project_state_record(projection_value as Dictionary, position)
		if not _active_identity_is_current(request_id, generation):
			return


func _project_state_record(projection: Dictionary, position: float) -> void:
	var player: AnimationPlayer = projection.get("player")
	var animation_name := StringName(projection.get("animation_name"))
	if (
		player == null
		or not is_instance_valid(player)
		or not player.has_animation(animation_name)
	):
		return
	var animation := player.get_animation(animation_name)
	var local_position := maxf(
		0.0, position - float(projection.get("offset_seconds", 0.0)))
	if animation.length > 0.0:
		if animation.loop_mode == Animation.LOOP_NONE:
			local_position = minf(local_position, animation.length)
		else:
			local_position = fposmod(local_position, animation.length)
	player.seek(local_position, true)


func _install_particle_projections(
	schedule_values: Variant,
	particle_root: Node2D,
	logical_size: Vector2i,
	target_size: Vector2i,
	fit_mode: StringName,
) -> Array[Dictionary]:
	var projections: Array[Dictionary] = []
	var fit := _clip_fit_transform(logical_size, target_size, fit_mode)
	var schedule_array: Array = schedule_values as Array
	for schedule_value: Variant in schedule_array:
		var schedule := (schedule_value as Dictionary).duplicate(true)
		var material := ShaderMaterial.new()
		material.shader = _particle_shader_for(
			StringName(schedule.get("blend_mode", &"mix")))
		var mask_mode := StringName(schedule.get("mask_mode", &"none"))
		material.set_shader_parameter("use_mask", mask_mode != &"none")
		material.set_shader_parameter("inverse_mask", mask_mode == &"inverse_alpha")
		material.set_shader_parameter(
			"linear_mask", schedule.get("mask_filter", &"linear") == &"linear")
		material.set_shader_parameter(
			"mask_texture_nearest", schedule.get("mask_texture"))
		material.set_shader_parameter(
			"mask_texture_linear", schedule.get("mask_texture"))
		var mask_rect: Rect2 = schedule.get("mask_rect", Rect2())
		material.set_shader_parameter("mask_rect", Vector4(
			mask_rect.position.x,
			mask_rect.position.y,
			mask_rect.size.x,
			mask_rect.size.y,
		))
		material.set_shader_parameter("target_size", Vector2(target_size))
		material.set_shader_parameter("fit_scale", fit.get("scale", Vector2.ONE))
		material.set_shader_parameter("fit_offset", fit.get("offset", Vector2.ZERO))
		var texture := schedule.get("texture") as Texture2D
		var quad := QuadMesh.new()
		quad.size = Vector2(texture.get_size())
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_2D
		multimesh.use_colors = true
		multimesh.mesh = quad
		multimesh.instance_count = int(schedule.get("maximum_live_particles", 0))
		multimesh.visible_instance_count = 0
		var instance := MultiMeshInstance2D.new()
		instance.name = "ParticleLayer_%s" % String(schedule.get("id", "layer"))
		instance.multimesh = multimesh
		instance.texture = texture
		instance.z_as_relative = false
		instance.z_index = int(schedule.get("z_index", 0))
		instance.material = material
		instance.texture_filter = (
			CanvasItem.TEXTURE_FILTER_LINEAR
			if schedule.get("texture_filter", &"linear") == &"linear"
			else CanvasItem.TEXTURE_FILTER_NEAREST
		)
		particle_root.add_child(instance)
		schedule["instance"] = instance
		schedule["multimesh"] = multimesh
		projections.append(schedule)
	return projections


func _particle_shader_for(blend_mode: StringName) -> Shader:
	match blend_mode:
		&"add":
			return PARTICLE_ADD_SHADER
		&"sub":
			return PARTICLE_SUB_SHADER
		&"mul":
			return PARTICLE_MUL_SHADER
	return PARTICLE_MIX_SHADER


func _project_active_particles(position: float) -> void:
	if _active.is_empty():
		return
	for projection_value: Variant in (
		_active.get("particle_projections", []) as Array):
		_project_particle_layer(projection_value as Dictionary, position)


func _project_particle_layer(projection: Dictionary, position: float) -> void:
	var multimesh := projection.get("multimesh") as MultiMesh
	if multimesh == null:
		return
	if bool(projection.get("teardown_cut_done", false)):
		return
	var spawn_times: PackedFloat64Array = projection.get(
		"spawn_times", PackedFloat64Array())
	var lifetime_seconds := float(projection.get("lifetime_seconds", 0.0))
	var first_alive := _upper_bound_particle_spawn_times(
		spawn_times, position - lifetime_seconds + 0.000001)
	var after_last_alive := _upper_bound_particle_spawn_times(
		spawn_times, position + 0.000001)
	var visible_count := mini(
		after_last_alive - first_alive,
		int(projection.get("maximum_live_particles", 0)),
	)
	var spawn_x: PackedFloat64Array = projection.get(
		"spawn_x", PackedFloat64Array())
	var spawn_y: PackedFloat64Array = projection.get(
		"spawn_y", PackedFloat64Array())
	var motion_scales: PackedFloat64Array = projection.get(
		"motion_scales", PackedFloat64Array())
	var initial_scales: PackedFloat64Array = projection.get(
		"initial_scales", PackedFloat64Array())
	var initial_rotations: PackedFloat64Array = projection.get(
		"initial_rotations", PackedFloat64Array())
	var texture := projection.get("texture") as Texture2D
	var texture_center := Vector2(texture.get_size()) * 0.5
	var origin: Vector2 = projection.get("origin", Vector2.ZERO)
	var authored_color: Color = projection.get("color", Color.WHITE)
	for slot_index in range(visible_count):
		var event_index := first_alive + slot_index
		var spawn_time := spawn_times[event_index]
		var normalized_life := clampf(
			(position - spawn_time) / lifetime_seconds, 0.0, 1.0)
		var offset_motion := _sample_particle_motion(
			projection.get("offset_motion_keys", PackedVector3Array()),
			normalized_life,
		)
		var scaled_motion := _sample_particle_motion(
			projection.get("scaled_motion_keys", PackedVector3Array()),
			normalized_life,
		)
		var opacity := _sample_particle_scalar(
			projection.get("opacity_keys", PackedVector2Array()), normalized_life)
		var scale_value := _sample_particle_scalar(
			projection.get("scale_keys", PackedVector2Array()), normalized_life)
		var rotation_value := _sample_particle_scalar(
			projection.get("rotation_keys", PackedVector2Array()), normalized_life)
		var scale_factor := initial_scales[event_index] * scale_value
		var rotation := initial_rotations[event_index] + rotation_value
		var position_value := Vector2(
			spawn_x[event_index], spawn_y[event_index]) + (
			offset_motion + scaled_motion * motion_scales[event_index])
		var pivot_offset := (texture_center - origin) * scale_factor
		var transform := Transform2D(
			rotation,
			Vector2.ONE * scale_factor,
			0.0,
			position_value + pivot_offset.rotated(rotation),
		)
		multimesh.set_instance_transform_2d(slot_index, transform)
		multimesh.set_instance_color(slot_index, Color(
			authored_color.r,
			authored_color.g,
			authored_color.b,
			authored_color.a * opacity,
		))
	multimesh.visible_instance_count = visible_count
	var instance := projection.get("instance") as MultiMeshInstance2D
	if instance != null and is_instance_valid(instance):
		instance.visible = visible_count > 0


## Synchronously clears clip-owned particle instances before their visual owner
## is hidden or queued for deletion.  The sealed projection dictionary carries
## the idempotence marker, so main-end cut and a later owner retirement cannot
## clear the same pool twice.
func _cut_particle_projections(
	record: Dictionary,
	required_policy: StringName = &"",
) -> void:
	for projection_value: Variant in (
		record.get("particle_projections", []) as Array):
		var projection := projection_value as Dictionary
		if (
			not required_policy.is_empty()
			and StringName(projection.get(
				"teardown_policy", &"fully_contained")) != required_policy
		):
			continue
		if bool(projection.get("teardown_cut_done", false)):
			continue
		projection["teardown_cut_done"] = true
		var multimesh := projection.get("multimesh") as MultiMesh
		if multimesh != null:
			multimesh.visible_instance_count = 0
		var instance := projection.get("instance") as MultiMeshInstance2D
		if instance != null and is_instance_valid(instance):
			instance.visible = false


func _upper_bound_particle_spawn_times(
	spawn_times: PackedFloat64Array,
	value: float,
) -> int:
	var low := 0
	var high := spawn_times.size()
	while low < high:
		var middle := low + int((high - low) / 2)
		if spawn_times[middle] <= value:
			low = middle + 1
		else:
			high = middle
	return low


func _sample_particle_motion(keys: PackedVector3Array, t: float) -> Vector2:
	if keys.is_empty():
		return Vector2.ZERO
	for key_index in range(1, keys.size()):
		var right := keys[key_index]
		if t <= right.x:
			var left := keys[key_index - 1]
			var weight := inverse_lerp(left.x, right.x, t)
			return Vector2(left.y, left.z).lerp(
				Vector2(right.y, right.z), weight)
	var last := keys[keys.size() - 1]
	return Vector2(last.y, last.z)


func _sample_particle_scalar(keys: PackedVector2Array, t: float) -> float:
	if keys.is_empty():
		return 0.0
	for key_index in range(1, keys.size()):
		var right := keys[key_index]
		if t <= right.x:
			var left := keys[key_index - 1]
			return lerpf(left.y, right.y, inverse_lerp(left.x, right.x, t))
	return keys[keys.size() - 1].y


func _on_finish_requested(request_id: int) -> void:
	_finish_active_input_request(request_id)


## SignalBus invokes this callable only through the exact Runtime registry
## capability. Returning true claims one physical input boundary and completes
## the active skippable projection before its caller may advance dialogue.
func _claim_active_input_finish(
	request_id: int,
	capability: RefCounted,
) -> bool:
	if capability == null or capability != _participant_capability:
		return false
	return _finish_active_input_request(request_id)


func _finish_active_input_request(request_id: int) -> bool:
	if _active.is_empty() or int(_active.get("request_id", 0)) != request_id:
		return false
	var definition: PresentationClipDefinition = _active["definition"]
	if not definition.skippable:
		# An unskippable modal clip still owns the physical input boundary; it
		# consumes the event without completing or advancing content behind it.
		return true
	var player: AnimationPlayer = _active["animation_player"]
	var generation := int(_active.get("generation", 0))
	_dispatch_due_cues(player.current_animation_length, false)
	if not _active_identity_is_current(request_id, generation):
		return true
	_project_active_state_cues(player.current_animation_length)
	if not _active_identity_is_current(request_id, generation):
		return true
	player.seek(player.current_animation_length, true)
	if not _active_identity_is_current(request_id, generation):
		return true
	_retire_active(&"completed")
	return true


func _on_projection_reset_requested(_epoch: int) -> void:
	_release_all_prepared()
	_release_claimed()
	_retire_active(&"cancelled")


func _on_request_settled(request: PresentationClipOperationRequest) -> void:
	if request == null:
		return
	var plan: Dictionary = _prepared_plans.get(request.get_instance_id(), {})
	_prepared_plans.erase(request.get_instance_id())
	_release_plan(plan)
	if (
		not _claimed.is_empty()
		and int(_claimed.get("request_id", 0)) == request.get_request_id()
	):
		_release_claimed()


func _retire_active(outcome: StringName) -> void:
	if _active.is_empty():
		return
	var active := _active
	_active = {}
	set_process(false)
	_generation += 1
	_retire_visual_record(active, outcome, true)


func _retire_visual_record(
	record: Dictionary,
	outcome: StringName,
	emit_lifecycle: bool,
) -> void:
	if record.is_empty():
		return
	_cut_particle_projections(record)
	var tween: Tween = record.get("transition_tween")
	if tween != null and tween.is_valid():
		tween.kill()
	var animation_player: AnimationPlayer = record.get("animation_player")
	if animation_player != null and is_instance_valid(animation_player):
		animation_player.stop()
	var input_blocker: Control = record.get("input_blocker")
	if input_blocker != null and is_instance_valid(input_blocker):
		input_blocker.queue_free()
	_release_reserved_resource_bytes(int(record.get("resource_bytes", 0)))
	if not emit_lifecycle:
		return
	var request_id := int(record.get("request_id", 0))
	var token := int(record.get("token", 0))
	SignalBus.presentation_clip_retire_requested.emit(
		request_id,
		int(record.get("generation", 0)),
		outcome,
	)
	if request_id > 0 and token > 0:
		SignalBus.presentation_clip_transition_terminal.emit(
			get_instance_id(),
			token,
			request_id,
			int(record.get("generation", 0)),
			outcome,
		)


func _release_claimed() -> void:
	if _claimed.is_empty():
		return
	var claimed := _claimed
	_claimed = {}
	_retire_visual_record(claimed, &"cancelled", false)


func _prepare_plan(definition: PresentationClipDefinition) -> Dictionary:
	if definition == null:
		return {"valid": false, "error": "clip definition was not prepared"}
	var definition_errors := definition.validation_errors()
	if not definition_errors.is_empty():
		return {"valid": false, "error": String(definition_errors[0])}
	if not _definition_resource_scripts_are_exact(definition):
		return {
			"valid": false,
			"error": (
				"clip definition, cues, audio-choice candidates, and particle layers "
				+ "must use exact Stella Resource scripts"),
		}
	if (
		not definition.resource_path.is_empty()
		and (
			definition.scene.resource_path.is_empty()
			or definition.scene.resource_path.get_extension().to_lower() != "tscn"
		)
	):
		return {
			"valid": false,
			"error": "clip definition must reference an inspectable .tscn scene",
		}
	var packed_scene_result := _validate_packed_scene_state_model(
		definition.scene, {}, {"visits": 0, "node_entries": 0})
	var packed_scene_error := String(packed_scene_result.get("error", ""))
	if not packed_scene_error.is_empty():
		return {"valid": false, "error": packed_scene_error}
	var expected_node_count := (
		packed_scene_result.get("paths", {}) as Dictionary).size()
	var scene_root := definition.scene.instantiate()
	if scene_root == null:
		return {"valid": false, "error": "clip scene could not be instantiated"}
	var node_count := _count_nodes(scene_root)
	if node_count > PresentationClipDefinition.MAX_SCENE_NODES:
		scene_root.free()
		return {"valid": false, "error": "clip scene exceeds the 512-node budget"}
	if node_count != expected_node_count:
		scene_root.free()
		return {
			"valid": false,
			"error": (
				"clip SceneState node reservation did not match the detached instance"
			),
		}
	var scene_contract_error := _validate_scene_contract(scene_root)
	if not scene_contract_error.is_empty():
		scene_root.free()
		return {"valid": false, "error": scene_contract_error}
	var animation_player := scene_root.get_node_or_null(
		definition.animation_player_path) as AnimationPlayer
	if animation_player == null:
		scene_root.free()
		return {"valid": false, "error": "clip animation_player_path is unavailable"}
	if not animation_player.has_animation(definition.animation_name):
		scene_root.free()
		return {"valid": false, "error": "clip animation_name is unavailable"}
	var animation := animation_player.get_animation(definition.animation_name)
	if animation.length <= 0.0 or animation.length > PresentationClipDefinition.MAX_DURATION_SECONDS:
		scene_root.free()
		return {"valid": false, "error": "clip animation length must be in 0..120 seconds"}
	if animation.length < definition.entry_duration:
		scene_root.free()
		return {
			"valid": false,
			"error": "clip main animation must not be shorter than its entry transition",
		}
	if animation.loop_mode != Animation.LOOP_NONE:
		scene_root.free()
		return {"valid": false, "error": "clip main animation must not loop"}
	if animation_player.speed_scale != 1.0:
		scene_root.free()
		return {
			"valid": false,
			"error": "clip main AnimationPlayer speed_scale must be exactly 1.0",
		}
	var main_animation_error := _validate_visual_animation(
		animation, "main animation", animation_player, scene_root)
	if not main_animation_error.is_empty():
		scene_root.free()
		return {"valid": false, "error": main_animation_error}
	for cue_index in range(definition.cues.size()):
		var cue: PresentationClipCue = definition.cues[cue_index]
		if cue.offset_seconds > animation.length:
			scene_root.free()
			return {
				"valid": false,
				"error": _cue_diagnostic(
					definition, "cues", cue_index, cue,
					"offset exceeds clip duration"),
			}
		if not cue is PresentationClipStateCue:
			continue
		var state_cue := cue as PresentationClipStateCue
		var state_player := scene_root.get_node_or_null(
			state_cue.animation_player_path) as AnimationPlayer
		if (
			state_player == null
			or not state_player.has_animation(state_cue.animation_name)
		):
			scene_root.free()
			return {
				"valid": false,
				"error": _cue_diagnostic(
					definition, "cues", cue_index, cue,
					"named animation target is unavailable"),
			}
		if state_player == animation_player:
			scene_root.free()
			return {
				"valid": false,
				"error": _cue_diagnostic(
					definition, "cues", cue_index, cue,
					"named state cue must not target the bounded main AnimationPlayer"),
			}
		if state_player.speed_scale != 1.0:
			scene_root.free()
			return {
				"valid": false,
				"error": _cue_diagnostic(
					definition, "cues", cue_index, cue,
					"named state AnimationPlayer speed_scale must be exactly 1.0"),
			}
		var state_animation_error := _validate_visual_animation(
			state_player.get_animation(state_cue.animation_name),
			"named state cue[%d] animation" % cue_index,
			state_player,
			scene_root,
		)
		if not state_animation_error.is_empty():
			scene_root.free()
			return {
				"valid": false,
				"error": _cue_diagnostic(
					definition, "cues", cue_index, cue,
					state_animation_error),
			}
	var particle_result := _seal_particle_schedules(definition, animation.length)
	if not bool(particle_result.get("valid", false)):
		scene_root.free()
		return {
			"valid": false,
			"error": String(particle_result.get(
				"error", "particle schedule could not be sealed")),
		}
	var actual_viewport_size := _preflight_viewport_size()
	var actual_viewport_pixels := (
		actual_viewport_size.x * actual_viewport_size.y)
	var logical_viewport_pixels := (
		definition.logical_viewport_size.x * definition.logical_viewport_size.y)
	if (
		actual_viewport_pixels <= 0
		or actual_viewport_pixels > StellaRuntime.presentation_clip_max_viewport_pixels
		or logical_viewport_pixels > StellaRuntime.presentation_clip_max_viewport_pixels
	):
		scene_root.free()
		return {
			"valid": false,
			"error": "clip logical or target viewport exceeds the configured pixel budget",
		}
	var visited_resources: Dictionary = {}
	var texture_bytes := _estimate_variant_texture_bytes(
		scene_root, visited_resources)
	texture_bytes += _estimate_variant_texture_bytes(
		definition.particle_layers, visited_resources)
	var transition_surface_bytes := actual_viewport_pixels * 4 * 2
	var particle_event_bytes := int(particle_result.get("event_bytes", 0))
	var particle_instance_bytes := int(particle_result.get("instance_bytes", 0))
	var particle_layer_owner_bytes := int(particle_result.get("layer_owner_bytes", 0))
	var particle_curve_bytes := int(particle_result.get("curve_bytes", 0))
	var resource_bytes := (
		texture_bytes
		+ transition_surface_bytes
		+ particle_event_bytes
		+ particle_instance_bytes
		+ particle_layer_owner_bytes
		+ particle_curve_bytes
	)
	if (
		resource_bytes <= 0
		or resource_bytes > StellaRuntime.presentation_clip_resource_budget_bytes
		or _reserved_resource_bytes + resource_bytes
			> StellaRuntime.presentation_clip_resource_budget_bytes
	):
		scene_root.free()
		return {
			"valid": false,
			"error": (
				"clip textures, transition surfaces, and particle work exceed the configured resource budget"),
		}
	_reserved_resource_bytes += resource_bytes
	return {
		"valid": true,
		"definition": definition,
		"scene_root": scene_root,
		"animation_player": animation_player,
		"definition_fingerprint": definition.semantic_fingerprint(),
		"viewport_size": actual_viewport_size,
		"particle_schedules": particle_result.get("schedules", []),
		"particle_event_bytes": particle_event_bytes,
		"particle_instance_bytes": particle_instance_bytes,
		"particle_layer_owner_bytes": particle_layer_owner_bytes,
		"particle_curve_bytes": particle_curve_bytes,
		"resource_bytes": resource_bytes,
	}


func _seal_particle_schedules(
	definition: PresentationClipDefinition,
	animation_length: float,
) -> Dictionary:
	var schedules: Array[Dictionary] = []
	var total_events := 0
	var total_instances := 0
	var total_curve_keys := 0
	for layer_index in range(definition.particle_layers.size()):
		var layer: PresentationClipParticleLayer = definition.particle_layers[layer_index]
		var projected_rect := _particle_projected_rect(layer)
		if not layer.projection_bounds.encloses(projected_rect):
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"projection_bounds do not enclose the conservative particle extent"),
			}
		var event_arrays := _seal_particle_event_arrays(layer, layer_index)
		var spawn_times: PackedFloat64Array = event_arrays.get(
			"spawn_times", PackedFloat64Array())
		if spawn_times.is_empty():
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"emission schedule resolves to no spawn events"),
			}
		if spawn_times.size() > PresentationClipParticleLayer.MAX_SPAWN_EVENTS:
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"sealed emission schedule exceeds the 8192-event limit"),
			}
		if spawn_times[spawn_times.size() - 1] > animation_length + 0.000001:
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"last sealed spawn exceeds the bounded main animation"),
			}
		if (
			layer.teardown_policy == &"fully_contained"
			and spawn_times[spawn_times.size() - 1] + layer.lifetime_seconds
			> animation_length + 0.000001
		):
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"last sealed spawn plus lifetime exceeds the bounded main animation"),
			}
		var maximum_live := _maximum_simultaneous_particle_events(
			spawn_times, layer.lifetime_seconds)
		if maximum_live > layer.maximum_live_particles:
			return {
				"valid": false,
				"error": _particle_diagnostic(
					definition, layer_index, layer,
					"sealed schedule exceeds maximum_live_particles"),
			}
		var curve_key_count := (
			layer.offset_motion_keys.size()
			+ layer.scaled_motion_keys.size()
			+ layer.opacity_keys.size()
			+ layer.scale_keys.size()
			+ layer.rotation_keys.size()
		)
		schedules.append({
			"ordinal": layer_index,
			"id": layer.id,
			"texture": layer.texture,
			"texture_filter": layer.texture_filter,
			"mask_texture": layer.mask_texture,
			"mask_filter": layer.mask_filter,
			"mask_rect": layer.mask_rect,
			"mask_mode": layer.mask_mode,
			"blend_mode": layer.blend_mode,
			"z_index": layer.z_index,
			"color": layer.color,
			"origin": layer.origin,
			"lifetime_seconds": layer.lifetime_seconds,
			"maximum_live_particles": layer.maximum_live_particles,
			"teardown_policy": layer.teardown_policy,
			"projection_bounds": layer.projection_bounds,
			"offset_motion_keys": layer.offset_motion_keys.duplicate(),
			"scaled_motion_keys": layer.scaled_motion_keys.duplicate(),
			"opacity_keys": layer.opacity_keys.duplicate(),
			"scale_keys": layer.scale_keys.duplicate(),
			"rotation_keys": layer.rotation_keys.duplicate(),
			"spawn_times": spawn_times,
			"spawn_x": event_arrays.get("spawn_x", PackedFloat64Array()),
			"spawn_y": event_arrays.get("spawn_y", PackedFloat64Array()),
			"motion_scales": event_arrays.get(
				"motion_scales", PackedFloat64Array()),
			"initial_scales": event_arrays.get(
				"initial_scales", PackedFloat64Array()),
			"initial_rotations": event_arrays.get(
				"initial_rotations", PackedFloat64Array()),
		})
		total_events += spawn_times.size()
		total_instances += layer.maximum_live_particles
		total_curve_keys += curve_key_count
	return {
		"valid": true,
		"schedules": schedules,
		"event_bytes": total_events * PARTICLE_EVENT_RESERVATION_BYTES,
		"instance_bytes": total_instances * PARTICLE_INSTANCE_RESERVATION_BYTES,
		"layer_owner_bytes": (
			schedules.size() * PARTICLE_LAYER_OWNER_RESERVATION_BYTES),
		"curve_bytes": total_curve_keys * PARTICLE_CURVE_KEY_BYTES,
	}


func _seal_particle_event_arrays(
	layer: PresentationClipParticleLayer,
	layer_ordinal: int,
) -> Dictionary:
	var spawn_times := PackedFloat64Array()
	if layer.emission_mode == &"burst":
		var count_range := layer.burst_count_max - layer.burst_count_min + 1
		var burst_count := layer.burst_count_min + mini(
			count_range - 1,
			int(floor(_particle_unit(layer.seed, layer_ordinal, 0, 0) * count_range)),
		)
		for _ordinal in range(burst_count):
			spawn_times.append(layer.emission_start_seconds)
	else:
		var spawn_time := layer.emission_start_seconds
		for ordinal in range(PresentationClipParticleLayer.MAX_SPAWN_EVENTS):
			var interval_seconds := lerpf(
				1.0 / layer.spawn_rate_min,
				1.0 / layer.spawn_rate_max,
				_particle_unit(layer.seed, layer_ordinal, ordinal, 0),
			)
			spawn_time += interval_seconds
			if spawn_time > layer.emission_end_seconds + 0.000001:
				break
			spawn_times.append(spawn_time)
	var spawn_x := PackedFloat64Array()
	var spawn_y := PackedFloat64Array()
	var motion_scales := PackedFloat64Array()
	var initial_scales := PackedFloat64Array()
	var initial_rotations := PackedFloat64Array()
	for ordinal in range(spawn_times.size()):
		var spawn_position := layer.spawn_rect.position + Vector2(
			layer.spawn_rect.size.x * _particle_unit(
				layer.seed, layer_ordinal, ordinal, 1),
			layer.spawn_rect.size.y * _particle_unit(
				layer.seed, layer_ordinal, ordinal, 2),
		)
		spawn_x.append(spawn_position.x)
		spawn_y.append(spawn_position.y)
		motion_scales.append(lerpf(
				layer.motion_scale_min,
				layer.motion_scale_max,
				_particle_unit(layer.seed, layer_ordinal, ordinal, 3),
			))
		initial_scales.append(lerpf(
				layer.initial_scale_min,
				layer.initial_scale_max,
				_particle_unit(layer.seed, layer_ordinal, ordinal, 4),
			))
		initial_rotations.append(lerpf(
				layer.initial_rotation_min,
				layer.initial_rotation_max,
				_particle_unit(layer.seed, layer_ordinal, ordinal, 5),
			))
	return {
		"spawn_times": spawn_times,
		"spawn_x": spawn_x,
		"spawn_y": spawn_y,
		"motion_scales": motion_scales,
		"initial_scales": initial_scales,
		"initial_rotations": initial_rotations,
	}


func _particle_unit(
	seed: int,
	layer_ordinal: int,
	spawn_ordinal: int,
	channel: int,
) -> float:
	var value := seed & 0x7fffffff
	for component: int in [layer_ordinal + 1, spawn_ordinal + 1, channel + 1]:
		value = int((value * 1103515245 + component * 12345 + 1013904223)
			& 0x7fffffff)
	return float(value) / PARTICLE_HASH_DENOMINATOR


func _maximum_simultaneous_particle_events(
	spawn_times: PackedFloat64Array,
	lifetime_seconds: float,
) -> int:
	var left := 0
	var maximum_live := 0
	for right in range(spawn_times.size()):
		var spawn_time := spawn_times[right]
		while (
			left <= right
			and spawn_times[left] + lifetime_seconds
				<= spawn_time + 0.000001
		):
			left += 1
		maximum_live = maxi(maximum_live, right - left + 1)
	return maximum_live


func _particle_projected_rect(layer: PresentationClipParticleLayer) -> Rect2:
	var offset_motion_min := Vector2(INF, INF)
	var offset_motion_max := Vector2(-INF, -INF)
	for key: Vector3 in layer.offset_motion_keys:
		var authored_motion := Vector2(key.y, key.z)
		offset_motion_min = offset_motion_min.min(authored_motion)
		offset_motion_max = offset_motion_max.max(authored_motion)
	var scaled_motion_min := Vector2(INF, INF)
	var scaled_motion_max := Vector2(-INF, -INF)
	for key: Vector3 in layer.scaled_motion_keys:
		var authored_motion := Vector2(key.y, key.z)
		for motion_scale: float in [layer.motion_scale_min, layer.motion_scale_max]:
			var scaled := authored_motion * motion_scale
			scaled_motion_min = scaled_motion_min.min(scaled)
			scaled_motion_max = scaled_motion_max.max(scaled)
	var center_min := (
		layer.spawn_rect.position + offset_motion_min + scaled_motion_min)
	var center_max := (
		layer.spawn_rect.end + offset_motion_max + scaled_motion_max)
	var texture_size := Vector2(layer.texture.get_size())
	var corner_radius := 0.0
	for corner: Vector2 in [
		-layer.origin,
		Vector2(texture_size.x, 0.0) - layer.origin,
		Vector2(0.0, texture_size.y) - layer.origin,
		texture_size - layer.origin,
	]:
		corner_radius = maxf(corner_radius, corner.length())
	var curve_scale_max := 0.0
	for key: Vector2 in layer.scale_keys:
		curve_scale_max = maxf(curve_scale_max, key.y)
	var radius := corner_radius * layer.initial_scale_max * curve_scale_max
	return Rect2(
		center_min - Vector2.ONE * radius,
		(center_max - center_min) + Vector2.ONE * radius * 2.0,
	)


func _plan_is_installable(plan: Dictionary) -> bool:
	if plan.is_empty() or not bool(plan.get("valid", false)):
		return false
	var definition: PresentationClipDefinition = plan.get("definition")
	var scene_root: Node = plan.get("scene_root")
	var animation_player: AnimationPlayer = plan.get("animation_player")
	var under_texture: Texture2D = plan.get("under_texture")
	var viewport_size: Vector2i = plan.get("viewport_size", Vector2i.ZERO)
	return (
		definition != null
		and scene_root != null
		and is_instance_valid(scene_root)
		and not scene_root.is_inside_tree()
		and animation_player != null
		and is_instance_valid(animation_player)
		and under_texture != null
		and under_texture.get_size() == Vector2(viewport_size)
		and scene_root.is_ancestor_of(animation_player)
		and animation_player.has_animation(definition.animation_name)
		and String(plan.get("definition_fingerprint", ""))
			== definition.semantic_fingerprint()
	)


func _attach_under_snapshot(plan: Dictionary) -> String:
	var viewport_size: Vector2i = plan.get("viewport_size", Vector2i.ZERO)
	var viewport := get_viewport()
	if viewport == null or viewport_size.x <= 0 or viewport_size.y <= 0:
		return "clip target viewport is unavailable for the sealed under snapshot"
	# A renderer-less headless process has no framebuffer by definition. Its
	# deterministic transparent canvas is still a sealed surface for lifecycle,
	# budget, and export validation; graphical backends must supply real pixels.
	var image := (
		Image.create(viewport_size.x, viewport_size.y, false, Image.FORMAT_RGBA8)
		if DisplayServer.get_name() == "headless"
		else viewport.get_texture().get_image()
	)
	if image == null or image.is_empty() or image.get_size() != viewport_size:
		return "clip target viewport could not provide the exact sealed under snapshot"
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(image)
	if texture == null or texture.get_size() != Vector2(viewport_size):
		return "clip sealed under snapshot texture could not be allocated"
	plan["under_texture"] = texture
	return ""


func _release_all_prepared() -> void:
	var plans := _prepared_plans.values()
	_prepared_plans.clear()
	for plan_value: Variant in plans:
		_release_plan(plan_value as Dictionary)


func _release_plan(plan: Dictionary) -> void:
	if plan.is_empty():
		return
	var scene_root: Node = plan.get("scene_root")
	if scene_root != null and is_instance_valid(scene_root):
		if scene_root.is_inside_tree():
			scene_root.queue_free()
		else:
			scene_root.free()
	_release_reserved_resource_bytes(int(plan.get("resource_bytes", 0)))


func _release_reserved_resource_bytes(resource_bytes: int) -> void:
	if resource_bytes <= 0:
		return
	_reserved_resource_bytes = maxi(0, _reserved_resource_bytes - resource_bytes)


func _resolve_definition_result(asset: String) -> Dictionary:
	if not PresentationClipDefinition.is_logical_id(asset):
		return {
			"definition": null,
			"error": "clip logical id '%s' is not canonical" % asset,
		}
	var expected_paths := PackedStringArray()
	for extension: String in ["tres"]:
		var path := "%s%s.%s" % [StellaRuntime.presentation_clips_path, asset, extension]
		expected_paths.append(path)
		if not ResourceLoader.exists(path):
			continue
		var dependency_error := _validate_definition_dependencies(path)
		if not dependency_error.is_empty():
			return {
				"definition": null,
				"error": "clip logical id '%s' at '%s': %s" % [
					asset, path, dependency_error,
				],
			}
		var resource := ResourceLoader.load(
			path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if resource is PresentationClipDefinition:
			if not _definition_resource_scripts_are_exact(resource):
				return {
					"definition": null,
					"error": (
						("clip logical id '%s' at '%s' must use exact Stella definition, "
						+ "cue, audio-choice-candidate, and particle-layer Resource scripts")
						% [asset, path]),
				}
			return {"definition": resource, "error": ""}
		return {
			"definition": null,
			"error": (
				"clip logical id '%s' resolved to '%s', but that Resource is not a PresentationClipDefinition"
				% [asset, path]),
		}
	return {
		"definition": null,
		"error": (
			"clip logical id '%s' was not found under configured presentation_clips root '%s' (checked %s)"
			% [asset, StellaRuntime.presentation_clips_path, ", ".join(expected_paths)]),
	}


func _validate_definition_dependencies(path: String) -> String:
	if path.get_extension().to_lower() != "tres":
		return "clip definitions must use inspectable .tres resources"
	var inspection := TextResourceInspector.new().inspect(
		path, "PresentationClipDefinition")
	if not inspection.ok or not inspection.matches_expected_type:
		return "clip definition is not a complete inspectable text Resource"
	for declared_type: String in inspection.sub_resource_types:
		if "Script" in declared_type:
			return "clip definition must not contain embedded Script sub-resources"
	return _validate_resource_dependency_tree(
		path, true, {}, {}, {"visits": 0})


func _validate_resource_dependency_tree(
	path: String,
	allow_definition_scripts: bool,
	visited: Dictionary,
	ancestry: Dictionary,
	work: Dictionary,
) -> String:
	var canonical := path.simplify_path()
	if canonical.is_empty():
		return "clip data dependency path is not canonical"
	if ancestry.has(canonical):
		return "clip data dependency graph contains a cycle"
	if ancestry.size() >= MAX_DEPENDENCY_DEPTH:
		return "clip data dependency graph exceeds the bounded nesting depth"
	if visited.has(canonical):
		return ""
	var visits := int(work.get("visits", 0))
	if visits < 0 or visits >= MAX_DEPENDENCY_RESOURCES:
		return "clip data dependency graph exceeds the bounded resource work budget"
	work["visits"] = visits + 1
	visited[canonical] = true
	var branch_ancestry := ancestry.duplicate()
	branch_ancestry[canonical] = true
	if canonical.get_extension().to_lower() in ["scn", "res"]:
		return "binary .scn/.res resources are outside the data-only clip boundary"
	var extension := canonical.get_extension().to_lower()
	if extension in ["tres", "tscn"]:
		var text_inspection := TextResourceInspector.new().inspect(
			canonical, "PackedScene" if extension == "tscn" else "")
		if not text_inspection.ok:
			return "clip data dependency is not a complete inspectable text Resource"
		if extension == "tscn" and not text_inspection.matches_expected_type:
			return "clip scene is not a complete inspectable .tscn Resource"
		for declared_type: String in text_inspection.sub_resource_types:
			if "Script" in declared_type:
				return "clip data dependency must not contain embedded Script sub-resources"
	for raw_dependency: String in ResourceLoader.get_dependencies(canonical):
		var fields := raw_dependency.split("::", true)
		var dependency_type := String(fields[1]) if fields.size() >= 2 else ""
		var dependency_path := _resource_dependency_path(raw_dependency)
		if dependency_path.is_empty() or not ResourceLoader.exists(dependency_path):
			return "dependency '%s' is unavailable" % dependency_path
		if dependency_type == "Script" or dependency_path.get_extension() == "gd":
			if (
				not allow_definition_scripts
				or dependency_path not in ALLOWED_DEFINITION_SCRIPTS
			):
				return (
					"data-only clip resources must not depend on script '%s'"
					% dependency_path)
			continue
		var is_scene := (
			dependency_type == "PackedScene"
			or dependency_path.get_extension().to_lower() in ["tscn", "scn"])
		if is_scene and dependency_path.get_extension().to_lower() != "tscn":
			return "clip scenes and nested scenes must use inspectable .tscn resources"
		var child_error := _validate_resource_dependency_tree(
			dependency_path,
			false,
			visited,
			branch_ancestry,
			work,
		)
		if not child_error.is_empty():
			return child_error
	return ""


func _resource_dependency_path(raw_dependency: String) -> String:
	var fields := raw_dependency.split("::", true)
	if not fields.is_empty() and fields[0].begins_with("uid://"):
		var dependency_uid := ResourceUID.text_to_id(fields[0])
		if dependency_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(
			dependency_uid):
			var canonical_path := ResourceUID.get_id_path(dependency_uid)
			if not canonical_path.is_empty():
				return canonical_path.simplify_path()
	if fields.size() >= 3 and not fields[2].is_empty():
		return fields[2].simplify_path()
	return fields[0].simplify_path() if not fields.is_empty() else ""


func _definition_resource_scripts_are_exact(
	definition: PresentationClipDefinition,
) -> bool:
	if (
		definition == null
		or definition.get_script() == null
		or definition.get_script().resource_path != DEFINITION_SCRIPT_PATH
	):
		return false
	for cue: PresentationClipCue in definition.cues:
		if cue == null:
			continue
		var expected_script_path := ""
		if cue is PresentationClipAudioCue:
			expected_script_path = AUDIO_CUE_SCRIPT_PATH
		elif cue is PresentationClipAudioChoiceCue:
			expected_script_path = AUDIO_CHOICE_CUE_SCRIPT_PATH
			for candidate: PresentationClipAudioChoiceCandidate in (
				(cue as PresentationClipAudioChoiceCue).candidates
			):
				if candidate == null:
					continue
				if (
					candidate.get_script() == null
					or candidate.get_script().resource_path
						!= AUDIO_CHOICE_CANDIDATE_SCRIPT_PATH
				):
					return false
		elif cue is PresentationClipStateCue:
			expected_script_path = STATE_CUE_SCRIPT_PATH
		else:
			return false
		if (
			cue.get_script() == null
			or cue.get_script().resource_path != expected_script_path
		):
			return false
	for layer: PresentationClipParticleLayer in definition.particle_layers:
		if layer == null:
			continue
		if (
			layer.get_script() == null
			or layer.get_script().resource_path != PARTICLE_LAYER_SCRIPT_PATH
		):
			return false
	return true


func _cue_diagnostic(
	definition: PresentationClipDefinition,
	field: String,
	index: int,
	cue: Resource,
	detail: String,
) -> String:
	var definition_path := definition.resource_path
	if definition_path.is_empty():
		definition_path = "<embedded PresentationClipDefinition>"
	var provenance := ""
	if cue != null:
		var source_path := String(cue.get("authored_source_path"))
		var source_line := int(cue.get("authored_source_line"))
		if not source_path.is_empty() and source_line > 0:
			provenance = " authored at %s:%d" % [source_path, source_line]
	return "%s %s[%d]%s: %s" % [
		definition_path, field, index, provenance, detail,
	]


func _particle_diagnostic(
	definition: PresentationClipDefinition,
	index: int,
	layer: PresentationClipParticleLayer,
	detail: String,
) -> String:
	return definition._particle_validation_diagnostic(index, layer, detail)


func _validate_packed_scene_state(
	scene: PackedScene,
	ancestry: Dictionary,
) -> String:
	var result := _validate_packed_scene_state_model(
		scene, ancestry, {"visits": 0, "node_entries": 0})
	return String(result.get("error", ""))


## Flatten the exact SceneState path set before instantiate. Repeated nested
## scene instances deliberately recurse independently: Resource identity is not
## a node-budget dedupe key. Only the current ancestry is tracked, so cyclic
## instance graphs fail while two authored instances consume budget twice.
func _validate_packed_scene_state_model(
	scene: PackedScene,
	ancestry: Dictionary,
	work: Dictionary,
) -> Dictionary:
	if scene == null or not scene.can_instantiate():
		return {"error": "clip PackedScene cannot be instantiated", "paths": {}}
	var identity := scene.resource_path
	if identity.is_empty():
		identity = str(scene.get_instance_id())
	if ancestry.has(identity):
		return {"error": "clip SceneState contains a cyclic scene instance", "paths": {}}
	if ancestry.size() >= MAX_SCENE_STATE_DEPTH:
		return {
			"error": "clip SceneState exceeds the bounded nesting depth before instantiation",
			"paths": {},
		}
	var visits := int(work.get("visits", 0))
	if visits < 0 or visits >= MAX_SCENE_STATE_WORK:
		return {
			"error": "clip SceneState exceeds the bounded expansion work before instantiation",
			"paths": {},
		}
	work["visits"] = visits + 1
	var branch_ancestry := ancestry.duplicate()
	branch_ancestry[identity] = true
	var paths: Dictionary = {}
	var state := scene.get_state()
	for node_index in range(state.get_node_count()):
		var node_entries := int(work.get("node_entries", 0))
		if node_entries < 0 or node_entries >= MAX_SCENE_STATE_WORK:
			return {
				"error": "clip SceneState exceeds the bounded expansion work before instantiation",
				"paths": {},
			}
		work["node_entries"] = node_entries + 1
		var node_path := _canonical_scene_state_path(
			String(state.get_node_path(node_index)))
		if node_path.is_empty():
			return {"error": "clip SceneState contains an invalid node path", "paths": {}}
		var nested_scene := state.get_node_instance(node_index)
		if nested_scene != null:
			var nested_result := _validate_packed_scene_state_model(
				nested_scene, branch_ancestry, work)
			var nested_error := String(nested_result.get("error", ""))
			if not nested_error.is_empty():
				return {"error": nested_error, "paths": {}}
			var nested_paths: Dictionary = nested_result.get("paths", {})
			for nested_path_value: Variant in nested_paths:
				var nested_path := String(nested_path_value)
				var projected_path := _join_scene_state_path(
					node_path, nested_path)
				paths[projected_path] = true
				if paths.size() > PresentationClipDefinition.MAX_SCENE_NODES:
					return {
						"error": "clip SceneState exceeds the 512-node budget before instantiation",
						"paths": {},
					}
		var native_type := StringName(state.get_node_type(node_index))
		# A native type identifies a node declared by this scene layer. Empty-type
		# entries without an instance are property overrides and must not inflate
		# the flattened node count inherited from their owning scene.
		if not native_type.is_empty():
			paths[node_path] = true
			if paths.size() > PresentationClipDefinition.MAX_SCENE_NODES:
				return {
					"error": "clip SceneState exceeds the 512-node budget before instantiation",
					"paths": {},
				}
		if not native_type.is_empty() and _class_owns_independent_clock(native_type):
			return {
				"error": (
					"clip scene contains forbidden data owner '%s' before instantiation"
					% native_type),
				"paths": {},
			}
		if (
			not native_type.is_empty()
			and _class_owns_forbidden_surface_or_3d(native_type)
		):
			return {
				"error": (
					"clip SceneState contains forbidden render-surface or 3D owner '%s' before instantiation"
					% native_type),
				"paths": {},
			}
		for property_index in range(state.get_node_property_count(node_index)):
			var property_name := state.get_node_property_name(
				node_index, property_index)
			var property_value := state.get_node_property_value(
				node_index, property_index)
			if property_name == &"script" and property_value != null:
				return {"error": "clip scene nodes must not declare scripts", "paths": {}}
			if _variant_contains_script(property_value, {}):
				return {"error": "clip scene resources must not contain scripts", "paths": {}}
	return {"error": "", "paths": paths}


func _canonical_scene_state_path(raw_path: String) -> String:
	var normalized := raw_path.strip_edges()
	if normalized == ".":
		return "."
	while normalized.begins_with("./"):
		normalized = normalized.substr(2)
	if (
		normalized.is_empty()
		or normalized.begins_with("/")
		or normalized == ".."
		or normalized.begins_with("../")
		or "/../" in normalized
	):
		return ""
	return normalized


func _join_scene_state_path(instance_path: String, nested_path: String) -> String:
	if instance_path == ".":
		return nested_path
	if nested_path == ".":
		return instance_path
	return instance_path + "/" + nested_path


func _variant_contains_script(value: Variant, visited: Dictionary) -> bool:
	if value is Script:
		return true
	if value is Resource:
		var resource := value as Resource
		var identity := resource.get_instance_id()
		if visited.has(identity):
			return false
		visited[identity] = true
		for property_value: Variant in resource.get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			if _variant_contains_script(
				resource.get(StringName(property.get("name", ""))), visited):
				return true
		return false
	if value is Array:
		for child_value: Variant in value:
			if _variant_contains_script(child_value, visited):
				return true
	if value is Dictionary:
		for child_value: Variant in (value as Dictionary).values():
			if _variant_contains_script(child_value, visited):
				return true
	return false


func _class_owns_independent_clock(class_name_value: StringName) -> bool:
	for forbidden_class: StringName in [
		&"AudioStreamPlayer", &"AudioStreamPlayer2D", &"AudioStreamPlayer3D",
		&"VideoStreamPlayer", &"Timer", &"AnimationTree", &"AnimatedSprite2D",
		&"AnimatedSprite3D", &"GPUParticles2D", &"GPUParticles3D",
		&"CPUParticles2D", &"CPUParticles3D",
	]:
		if (
			class_name_value == forbidden_class
			or ClassDB.is_parent_class(class_name_value, forbidden_class)
		):
			return true
	return false


func _class_owns_forbidden_surface_or_3d(
	class_name_value: StringName,
) -> bool:
	for forbidden_class: StringName in [
		&"Viewport", &"CanvasGroup", &"BackBufferCopy", &"Node3D",
	]:
		if (
			class_name_value == forbidden_class
			or ClassDB.is_parent_class(class_name_value, forbidden_class)
		):
			return true
	return false


func _count_nodes(root: Node) -> int:
	var count := 1
	for child: Node in root.get_children():
		count += _count_nodes(child)
	return count


func _apply_clip_fit(
	visual_group: CanvasGroup,
	logical_size: Vector2i,
	target_size: Vector2i,
	fit_mode: StringName,
) -> void:
	var fit := _clip_fit_transform(logical_size, target_size, fit_mode)
	visual_group.scale = fit.get("scale", Vector2.ONE)
	visual_group.position = fit.get("offset", Vector2.ZERO)


func _clip_fit_transform(
	logical_size: Vector2i,
	target_size: Vector2i,
	fit_mode: StringName,
) -> Dictionary:
	var scale_value := Vector2(
		float(target_size.x) / float(logical_size.x),
		float(target_size.y) / float(logical_size.y),
	)
	if fit_mode in [&"contain", &"cover"]:
		var uniform := (
			minf(scale_value.x, scale_value.y)
			if fit_mode == &"contain"
			else maxf(scale_value.x, scale_value.y)
		)
		scale_value = Vector2.ONE * uniform
	return {
		"scale": scale_value,
		"offset": (
			Vector2(target_size) - Vector2(logical_size) * scale_value) * 0.5,
	}


func _preflight_viewport_size() -> Vector2i:
	var viewport := get_viewport()
	if viewport != null:
		return Vector2i(viewport.get_visible_rect().size)
	return Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 648)),
	)


func _estimate_scene_texture_bytes(root: Node) -> int:
	var visited_resources: Dictionary = {}
	return _estimate_variant_texture_bytes(root, visited_resources)


func _estimate_variant_texture_bytes(
	value: Variant,
	visited_resources: Dictionary,
) -> int:
	if value is AtlasTexture:
		var atlas_texture := value as AtlasTexture
		var atlas_identity := atlas_texture.get_instance_id()
		if visited_resources.has(atlas_identity):
			return 0
		visited_resources[atlas_identity] = true
		if atlas_texture.atlas == null:
			return StellaRuntime.presentation_clip_resource_budget_bytes + 1
		return _estimate_variant_texture_bytes(
			atlas_texture.atlas, visited_resources)
	if value is CanvasTexture:
		var canvas_texture := value as CanvasTexture
		var canvas_identity := canvas_texture.get_instance_id()
		if visited_resources.has(canvas_identity):
			return 0
		visited_resources[canvas_identity] = true
		var canvas_total := 0
		for property_value: Variant in canvas_texture.get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			canvas_total += _estimate_variant_texture_bytes(
				canvas_texture.get(StringName(property.get("name", ""))),
				visited_resources,
			)
		return canvas_total
	if value is Texture2D:
		var texture := value as Texture2D
		var identity := texture.get_instance_id()
		if visited_resources.has(identity):
			return 0
		visited_resources[identity] = true
		var width := texture.get_width()
		var height := texture.get_height()
		var configured_limit := StellaRuntime.presentation_clip_resource_budget_bytes
		if width <= 0 or height <= 0:
			return configured_limit + 1
		if width > configured_limit / 4 / height:
			return configured_limit + 1
		return width * height * 4
	if value is Node:
		var node_total := 0
		for property_value: Variant in (value as Node).get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			node_total += _estimate_variant_texture_bytes(
				(value as Node).get(StringName(property.get("name", ""))),
				visited_resources,
			)
		for child: Node in (value as Node).get_children():
			node_total += _estimate_variant_texture_bytes(child, visited_resources)
		return node_total
	if value is Resource:
		var resource := value as Resource
		var identity := resource.get_instance_id()
		if visited_resources.has(identity):
			return 0
		visited_resources[identity] = true
		var resource_total := 0
		for property_value: Variant in resource.get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			resource_total += _estimate_variant_texture_bytes(
				resource.get(StringName(property.get("name", ""))),
				visited_resources,
			)
		return resource_total
	if value is Array:
		var array_total := 0
		for child_value: Variant in value:
			array_total += _estimate_variant_texture_bytes(
				child_value, visited_resources)
		return array_total
	if value is Dictionary:
		var dictionary_total := 0
		for child_value: Variant in (value as Dictionary).values():
			dictionary_total += _estimate_variant_texture_bytes(
				child_value, visited_resources)
		return dictionary_total
	return 0


func _validate_scene_contract(root: Node) -> String:
	if root.get_script() != null:
		return "clip scene nodes must not execute scripts"
	if root is Viewport or root is CanvasGroup or root is BackBufferCopy:
		return "clip scene must not own nested render surfaces or back-buffer copies"
	if root is Node3D:
		return "clip scene is a deterministic 2D contract and must not contain 3D nodes"
	if (
		root is AudioStreamPlayer
		or root is AudioStreamPlayer2D
		or root is AudioStreamPlayer3D
		or root is VideoStreamPlayer
		or root is Timer
		or root is AnimationTree
		or root is AnimatedSprite2D
		or root is AnimatedSprite3D
		or root is GPUParticles2D
		or root is GPUParticles3D
		or root is CPUParticles2D
		or root is CPUParticles3D
	):
		return "clip scene contains an independent clock or audio/video owner"
	if root is AnimationPlayer and not String((root as AnimationPlayer).autoplay).is_empty():
		return "clip AnimationPlayer autoplay must be disabled"
	if root is CanvasItem:
		var material := (root as CanvasItem).material
		if material is ShaderMaterial:
			var shader := (material as ShaderMaterial).shader
			if shader != null and _shader_uses_time(shader.code):
				return "clip scene shaders must not use the wall-clock TIME built-in"
	var visited_resources: Dictionary = {}
	for property_value: Variant in root.get_property_list():
		var property: Dictionary = property_value
		if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
			continue
		var property_name := StringName(property.get("name", ""))
		if _variant_uses_independent_clock(root.get(property_name), visited_resources):
			return "clip scene resources must not use self-advancing visual clocks"
	for child: Node in root.get_children():
		var child_error := _validate_scene_contract(child)
		if not child_error.is_empty():
			return child_error
	return ""


func _validate_visual_animation(
	animation: Animation,
	label: String,
	animation_player: AnimationPlayer,
	scene_root: Node,
) -> String:
	if animation == null:
		return "%s is unavailable" % label
	for track_index in range(animation.get_track_count()):
		if animation.track_get_type(track_index) in [
			Animation.TYPE_AUDIO,
			Animation.TYPE_METHOD,
			Animation.TYPE_ANIMATION,
		]:
			return (
				"%s must not contain audio, method, or nested-animation tracks; use typed cues"
				% label)
		var track_path := animation.track_get_path(track_index)
		var animation_root := animation_player.get_node_or_null(
			animation_player.root_node)
		var target := (
			animation_root.get_node_or_null(NodePath(track_path.get_concatenated_names()))
			if animation_root != null
			else null
		)
		if (
			target == null
			or (target != scene_root and not scene_root.is_ancestor_of(target))
		):
			return "%s track[%d] target must resolve inside the clip scene" % [
				label, track_index,
			]
		if target is AnimationPlayer or _node_owns_independent_clock(target):
			return "%s must not mutate an animation or independent-clock owner" % label
		var binding_error := _validate_track_binding(
			animation.track_get_type(track_index), track_path, target)
		if not binding_error.is_empty():
			return "%s track[%d] %s" % [label, track_index, binding_error]
	return ""


func _validate_track_binding(
	track_type: Animation.TrackType,
	track_path: NodePath,
	target: Node,
) -> String:
	if track_type in [Animation.TYPE_VALUE, Animation.TYPE_BEZIER]:
		if track_path.get_subname_count() == 0:
			return "must name a writable visual property"
		var current: Variant = target
		for subname_index in range(track_path.get_subname_count()):
			var property_name := StringName(track_path.get_subname(subname_index))
			if current is Object:
				if not _object_has_property(current as Object, property_name):
					return "references unknown property '%s'" % property_name
				current = (current as Object).get(property_name)
			elif current is Dictionary:
				if not (current as Dictionary).has(property_name):
					return "references unknown dictionary key '%s'" % property_name
				current = (current as Dictionary).get(property_name)
			else:
				return "cannot traverse property '%s'" % property_name
		return ""
	if track_path.get_subname_count() != 0:
		return "must not attach property subnames to this typed visual track"
	return "unsupported visual track type"


func _object_has_property(object: Object, property_name: StringName) -> bool:
	for property_value: Variant in object.get_property_list():
		var property: Dictionary = property_value
		if StringName(property.get("name", "")) == property_name:
			return true
	return false


func _node_owns_independent_clock(node: Node) -> bool:
	return (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
		or node is VideoStreamPlayer
		or node is Timer
		or node is AnimationTree
		or node is AnimatedSprite2D
		or node is AnimatedSprite3D
		or node is GPUParticles2D
		or node is GPUParticles3D
		or node is CPUParticles2D
		or node is CPUParticles3D
	)


func _shader_uses_time(code: String) -> bool:
	var regex := RegEx.new()
	return regex.compile("(^|[^A-Za-z0-9_])TIME([^A-Za-z0-9_]|$)") == OK and regex.search(code) != null


func _variant_uses_independent_clock(
	value: Variant,
	visited_resources: Dictionary,
) -> bool:
	if value is AnimatedTexture:
		return true
	if value is ShaderMaterial:
		var shader := (value as ShaderMaterial).shader
		if shader != null and _shader_uses_time(shader.code):
			return true
	if value is Resource:
		var resource := value as Resource
		var resource_id := resource.get_instance_id()
		if visited_resources.has(resource_id):
			return false
		visited_resources[resource_id] = true
		for property_value: Variant in resource.get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			var property_name := StringName(property.get("name", ""))
			if _variant_uses_independent_clock(
				resource.get(property_name), visited_resources):
				return true
		return false
	if value is Array:
		for child_value: Variant in value:
			if _variant_uses_independent_clock(child_value, visited_resources):
				return true
		return false
	if value is Dictionary:
		for child_value: Variant in (value as Dictionary).values():
			if _variant_uses_independent_clock(child_value, visited_resources):
				return true
	return false


func _active_identity_is_current(request_id: int, generation: int) -> bool:
	return (
		not _active.is_empty()
		and int(_active.get("request_id", 0)) == request_id
		and int(_active.get("generation", 0)) == generation
	)


func prepared_plan_count() -> int:
	return _prepared_plans.size()


func has_active_clip() -> bool:
	return not _active.is_empty()
