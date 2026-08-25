## Generic renderer for reusable named visual layers.
##
## Each layer owns stable Asset/Body/Face Sprite2D nodes. Updates touch only
## explicitly changed textures, so cycling face differences never reloads or
## recreates an unchanged background or character body.
class_name StagePresenter extends CanvasLayer

signal layer_transition_finished(layer_id: String)

const REDRAW_SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/stage_redraw.gdshader"
)
const REDRAW_BOX_HORIZONTAL_SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/"
	+ "stage_redraw_box_horizontal.gdshader"
)
const REDRAW_BOX_VERTICAL_SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/"
	+ "stage_redraw_box_vertical.gdshader"
)
const REDRAW_TEXTURE_SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/stage_redraw_texture.gdshader"
)
const TEXTURE_EXTENSIONS := [".png", ".jpg", ".jpeg", ".webp", ".svg", ".tres", ".res"]
const DEFAULT_VIEWPORT_SIZE := Vector2(1920.0, 1080.0)
const REDRAW_EFFECT_TYPE_CODES := {
	"color_overlay": 1.0,
	"brightness_contrast": 2.0,
	"grayscale": 3.0,
	"tint": 4.0,
	"clip": 5.0,
	"blur": 6.0,
}
const COLOR_OVERLAY_BLEND_CODES := {
	"normal": 0.0,
	"soft_light": 1.0,
}
const MAX_REDRAW_TARGET_AXIS := 8192
const FALLBACK_REDRAW_TARGET_AXIS := 4096
const MAX_REDRAW_TARGET_BYTES := 256 * 1024 * 1024
const MAX_REDRAW_STATIC_SAMPLE_FETCHES := 256 * 1024 * 1024
const MAX_REDRAW_CONTINUOUS_SAMPLE_FETCHES := 64 * 1024 * 1024
const REDRAW_SOURCE_BYTES_PER_PIXEL := 4
const REDRAW_BLUR_PASS_BYTES_MOBILE := 12
const REDRAW_BLUR_PASS_BYTES_COMPATIBILITY := 20
const MAX_TRANSITION_TARGET_AXIS := 8192
const MAX_TRANSITION_SNAPSHOT_BYTES := 256 * 1024 * 1024
const MAX_TRANSITION_TEXTURE_CACHE := 16

static var _next_transition_token: int = 1

var _layers: Dictionary = {}
var _states: Dictionary = {}
var _layer_tweens: Dictionary = {}
var _layer_transition_tokens: Dictionary = {}
var _layer_transition_request_ids: Dictionary = {}
var _layer_transition_generations: Dictionary = {}
var _layer_generations: Dictionary = {}
var _layer_generation_counters: Dictionary = {}
var _next_node_index: int = 0
var _redraw_shader: Shader
var _redraw_box_horizontal_shader: Shader
var _redraw_box_vertical_shader: Shader
var _redraw_texture_shader: Shader
var _completion_batch_depth: int = 0
var _queued_transition_starts: Array[Dictionary] = []
var _flushing_transition_starts: bool = false
var _queued_transition_completions: Array = []
var _flushing_transition_completions: bool = false
var _completion_lifecycle_epoch: int = 1
var _queued_stage_terminals: Array[Dictionary] = []
var _flushing_stage_terminals: bool = false
var _active_stage_operation_request_id: int = 0
var _stage_participant_capability: RefCounted
var _transition_registry := StageTransitionRegistry.new()
var _transition_texture_cache: Dictionary = {}
var _transition_texture_cache_order: Array[String] = []
var _active_transition_snapshot_bytes := 0
var _pending_transition_snapshot_bytes := 0
var _layer_transition_projections: Dictionary = {}
var _pending_stage_request_plans: Dictionary = {}
var _pending_stage_preflight_states: Dictionary = {}
var _held_stage_transactions: Dictionary = {}


func _ready() -> void:
	_redraw_shader = load(REDRAW_SHADER_PATH) as Shader
	_redraw_box_horizontal_shader = load(
		REDRAW_BOX_HORIZONTAL_SHADER_PATH
	) as Shader
	_redraw_box_vertical_shader = load(
		REDRAW_BOX_VERTICAL_SHADER_PATH
	) as Shader
	_redraw_texture_shader = load(REDRAW_TEXTURE_SHADER_PATH) as Shader
	_stage_participant_capability = StellaRuntime._register_stage_presenter(self)
	if _stage_participant_capability == null:
		push_error("StagePresenter: Runtime participant registration failed")
	SignalBus.stage_validate_requested.connect(_on_stage_validate_requested)
	SignalBus.stage_accept_requested.connect(_on_stage_accept_requested)
	SignalBus.stage_apply_readiness_requested.connect(
		_on_stage_apply_readiness_requested)
	SignalBus.stage_apply_requested.connect(_on_stage_apply_requested)
	SignalBus.stage_operations_requested.connect(_on_stage_operations_requested)
	SignalBus.stage_visuals_reset_requested.connect(
		_on_stage_visuals_reset_requested
	)
	SignalBus.stage_state_apply_requested.connect(_on_stage_state_apply_requested)
	SignalBus.stage_transitions_finish_requested.connect(
		_on_stage_transitions_finish_requested
	)
	SignalBus.stage_transition_receipts_finish_requested.connect(
		_on_stage_transition_receipts_finish_requested
	)
	SignalBus.engine_abort_requested.connect(_on_engine_abort_requested)

	var viewport := get_viewport()
	if viewport and not viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.connect(_on_viewport_size_changed)


func _exit_tree() -> void:
	_discard_all_held_stage_transactions()
	StellaRuntime._unregister_stage_presenter(self, _stage_participant_capability)
	_stage_participant_capability = null
	# Scene replacement is a terminal presentation boundary. Retire exact owners
	# before their Tween/viewport nodes disappear so Director never keeps an
	# unreachable JOIN or FNF receipt owned by this Presenter instance.
	_completion_lifecycle_epoch += 1
	_begin_completion_batch()
	var cancelled := _clear_visuals(false)
	for identity: Dictionary in cancelled:
		_publish_stage_transition_terminal(identity, &"cancelled")
	_end_completion_batch()
	# Validation owns detached, fully prepared projection trees until the request
	# either applies or settles. Scene replacement can retire this participant
	# between those phases, so release those unparented allocations here instead
	# of relying on a settled callback whose target Node is leaving the tree.
	for record_value: Variant in _pending_stage_request_plans.values():
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		_free_unclaimed_stage_plan(record.get("plan", {}))
	_pending_stage_request_plans.clear()
	_pending_transition_snapshot_bytes = 0
	_pending_stage_preflight_states.clear()


func register_transition_provider(provider: StageTransitionProvider) -> bool:
	return _transition_registry.register_provider(provider)


func unregister_transition_provider(kind: StringName) -> bool:
	return _transition_registry.unregister_provider(kind)


## Return the live Node2D for a named layer id. Primarily useful to custom
## presenters and deterministic tests; callers must not retain it after remove.
func get_layer_node(layer_id: String) -> Node2D:
	var record: Dictionary = _layers.get(layer_id, {})
	return record.get("root") as Node2D


func get_layer_state(layer_id: String) -> Dictionary:
	if not _states.has(layer_id):
		return {}
	return (_states[layer_id] as Dictionary).duplicate(true)


func get_layer_ids() -> Array:
	return _states.keys()


func _on_stage_validate_requested(request: StageOperationRequest) -> void:
	if (
		_stage_participant_capability == null
		or request == null
		or not request.is_target(self)
	):
		return
	var preflight_base := _stage_preflight_base(request)
	if not bool(preflight_base.get("valid", false)):
		SignalBus.reject_stage_request(
			request,
			self,
			_stage_participant_capability,
			0,
			String(preflight_base.get(
				"error", "Stage preflight chain is invalid")),
		)
		return
	var validation := _build_stage_request_plan(
		request, preflight_base.get("state", {}))
	if not bool(validation.get("valid", false)):
		SignalBus.reject_stage_request(
			request,
			self,
			_stage_participant_capability,
			int(validation.get("operation_index", -1)),
			String(validation.get("error", "Stage preflight failed")),
		)
		return
	var plan: Dictionary = validation.get("plan", {})
	if not SignalBus.validate_stage_request(
		request,
		self,
		_stage_participant_capability,
		plan,
	):
		_free_unclaimed_stage_plan(plan)
		return
	_advance_stage_preflight_state(request, validation.get("target_state", {}))
	var request_key := request.get_instance_id()
	var reserved_bytes := int(plan.get("reserved_bytes", 0))
	_pending_transition_snapshot_bytes += reserved_bytes
	_pending_stage_request_plans[request_key] = {
		"plan": plan,
		"reserved_bytes": reserved_bytes,
		"reservation_released": false,
	}
	request.settled.connect(
		_on_stage_request_settled.bind(
			request_key, request.get_preflight_chain_id()), CONNECT_ONE_SHOT)


func _on_stage_accept_requested(request: StageOperationRequest) -> void:
	if _stage_participant_capability == null or request == null:
		return
	var plan := request.get_plan(self)
	if Vector2(plan.get("viewport_size", Vector2.ZERO)) != _viewport_size():
		return
	SignalBus.accept_stage_request(
		request, self, _stage_participant_capability)


func _on_stage_apply_readiness_requested(request: StageOperationRequest) -> void:
	if (
		_stage_participant_capability == null
		or request == null
		or not request.is_target(self)
	):
		return
	var plan := request.get_plan(self)
	var apply_validation := _validate_stage_apply_plan(request, plan)
	if not bool(apply_validation.get("valid", false)):
		SignalBus.fail_stage_apply(
			request,
			self,
			_stage_participant_capability,
			int(apply_validation.get("operation_index", 0)),
			String(apply_validation.get(
				"error", "sealed Stage plan cannot be applied")),
		)
		return
	SignalBus.mark_stage_apply_ready(
		request, self, _stage_participant_capability)


func _on_stage_apply_requested(request: StageOperationRequest) -> void:
	if (
		_stage_participant_capability == null
		or request == null
		or not request.is_target(self)
	):
		return
	var apply_validation := _validate_stage_apply_plan(request, request.get_plan(self))
	if not bool(apply_validation.get("valid", false)):
		SignalBus.fail_stage_apply(
			request,
			self,
			_stage_participant_capability,
			int(apply_validation.get("operation_index", 0)),
			String(apply_validation.get(
				"error", "sealed Stage plan could not be claimed")),
		)
		return
	SignalBus.mark_stage_apply_claimed(
		request, self, _stage_participant_capability)


## Runtime registration hands this capability-bound callable only to SignalBus.
## The public apply signal performs claim-only validation; after the whole
## captured quorum claims, SignalBus invokes this uninterrupted hold/commit/
## publish chain so ordinary listeners cannot observe or create a half-apply.
func _run_sealed_stage_transaction_phase(
	request: StageOperationRequest,
	capability: RefCounted,
	phase: StringName,
) -> bool:
	if (
		request == null
		or capability == null
		or capability != _stage_participant_capability
		or not request.is_target(self)
	):
		return false
	var request_key := request.get_instance_id()
	match phase:
		&"hold":
			if _held_stage_transactions.has(request_key):
				return false
			_held_stage_transactions[request_key] = {
				"starts": _queued_transition_starts.size(),
				"completions": _queued_transition_completions.size(),
				"terminals": _queued_stage_terminals.size(),
				"committed": false,
			}
			_begin_completion_batch()
			return true
		&"commit":
			if not _held_stage_transactions.has(request_key):
				return false
			var plan := request.get_plan(self)
			var operation_plans: Array = plan.get("operation_plans", [])
			_release_stage_request_reservation(request_key)
			var previous_request_id := _active_stage_operation_request_id
			_active_stage_operation_request_id = request.get_request_id()
			var apply_result := _apply_operations(
				request.get_payloads(), request.get_force_cut(), operation_plans)
			_active_stage_operation_request_id = previous_request_id
			if not bool(apply_result.get("success", false)):
				SignalBus.fail_stage_apply(
					request,
					self,
					_stage_participant_capability,
					int(apply_result.get("operation_index", 0)),
					String(apply_result.get(
						"error", "sealed Stage run could not be committed")),
				)
				return false
			(_held_stage_transactions[request_key] as Dictionary)["committed"] = true
			return SignalBus.acknowledge_stage_apply(
				request, self, _stage_participant_capability)
		&"publish":
			if not _held_stage_transactions.has(request_key):
				return false
			_held_stage_transactions.erase(request_key)
			_end_completion_batch()
			return true
		&"abort":
			return _discard_held_stage_transaction(request_key)
	return false


func _discard_held_stage_transaction(request_key: int) -> bool:
	var record: Dictionary = _held_stage_transactions.get(request_key, {})
	if record.is_empty():
		return true
	# A rejected or retired transaction cannot publish queued receipt/completion
	# events. Live private projection is restored either by the current Director
	# rollback or by the newer lifecycle boundary that retired this participant.
	_queued_transition_starts.resize(int(record.get(
		"starts", _queued_transition_starts.size())))
	_queued_transition_completions.resize(int(record.get(
		"completions", _queued_transition_completions.size())))
	_queued_stage_terminals.resize(int(record.get(
		"terminals", _queued_stage_terminals.size())))
	_held_stage_transactions.erase(request_key)
	_end_completion_batch()
	return not bool(record.get("committed", false))


