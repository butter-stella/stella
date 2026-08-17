## Skinnable current-chapter indicator binding.
##
## Attach to a project-owned Control and point title_label_path at its Label.
## Stella supplies localized metadata, visibility, and transition lifecycle;
## the project retains all geometry, theme, decoration, and sibling ownership.
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
var _active_request_accept_advance_serial := -1
var _transition_generation := 0
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
		push_error(
			"ChapterIndicatorPresenter '%s' could not join the internal registry"
			% name)
		return
	_connect_signal(SignalBus.current_chapter_changed, _on_current_chapter_changed)
	_connect_signal(
		SignalBus.chapter_indicator_validate_requested,
		_on_validate_request,
	)
	_connect_signal(
		SignalBus.chapter_indicator_apply_requested,
		_on_apply_request,
	)
	_connect_signal(
		SignalBus.chapter_indicator_finish_requested,
		_on_finish_requested,
	)
	_connect_signal(
		SignalBus.chapter_indicator_state_apply_requested,
		_on_state_apply_requested,
	)
	_connect_signal(
		SignalBus.chapter_indicator_projection_committed,
		_on_projection_committed,
	)
	_connect_signal(
		SignalBus.chapter_indicator_reset_requested,
		_on_reset_requested,
	)
	_connect_signal(SignalBus.advance_requested, _on_advance_requested)
	# A presenter added after scenario start is not retroactively admitted to an
	# existing barrier. It cut-projects only the public canonical facade state.
	var projection_active := SignalBus.is_chapter_indicator_projection_active()
	if projection_active:
		_on_current_chapter_changed(
			StellaRuntime.get_current_chapter_id(),
			StellaRuntime.get_current_chapter_title(),
		)
	else:
		_chapter_id = ""
		_chapter_title = ""
		if _binding_error().is_empty():
			_title_label.text = ""
	_target_visible = (
		projection_active and SignalBus.get_projected_chapter_indicator_visibility())
	_apply_final_state()


func _exit_tree() -> void:
	_finish_active_request(false)
	StellaRuntime._unregister_chapter_indicator_presenter(
		self, _participant_capability)
	_participant_capability = null


func _connect_signal(target: Signal, callback: Callable) -> void:
	if not target.is_connected(callback):
		target.connect(callback)


func _on_current_chapter_changed(chapter_id: String, title: String) -> void:
	if not SignalBus.current_chapter_event_is_current(
		chapter_id, title, get_instance_id()):
		return
	_chapter_id = chapter_id
	_chapter_title = title
	if _binding_error().is_empty():
		_title_label.text = _chapter_title
	if _active_request_id != 0 and not _has_presentable_title():
		_finish_active_request(true)
	elif _active_request_id == 0:
		_apply_final_state()


func _on_validate_request(request: ChapterIndicatorRequest) -> void:
	if request == null or not request.is_target(self):
		return
	_clear_validated_binding()
	var binding_error := _binding_resolution_error()
	if not binding_error.is_empty():
		SignalBus.reject_chapter_indicator_request(
			request,
			self,
			_participant_capability,
			"ChapterIndicatorPresenter '%s': %s" % [name, binding_error])
		return
	_validated_request = request
	_validated_title_label_path = title_label_path
	_validated_title_label = get_node_or_null(title_label_path) as Label
	if not SignalBus.validate_chapter_indicator_request(
		request, self, _participant_capability):
		_clear_validated_binding()


func _on_apply_request(request: ChapterIndicatorRequest) -> void:
	if request == null or not request.is_target(self):
		return
	var request_id := request.get_request_id()
	if not SignalBus.accept_chapter_indicator_request(
		request, self, _participant_capability):
		return
	if not _validated_binding_is_current(request):
		_clear_validated_binding()
		SignalBus.finish_chapter_indicator_request(
			request_id, self, _participant_capability, false)
		return
	_title_label = _validated_title_label
	_title_label.text = _chapter_title
	# Label/property listeners are synchronously reentrant. They may reset the
	# request or replace the exported binding while text assignment is in flight;
	# never clear the validation snapshot and start that stale operation.
	if request.is_finished() or not _validated_binding_is_current(request):
		_clear_validated_binding()
		SignalBus.finish_chapter_indicator_request(
			request_id, self, _participant_capability, false)
		return
	_clear_validated_binding()
	if _active_request_id != 0 and _active_request_id != request_id:
		SignalBus.finish_chapter_indicator_request(
			request_id, self, _participant_capability, false)
		return
	_active_request_id = request_id
	_active_request_accept_advance_serial = SignalBus.current_advance_dispatch_serial()
	_target_visible = request.get_visible()
	var transition := request.get_transition()
	var duration := request.get_duration()
	if StellaRuntime.is_skipping():
		transition = "cut"
		duration = 0.0
	if transition == "cut" or duration <= 0.0 or not _transition_has_work():
		_finish_active_request(true)
		return
	_start_fade(duration)


