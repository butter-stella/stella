## Skinnable current-chapter indicator binding.
## Stella owns metadata, typed operations, and lifecycle; projects own visuals.
class_name ChapterIndicatorPresenter extends Control

const ChapterIndicatorRequest = preload(
	"res://addons/stella/core/data/chapter_indicator_request.gd")

@export_node_path("Label") var title_label_path: NodePath

var _title_label: Label
var _chapter_id := ""
var _chapter_title := ""
var _target_visible := false
var _authored_alpha := 1.0
var _active_tween: Tween
var _active_request_id := 0
var _active_token := 0
var _transition_generation := 0
var _next_token := 1
var _validated_request: ChapterIndicatorRequest
var _validated_title_label_path: NodePath
var _validated_title_label: Label
var _participant_capability: RefCounted


func _ready() -> void:
	_authored_alpha = modulate.a
	_title_label = get_node_or_null(title_label_path) as Label
	visible = false
	_participant_capability = StellaRuntime._register_chapter_indicator_presenter(self)
	if _participant_capability == null:
		push_error("ChapterIndicatorPresenter '%s' could not join the internal registry" % name)
		return
	_connect_signal(SignalBus.current_chapter_changed, _on_current_chapter_changed)
	_connect_signal(SignalBus.chapter_indicator_validate_requested, _on_validate_request)
	_connect_signal(SignalBus.chapter_indicator_accept_requested, _on_accept_request)
	_connect_signal(SignalBus.chapter_indicator_apply_requested, _on_apply_request)
	_connect_signal(SignalBus.chapter_indicator_finish_requested, _on_finish_requested)
	_connect_signal(SignalBus.chapter_indicator_state_apply_requested, _on_state_apply_requested)
	_connect_signal(SignalBus.chapter_indicator_projection_committed, _on_projection_committed)
	_connect_signal(SignalBus.chapter_indicator_reset_requested, _on_reset_requested)
	var projection_active := SignalBus.is_chapter_indicator_projection_active()
	if projection_active:
		_on_current_chapter_changed(
			StellaRuntime.get_current_chapter_id(),
			StellaRuntime.get_current_chapter_title())
	else:
		_chapter_id = ""
		_chapter_title = ""
		if _binding_resolution_error().is_empty():
			_title_label.text = ""
	_target_visible = (
		projection_active and SignalBus.get_projected_chapter_indicator_visibility())
	_apply_final_state()


func _exit_tree() -> void:
	_terminate_active(&"cancelled", false)
	StellaRuntime._unregister_chapter_indicator_presenter(self, _participant_capability)
	_participant_capability = null


func _connect_signal(target: Signal, callback: Callable) -> void:
	if not target.is_connected(callback):
		target.connect(callback)


func _on_current_chapter_changed(chapter_id: String, title: String) -> void:
	if not SignalBus.current_chapter_event_is_current(chapter_id, title, get_instance_id()):
		return
	_chapter_id = chapter_id
	_chapter_title = title
	if _binding_resolution_error().is_empty():
		_title_label = get_node_or_null(title_label_path) as Label
		_title_label.text = _chapter_title
	if _active_request_id > 0 and not _has_presentable_title():
		_terminate_active(&"completed", true)
	elif _active_request_id == 0:
		_apply_final_state()


func _on_validate_request(request: ChapterIndicatorRequest) -> void:
	if request == null or not request.is_target(self):
		return
	_clear_validated_binding()
	var binding_error := _binding_resolution_error()
	if not binding_error.is_empty():
		SignalBus.reject_chapter_indicator_request(
			request, self, _participant_capability,
			"ChapterIndicatorPresenter '%s': %s" % [name, binding_error])
		return
	_validated_request = request
	_validated_title_label_path = title_label_path
	_validated_title_label = get_node_or_null(title_label_path) as Label
	if not SignalBus.validate_chapter_indicator_request(
		request, self, _participant_capability):
		_clear_validated_binding()


func _on_accept_request(request: ChapterIndicatorRequest) -> void:
	if request == null or not request.is_target(self):
		return
	if not _validated_binding_is_current(request):
		_clear_validated_binding()
		return
	if not SignalBus.accept_chapter_indicator_request(
		request, self, _participant_capability):
		_clear_validated_binding()