func _discard_all_held_stage_transactions() -> void:
	for request_key_value: Variant in _held_stage_transactions.keys():
		_discard_held_stage_transaction(int(request_key_value))


func _on_stage_request_settled(request_key: int, preflight_chain_id: int) -> void:
	_pending_stage_preflight_states.erase(preflight_chain_id)
	_release_stage_request_reservation(request_key)
	var record: Dictionary = _pending_stage_request_plans.get(request_key, {})
	_pending_stage_request_plans.erase(request_key)
	var plan: Dictionary = record.get("plan", {})
	_free_unclaimed_stage_plan(plan)


func _release_stage_request_reservation(request_key: int) -> void:
	var record: Dictionary = _pending_stage_request_plans.get(request_key, {})
	if record.is_empty() or bool(record.get("reservation_released", false)):
		return
	_pending_transition_snapshot_bytes = maxi(
		0,
		_pending_transition_snapshot_bytes - int(record.get("reserved_bytes", 0)),
	)
	record["reservation_released"] = true
	_pending_stage_request_plans[request_key] = record


func _free_unclaimed_stage_plan(plan: Dictionary) -> void:
	for operation_plan_value: Variant in plan.get("operation_plans", []):
		if not operation_plan_value is Dictionary:
			continue
		for projection_value: Variant in (
			(operation_plan_value as Dictionary).get("projections", [])):
			if not projection_value is Dictionary:
				continue
			var projection: Dictionary = projection_value
			if bool(projection.get("consumed", false)):
				continue
			var prepared: Dictionary = projection.get("prepared", {})
			var holder_value: Variant = prepared.get("holder")
			if holder_value is Node and is_instance_valid(holder_value):
				var holder := holder_value as Node
				if holder.is_queued_for_deletion():
					continue
				if holder.get_parent() == null:
					holder.free()
				continue
			for root_key in ["source_root", "target_root"]:
				var root := projection.get(root_key) as Node
				if is_instance_valid(root) and root.get_parent() == null:
					root.free()


func _stage_preflight_base(request: StageOperationRequest) -> Dictionary:
	var chain_id := request.get_preflight_chain_id()
	var run_index := request.get_preflight_run_index()
	var run_count := request.get_preflight_run_count()
	if chain_id <= 0 or run_count <= 1:
		return {"valid": true, "state": _states.duplicate(true)}
	if run_index == 0:
		_pending_stage_preflight_states.erase(chain_id)
		return {"valid": true, "state": _states.duplicate(true)}
	var record_value: Variant = _pending_stage_preflight_states.get(chain_id)
	if not record_value is Dictionary:
		return {
			"valid": false,
			"error": "Stage preflight chain is missing its preceding run",
		}
	var record: Dictionary = record_value
	if int(record.get("next_run_index", -1)) != run_index:
		return {
			"valid": false,
			"error": "Stage preflight chain run order is invalid",
		}
	var state_value: Variant = record.get("state")
	if not state_value is Dictionary:
		return {
			"valid": false,
			"error": "Stage preflight chain state is invalid",
		}
	return {"valid": true, "state": (state_value as Dictionary).duplicate(true)}


func _advance_stage_preflight_state(
	request: StageOperationRequest,
	target_state_value: Variant,
) -> void:
	var chain_id := request.get_preflight_chain_id()
	var run_index := request.get_preflight_run_index()
	var run_count := request.get_preflight_run_count()
	if chain_id <= 0 or run_count <= 1:
		return
	if run_index + 1 >= run_count:
		_pending_stage_preflight_states.erase(chain_id)
		return
	if not target_state_value is Dictionary:
		_pending_stage_preflight_states.erase(chain_id)
		return
	_pending_stage_preflight_states[chain_id] = {
		"next_run_index": run_index + 1,
		"state": (target_state_value as Dictionary).duplicate(true),
	}


func _build_stage_request_plan(
	request: StageOperationRequest,
	preflight_state_value: Variant = null,
) -> Dictionary:
	var viewport_size := _viewport_size()
	if (
		not viewport_size.is_finite()
		or viewport_size.x <= 0.0
		or viewport_size.y <= 0.0
	):
		return {"valid": false, "error": "Stage viewport must have finite positive size"}
	var axis_limit := _transition_target_axis_limit()
	if viewport_size.x > axis_limit or viewport_size.y > axis_limit:
		return {
			"valid": false,
			"error": "Stage viewport %dx%d exceeds transition axis limit %d" % [
				int(viewport_size.x), int(viewport_size.y), axis_limit,
			],
		}
	var operations := request.get_operations()
	var initial_state: Dictionary = (
		_states.duplicate(true)
		if preflight_state_value == null
		else (preflight_state_value as Dictionary).duplicate(true)
	)
	var simulated := initial_state.duplicate(true)
	var operation_plans: Array = []
	var planned_bytes := 0
	for operation_index in range(operations.size()):
		var operation: StagePresentationOperation = operations[operation_index]
		var payload := operation.get_payload()
		if not StageLayerState.validate_operation(payload, false):
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": "operation failed canonical Stage validation",
			}
		var kind := String(payload.get("transition", "cut"))
		var params: Dictionary = payload.get("transition_params", {})
		var provider_validation := _transition_registry.validate_transition(
			kind,
			params,
			_load_stage_transition_texture,
		)
		if not bool(provider_validation.get("valid", false)):
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": String(provider_validation.get(
					"error", "transition provider rejected the operation")),
			}
		var before := simulated
		var reduced := StageLayerState.reduce(simulated, [payload], false)
		if not reduced is Dictionary:
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": "operation cannot be reduced",
			}
		simulated = (reduced as Dictionary).duplicate(true)
		var action := String(payload.get("action", ""))
		var layer_id := String(payload.get("id", ""))
		var affected_ids: Array[String] = []
		if action == "clear":
			var clear_ids := {}
			for value: Variant in before:
				clear_ids[String(value)] = true
			for value: Variant in _layers:
				clear_ids[String(value)] = true
			for value: Variant in clear_ids:
				affected_ids.append(String(value))
		elif before != simulated:
			affected_ids.append(layer_id)
		for affected_id: String in affected_ids:
			if simulated.has(affected_id):
				var resource_error := _preflight_stage_state_resources(
					simulated[affected_id])
				if not resource_error.is_empty():
					return {
						"valid": false,
						"operation_index": operation_index,
						"error": resource_error,
					}
		var is_projection := StageTransitionSpec.is_projection_effect(kind)
		var duration := float(payload.get("duration", 0.0))
		var snapshot_bytes := 0
		var projection_states: Array = []
		if (
			is_projection
			and not request.get_force_cut()
			and duration > 0.0
			and not affected_ids.is_empty()
		):
			snapshot_bytes = (
				int(viewport_size.x) * int(viewport_size.y) * 8
				* affected_ids.size()
			)
			planned_bytes += snapshot_bytes
			if (
				_active_transition_snapshot_bytes
				+ _pending_transition_snapshot_bytes
				+ planned_bytes
				> MAX_TRANSITION_SNAPSHOT_BYTES
			):
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": (
						"Stage transition snapshots require %d bytes; active budget is %d bytes"
						% [
							_active_transition_snapshot_bytes
							+ _pending_transition_snapshot_bytes
							+ planned_bytes,
							MAX_TRANSITION_SNAPSHOT_BYTES,
						]
					),
				}
			for affected_id: String in affected_ids:
				projection_states.append({
					"layer_id": affected_id,
					"source_state": (
						(before[affected_id] as Dictionary).duplicate(true)
						if before.has(affected_id) else null),
					"source_live": not before.has(affected_id) and _layers.has(affected_id),
					"target_state": (
						(simulated[affected_id] as Dictionary).duplicate(true)
						if simulated.has(affected_id) else null),
				})
		operation_plans.append({
			"kind": kind,
			"provider": provider_validation.get("provider"),
			"provider_plan": (
				provider_validation.get("plan", {}) as Dictionary).duplicate(true),
			"snapshot_bytes": snapshot_bytes,
			"projection_states": projection_states,
		})
	var allocated_holders: Array[Node] = []
	for operation_index in range(operation_plans.size()):
		var operation_plan: Dictionary = operation_plans[operation_index]
		var projections: Array = []
		for snapshot_value: Variant in operation_plan.get("projection_states", []):
			var snapshot: Dictionary = snapshot_value
			var layer_id := String(snapshot.get("layer_id", ""))
			var source_root: Node2D
			var source_state: Variant = snapshot.get("source_state")
			if source_state is Dictionary:
				source_root = _build_transition_snapshot_root(layer_id, source_state)
			elif bool(snapshot.get("source_live", false)) and _layers.has(layer_id):
				var live_root := (_layers[layer_id] as Dictionary)["root"] as Node2D
				source_root = live_root.duplicate(0) as Node2D
			var target_root: Node2D
			var target_state: Variant = snapshot.get("target_state")
			if target_state is Dictionary:
				target_root = _build_transition_snapshot_root(layer_id, target_state)
			for root in [source_root, target_root]:
				if root != null:
					var snapshot_error := _transition_snapshot_error(root)
					if not snapshot_error.is_empty():
						for allocated: Node in allocated_holders:
							if is_instance_valid(allocated) and allocated.get_parent() == null:
								allocated.free()
						for pending_root in [source_root, target_root]:
							if pending_root != null and pending_root.get_parent() == null:
								pending_root.free()
						return {
							"valid": false,
							"operation_index": operation_index,
							"error": snapshot_error,
						}
			var provider := operation_plan.get("provider") as StageTransitionProvider
			var prepared := _prepare_transition_projection(
				provider,
				operation_plan.get("provider_plan", {}),
				source_root,
				target_root,
				viewport_size,
			)
			if prepared.is_empty():
				for allocated: Node in allocated_holders:
					if is_instance_valid(allocated) and allocated.get_parent() == null:
						allocated.free()
				for pending_root in [source_root, target_root]:
					if pending_root != null and pending_root.get_parent() == null:
						pending_root.free()
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "transition provider could not create its sealed material",
				}
			allocated_holders.append(prepared["holder"])
			projections.append({
				"layer_id": layer_id,
				"source_root": source_root,
				"target_root": target_root,
				"prepared": prepared,
			})
		operation_plan.erase("projection_states")
		operation_plan["projections"] = projections
	return {"valid": true, "target_state": simulated.duplicate(true), "plan": {
		"viewport_size": viewport_size,
		"reserved_bytes": planned_bytes,
		"expected_before_state": initial_state,
		"operation_plans": operation_plans,
	}}


func _validate_stage_apply_plan(
	request: StageOperationRequest,
	plan: Dictionary,
) -> Dictionary:
	if Vector2(plan.get("viewport_size", Vector2.ZERO)) != _viewport_size():
		return {
			"valid": false,
			"operation_index": 0,
			"error": "sealed Stage viewport changed before apply",
		}
	var expected_state_value: Variant = plan.get("expected_before_state")
	if not expected_state_value is Dictionary or expected_state_value != _states:
		return {
			"valid": false,
			"operation_index": 0,
			"error": "sealed Stage source state changed before apply",
		}
	var operation_plans_value: Variant = plan.get("operation_plans")
	if (
		not operation_plans_value is Array
		or (operation_plans_value as Array).size() != request.get_operations().size()
	):
		return {
			"valid": false,
			"operation_index": 0,
			"error": "sealed Stage operation plan count is invalid",
		}
	var operation_plans: Array = operation_plans_value
	for operation_index in range(operation_plans.size()):
		var operation_plan_value: Variant = operation_plans[operation_index]
		if not operation_plan_value is Dictionary:
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": "sealed Stage operation plan is invalid",
			}
		var operation_plan: Dictionary = operation_plan_value
		var transition_kind := String(operation_plan.get("kind", ""))
		var provider_value: Variant = operation_plan.get("provider")
		if (
			StageTransitionSpec.is_projection_effect(transition_kind)
			and (
				not provider_value is StageTransitionProvider
				or not _transition_registry.owns_provider(
					transition_kind, provider_value as StageTransitionProvider)
			)
		):
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": "sealed Stage transition provider is unavailable at apply",
			}
		var projections_value: Variant = operation_plan.get("projections")
		if not projections_value is Array:
			return {
				"valid": false,
				"operation_index": operation_index,
				"error": "sealed Stage projection list is invalid",
			}
		for projection_value: Variant in projections_value:
			if not projection_value is Dictionary:
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "sealed Stage projection is invalid",
				}
			var projection: Dictionary = projection_value
			if bool(projection.get("consumed", false)):
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "sealed Stage projection was already consumed",
				}
			var prepared_value: Variant = projection.get("prepared")
			if not prepared_value is Dictionary:
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "sealed Stage projection preparation is invalid",
				}
			var prepared: Dictionary = prepared_value
			var holder_value: Variant = prepared.get("holder")
			var material_value: Variant = prepared.get("material")
			if (
				not holder_value is Node2D
				or not is_instance_valid(holder_value)
				or (holder_value as Node2D).is_queued_for_deletion()
				or (holder_value as Node2D).get_parent() != null
			):
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "sealed Stage projection holder is unavailable at apply",
				}
			if (
				not material_value is ShaderMaterial
				or not is_instance_valid(material_value)
				or (material_value as ShaderMaterial).shader == null
			):
				return {
					"valid": false,
					"operation_index": operation_index,
					"error": "sealed Stage transition material is unavailable at apply",
				}
	return {"valid": true}