func _on_finish_requested(request_id: int) -> void:
	if request_id == _active_request_id:
		_finish_active_request(true)


func _on_state_apply_requested(state_visible: bool, generation: int) -> void:
	if not SignalBus.chapter_indicator_projection_is_current(generation):
		return
	_cancel_active_visual()
	_target_visible = state_visible
	_apply_final_state()


func _on_projection_committed(state_visible: bool, generation: int) -> void:
	if not SignalBus.chapter_indicator_projection_is_current(generation):
		return
	# Accepted participants already own the request's exact fade/barrier. Only a
	# presenter that arrived after validation needs this cut projection.
	if _active_request_id != 0:
		return
	_target_visible = state_visible
	_apply_final_state()


func _on_reset_requested(epoch: int) -> void:
	if not SignalBus.chapter_indicator_reset_is_current(epoch):
		return
	_clear_validated_binding()
	_cancel_active_visual()
	_chapter_id = ""
	_chapter_title = ""
	_target_visible = false
	if _binding_error().is_empty():
		_title_label.text = ""
	_apply_final_state()


func _on_advance_requested() -> void:
	if (
		_active_request_id != 0
		and SignalBus.current_advance_dispatch_serial() > (
			_active_request_accept_advance_serial
		)
	):
		_finish_active_request(true)


func _start_fade(duration: float) -> void:
	_transition_generation += 1
	var generation := _transition_generation
	var request_id := _active_request_id
	var showing := _target_visible
	if showing:
		visible = true
		if not _fade_owner_is_current(request_id, generation):
			return
		modulate.a = 0.0
		if not _fade_owner_is_current(request_id, generation):
			return
	var tween := create_tween()
	if not _fade_owner_is_current(request_id, generation):
		tween.kill()
		return
	_active_tween = tween
	_active_tween.tween_property(
		self,
		"modulate:a",
		_authored_alpha if showing else 0.0,
		duration,
	)
	_active_tween.finished.connect(
		_on_tween_finished.bind(generation),
		CONNECT_ONE_SHOT,
	)


func _fade_owner_is_current(request_id: int, generation: int) -> bool:
	return (
		request_id > 0
		and request_id == _active_request_id
		and generation == _transition_generation
	)


func _on_tween_finished(generation: int) -> void:
	if generation != _transition_generation:
		return
	_active_tween = null
	_finish_active_request(true)


func _finish_active_request(success: bool) -> void:
	var request_id := _active_request_id
	if success and not _binding_error().is_empty():
		success = false
	_cancel_active_visual()
	if success:
		_apply_final_state()
	if request_id > 0:
		SignalBus.finish_chapter_indicator_request(
			request_id,
			self,
			_participant_capability,
			success,
		)


func _cancel_active_visual() -> void:
	_transition_generation += 1
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	_active_request_id = 0
	_active_request_accept_advance_serial = -1


func _transition_has_work() -> bool:
	if _target_visible:
		return _has_presentable_title() and not visible
	return visible


func _apply_final_state() -> void:
	modulate.a = _authored_alpha
	visible = _target_visible and _has_presentable_title()


func _has_presentable_title() -> bool:
	return not _chapter_id.is_empty() and not _chapter_title.is_empty()


func _binding_error() -> String:
	var resolution_error := _binding_resolution_error()
	if not resolution_error.is_empty():
		return resolution_error
	var resolved := get_node_or_null(title_label_path) as Label
	if resolved != _title_label:
		return "title_label_path changed after the accepted binding"
	return ""


func _binding_resolution_error() -> String:
	if title_label_path.is_empty():
		return "title_label_path is empty"
	var resolved := get_node_or_null(title_label_path) as Label
	if resolved == null or not is_instance_valid(resolved):
		return "title_label_path does not resolve to a Label"
	return ""


func _validated_binding_is_current(request: ChapterIndicatorRequest) -> bool:
	return (
		_validated_request == request
		and title_label_path == _validated_title_label_path
		and _validated_title_label != null
		and is_instance_valid(_validated_title_label)
		and get_node_or_null(title_label_path) == _validated_title_label
		and _binding_resolution_error().is_empty()
	)


func _clear_validated_binding() -> void:
	_validated_request = null
	_validated_title_label_path = NodePath()
	_validated_title_label = null