func _on_apply_request(request: ChapterIndicatorRequest) -> void:
	if request == null or not request.is_target(self):
		return
	if not _validated_binding_is_current(request):
		_clear_validated_binding()
		return
	_title_label = _validated_title_label
	_title_label.text = _chapter_title
	if not _validated_binding_is_current(request):
		_clear_validated_binding()
		return
	_clear_validated_binding()
	if not SignalBus.acknowledge_chapter_indicator_apply(
		request, self, _participant_capability):
		return
	if _active_request_id > 0:
		_terminate_active(&"superseded", false)
	_target_visible = request.get_visible()
	var transition := request.get_transition()
	var duration := request.get_duration()
	if request.get_force_cut():
		transition = "cut"
		duration = 0.0
	if transition == "cut" or duration <= 0.0 or not _transition_has_work():
		_apply_final_state()
		return
	_active_request_id = request.get_request_id()
	_active_token = _next_token
	_next_token += 1
	_transition_generation += 1
	SignalBus.chapter_indicator_transition_receipt_started.emit(
		get_instance_id(), _active_token, _active_request_id,
		_transition_generation)
	_start_fade(duration)


func _on_finish_requested(request_id: int) -> void:
	if request_id == _active_request_id:
		_terminate_active(&"completed", true)


func _on_state_apply_requested(state_visible: bool, generation: int) -> void:
	if not SignalBus.chapter_indicator_projection_is_current(generation):
		return
	_terminate_active(&"cancelled", false)
	_target_visible = state_visible
	_apply_final_state()


func _on_projection_committed(state_visible: bool, generation: int) -> void:
	if not SignalBus.chapter_indicator_projection_is_current(generation):
		return
	if _active_request_id > 0:
		return
	_target_visible = state_visible
	_apply_final_state()


func _on_reset_requested(epoch: int) -> void:
	if not SignalBus.chapter_indicator_reset_is_current(epoch):
		return
	_clear_validated_binding()
	_terminate_active(&"cancelled", false)
	_chapter_id = ""
	_chapter_title = ""
	_target_visible = false
	if _binding_resolution_error().is_empty():
		_title_label = get_node_or_null(title_label_path) as Label
		_title_label.text = ""
	_apply_final_state()


func _start_fade(duration: float) -> void:
	var request_id := _active_request_id
	var generation := _transition_generation
	var showing := _target_visible
	if showing:
		visible = true
		if not _fade_owner_is_current(request_id, generation):
			return
		modulate.a = 0.0
	var tween := create_tween()
	if not _fade_owner_is_current(request_id, generation):
		tween.kill()
		return
	_active_tween = tween
	_active_tween.tween_property(
		self, "modulate:a", _authored_alpha if showing else 0.0, duration)
	_active_tween.finished.connect(
		_on_tween_finished.bind(request_id, generation), CONNECT_ONE_SHOT)


func _fade_owner_is_current(request_id: int, generation: int) -> bool:
	return (
		request_id > 0
		and request_id == _active_request_id
		and generation == _transition_generation)


func _on_tween_finished(request_id: int, generation: int) -> void:
	if not _fade_owner_is_current(request_id, generation):
		return
	_active_tween = null
	_terminate_active(&"completed", true)


func _terminate_active(outcome: StringName, apply_final: bool) -> void:
	var request_id := _active_request_id
	var token := _active_token
	var generation := _transition_generation
	if outcome == &"completed" and request_id > 0 and not _active_binding_is_current():
		outcome = &"cancelled"
		apply_final = false
	_cancel_active_visual()
	if apply_final:
		_apply_final_state()
	if request_id > 0:
		SignalBus.chapter_indicator_transition_terminal.emit(
			get_instance_id(), token, request_id, generation, outcome)


func _cancel_active_visual() -> void:
	_transition_generation += 1
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	_active_request_id = 0
	_active_token = 0


func _transition_has_work() -> bool:
	if _target_visible:
		return _has_presentable_title() and not visible
	return visible


func _apply_final_state() -> void:
	modulate.a = _authored_alpha
	visible = _target_visible and _has_presentable_title()


func _has_presentable_title() -> bool:
	return not _chapter_id.is_empty() and not _chapter_title.is_empty()


func _binding_resolution_error() -> String:
	if title_label_path.is_empty():
		return "title_label_path is empty"
	var resolved := get_node_or_null(title_label_path) as Label
	if resolved == null or not is_instance_valid(resolved):
		return "title_label_path does not resolve to a Label"
	return ""


func _active_binding_is_current() -> bool:
	return (
		_binding_resolution_error().is_empty()
		and _title_label != null
		and is_instance_valid(_title_label)
		and get_node_or_null(title_label_path) == _title_label)


func _validated_binding_is_current(request: ChapterIndicatorRequest) -> bool:
	return (
		_validated_request == request
		and title_label_path == _validated_title_label_path
		and _validated_title_label != null
		and is_instance_valid(_validated_title_label)
		and get_node_or_null(title_label_path) == _validated_title_label
		and _binding_resolution_error().is_empty())


func _clear_validated_binding() -> void:
	_validated_request = null
	_validated_title_label_path = NodePath()
	_validated_title_label = null