func _preflight_stage_state_resources(state: Dictionary) -> String:
	for channel in ["asset", "body", "face"]:
		var asset_id := String(state.get(channel, "")).strip_edges()
		if asset_id.is_empty():
			continue
		if _load_stage_transition_texture(asset_id) == null:
			return "Stage %s resource '%s' could not be resolved" % [channel, asset_id]
	var redraw_value: Variant = state.get("redraw", [])
	if redraw_value is Array:
		for effect_value: Variant in redraw_value:
			if not effect_value is Dictionary:
				continue
			var effect: Dictionary = effect_value
			if String(effect.get("type", "")) != "clip":
				continue
			var clip_id := String(effect.get("asset", "")).strip_edges()
			if not clip_id.is_empty() and _load_stage_transition_texture(clip_id) == null:
				return "Stage redraw clip resource '%s' could not be resolved" % clip_id
	return ""


func _build_transition_snapshot_root(
	layer_id: String,
	state: Dictionary,
) -> Node2D:
	var record := _create_layer_record(layer_id)
	_apply_channels_cut(record, state)
	var visible := bool(state.get("visible", true))
	_apply_redraw(record, state, true, false, visible)
	_apply_transform_cut(record, state)
	var root := record["root"] as Node2D
	root.visible = visible
	(record["composite"] as CanvasGroup).self_modulate.a = clampf(
		float(state.get("opacity", 1.0)), 0.0, 1.0)
	return root


func _transition_snapshot_error(root: Node2D) -> String:
	var composite := root.get_node_or_null("Composite") as CanvasGroup
	if composite == null or not composite.visible:
		return "Stage transition snapshot could not allocate its sealed projection"
	return ""


func _load_stage_transition_texture(asset_id: String) -> Texture2D:
	var normalized := asset_id.strip_edges()
	if normalized.is_empty():
		return null
	if _transition_texture_cache.has(normalized):
		_transition_texture_cache_order.erase(normalized)
		_transition_texture_cache_order.append(normalized)
		return _transition_texture_cache[normalized] as Texture2D
	var texture := _load_stage_texture(normalized)
	if texture == null:
		return null
	_transition_texture_cache[normalized] = texture
	_transition_texture_cache_order.append(normalized)
	while _transition_texture_cache_order.size() > MAX_TRANSITION_TEXTURE_CACHE:
		var retired := _transition_texture_cache_order.pop_front()
		_transition_texture_cache.erase(retired)
	return texture


func _transition_target_axis_limit() -> int:
	var rendering_device := RenderingServer.get_rendering_device()
	if rendering_device == null:
		return mini(MAX_TRANSITION_TARGET_AXIS, FALLBACK_REDRAW_TARGET_AXIS)
	return mini(
		MAX_TRANSITION_TARGET_AXIS,
		int(rendering_device.limit_get(
			RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)),
	)


func _on_stage_operations_requested(operations: Array, force_cut: bool) -> void:
	if SignalBus.is_applying_typed_stage_request():
		return
	if not SignalBus.is_current_stage_operation_valid():
		return
	var previous_request_id := _active_stage_operation_request_id
	_active_stage_operation_request_id = SignalBus.current_stage_operation_request_id()
	_apply_operations(operations.duplicate(true), force_cut)
	_active_stage_operation_request_id = previous_request_id


func _apply_operations(
	operations: Array,
	force_cut: bool,
	transition_plans: Array = [],
) -> Dictionary:
	_begin_completion_batch()
	if force_cut:
		var cut_result := _apply_operations_cut(operations)
		_end_completion_batch()
		return cut_result

	for operation_index in range(operations.size()):
		var raw_operation: Variant = operations[operation_index]
		if not StageLayerState.validate_operation(raw_operation, true):
			_end_completion_batch()
			return {
				"success": false,
				"operation_index": operation_index,
				"error": "operation failed canonical Stage validation at apply",
			}
		var operation: Dictionary = raw_operation
		var transition_plan: Dictionary = (
			transition_plans[operation_index]
			if operation_index < transition_plans.size()
			and transition_plans[operation_index] is Dictionary
			else {}
		)
		var raw_transition := String(operation.get("transition", "cut"))
		var transition := _normalize_transition(
			"cut" if force_cut else raw_transition)
		if transition.is_empty():
			_end_completion_batch()
			return {
				"success": false,
				"operation_index": operation_index,
				"error": "Stage transition provider is not registered",
			}
		if (
			not force_cut
			and float(operation.get("duration", 0.0)) > 0.0
			and StageTransitionSpec.is_projection_effect(raw_transition)
			and transition_plan.get("provider") == null
		):
			push_error(
				"StagePresenter: transition '%s' requires typed participant preflight"
				% raw_transition)
			_end_completion_batch()
			return {
				"success": false,
				"operation_index": operation_index,
				"error": "projection transition lacks its sealed participant plan",
			}
		var before := _states.duplicate(true)
		var reduced = StageLayerState.reduce(_states, [operation], true)
		if not reduced is Dictionary:
			push_warning("StagePresenter: StageLayerState.reduce returned invalid state")
			_end_completion_batch()
			return {
				"success": false,
				"operation_index": operation_index,
				"error": "Stage reducer failed during apply",
			}

		_states = (reduced as Dictionary).duplicate(true)
		var duration := (
			0.0 if force_cut
			else maxf(0.0, float(operation.get("duration", 0.0)))
		)
		var action := String(operation.get("action", "update")).to_lower()
		var layer_id := String(operation.get("id", "")).strip_edges()

		if action == "clear":
			# Clear is the one authored action that also owns visuals whose
			# canonical state was already removed while a fade is still running.
			var clear_ids := {}
			for old_id in before:
				clear_ids[String(old_id)] = true
			for live_id in _layers:
				clear_ids[String(live_id)] = true
			var ordered_clear_ids := clear_ids.keys()
			ordered_clear_ids.sort()
			for clear_id in ordered_clear_ids:
				if not _remove_layer(
					String(clear_id), transition, duration, transition_plan):
					_end_completion_batch()
					return {
						"success": false,
						"operation_index": operation_index,
						"error": "sealed Stage clear transition could not be installed",
					}
			continue

		if layer_id == "":
			continue
		# Reducer-rejected unknown update/hide/remove operations must not touch
		# a same-id visual that is merely finishing an earlier fade-remove.
		if before == _states:
			continue
		var old_state: Dictionary = before.get(layer_id, {})
		if _states.has(layer_id):
			if not _apply_layer(
				layer_id,
				old_state,
				_states[layer_id],
				transition,
				duration,
				transition_plan,
			):
				_end_completion_batch()
				return {
					"success": false,
					"operation_index": operation_index,
					"error": "sealed Stage transition could not be installed",
				}
		elif before.has(layer_id):
			if not _remove_layer(layer_id, transition, duration, transition_plan):
				_end_completion_batch()
				return {
					"success": false,
					"operation_index": operation_index,
					"error": "sealed Stage remove transition could not be installed",
				}
	_end_completion_batch()
	return {"success": true}


## Skip/final-restore batches are reduced before any texture is touched. This
## makes the projection atomic and avoids loading every intermediate face from
## a long dialogue batch when only the final authored state can be visible.
func _apply_operations_cut(operations: Array) -> Dictionary:
	var before := _states.duplicate(true)
	var valid_operations: Array = []
	for operation_index in range(operations.size()):
		var operation: Variant = operations[operation_index]
		if not StageLayerState.validate_operation(operation, true):
			return {
				"success": false,
				"operation_index": operation_index,
				"error": "operation failed canonical Stage validation at cut apply",
			}
		valid_operations.append(operation)
	var affected_ids := _cut_batch_affected_ids(before, valid_operations)
	var reduced = StageLayerState.reduce(_states, valid_operations, true)
	if not reduced is Dictionary:
		push_warning("StagePresenter: StageLayerState.reduce returned invalid state")
		return {
			"success": false,
			"operation_index": 0,
			"error": "Stage reducer failed during cut apply",
		}
	_states = (reduced as Dictionary).duplicate(true)

	for layer_id in affected_ids:
		var id := String(layer_id)
		if _states.has(id):
			_apply_layer(id, before.get(id, {}), _states[id], "cut", 0.0)
		elif _layers.has(id):
			_remove_layer(id, "cut", 0.0)
	return {"success": true}


func _cut_batch_affected_ids(before: Dictionary, operations: Array) -> Dictionary:
	var affected_ids := {}
	var simulated := before.duplicate(true)

	for raw_operation in operations:
		var operation: Dictionary = raw_operation
		var action := String(operation.get("action", "")).to_lower()
		if action == "clear":
			for layer_id in simulated:
				affected_ids[String(layer_id)] = true
			# A non-cut remove drops canonical state immediately while its visual
			# may still be fading. Clear explicitly owns those pending visuals.
			for layer_id in _layers:
				affected_ids[String(layer_id)] = true
		var next = StageLayerState.reduce(simulated, [operation], false)
		if not next is Dictionary:
			continue
		var next_state: Dictionary = next
		if action != "clear":
			var layer_id := String(operation.get("id", "")).strip_edges()
			if layer_id != "" and simulated != next_state:
				affected_ids[layer_id] = true
		simulated = next_state
	return affected_ids


## Restore is a presentation-only exact projection of the named-stage target
## in one synchronous, transition-free pass. Matching ids retain their nodes and
## resident textures; absent ids are removed.
func _on_stage_state_apply_requested(layers: Dictionary) -> void:
	if not SignalBus.is_current_stage_projection_valid():
		return
	_begin_completion_batch()
	# Build the exact target first, then update matching ids in place.
	# Save/load still removes ids absent from the snapshot, while dialogue
	# finalization can cancel an active tween without throwing away an unchanged
	# background/body node and its resident texture references.
	var target_states: Dictionary = {}
	for raw_id in layers:
		var layer_id := String(raw_id).strip_edges()
		if layer_id == "":
			push_warning("StagePresenter: ignored restored layer with empty id")
			continue
		var raw_state = layers[raw_id]
		if not raw_state is Dictionary:
			push_warning("StagePresenter: ignored invalid restored layer '%s'" % layer_id)
			continue
		var state = StageLayerState.normalize_full(raw_state)
		if not state is Dictionary:
			push_warning("StagePresenter: failed to normalize restored layer '%s'" % layer_id)
			continue
		target_states[layer_id] = (state as Dictionary).duplicate(true)

	for raw_id in _layers.keys().duplicate():
		var layer_id := String(raw_id)
		if not target_states.has(layer_id):
			_free_layer(layer_id)
	for raw_id in _states.keys().duplicate():
		var layer_id := String(raw_id)
		if not target_states.has(layer_id):
			_states.erase(layer_id)

	for raw_id in target_states:
		var layer_id := String(raw_id)
		var old_state: Dictionary = _states.get(layer_id, {})
		_states[layer_id] = (target_states[layer_id] as Dictionary).duplicate(true)
		_apply_layer(layer_id, old_state, _states[layer_id], "cut", 0.0)
	_end_completion_batch()


## Finish only exact transitions previously acknowledged by this presenter.
## Layer ids alone are insufficient: a later command may have replaced a
## dialogue-owned tween on the same id before the dialogue completes.
func _on_stage_transitions_finish_requested(transitions: Array) -> void:
	_finish_stage_transitions(transitions, false)


## Strict batch receipts must match the complete Presenter-owned transition
## identity. Missing or malformed fields can never degrade to legacy matching.
func _on_stage_transition_receipts_finish_requested(
	transitions: Array,
) -> void:
	_finish_stage_transitions(transitions, true)


func _finish_stage_transitions(transitions: Array, strict: bool) -> void:
	_begin_completion_batch()
	for raw_transition in transitions:
		if not raw_transition is Dictionary:
			continue
		var transition_record: Dictionary = raw_transition
		if strict and not _is_strict_transition_receipt(transition_record):
			continue
		if (
			int(transition_record.get("presenter_instance_id", -1))
			!= get_instance_id()
		):
			continue
		var layer_id := String(transition_record.get("layer_id", "")).strip_edges()
		var token := int(transition_record.get("token", -1))
		if (
			layer_id == ""
			or token < 1
			or int(_layer_transition_tokens.get(layer_id, -1)) != token
			or (
				strict
				and int(transition_record.get("operation_request_id", -1))
				!= int(_layer_transition_request_ids.get(layer_id, -2))
			)
			or (
				strict
				and int(transition_record.get("generation", -1))
				!= int(_layer_transition_generations.get(layer_id, -2))
			)
			or not _layer_tweens.has(layer_id)
		):
			continue
		var identity := _take_active_transition(layer_id)
		if _states.has(layer_id):
			var target_state: Dictionary = _states[layer_id]
			_apply_layer(
				layer_id,
				target_state,
				target_state,
				"cut",
				0.0,
			)
		elif _layers.has(layer_id):
			# A fading remove has already left canonical state but still owns a
			# live node until its transition finishes.
			_remove_layer(layer_id, "cut", 0.0)
		_publish_stage_transition_terminal(identity, &"completed")
	_end_completion_batch()


func _is_strict_transition_receipt(record: Dictionary) -> bool:
	const EXACT_KEYS := [
		"generation",
		"layer_id",
		"operation_request_id",
		"presenter_instance_id",
		"token",
	]
	var keys := record.keys()
	keys.sort()
	if keys != EXACT_KEYS:
		return false
	if (
		not record["presenter_instance_id"] is int
		or not record["layer_id"] is String
		or not record["token"] is int
		or not record["operation_request_id"] is int
		or not record["generation"] is int
	):
		return false
	var layer_id := String(record["layer_id"])
	return (
		int(record["presenter_instance_id"]) > 0
		and layer_id == layer_id.strip_edges()
		and not layer_id.is_empty()
		and layer_id != "*"
		and int(record["token"]) > 0
		and int(record["operation_request_id"]) > 0
		and int(record["generation"]) > 0
	)


func _on_stage_visuals_reset_requested() -> void:
	if not SignalBus.is_current_stage_reset_valid():
		return
	# A newer reset owns every event it publishes. Drop only this transaction's
	# held commit events before the reset starts its own completion batch.
	_discard_all_held_stage_transactions()
	# Retire every frozen legacy completion before teardown can re-enter and
	# create a same-layer owner. Persistent per-layer counters handle ordinary
	# replacement; this epoch also invalidates absent remove completions.
	_completion_lifecycle_epoch += 1
	_begin_completion_batch()
	var cancelled := _clear_visuals(false)
	_states.clear()
	_layer_tweens.clear()
	_layer_transition_tokens.clear()
	_layer_transition_request_ids.clear()
	_layer_transition_generations.clear()
	_layer_generations.clear()
	_queued_transition_completions.clear()
	for identity: Dictionary in cancelled:
		_publish_stage_transition_terminal(identity, &"cancelled")
	_end_completion_batch()


func _apply_layer(
	layer_id: String,
	old_state: Dictionary,
	new_state: Dictionary,
	transition: String,
	duration: float,
	transition_plan: Dictionary = {},
) -> bool:
	var record := _ensure_layer(layer_id)
	var change := _begin_layer_change(layer_id)
	var generation := int(change["generation"])
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	var was_visible := root.visible and composite.self_modulate.a > 0.0001
	var old_target_visible := bool(old_state.get("visible", false))
	var target_visible := bool(new_state.get("visible", true))
	var target_opacity := clampf(float(new_state.get("opacity", 1.0)), 0.0, 1.0)
	var animate := (
		duration > 0.0
		and transition != "cut"
		and (old_target_visible or target_visible)
	)
	var provider := transition_plan.get("provider") as StageTransitionProvider
	if animate and provider != null:
		_apply_channels_cut(record, new_state)
		_apply_redraw(record, new_state, true, false, target_visible)
		_apply_transform_cut(record, new_state)
		root.visible = target_visible
		composite.self_modulate.a = target_opacity
		if _start_projection_transition(
			layer_id,
			record,
			new_state,
			duration,
			transition_plan,
			generation,
			false,
			):
				_publish_superseded_transition(change)
				return true
		return false

	if not animate:
		_apply_channels_cut(record, new_state)
		_apply_redraw(record, new_state, true, false, target_visible)
		_apply_transform_cut(record, new_state)
		root.visible = target_visible
		composite.self_modulate.a = target_opacity
		_emit_or_queue_transition_finished(layer_id, generation, true)
		_publish_superseded_transition(change)
		return true

	root.visible = true
	if not was_visible:
		# A fade-in should not also fly from Node2D's default origin. Slide
		# transitions establish their own off-screen starting point below.
		_apply_transform_cut(record, new_state)
	var tween := create_tween().set_parallel(true)
	_layer_tweens[layer_id] = tween

	var crossfade_textures := transition == "fade" and target_visible and was_visible
	var source_changes := _apply_channels_animated(
		record,
		new_state,
		tween,
		crossfade_textures,
		duration,
	)
	_apply_redraw(record, new_state, true, source_changes)
	_tween_transform(
		record,
		new_state,
		tween,
		duration,
		not transition.begins_with("slide"),
	)

	if transition == "fade":
		if not was_visible and target_visible:
			composite.self_modulate.a = 0.0
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)
	elif transition.begins_with("slide"):
		var target_position := _state_position(new_state)
		var delta := _slide_delta(transition)
		if not was_visible and target_visible:
			root.position = target_position - delta
		elif not target_visible:
			target_position += delta
		tween.tween_property(root, "position", target_position, duration) \
			.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)
	else:
		# "move" and future transform transitions interpolate authored values
		# without inventing an off-screen start position.
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)

	var token := _claim_layer_transition(layer_id, generation)
	tween.finished.connect(func() -> void:
		if generation != int(_layer_generations.get(layer_id, -1)):
			return
		_begin_completion_batch()
		var identity := _active_transition_identity(layer_id)
		_layer_tweens.erase(layer_id)
		_clear_layer_transition_token(layer_id, token)
		_cleanup_outgoing(record)
		_apply_channels_cut(record, new_state)
		if target_visible:
			# The live blur target covered both transition endpoints (and an outgoing
			# crossfade sprite). Reproject once at the canonical endpoint so an
			# UPDATE_ALWAYS pipeline does not retain that allocation forever.
			_apply_redraw(record, new_state, true)
		else:
			# Hidden layers retain canonical state and resident resources, but no
			# derived render targets until they are shown again.
			_clear_redraw_pipeline(record)
			record["redraw_pipeline_dynamic"] = false
		_apply_transform_cut(record, new_state)
		composite.self_modulate.a = target_opacity
		root.visible = target_visible
		_emit_or_queue_transition_finished(layer_id, generation, true)
		_publish_stage_transition_terminal(identity, &"completed")
		_end_completion_batch()
	)
	_emit_stage_transition_started(layer_id, token)
	_publish_superseded_transition(change)
	return true


func _remove_layer(
	layer_id: String,
	transition: String,
	duration: float,
	transition_plan: Dictionary = {},
) -> bool:
	if not _layers.has(layer_id):
		return true
	var record: Dictionary = _layers[layer_id]
	var change := _begin_layer_change(layer_id)
	var generation := int(change["generation"])
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	var provider := transition_plan.get("provider") as StageTransitionProvider
	if duration > 0.0 and transition != "cut" and provider != null:
		if _start_projection_transition(
			layer_id,
			record,
			{},
			duration,
			transition_plan,
			generation,
			true,
			):
				_publish_superseded_transition(change)
				return true
		return false

	if duration <= 0.0 or transition == "cut":
		_free_layer(layer_id)
		_emit_or_queue_transition_finished(layer_id, generation, false)
		_publish_superseded_transition(change)
		return true

	var tween := create_tween().set_parallel(true)
	_layer_tweens[layer_id] = tween
	if transition.begins_with("slide"):
		tween.tween_property(
			root,
			"position",
			root.position + _slide_delta(transition),
			duration,
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		tween.tween_property(composite, "self_modulate:a", 0.0, duration)

	var token := _claim_layer_transition(layer_id, generation)
	tween.finished.connect(func() -> void:
		if generation != int(_layer_generations.get(layer_id, -1)):
			return
		_begin_completion_batch()
		var identity := _active_transition_identity(layer_id)
		_layer_tweens.erase(layer_id)
		_clear_layer_transition_token(layer_id, token)
		_free_layer(layer_id)
		_emit_or_queue_transition_finished(layer_id, generation, false)
		_publish_stage_transition_terminal(identity, &"completed")
		_end_completion_batch()
	)
	_emit_stage_transition_started(layer_id, token)
	_publish_superseded_transition(change)
	return true


func _start_projection_transition(
	layer_id: String,
	record: Dictionary,
	target_state: Dictionary,
	duration: float,
	transition_plan: Dictionary,
	generation: int,
	removing: bool,
) -> bool:
	var provider := transition_plan.get("provider") as StageTransitionProvider
	var projection := _take_preflight_projection(transition_plan, layer_id)
	if provider == null or projection.is_empty():
		return false
	var prepared: Dictionary = projection.get("prepared", {})
	var holder := prepared.get("holder") as Node2D
	var material := prepared.get("material") as ShaderMaterial
	if (
		holder == null
		or material == null
		or material.shader == null
		or holder.get_parent() != null
	):
		return false
	holder.name = "Transition_%s" % layer_id
	holder.z_as_relative = false
	holder.z_index = clampi(
		int(target_state.get(
			"z_index", (record["root"] as Node2D).z_index)),
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	_layer_host().add_child(holder)
	var snapshot_bytes := int(prepared.get("snapshot_bytes", 0))
	_active_transition_snapshot_bytes += snapshot_bytes
	_layer_transition_projections[layer_id] = {
		"holder": holder,
		"bytes": snapshot_bytes,
		"removing": removing,
	}
	(record["root"] as Node2D).visible = false
	var tween := create_tween()
	_layer_tweens[layer_id] = tween
	tween.tween_method(
		func(progress: float) -> void:
			material.set_shader_parameter("progress", progress),
		0.0,
		1.0,
		duration,
	)
	var token := _claim_layer_transition(layer_id, generation)
	tween.finished.connect(func() -> void:
		if generation != int(_layer_generations.get(layer_id, -1)):
			return
		_begin_completion_batch()
		var identity := _active_transition_identity(layer_id)
		_layer_tweens.erase(layer_id)
		_clear_layer_transition_token(layer_id, token)
		_cleanup_transition_projection(layer_id, not removing)
		if removing:
			_free_layer(layer_id)
		else:
			var root := record["root"] as Node2D
			var composite := record["composite"] as CanvasGroup
			var target_visible := bool(target_state.get("visible", true))
			root.visible = target_visible
			composite.self_modulate.a = clampf(
				float(target_state.get("opacity", 1.0)), 0.0, 1.0)
			_emit_or_queue_transition_finished(layer_id, generation, not removing)
		_publish_stage_transition_terminal(identity, &"completed")
		_end_completion_batch()
	)
	_emit_stage_transition_started(layer_id, token)
	return true


func _take_preflight_projection(
	transition_plan: Dictionary,
	layer_id: String,
) -> Dictionary:
	var projections: Array = transition_plan.get("projections", [])
	for projection_value: Variant in projections:
		if not projection_value is Dictionary:
			continue
		var projection: Dictionary = projection_value
		if (
			String(projection.get("layer_id", "")) == layer_id
			and not bool(projection.get("consumed", false))
		):
			projection["consumed"] = true
			return projection
	return {}


func _new_transition_snapshot_viewport(
	root: Node2D,
	size: Vector2i,
) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if root != null:
		viewport.add_child(root)
	return viewport


func _prepare_transition_projection(
	provider: StageTransitionProvider,
	provider_plan: Dictionary,
	source_root: Node2D,
	target_root: Node2D,
	viewport_size_value: Vector2,
) -> Dictionary:
	if provider == null:
		return {}
	var viewport_size := Vector2i(
		maxi(1, int(viewport_size_value.x)),
		maxi(1, int(viewport_size_value.y)),
	)
	var holder := Node2D.new()
	var source_viewport := _new_transition_snapshot_viewport(
		source_root, viewport_size)
	var target_viewport := _new_transition_snapshot_viewport(
		target_root, viewport_size)
	holder.add_child(source_viewport)
	holder.add_child(target_viewport)
	var material := provider.create_material(
		provider_plan,
		source_viewport.get_texture(),
		target_viewport.get_texture(),
		Vector2(viewport_size),
	)
	if material == null or material.shader == null:
		holder.free()
		return {}
	var display := ColorRect.new()
	display.name = "Projection"
	display.position = Vector2.ZERO
	display.size = Vector2(viewport_size)
	display.color = Color.WHITE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.material = material
	holder.add_child(display)
	return {
		"holder": holder,
		"material": material,
		"snapshot_bytes": int(viewport_size.x) * int(viewport_size.y) * 8,
	}


func _cleanup_transition_projection(layer_id: String, show_live: bool) -> void:
	if not _layer_transition_projections.has(layer_id):
		return
	var projection: Dictionary = _layer_transition_projections[layer_id]
	_layer_transition_projections.erase(layer_id)
	_active_transition_snapshot_bytes = maxi(
		0,
		_active_transition_snapshot_bytes - int(projection.get("bytes", 0)),
	)
	var holder := projection.get("holder") as Node
	if is_instance_valid(holder):
		if holder.get_parent() != null:
			holder.get_parent().remove_child(holder)
		holder.queue_free()
	if show_live and _layers.has(layer_id) and _states.has(layer_id):
		var record: Dictionary = _layers[layer_id]
		(record["root"] as Node2D).visible = bool(
			(_states[layer_id] as Dictionary).get("visible", true))


func _begin_completion_batch() -> void:
	_completion_batch_depth += 1


func _end_completion_batch() -> void:
	_completion_batch_depth = maxi(0, _completion_batch_depth - 1)
	# Receipt starts are part of the submitting batch's synchronous dispatch
	# contract. A batch installed from an outer completion/terminal callback must
	# still publish its exact receipts before its own SignalBus dispatch tail.
	if _completion_batch_depth == 0 and not _flushing_transition_starts:
		_flush_transition_starts()
	_drain_presentation_events()


func _emit_or_queue_transition_finished(
	layer_id: String,
	generation: int,
	expects_layer: bool,
) -> void:
	var completion := {
		"id": layer_id,
		"generation": generation,
		"expects_layer": expects_layer,
		"lifecycle_epoch": _completion_lifecycle_epoch,
	}
	_queued_transition_completions.append(completion)
	_drain_presentation_events()


func _flush_transition_completions() -> void:
	if _flushing_transition_completions:
		return
	_flushing_transition_completions = true
	var snapshot := _queued_transition_completions.duplicate(true)
	_queued_transition_completions.clear()
	for completion: Dictionary in snapshot:
		if _is_transition_completion_current(completion):
			layer_transition_finished.emit(String(completion["id"]))
	_flushing_transition_completions = false


func _is_transition_completion_current(completion: Dictionary) -> bool:
	var layer_id := String(completion.get("id", ""))
	var generation := int(completion.get("generation", -2))
	if (
		int(completion.get("lifecycle_epoch", -1))
			!= _completion_lifecycle_epoch
		or int(_layer_generation_counters.get(layer_id, -1)) != generation
	):
		return false
	if bool(completion.get("expects_layer", false)):
		return (
			_states.has(layer_id)
			and _layers.has(layer_id)
			and int(_layer_generations.get(layer_id, -1)) == generation
		)
	return not _states.has(layer_id) and not _layers.has(layer_id)


func _layer_host() -> Node:
	var shake_root := get_node_or_null("ShakeRoot")
	return shake_root if shake_root != null else self


func _ensure_layer(layer_id: String) -> Dictionary:
	if _layers.has(layer_id):
		return _layers[layer_id]
	var record := _create_layer_record(layer_id)
	_layer_host().add_child(record["root"])
	_layers[layer_id] = record
	return record


func _create_layer_record(layer_id: String) -> Dictionary:

	var root := Node2D.new()
	root.name = "Layer_%d" % _next_node_index
	_next_node_index += 1
	root.set_meta("stage_layer_id", layer_id)
	root.z_as_relative = false
	root.visible = false

	var composite := CanvasGroup.new()
	composite.name = "Composite"
	root.add_child(composite)
	var source := Node2D.new()
	source.name = "Source"
	composite.add_child(source)
	var redraw_material := ShaderMaterial.new()
	redraw_material.shader = _redraw_shader

	var sprites := {}
	var asset_ids := {}
	for channel in ["asset", "body", "face"]:
		var sprite := Sprite2D.new()
		sprite.name = "%sSprite" % channel.capitalize()
		sprite.centered = false
		sprite.z_index = {"asset": 0, "body": 1, "face": 2}[channel]
		source.add_child(sprite)
		sprites[channel] = sprite
		asset_ids[channel] = ""

	return {
		"root": root,
		"composite": composite,
		"source": source,
		"sprites": sprites,
		"asset_ids": asset_ids,
		"outgoing": [],
		"redraw": [],
		"redraw_material": redraw_material,
		"redraw_mask_asset": "",
		"redraw_mask_texture": null,
		"redraw_pipeline_root": null,
		"redraw_pipeline_output": null,
		"redraw_pipeline_passes": [],
		"redraw_pipeline_signature": [],
		"redraw_render_bounds": Rect2(),
		"redraw_pipeline_dynamic": false,
		"redraw_dynamic_size_signature": [],
	}


func _begin_layer_change(layer_id: String) -> Dictionary:
	var superseded := _take_active_transition(layer_id)
	var generation := _claim_next_layer_generation(layer_id)
	if _layers.has(layer_id):
		var record: Dictionary = _layers[layer_id]
		_cleanup_outgoing(record)
		for sprite in (record["sprites"] as Dictionary).values():
			(sprite as Sprite2D).modulate.a = 1.0
		_set_redraw_pipeline_update_mode(
			record,
			bool(record.get("redraw_pipeline_dynamic", false)),
		)
	return {
		"generation": generation,
		"superseded": superseded,
	}


func _claim_next_layer_generation(layer_id: String) -> int:
	var generation := int(_layer_generation_counters.get(layer_id, 0)) + 1
	_layer_generation_counters[layer_id] = generation
	_layer_generations[layer_id] = generation
	return generation


## Publish only after the replacement owner is fully installed. While an
## atomic Stage dispatch is still mutating other members, defer the callback to
## the batch tail so a reentrant listener cannot overwrite a partial batch.
func _publish_superseded_transition(change: Dictionary) -> void:
	var identity: Dictionary = change.get("superseded", {})
	if identity.is_empty():
		return
	_publish_stage_transition_terminal(identity, &"superseded")


func _publish_stage_transition_terminal(
	identity: Dictionary,
	outcome: StringName,
) -> void:
	if identity.is_empty():
		return
	_queued_stage_terminals.append({
		"identity": identity.duplicate(true),
		"outcome": outcome,
	})
	_drain_presentation_events()


func _flush_stage_terminals() -> void:
	if _flushing_stage_terminals:
		return
	_flushing_stage_terminals = true
	var snapshot := _queued_stage_terminals.duplicate(true)
	_queued_stage_terminals.clear()
	for terminal: Dictionary in snapshot:
		_emit_stage_transition_terminal(
			terminal["identity"], StringName(terminal["outcome"]))
	_flushing_stage_terminals = false


func _drain_presentation_events() -> void:
	if (
		_completion_batch_depth > 0
		or _flushing_transition_starts
		or _flushing_transition_completions
		or _flushing_stage_terminals
	):
		return
	while true:
		if not _queued_transition_starts.is_empty():
			_flush_transition_starts()
			continue
		if not _queued_transition_completions.is_empty():
			_flush_transition_completions()
			continue
		if not _queued_stage_terminals.is_empty():
			_flush_stage_terminals()
			continue
		break


func _claim_layer_transition(layer_id: String, generation: int) -> int:
	var token := _next_transition_token
	_next_transition_token += 1
	_layer_transition_tokens[layer_id] = token
	_layer_transition_request_ids[layer_id] = _active_stage_operation_request_id
	_layer_transition_generations[layer_id] = generation
	return token


func _emit_stage_transition_started(layer_id: String, token: int) -> void:
	var identity := _active_transition_identity(layer_id)
	if identity.is_empty() or int(identity.get("token", 0)) != token:
		return
	_queued_transition_starts.append(identity.duplicate(true))
	_drain_presentation_events()


func _flush_transition_starts() -> void:
	if _flushing_transition_starts:
		return
	_flushing_transition_starts = true
	var snapshot := _queued_transition_starts.duplicate(true)
	_queued_transition_starts.clear()
	for identity: Dictionary in snapshot:
		if not _transition_identity_is_current(identity):
			continue
		SignalBus.stage_transition_receipt_started.emit(
			int(identity["presenter_instance_id"]),
			String(identity["layer_id"]),
			int(identity["token"]),
			int(identity["operation_request_id"]),
			int(identity["generation"]),
		)
		# An exact-start listener may synchronously reset or replace this owner.
		# Never publish the legacy companion for a transition that died in that
		# callback, and never continue mutating the retired outer batch.
		if not _transition_identity_is_current(identity):
			continue
		SignalBus.stage_transition_started.emit(
			int(identity["presenter_instance_id"]),
			String(identity["layer_id"]),
			int(identity["token"]),
			int(identity["operation_request_id"]),
		)
	_flushing_transition_starts = false


func _transition_identity_is_current(identity: Dictionary) -> bool:
	var layer_id := String(identity.get("layer_id", ""))
	return (
		SignalBus.is_current_stage_operation_valid()
		and int(identity.get("presenter_instance_id", 0)) == get_instance_id()
		and not layer_id.is_empty()
		and int(identity.get("token", 0))
			== int(_layer_transition_tokens.get(layer_id, -1))
		and int(identity.get("operation_request_id", 0))
			== int(_layer_transition_request_ids.get(layer_id, -1))
		and int(identity.get("generation", 0))
			== int(_layer_transition_generations.get(layer_id, -1))
		and _layer_tweens.has(layer_id)
	)


func _clear_layer_transition_token(layer_id: String, token: int) -> void:
	if int(_layer_transition_tokens.get(layer_id, -1)) == token:
		_layer_transition_tokens.erase(layer_id)
		_layer_transition_request_ids.erase(layer_id)
		_layer_transition_generations.erase(layer_id)


func _active_transition_identity(layer_id: String) -> Dictionary:
	var token := int(_layer_transition_tokens.get(layer_id, 0))
	if token <= 0:
		return {}
	return {
		"presenter_instance_id": get_instance_id(),
		"layer_id": layer_id,
		"token": token,
		"operation_request_id": int(
			_layer_transition_request_ids.get(layer_id, 0)),
		"generation": int(_layer_transition_generations.get(layer_id, 0)),
	}


func _take_active_transition(layer_id: String) -> Dictionary:
	var identity := _active_transition_identity(layer_id)
	var token := int(identity.get("token", 0))
	if _layer_tweens.has(layer_id):
		var tween := _layer_tweens[layer_id] as Tween
		if tween != null and tween.is_valid():
			tween.kill()
		_layer_tweens.erase(layer_id)
	if token > 0:
		_clear_layer_transition_token(layer_id, token)
	_cleanup_transition_projection(layer_id, true)
	return identity


func _emit_stage_transition_terminal(
	identity: Dictionary,
	outcome: StringName,
) -> void:
	if identity.is_empty():
		return
	SignalBus.stage_transition_terminal.emit(
		int(identity.get("presenter_instance_id", 0)),
		String(identity.get("layer_id", "")),
		int(identity.get("token", 0)),
		int(identity.get("operation_request_id", 0)),
		int(identity.get("generation", 0)),
		outcome,
	)


func _cleanup_outgoing(record: Dictionary) -> void:
	for node in record.get("outgoing", []):
		if not is_instance_valid(node):
			continue
		var parent := (node as Node).get_parent()
		if parent:
			parent.remove_child(node)
		(node as Node).queue_free()
	record["outgoing"] = []


func _free_layer(layer_id: String, emit_terminal: bool = true) -> Dictionary:
	var cancelled := _take_active_transition(layer_id)
	_cleanup_transition_projection(layer_id, false)
	if not _layers.has(layer_id):
		if emit_terminal:
			_publish_stage_transition_terminal(cancelled, &"cancelled")
		return cancelled
	var record: Dictionary = _layers[layer_id]
	_cleanup_outgoing(record)
	var root := record["root"] as Node2D
	if is_instance_valid(root):
		if root.get_parent():
			root.get_parent().remove_child(root)
		root.queue_free()
	_layers.erase(layer_id)
	_layer_generations.erase(layer_id)
	if emit_terminal:
		_publish_stage_transition_terminal(cancelled, &"cancelled")
	return cancelled


func _clear_visuals(emit_terminals: bool = true) -> Array[Dictionary]:
	var cancelled: Array[Dictionary] = []
	var layer_ids := {}
	for layer_id: Variant in _layers:
		layer_ids[String(layer_id)] = true
	for layer_id: Variant in _layer_transition_tokens:
		layer_ids[String(layer_id)] = true
	for layer_id: Variant in layer_ids:
		var identity := _free_layer(String(layer_id), emit_terminals)
		if not identity.is_empty():
			cancelled.append(identity)
	return cancelled


func _apply_channels_cut(record: Dictionary, state: Dictionary) -> void:
	for channel in ["asset", "body", "face"]:
		_set_channel_texture(record, channel, String(state.get(channel, "")), null, false)
		_apply_channel_layout(record, channel, state)


func _apply_channels_animated(
	record: Dictionary,
	state: Dictionary,
	tween: Tween,
	crossfade: bool,
	duration: float,
) -> bool:
	var source_changes := false
	for channel in ["asset", "body", "face"]:
		var changed := _set_channel_texture(
			record,
			channel,
			String(state.get(channel, "")),
			tween,
			crossfade,
			duration,
		)
		var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
		var target := _channel_layout(sprite, channel, state)
		if not sprite.position.is_equal_approx(target["position"]):
			tween.tween_property(sprite, "position", target["position"], duration)
			source_changes = true
		if not sprite.scale.is_equal_approx(target["scale"]):
			tween.tween_property(sprite, "scale", target["scale"], duration)
			source_changes = true
		sprite.centered = target["centered"]
		if crossfade and changed and sprite.texture != null:
			tween.tween_property(sprite, "modulate:a", 1.0, duration)
		if crossfade and changed:
			source_changes = true
	return source_changes


func _set_channel_texture(
	record: Dictionary,
	channel: String,
	asset_id: String,
	tween: Tween,
	crossfade: bool,
	duration: float = 0.0,
) -> bool:
	var asset_ids := record["asset_ids"] as Dictionary
	if String(asset_ids.get(channel, "")) == asset_id:
		return false

	var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
	var new_texture: Texture2D = null
	if asset_id != "":
		new_texture = _load_stage_texture(asset_id)
		if new_texture == null:
			push_warning("StagePresenter: texture not found: %s" % asset_id)
			# Keep the visible projection deterministic with the canonical state:
			# a missing target clears this channel both now and after save/restore,
			# rather than retaining an old texture that the snapshot cannot name.

	if crossfade and tween != null and sprite.texture != null:
		var outgoing := _clone_sprite(sprite)
		outgoing.name = "Outgoing_%s" % channel
		(record["source"] as Node2D).add_child(outgoing)
		(record["outgoing"] as Array).append(outgoing)
		tween.tween_property(outgoing, "modulate:a", 0.0, duration)

	sprite.texture = new_texture
	asset_ids[channel] = asset_id
	if crossfade and tween != null and new_texture != null:
		sprite.modulate.a = 0.0
		# The caller adds the real-duration alpha track below after this helper.
	return true


func _clone_sprite(source: Sprite2D) -> Sprite2D:
	var clone := Sprite2D.new()
	clone.texture = source.texture
	clone.position = source.position
	clone.scale = source.scale
	clone.rotation = source.rotation
	clone.centered = source.centered
	clone.offset = source.offset
	clone.flip_h = source.flip_h
	clone.flip_v = source.flip_v
	clone.z_index = source.z_index
	clone.modulate = source.modulate
	return clone


func _apply_channel_layout(record: Dictionary, channel: String, state: Dictionary) -> void:
	var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
	var layout := _channel_layout(sprite, channel, state)
	sprite.centered = layout["centered"]
	sprite.position = layout["position"]
	sprite.scale = layout["scale"]
	sprite.modulate.a = 1.0


func _channel_layout(sprite: Sprite2D, channel: String, state: Dictionary) -> Dictionary:
	var offset := _array_to_vector2(state.get("%s_offset" % channel, [0.0, 0.0]))
	if channel != "asset" or sprite.texture == null:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}

	var fit := String(state.get("fit", "native"))
	if fit in ["native", "none", ""]:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}

	var texture_size := sprite.texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}
	var viewport_size := _viewport_size()
	var fit_scale := Vector2.ONE
	match fit:
		"cover":
			var factor := maxf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
			fit_scale = Vector2(factor, factor)
		"contain":
			var factor := minf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
			fit_scale = Vector2(factor, factor)
		"stretch":
			fit_scale = Vector2(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
		_:
			push_warning("StagePresenter: unknown fit mode '%s'; using native" % fit)
			return {"centered": false, "position": offset, "scale": Vector2.ONE}
	return {
		"centered": true,
		"position": viewport_size * 0.5 + offset,
		"scale": fit_scale,
	}


func _apply_transform_cut(record: Dictionary, state: Dictionary) -> void:
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	root.position = _state_position(state)
	root.rotation_degrees = float(state.get("rotation", 0.0))
	root.scale = _state_scale(state)
	root.z_index = clampi(
		int(state.get("z_index", 0)),
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	composite.position = _composite_origin_position(state)
	composite.scale = Vector2(
		-1.0 if bool(state.get("flip_x", false)) else 1.0,
		-1.0 if bool(state.get("flip_y", false)) else 1.0,
	)


func _tween_transform(
	record: Dictionary,
	state: Dictionary,
	tween: Tween,
	duration: float,
	tween_position: bool = true,
) -> void:
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	root.z_index = clampi(
		int(state.get("z_index", 0)),
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	if tween_position:
		tween.tween_property(root, "position", _state_position(state), duration)
	tween.tween_property(
		root,
		"rotation_degrees",
		float(state.get("rotation", 0.0)),
		duration,
	)
	tween.tween_property(root, "scale", _state_scale(state), duration)
	tween.tween_property(
		composite,
		"position",
		_composite_origin_position(state),
		duration,
	)
	composite.scale = Vector2(
		-1.0 if bool(state.get("flip_x", false)) else 1.0,
		-1.0 if bool(state.get("flip_y", false)) else 1.0,
	)


func _state_position(state: Dictionary) -> Vector2:
	return _array_to_vector2(state.get("position", [0.0, 0.0]))


func _state_scale(state: Dictionary) -> Vector2:
	var scale_value := _array_to_vector2(state.get("scale", [1.0, 1.0]), Vector2.ONE)
	var zoom := _array_to_vector2(state.get("zoom", [1.0, 1.0]), Vector2.ONE)
	var depth_scale := float(state.get("depth_scale", 1.0))
	return scale_value * zoom * depth_scale


func _composite_origin_position(state: Dictionary) -> Vector2:
	var origin := _array_to_vector2(state.get("origin", [0.0, 0.0]))
	var flip := Vector2(
		-1.0 if bool(state.get("flip_x", false)) else 1.0,
		-1.0 if bool(state.get("flip_y", false)) else 1.0,
	)
	return -(flip * origin)


func _apply_redraw(
	record: Dictionary,
	state: Dictionary,
	force_layout: bool = false,
	continuous: bool = false,
	build_pipeline: bool = true,
) -> void:
	var redraw_value = state.get("redraw", [])
	var redraw: Array = redraw_value if redraw_value is Array else []
	var previous_redraw = record.get("redraw", [])
	if previous_redraw is Array and previous_redraw == redraw:
		if force_layout:
			_set_redraw_parameters(
				record,
				redraw,
				state,
				continuous,
				build_pipeline,
			)
		else:
			_update_redraw_margin(record, redraw, state)
		return

	_set_redraw_parameters(record, redraw, state, continuous, build_pipeline)
	record["redraw"] = redraw.duplicate(true)


func _set_redraw_parameters(
	record: Dictionary,
	redraw: Array,
	state: Dictionary,
	continuous: bool = false,
	build_pipeline: bool = true,
) -> void:
	var composite := record["composite"] as CanvasGroup
	var material := record["redraw_material"] as ShaderMaterial
	# A previous oversized projection may have failed closed. Every new valid
	# projection explicitly restores the composite.
	composite.visible = true
	composite.use_mipmaps = false
	var split := _split_redraw(redraw)
	var blur_passes: Array = split["blur_passes"]
	var suffix_effects: Array = split["suffix_effects"]
	var clip_effect := _find_clip_effect(redraw)
	var clip_texture: Texture2D = null
	var clip_rect := Rect2(Vector2.ZERO, Vector2.ONE)
	if not clip_effect.is_empty():
		var clip_asset := String(clip_effect.get("asset", ""))
		clip_texture = _redraw_texture(record, clip_asset)
		clip_rect = _clip_rect(clip_texture, clip_effect)
	else:
		record["redraw_mask_asset"] = ""
		record["redraw_mask_texture"] = null
	record["redraw_dynamic_size_signature"] = (
		_redraw_dynamic_size_signature(record, clip_texture)
	)

	if blur_passes.is_empty():
		record["redraw_pipeline_dynamic"] = false
		_clear_redraw_pipeline(record)
		material.shader = _redraw_shader
		_configure_pointwise_material(
			material,
			suffix_effects,
			clip_texture,
			clip_rect,
		)
		composite.material = material if not suffix_effects.is_empty() else null
	elif not build_pipeline:
		# Hidden canonical states retain their reusable resources and pointwise
		# configuration without ever allocating derived render targets. A later
		# show re-evaluates bounds and safety limits before building the pipeline.
		record["redraw_pipeline_dynamic"] = false
		_clear_redraw_pipeline(record)
		material.shader = _redraw_texture_shader
		_configure_pointwise_material(
			material,
			suffix_effects,
			clip_texture,
			clip_rect,
		)
		composite.material = null
	else:
		var pipeline_dynamic := _redraw_uses_dynamic_textures(
			record,
			blur_passes,
			clip_texture,
		)
		var updates_continuously := continuous or pipeline_dynamic
		record["redraw_pipeline_dynamic"] = pipeline_dynamic
		var bounds := _redraw_render_bounds(record, state, blur_passes)
		var allocation_error := _redraw_pipeline_allocation_error(
			bounds,
			blur_passes,
			updates_continuously,
		)
		if not allocation_error.is_empty():
			_clear_redraw_pipeline(record)
			record["redraw_pipeline_dynamic"] = false
			composite.material = null
			composite.visible = false
			var layer_id := String(
				(record["root"] as Node).get_meta("stage_layer_id", "")
			)
			push_error(
				"StagePresenter: redraw pipeline for layer '%s': %s"
				% [layer_id, allocation_error]
			)
			_update_redraw_margin(record, redraw, state)
			return
		_ensure_redraw_pipeline(record, blur_passes, bounds)
		_configure_redraw_pipeline(
			record,
			blur_passes,
			suffix_effects,
			clip_texture,
			clip_rect,
			bounds,
		)
		composite.material = null
		_set_redraw_pipeline_update_mode(
			record,
			updates_continuously,
		)
	_update_redraw_margin(record, redraw, state)


func _redraw_pipeline_allocation_error(
	bounds: Rect2,
	blur_passes: Array,
	continuous: bool,
) -> String:
	var pass_count := blur_passes.size()
	if pass_count > StageLayerState.MAX_BLUR_PASSES:
		return (
			"redraw pipeline has %d blur passes; maximum is %d"
			% [pass_count, StageLayerState.MAX_BLUR_PASSES]
		)
	if (
		not bounds.position.is_finite()
		or not bounds.size.is_finite()
		or bounds.size.x <= 0.0
		or bounds.size.y <= 0.0
	):
		return "redraw target bounds must be finite with positive size"
	var width := int(bounds.size.x)
	var height := int(bounds.size.y)
	var axis_limit := _redraw_target_axis_limit()
	if width > axis_limit or height > axis_limit:
		return (
			"redraw target %dx%d exceeds the %d-pixel axis limit"
			% [width, height, axis_limit]
		)
	var pixel_count := width * height
	var bytes_per_pixel := (
		REDRAW_SOURCE_BYTES_PER_PIXEL
		+ _redraw_blur_pass_bytes_per_pixel() * pass_count
	)
	var estimated_bytes := pixel_count * bytes_per_pixel
	if estimated_bytes > MAX_REDRAW_TARGET_BYTES:
		return (
			"redraw target %dx%d with %d blur passes requires an estimated "
			+ "%d bytes; per-layer limit is %d bytes"
		) % [
			width,
			height,
			pass_count,
			estimated_bytes,
			MAX_REDRAW_TARGET_BYTES,
		]
	var samples_per_pixel := 0
	for pass_value in blur_passes:
		var radius := ((pass_value as Dictionary)["radius"] as Vector2).abs()
		samples_per_pixel += (
			int(radius.x) * 2 + 1
			+ int(radius.y) * 2 + 1
		)
	var sample_fetches := pixel_count * samples_per_pixel
	var sample_limit := (
		MAX_REDRAW_CONTINUOUS_SAMPLE_FETCHES
		if continuous
		else MAX_REDRAW_STATIC_SAMPLE_FETCHES
	)
	if sample_fetches > sample_limit:
		return (
			"redraw workload requires %d texture fetches per update; %s limit is %d"
			% [
				sample_fetches,
				"continuous" if continuous else "static",
				sample_limit,
			]
		)
	return ""


func _redraw_blur_pass_bytes_per_pixel() -> int:
	if RenderingServer.get_current_rendering_method() in ["mobile", "forward_plus"]:
		# These renderers store the encoded horizontal sums in RGBA16F (8
		# bytes), followed by the authored RGBA8 boundary (4 bytes).
		return REDRAW_BLUR_PASS_BYTES_MOBILE
	# Compatibility stores the HDR target as RGBA32F on supported Godot
	# versions. Unknown methods use the same conservative estimate.
	return REDRAW_BLUR_PASS_BYTES_COMPATIBILITY


func _redraw_target_axis_limit() -> int:
	var rendering_device := RenderingServer.get_rendering_device()
	if rendering_device == null:
		# Compatibility does not expose a RenderingDevice. Its cross-platform
		# minimum is the safer ceiling when the driver limit cannot be queried.
		return mini(MAX_REDRAW_TARGET_AXIS, FALLBACK_REDRAW_TARGET_AXIS)
	return mini(
		MAX_REDRAW_TARGET_AXIS,
		int(rendering_device.limit_get(
			RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D
		)),
	)


func _split_redraw(redraw: Array) -> Dictionary:
	var blur_passes: Array = []
	var pending_effects: Array = []
	for effect_value in redraw:
		if not effect_value is Dictionary:
			push_warning("StagePresenter: redraw effect is not a Dictionary")
			continue
		var effect: Dictionary = effect_value
		var effect_type := String(effect.get("type", ""))
		if not REDRAW_EFFECT_TYPE_CODES.has(effect_type):
			push_warning("StagePresenter: unknown redraw effect '%s'" % effect_type)
			continue
		if effect_type == "blur":
			var radius := _array_to_vector2(
				effect.get("radius", [0.0, 0.0])
			).abs()
			# A zero-area rectangular blur is an authored no-op. Keep the surrounding
			# pointwise operations in one ordered segment so this marker cannot
			# introduce an extra render-target quantization boundary.
			if radius == Vector2.ZERO:
				continue
			blur_passes.append({
				"effects": pending_effects,
				"radius": radius,
			})
			pending_effects = []
		else:
			pending_effects.append(effect)
	return {
		"blur_passes": blur_passes,
		"suffix_effects": pending_effects,
	}


func _find_clip_effect(redraw: Array) -> Dictionary:
	for effect_value in redraw:
		if (
			effect_value is Dictionary
			and String((effect_value as Dictionary).get("type", "")) == "clip"
		):
			return effect_value
	return {}


func _configure_pointwise_material(
	material: ShaderMaterial,
	effects: Array,
	clip_texture: Texture2D,
	clip_rect: Rect2,
) -> void:
	var parameters := PackedVector4Array()
	var colors := PackedVector4Array()
	for effect_value in effects:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		var effect_type := String(effect.get("type", ""))
		if effect_type == "blur" or not REDRAW_EFFECT_TYPE_CODES.has(effect_type):
			continue
		var color := Color.WHITE
		var parameter := Vector4(
			float(REDRAW_EFFECT_TYPE_CODES[effect_type]),
			0.0,
			0.0,
			0.0,
		)
		match effect_type:
			"color_overlay":
				color = _to_color(effect.get("color", "#00000000"))
				parameter.y = float(COLOR_OVERLAY_BLEND_CODES.get(
					String(effect.get("blend", "normal")),
					0.0,
				))
			"brightness_contrast":
				parameter.y = float(effect.get("brightness", 0))
				parameter.z = float(effect.get("contrast", 0))
			"grayscale":
				parameter.y = float(effect.get("amount", 0.0))
			"tint":
				color = _to_color(effect.get("color", "#ffffffff"))
		parameters.append(parameter)
		colors.append(Vector4(color.r, color.g, color.b, color.a))

	var effect_count := parameters.size()
	while parameters.size() < 16:
		parameters.append(Vector4.ZERO)
		colors.append(Vector4.ONE)
	material.set_shader_parameter("effect_count", effect_count)
	material.set_shader_parameter("effect_parameters", parameters)
	material.set_shader_parameter("effect_colors", colors)
	material.set_shader_parameter("clip_texture", clip_texture)
	material.set_shader_parameter("clip_available", clip_texture != null)
	material.set_shader_parameter(
		"clip_rect",
		Vector4(
			clip_rect.position.x,
			clip_rect.position.y,
			clip_rect.size.x,
			clip_rect.size.y,
		),
	)


func _redraw_render_bounds(
	record: Dictionary,
	state: Dictionary,
	blur_passes: Array,
) -> Rect2:
	var bounds := Rect2()
	var has_bounds := false
	var sprites := record["sprites"] as Dictionary
	for channel in ["asset", "body", "face"]:
		var sprite := sprites[channel] as Sprite2D
		if sprite.texture == null:
			continue
		var current_rect := _sprite_render_rect(
			sprite,
			sprite.position,
			sprite.scale,
			sprite.centered,
		)
		bounds = current_rect if not has_bounds else bounds.merge(current_rect)
		has_bounds = true
		var target_layout := _channel_layout(sprite, channel, state)
		var target_rect := _sprite_render_rect(
			sprite,
			target_layout["position"],
			target_layout["scale"],
			bool(target_layout["centered"]),
		)
		bounds = bounds.merge(target_rect)
	for outgoing_value in record.get("outgoing", []):
		if not is_instance_valid(outgoing_value):
			continue
		var outgoing := outgoing_value as Sprite2D
		if outgoing.texture == null:
			continue
		var outgoing_rect := _sprite_render_rect(
			outgoing,
			outgoing.position,
			outgoing.scale,
			outgoing.centered,
		)
		bounds = outgoing_rect if not has_bounds else bounds.merge(outgoing_rect)
		has_bounds = true
	if not has_bounds:
		bounds = Rect2(Vector2.ZERO, Vector2.ONE)

	var cumulative_radius := Vector2.ZERO
	for pass_value in blur_passes:
		var pass_data: Dictionary = pass_value
		cumulative_radius += (pass_data["radius"] as Vector2).abs()
	# Keep authored pixels away from the render-target boundary even for a
	# zero-radius pass. Besides retaining one transparent texel around the final
	# support, this makes nearest sampling deterministic for one-pixel-wide or
	# one-pixel-high sources on every supported renderer.
	var guard := Vector2.ONE
	var start := (bounds.position - cumulative_radius - guard).floor()
	var finish := (bounds.end + cumulative_radius + guard).ceil()
	return Rect2(start, (finish - start).max(Vector2.ONE))


func _sprite_render_rect(
	sprite: Sprite2D,
	position: Vector2,
	scale: Vector2,
	centered: bool,
) -> Rect2:
	var texture_size := sprite.texture.get_size()
	var local_start := sprite.offset
	if centered:
		local_start -= texture_size * 0.5
	var local_end := local_start + texture_size
	var first := position + local_start * scale
	var second := position + local_end * scale
	var rect_start := Vector2(
		minf(first.x, second.x),
		minf(first.y, second.y),
	)
	var rect_end := Vector2(
		maxf(first.x, second.x),
		maxf(first.y, second.y),
	)
	return Rect2(rect_start, rect_end - rect_start)


func _ensure_redraw_pipeline(
	record: Dictionary,
	blur_passes: Array,
	bounds: Rect2,
) -> void:
	var signature: Array = [bounds.position, bounds.size, blur_passes.size()]
	var pipeline_root = record.get("redraw_pipeline_root")
	var output = record.get("redraw_pipeline_output")
	var pass_records = record.get("redraw_pipeline_passes", [])
	if (
		record.get("redraw_pipeline_signature", []) == signature
		and is_instance_valid(pipeline_root)
		and is_instance_valid(output)
		and pass_records is Array
		and pass_records.size() == blur_passes.size()
	):
		return

	_clear_redraw_pipeline(record)
	var composite := record["composite"] as CanvasGroup
	var source := record["source"] as Node2D
	var render_size := Vector2i(
		maxi(1, int(bounds.size.x)),
		maxi(1, int(bounds.size.y)),
	)
	var source_viewport := _new_redraw_viewport(render_size, false)
	source_viewport.name = "RedrawSource"
	var owner_viewport := get_viewport()
	if owner_viewport != null:
		source_viewport.canvas_item_default_texture_filter = (
			owner_viewport.canvas_item_default_texture_filter
		)
	source.position = -bounds.position
	var source_parent := source.get_parent()
	if source_parent:
		source_parent.remove_child(source)
	source_viewport.add_child(source)
	var previous_viewport := source_viewport
	var new_pass_records: Array = []

	for index in range(blur_passes.size()):
		var horizontal_viewport := _new_redraw_viewport(render_size, true)
		horizontal_viewport.name = "RedrawBox%dFirst" % index
		var horizontal_material := ShaderMaterial.new()
		horizontal_material.shader = _redraw_box_horizontal_shader
		var horizontal_rect := _new_redraw_pass_rect(
			render_size,
			horizontal_material,
		)
		horizontal_viewport.add_child(horizontal_rect)
		horizontal_viewport.add_child(previous_viewport)

		var vertical_viewport := _new_redraw_viewport(render_size, false)
		vertical_viewport.name = "RedrawBox%dSecond" % index
		var vertical_material := ShaderMaterial.new()
		vertical_material.shader = _redraw_box_vertical_shader
		var vertical_rect := _new_redraw_pass_rect(
			render_size,
			vertical_material,
		)
		vertical_viewport.add_child(vertical_rect)
		vertical_viewport.add_child(horizontal_viewport)
		new_pass_records.append({
			"input_viewport": previous_viewport,
			"horizontal_viewport": horizontal_viewport,
			"horizontal_material": horizontal_material,
			"vertical_viewport": vertical_viewport,
			"vertical_material": vertical_material,
		})
		previous_viewport = vertical_viewport

	composite.add_child(previous_viewport)
	var output_sprite := Sprite2D.new()
	output_sprite.name = "RedrawOutput"
	output_sprite.centered = false
	output_sprite.position = bounds.position
	output_sprite.texture = previous_viewport.get_texture()
	composite.add_child(output_sprite)
	record["redraw_pipeline_root"] = previous_viewport
	record["redraw_pipeline_output"] = output_sprite
	record["redraw_pipeline_passes"] = new_pass_records
	record["redraw_pipeline_signature"] = signature
	record["redraw_render_bounds"] = bounds


func _new_redraw_viewport(size: Vector2i, hdr: bool) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = hdr
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# The complete dependency chain is activated only after every material has
	# its input texture and parameters. Static projections render once; animated
	# source content opts into continuous updates for the tween lifetime.
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return viewport


func _new_redraw_pass_rect(
	size: Vector2i,
	material: ShaderMaterial,
) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = "Pass"
	rect.color = Color.WHITE
	rect.position = Vector2.ZERO
	rect.size = Vector2(size)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = material
	return rect


func _configure_redraw_pipeline(
	record: Dictionary,
	blur_passes: Array,
	suffix_effects: Array,
	clip_texture: Texture2D,
	clip_rect: Rect2,
	bounds: Rect2,
) -> void:
	var render_size := bounds.size
	var pass_records := record["redraw_pipeline_passes"] as Array
	for index in range(blur_passes.size()):
		var pass_data: Dictionary = blur_passes[index]
		var pass_record: Dictionary = pass_records[index]
		var radius := (pass_data["radius"] as Vector2).abs()
		var horizontal_material := (
			pass_record["horizontal_material"] as ShaderMaterial
		)
		_configure_pointwise_material(
			horizontal_material,
			pass_data["effects"],
			clip_texture,
			clip_rect,
		)
		horizontal_material.set_shader_parameter(
			"input_texture",
			(pass_record["input_viewport"] as SubViewport).get_texture(),
		)
		horizontal_material.set_shader_parameter("render_size", render_size)
		horizontal_material.set_shader_parameter("render_origin", bounds.position)
		horizontal_material.set_shader_parameter("blur_axis", Vector2.RIGHT)
		horizontal_material.set_shader_parameter("blur_radius", int(radius.x))

		var vertical_material := pass_record["vertical_material"] as ShaderMaterial
		vertical_material.set_shader_parameter(
			"input_texture",
			(pass_record["horizontal_viewport"] as SubViewport).get_texture(),
		)
		vertical_material.set_shader_parameter("render_size", render_size)
		vertical_material.set_shader_parameter("blur_axis", Vector2.DOWN)
		vertical_material.set_shader_parameter("blur_radius", int(radius.y))
		vertical_material.set_shader_parameter(
			"first_axis_sample_count",
			int(radius.x) * 2 + 1,
		)

	var material := record["redraw_material"] as ShaderMaterial
	material.shader = _redraw_texture_shader
	_configure_pointwise_material(
		material,
		suffix_effects,
		clip_texture,
		clip_rect,
	)
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	material.set_shader_parameter("render_size", render_size)
	material.set_shader_parameter("render_origin", bounds.position)
	var output := record["redraw_pipeline_output"] as Sprite2D
	output.position = bounds.position
	output.texture = pipeline_root.get_texture()
	output.material = material


func _set_redraw_pipeline_update_mode(
	record: Dictionary,
	continuous: bool,
) -> void:
	var mode := (
		SubViewport.UPDATE_ALWAYS
		if continuous
		else SubViewport.UPDATE_ONCE
	)
	var configured := {}
	for pass_value in record.get("redraw_pipeline_passes", []):
		var pass_record: Dictionary = pass_value
		for key in ["input_viewport", "horizontal_viewport", "vertical_viewport"]:
			var viewport := pass_record.get(key) as SubViewport
			if not is_instance_valid(viewport):
				continue
			var instance_id := viewport.get_instance_id()
			if configured.has(instance_id):
				continue
			configured[instance_id] = true
			viewport.render_target_update_mode = mode


func _redraw_uses_dynamic_textures(
	record: Dictionary,
	blur_passes: Array,
	clip_texture: Texture2D = null,
) -> bool:
	for sprite_value in (record.get("sprites", {}) as Dictionary).values():
		if _is_dynamic_redraw_texture((sprite_value as Sprite2D).texture):
			return true
	for outgoing_value in record.get("outgoing", []):
		if (
			is_instance_valid(outgoing_value)
			and _is_dynamic_redraw_texture((outgoing_value as Sprite2D).texture)
		):
			return true

	# A clip in the suffix is sampled by RedrawOutput in the owner's viewport,
	# so it remains live without rerendering the blur chain. Only a clip consumed
	# before an authored blur makes the offscreen pipeline itself dynamic.
	var dynamic_clip := (
		clip_texture
		if clip_texture != null
		else record.get("redraw_mask_texture") as Texture2D
	)
	if not _is_dynamic_redraw_texture(dynamic_clip):
		return false
	for pass_value in blur_passes:
		for effect_value in (pass_value as Dictionary).get("effects", []):
			if (
				effect_value is Dictionary
				and String((effect_value as Dictionary).get("type", "")) == "clip"
			):
				return true
	return false


func _is_dynamic_redraw_texture(texture: Texture2D) -> bool:
	if texture is AnimatedTexture or texture is ViewportTexture:
		return true
	if texture is AtlasTexture:
		return _is_dynamic_redraw_texture((texture as AtlasTexture).atlas)
	return false


func _redraw_dynamic_size_signature(
	record: Dictionary,
	clip_texture: Texture2D = null,
) -> Array:
	var signature: Array = []
	var sprites := record.get("sprites", {}) as Dictionary
	for channel in ["asset", "body", "face"]:
		var texture := (sprites[channel] as Sprite2D).texture
		if not _is_dynamic_redraw_texture(texture):
			continue
		signature.append([
			channel,
			texture.get_instance_id(),
			texture.get_size(),
		])
	for outgoing_value in record.get("outgoing", []):
		if not is_instance_valid(outgoing_value):
			continue
		var outgoing_texture := (outgoing_value as Sprite2D).texture
		if not _is_dynamic_redraw_texture(outgoing_texture):
			continue
		signature.append([
			"outgoing",
			outgoing_texture.get_instance_id(),
			outgoing_texture.get_size(),
		])
	var mask := (
		clip_texture
		if clip_texture != null
		else record.get("redraw_mask_texture") as Texture2D
	)
	if _is_dynamic_redraw_texture(mask):
		signature.append(["clip", mask.get_instance_id(), mask.get_size()])
	return signature


func _clear_redraw_pipeline(record: Dictionary) -> void:
	var composite := record["composite"] as CanvasGroup
	var source := record["source"] as Node2D
	if source.get_parent() != composite:
		var source_parent := source.get_parent()
		if source_parent:
			source_parent.remove_child(source)
		composite.add_child(source)
	source.position = Vector2.ZERO

	var output = record.get("redraw_pipeline_output")
	if is_instance_valid(output):
		var output_parent := (output as Node).get_parent()
		if output_parent:
			output_parent.remove_child(output)
		(output as Node).queue_free()
	var pipeline_root = record.get("redraw_pipeline_root")
	if is_instance_valid(pipeline_root):
		var pipeline_parent := (pipeline_root as Node).get_parent()
		if pipeline_parent:
			pipeline_parent.remove_child(pipeline_root)
		(pipeline_root as Node).queue_free()
	record["redraw_pipeline_root"] = null
	record["redraw_pipeline_output"] = null
	record["redraw_pipeline_passes"] = []
	record["redraw_pipeline_signature"] = []
	record["redraw_render_bounds"] = Rect2()


func _update_redraw_margin(
	record: Dictionary,
	_redraw: Array,
	_state: Dictionary,
) -> void:
	var composite := record["composite"] as CanvasGroup
	# Blur support is already accumulated into the offscreen texture bounds.
	# Root scale/rotation then transforms that real geometry, so no screen-space
	# CanvasGroup estimate or transition envelope is needed.
	composite.fit_margin = 1.0
	composite.clear_margin = 1.0


func _redraw_texture(record: Dictionary, asset_id: String) -> Texture2D:
	if String(record.get("redraw_mask_asset", "")) == asset_id:
		return record.get("redraw_mask_texture") as Texture2D
	var texture: Texture2D = null
	if asset_id != "":
		texture = _load_stage_texture(asset_id)
	record["redraw_mask_asset"] = asset_id
	record["redraw_mask_texture"] = texture
	if texture == null:
		push_warning("StagePresenter: redraw texture not found: %s" % asset_id)
	return texture


func _clip_rect(texture: Texture2D, effect: Dictionary) -> Rect2:
	var offset := _array_to_vector2(effect.get("offset", [0.0, 0.0]))
	if texture == null:
		return Rect2(offset, Vector2.ONE)
	var texture_size := texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return Rect2(offset, Vector2.ONE)
	var fit := String(effect.get("fit", "native"))
	if fit == "native":
		return Rect2(offset, texture_size)
	var viewport_size := _viewport_size()
	var fitted_size := texture_size
	match fit:
		"contain":
			fitted_size *= minf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
		"cover":
			fitted_size *= maxf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
		"stretch":
			fitted_size = viewport_size
		_:
			push_warning("StagePresenter: unknown clip fit '%s'" % fit)
			return Rect2(offset, texture_size)
	return Rect2((viewport_size - fitted_size) * 0.5 + offset, fitted_size)


func _slide_delta(transition: String) -> Vector2:
	var viewport_size := _viewport_size()
	match transition:
		"slide_right":
			return Vector2(viewport_size.x, 0.0)
		"slide_up":
			return Vector2(0.0, -viewport_size.y)
		"slide_down":
			return Vector2(0.0, viewport_size.y)
		_:
			return Vector2(-viewport_size.x, 0.0)


func _normalize_transition(raw_transition: String) -> String:
	var transition := raw_transition
	if not _transition_registry.has_provider(transition):
		push_error("StagePresenter: unregistered transition '%s'" % raw_transition)
		return ""
	return transition


func _load_stage_texture(asset_id: String) -> Texture2D:
	var path := asset_id
	if asset_id.begins_with("background:"):
		path = StellaRuntime.backgrounds_path + asset_id.trim_prefix("background:")
	elif asset_id.begins_with("character:"):
		path = StellaRuntime.characters_path + asset_id.trim_prefix("character:")
	elif asset_id.begins_with("stage:"):
		path = StellaRuntime.stage_assets_path + asset_id.trim_prefix("stage:")
	elif not asset_id.begins_with("res://"):
		path = StellaRuntime.stage_assets_path + asset_id

	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE) as Texture2D
	if path.get_extension() != "":
		return null
	for extension in TEXTURE_EXTENSIONS:
		var candidate: String = path + String(extension)
		if ResourceLoader.exists(candidate):
			return ResourceLoader.load(
				candidate,
				"Texture2D",
				ResourceLoader.CACHE_MODE_REUSE,
			) as Texture2D
	return null


func _array_to_vector2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary:
		return Vector2(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)))
	if value is int or value is float:
		return Vector2(float(value), float(value))
	return fallback


func _to_color(value: Variant) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color.from_string(value, Color.WHITE)
	if value is Array and value.size() >= 3:
		return Color(
			float(value[0]),
			float(value[1]),
			float(value[2]),
			float(value[3]) if value.size() >= 4 else 1.0,
		)
	if value is Dictionary:
		return Color(
			float(value.get("r", 1.0)),
			float(value.get("g", 1.0)),
			float(value.get("b", 1.0)),
			float(value.get("a", 1.0)),
		)
	return Color.WHITE


func _process(_delta: float) -> void:
	var changed_layers: Array[String] = []
	for raw_layer_id in _layers:
		var layer_id := String(raw_layer_id)
		var record: Dictionary = _layers[layer_id]
		var signature := _redraw_dynamic_size_signature(record)
		if signature == record.get("redraw_dynamic_size_signature", []):
			continue
		record["redraw_dynamic_size_signature"] = signature
		changed_layers.append(layer_id)
	if changed_layers.is_empty():
		return

	_begin_completion_batch()
	for layer_id in changed_layers:
		_reproject_dynamic_texture_size(layer_id)
	_end_completion_batch()


func _reproject_dynamic_texture_size(layer_id: String) -> void:
	if not _layers.has(layer_id):
		return
	var had_active_transition := _layer_tweens.has(layer_id)
	var generation := int(_layer_generations.get(layer_id, 0))
	var completed_transition: Dictionary = {}
	var change: Dictionary = {}
	if had_active_transition:
		completed_transition = _take_active_transition(layer_id)
		generation = _claim_next_layer_generation(layer_id)
	elif not _states.has(layer_id):
		change = _begin_layer_change(layer_id)
		generation = int(change["generation"])

	# A pending remove has no canonical projection to resize. Finish it exactly
	# like a viewport-resize boundary, invalidating the old tween token first.
	if not _states.has(layer_id):
		_free_layer(layer_id)
		if had_active_transition:
			_emit_or_queue_transition_finished(layer_id, generation, false)
			_publish_stage_transition_terminal(
				completed_transition, &"completed")
		_publish_superseded_transition(change)
		return

	var record: Dictionary = _layers[layer_id]
	var state: Dictionary = _states[layer_id]
	if had_active_transition:
		# Tween tracks captured geometry for the previous texture dimensions.
		# Snap to canonical state so a stale track cannot overwrite the rebuild.
		_apply_channels_cut(record, state)
		_apply_transform_cut(record, state)
	else:
		for channel in ["asset", "body", "face"]:
			_apply_channel_layout(record, channel, state)

	var visible := bool(state.get("visible", true))
	_apply_redraw(record, state, true, false, visible)
	(record["root"] as Node2D).visible = visible
	(record["composite"] as CanvasGroup).self_modulate.a = clampf(
		float(state.get("opacity", 1.0)), 0.0, 1.0
	)
	record["redraw_dynamic_size_signature"] = (
		_redraw_dynamic_size_signature(record)
	)
	if had_active_transition:
		_emit_or_queue_transition_finished(layer_id, generation, true)
		_publish_stage_transition_terminal(
			completed_transition, &"completed")
	_publish_superseded_transition(change)


func _viewport_size() -> Vector2:
	var size := get_viewport().get_visible_rect().size
	return DEFAULT_VIEWPORT_SIZE if size == Vector2.ZERO else size


func _on_viewport_size_changed() -> void:
	_begin_completion_batch()
	for raw_layer_id in _layers.keys().duplicate():
		var layer_id := String(raw_layer_id)
		var had_active_transition := _layer_tweens.has(layer_id)
		var generation := int(_layer_generations.get(layer_id, 0))
		var completed_transition: Dictionary = {}
		var change: Dictionary = {}
		if had_active_transition:
			completed_transition = _take_active_transition(layer_id)
			generation = _claim_next_layer_generation(layer_id)
		elif not _states.has(layer_id):
			change = _begin_layer_change(layer_id)
			generation = int(change["generation"])

		# A remove drops canonical state before its visual fade finishes. A
		# viewport resize is a new projection boundary, so finish that removal
		# instead of leaving an old tween targeting stale viewport coordinates.
		if not _states.has(layer_id):
			_free_layer(layer_id)
			if had_active_transition:
				_emit_or_queue_transition_finished(layer_id, generation, false)
				_publish_stage_transition_terminal(
					completed_transition, &"completed")
			_publish_superseded_transition(change)
			continue

		var record: Dictionary = _layers[layer_id]
		var state: Dictionary = _states[layer_id]
		if had_active_transition:
			# Tween tracks cache their target values when created. Reproject the
			# canonical target synchronously so a later tick cannot restore layout
			# computed for the old viewport.
			_apply_channels_cut(record, state)
			_apply_transform_cut(record, state)
		else:
			_apply_channel_layout(record, "asset", state)
		var visible := bool(state.get("visible", true))
		_apply_redraw(record, state, true, false, visible)
		(record["root"] as Node2D).visible = bool(state.get("visible", true))
		(record["composite"] as CanvasGroup).self_modulate.a = clampf(
			float(state.get("opacity", 1.0)), 0.0, 1.0
		)
		if had_active_transition:
			_emit_or_queue_transition_finished(layer_id, generation, true)
			_publish_stage_transition_terminal(
				completed_transition, &"completed")
		_publish_superseded_transition(change)
	_end_completion_batch()

## Cancel visual work without changing authored target state. Removed layers
## finish removal immediately; retained layers snap to their current target.
func _on_engine_abort_requested() -> void:
	# Abort is a lifecycle boundary even when no live transition exists. Retire
	# frozen completion snapshots before any teardown or terminal callback.
	_completion_lifecycle_epoch += 1
	_begin_completion_batch()
	var cancelled_identities: Array[Dictionary] = []
	for layer_id in _layers.keys().duplicate():
		var id := String(layer_id)
		var cancelled := _take_active_transition(id)
		if not cancelled.is_empty():
			cancelled_identities.append(cancelled)
		_claim_next_layer_generation(id)
		if not _states.has(id):
			_free_layer(id, false)
			continue
		var record: Dictionary = _layers[id]
		var state: Dictionary = _states[id]
		_apply_channels_cut(record, state)
		var visible := bool(state.get("visible", true))
		_apply_redraw(record, state, true, false, visible)
		_apply_transform_cut(record, state)
		(record["root"] as Node2D).visible = bool(state.get("visible", true))
		(record["composite"] as CanvasGroup).self_modulate.a = clampf(
			float(state.get("opacity", 1.0)), 0.0, 1.0
		)
	for identity: Dictionary in cancelled_identities:
		_publish_stage_transition_terminal(identity, &"cancelled")
	_end_completion_batch()
