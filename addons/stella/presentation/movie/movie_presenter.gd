## Runtime-owned full-screen projector for one native movie stream.
class_name MoviePresenter extends CanvasLayer

const SURFACE_LAYER := PresentationLayerOrder.FULLSCREEN_MEDIA
const SEEK_EPSILON := 0.000001

var _capability: RefCounted
var _backdrop: ColorRect
var _player: VideoStreamPlayer
var _validation_cache: Dictionary = {}
var _restore_cache: Dictionary = {}
var _rollback_cache: Dictionary = {}
var _armed_rollback_plans: Dictionary = {}
var _recovery_cache: Dictionary = {}
var _restore_ticket_serial := 0
var _restore_ticket := 0
var _armed_restore_ticket := 0
var _armed_restore_key := ""
var _active: Dictionary = {}
var _generation := 1
var _token_serial := 0
var _exiting := false


func _ready() -> void:
	layer = SURFACE_LAYER
	_build_surface()
	_capability = StellaRuntime._register_movie_presenter(self)
	if _capability == null:
		push_error("MoviePresenter could not join the Runtime registry")
		return
	SignalBus.movie_validate_requested.connect(_on_validate_requested)
	SignalBus.movie_accept_requested.connect(_on_accept_requested)
	SignalBus.movie_apply_requested.connect(_on_apply_requested)
	SignalBus.movie_finish_requested.connect(_on_finish_requested)
	SignalBus.movie_projection_reset_requested.connect(_on_projection_reset_requested)
	SignalBus.movie_state_capture_requested.connect(_on_state_capture_requested)
	SignalBus.settings_changed.connect(_on_settings_changed)


func _exit_tree() -> void:
	_exiting = true
	_disconnect_runtime_signals()
	_validation_cache.clear()
	_restore_cache.clear()
	_rollback_cache.clear()
	_armed_rollback_plans.clear()
	_recovery_cache.clear()
	_restore_ticket = 0
	_armed_restore_ticket = 0
	_armed_restore_key = ""
	_retire_active(&"cancelled")
	if _capability != null:
		StellaRuntime._unregister_movie_presenter(self, _capability)
	_capability = null


func _build_surface() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "MovieBackdrop"
	_backdrop.color = Color.BLACK
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.visible = false
	add_child(_backdrop)
	_player = VideoStreamPlayer.new()
	_player.name = "MoviePlayer"
	_player.expand = true
	_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player.visible = false
	_player.bus = &"Master"
	_player.finished.connect(_on_player_finished)
	add_child(_player)


func _on_validate_requested(request: MovieOperationRequest) -> void:
	if _capability == null or request == null or not request.is_target(self):
		return
	var payload := request.get_payload()
	if not MovieChannelState.validate_operation(payload, false):
		SignalBus.reject_movie_request(
			request, self, _capability, "invalid canonical movie operation")
		return
	var previous_state := _capture_active_state()
	if not _active.is_empty() and previous_state.is_empty():
		SignalBus.reject_movie_request(
			request,
			self,
			_capability,
			"active native movie is between physical stop and terminal commit",
		)
		return
	var rollback_plan: Dictionary = {}
	if not previous_state.is_empty():
		rollback_plan = _resolve_movie(String(previous_state["asset"]))
		if not _restore_state_matches_plan(previous_state, rollback_plan):
			SignalBus.reject_movie_request(
				request, self, _capability,
				"active movie cannot be sealed for atomic rollback")
			return
	var prepared := {"action": String(payload["action"])}
	if payload["action"] == "play":
		if SignalBus.has_active_presentation_clip_projection():
			SignalBus.reject_movie_request(
				request, self, _capability,
				"a presentation clip owns the mutually exclusive full-screen media surface",
			)
			return
		prepared = _resolve_movie(String(payload["asset"]))
		if prepared.is_empty():
			SignalBus.reject_movie_request(
				request,
				self,
				_capability,
				"asset '%s' is missing, ambiguous, or not a native Ogg Theora stream"
				% String(payload["asset"]),
			)
			return
	_validation_cache[request.get_instance_id()] = {
		"apply": prepared,
		"rollback_state": previous_state.duplicate(true),
		"rollback_plan": rollback_plan,
	}
	request.finished.connect(
		_cleanup_validation.bind(request.get_instance_id()), CONNECT_ONE_SHOT)
	SignalBus.validate_movie_request(request, self, _capability)


func _on_accept_requested(request: MovieOperationRequest) -> void:
	if (
		_capability == null
		or request == null
		or not _validation_cache.has(request.get_instance_id())
	):
		return
	var record: Dictionary = _validation_cache[request.get_instance_id()]
	var previous_state: Dictionary = record.get("rollback_state", {})
	_rollback_cache[request.get_request_id()] = {
		"empty": previous_state.is_empty(),
		"key": _state_key(previous_state),
		"plan": record.get("rollback_plan", {}),
	}
	SignalBus.accept_movie_request(request, self, _capability)


func _on_apply_requested(request: MovieOperationRequest) -> void:
	if _capability == null or request == null:
		return
	var record: Dictionary = _validation_cache.get(request.get_instance_id(), {})
	var prepared: Dictionary = record.get("apply", {})
	if record.is_empty() or prepared.is_empty():
		return
	var payload := request.get_payload()
	if (
		payload.get("action") == "play"
		and SignalBus.has_active_presentation_clip_projection()
	):
		SignalBus.fail_movie_apply(
			request,
			self,
			_capability,
			"a presentation clip claimed the mutually exclusive full-screen media surface after movie preflight",
		)
		return
	var committed: Dictionary = {}
	if payload["action"] == "stop":
		var expected_epoch := SignalBus.current_movie_epoch()
		var expected_generation := _generation
		_retire_active(&"superseded")
		if (
			expected_epoch != SignalBus.current_movie_epoch()
			or expected_generation != _generation
			or not _active.is_empty()
		):
			SignalBus.fail_movie_apply(
				request,
				self,
				_capability,
				"movie stop was invalidated by a reentrant replacement",
			)
			return
		_recovery_cache.clear()
		var receipt := _new_receipt(request.get_request_id())
		SignalBus.movie_transition_receipt_started.emit(
			get_instance_id(), receipt.token, receipt.request_id, receipt.generation)
		SignalBus.movie_transition_terminal.emit(
			get_instance_id(), receipt.token, receipt.request_id,
			receipt.generation, &"completed")
	else:
		committed = _apply_play(payload, prepared, request.get_request_id())
		if committed.is_empty():
			SignalBus.fail_movie_apply(
				request,
				self,
				_capability,
				"native movie apply was invalidated or could not start",
			)
			return
	SignalBus.acknowledge_movie_apply(
		request, self, _capability, committed)


func _apply_play(
	payload: Dictionary,
	prepared: Dictionary,
	request_id: int,
) -> Dictionary:
	var stream: VideoStream = prepared.get("stream")
	var length := float(prepared.get("length", 0.0))
	if stream == null or length <= 0.0:
		return {}
	var target := MovieChannelState.state_for_play(
		String(payload["asset"]),
		bool(payload["loop"]),
		bool(payload["skippable"]),
		length,
		0.0,
	)
	if target.is_empty():
		return {}
	if (
		not _active.is_empty()
		and MovieChannelState.operation_matches_state(
			_capture_active_state(), payload)
		and absf(float(_active.state.length) - length) <= SEEK_EPSILON
		and _player.stream == stream
	):
		var expected_epoch := SignalBus.current_movie_epoch()
		var expected_generation := _generation
		var expected_state_key := _state_key(
			(_active.get("state", {}) as Dictionary))
		_retire_receipt(&"superseded")
		if (
			expected_epoch != SignalBus.current_movie_epoch()
			or expected_generation != _generation
			or _active.is_empty()
			or not (_active.get("receipt", {}) as Dictionary).is_empty()
			or _player.stream != stream
			or not _player.is_playing()
			or _state_key(
				(_active.get("state", {}) as Dictionary)) != expected_state_key
		):
			return {}
		var attached := _new_receipt(request_id)
		_active["receipt"] = attached
		_active["state"] = _capture_active_state()
		SignalBus.movie_transition_receipt_started.emit(
			get_instance_id(), attached.token, attached.request_id,
			attached.generation)
		return _capture_active_state()
	var expected_epoch := SignalBus.current_movie_epoch()
	var expected_generation := _generation
	_retire_active(&"superseded")
	if (
		expected_epoch != SignalBus.current_movie_epoch()
		or expected_generation != _generation
		or not _active.is_empty()
	):
		return {}
	_generation += 1
	_player.stream = stream
	_player.loop = bool(payload["loop"])
	_apply_volume()
	_player.visible = true
	_backdrop.visible = true
	_player.play()
	if not _player.is_playing():
		_player.visible = false
		_backdrop.visible = false
		_player.stream = null
		return {}
	var receipt := _new_receipt(request_id)
	_active = {
		"receipt": receipt,
		"state": target,
		"generation": _generation,
	}
	SignalBus.movie_transition_receipt_started.emit(
		get_instance_id(), receipt.token, receipt.request_id, receipt.generation)
	_recovery_cache.clear()
	return target.duplicate(true)


func _on_finish_requested(request_id: int, input_kind: StringName) -> void:
	_claim_active_input_finish(request_id, input_kind, _capability)


func _has_active_projection(capability: RefCounted) -> bool:
	return capability == _capability and not _active.is_empty()


func _discard_recovery_state(capability: RefCounted) -> bool:
	if capability != _capability:
		return false
	_recovery_cache.clear()
	return true


func _claim_active_input_finish(
	request_id: int,
	input_kind: StringName,
	capability: RefCounted,
) -> bool:
	if capability == null or capability != _capability or _active.is_empty():
		return false
	var receipt: Dictionary = _active.get("receipt", {})
	if int(receipt.get("request_id", 0)) != request_id:
		return false
	if input_kind not in [&"advance", &"right_click", &"skip"]:
		return false
	var state: Dictionary = _active.get("state", {})
	if not bool(state.get("skippable", true)):
		return true
	if (
		input_kind == &"right_click"
		and not bool(StellaRuntime.get_setting("movie_right_click_skip"))
	):
		return true
	if (
		input_kind == &"skip"
		and not bool(StellaRuntime.get_setting("movie_skip_on_skip"))
	):
		return true
	_retire_active(&"completed")
	return true


func _on_player_finished() -> void:
	if _active.is_empty() or bool((_active.state as Dictionary).get("loop", false)):
		return
	_retire_active(&"completed", false)


func _on_projection_reset_requested(epoch: int) -> void:
	if _capability == null or epoch != SignalBus.current_movie_epoch():
		return
	var recovery_state := _capture_active_state()
	if (
		not recovery_state.is_empty()
		and _player.stream is VideoStreamTheora
	):
		# A return-to-title transaction may reject its configured scene and retry
		# the built-in destination under the same reversible navigation. The second
		# reset observes no active player; retain the first sealed cursor until that
		# transaction either restores it or explicitly discards the lease.
		_recovery_cache.clear()
		_recovery_cache[_state_key(recovery_state)] = {
			"stream": _player.stream,
			"length": float(recovery_state["length"]),
		}
	_generation += 1
	_validation_cache.clear()
	_retire_active(&"cancelled")


func _apply_restore_state(
	state: Dictionary,
	epoch: int,
	capability: RefCounted,
) -> bool:
	var key := _state_key(state)
	var prepared: Dictionary = {}
	if _armed_restore_ticket == _restore_ticket and _armed_restore_key == key:
		prepared = _restore_cache.get(key, {})
	if prepared.is_empty():
		prepared = _recovery_cache.get(key, {})
	_restore_cache.erase(key)
	_restore_ticket = 0
	_armed_restore_ticket = 0
	_armed_restore_key = ""
	_recovery_cache.erase(key)
	if (
		capability != _capability
		or epoch != SignalBus.current_movie_epoch()
		or not _active.is_empty()
		or state.is_empty()
		or not MovieChannelState.validate_snapshot_state(state, false)
	):
		return false
	if prepared.is_empty() or not _restore_state_matches_plan(state, prepared):
		push_error("MoviePresenter: saved movie resource changed after restore preflight")
		return false
	return _install_restored_state(
		state, prepared, "MoviePresenter: native movie seek failed during restore")


func _apply_rollback_state(
	request_id: int,
	state: Dictionary,
	epoch: int,
	capability: RefCounted,
) -> bool:
	var record: Dictionary = _armed_rollback_plans.get(request_id, {})
	_armed_rollback_plans.erase(request_id)
	_recovery_cache.clear()
	if (
		_capability == null
		or capability != _capability
		or epoch != SignalBus.current_movie_epoch()
		or not _active.is_empty()
		or record.is_empty()
	):
		return false
	if state.is_empty():
		return bool(record.get("empty", false))
	if bool(record.get("empty", false)):
		return false
	var prepared: Dictionary = record.get("plan", {})
	if (
		String(record.get("key", "")) != _state_key(state)
		or not MovieChannelState.validate_snapshot_state(state, false)
		or not _restore_state_matches_plan(state, prepared)
	):
		push_error(
			"MoviePresenter: sealed movie rollback resource changed before apply")
		return false
	return _install_restored_state(
		state,
		prepared,
		"MoviePresenter: native movie seek failed during sealed rollback",
	)


func _install_restored_state(
	state: Dictionary,
	prepared: Dictionary,
	failure_message: String,
) -> bool:
	var stream: VideoStream = prepared.get("stream")
	_generation += 1
	_player.stream = stream
	_player.loop = bool(state["loop"])
	_apply_volume()
	_player.visible = true
	_backdrop.visible = true
	_player.play()
	_player.stream_position = float(state["position"])
	if (
		not _player.is_playing()
		or absf(_player.stream_position - float(state["position"])) > SEEK_EPSILON
	):
		_player.stop()
		_player.stream = null
		_player.visible = false
		_backdrop.visible = false
		push_error(failure_message)
		return false
	_active = {
		"receipt": {},
		"state": state.duplicate(true),
		"generation": _generation,
	}
	_recovery_cache.clear()
	return true


func _on_state_capture_requested(request: MovieStateCaptureRequest) -> void:
	if _capability == null or request == null:
		return
	var state := _capture_active_state()
	var stable := _active.is_empty() or not state.is_empty()
	SignalBus.resolve_movie_state_capture(
		request, self, _capability, state, stable)


## Side-effect-free restore admission called before Runtime acquires navigation.
func prepare_restore_state(state: Dictionary) -> int:
	_restore_cache.clear()
	_restore_ticket = 0
	_armed_restore_ticket = 0
	_armed_restore_key = ""
	if not MovieChannelState.validate_snapshot_state(state, false):
		return 0
	_restore_ticket_serial += 1
	var ticket := _restore_ticket_serial
	if state.is_empty():
		_restore_ticket = ticket
		return ticket
	var prepared := _resolve_movie(String(state["asset"]))
	if not _restore_state_matches_plan(state, prepared):
		return 0
	_restore_cache[_state_key(state)] = prepared
	_restore_ticket = ticket
	return ticket


func arm_restore_state(ticket: int, state: Dictionary) -> bool:
	if ticket <= 0 or ticket != _restore_ticket:
		return false
	if not MovieChannelState.validate_snapshot_state(state, false):
		return false
	var key := _state_key(state)
	if not state.is_empty() and not _restore_cache.has(key):
		return false
	_armed_restore_ticket = ticket
	_armed_restore_key = key
	return true


func discard_restore_state(ticket: int) -> bool:
	if ticket <= 0 or ticket != _restore_ticket:
		return false
	_restore_cache.clear()
	_restore_ticket = 0
	_armed_restore_ticket = 0
	_armed_restore_key = ""
	return true


func _prepare_rollback_state(
	request_id: int,
	state: Dictionary,
	capability: RefCounted,
) -> bool:
	if capability != _capability or request_id <= 0:
		return false
	var record: Dictionary = _rollback_cache.get(request_id, {})
	if state.is_empty():
		if record.is_empty() or not bool(record.get("empty", false)):
			return false
		_armed_rollback_plans[request_id] = {
			"empty": true,
			"key": _state_key(state),
			"plan": {},
		}
		return true
	if (
		record.is_empty()
		or bool(record.get("empty", false))
		or String(record.get("key", "")) != _state_key(state)
		or not record.get("plan", {}) is Dictionary
		or not _restore_state_matches_plan(state, record.get("plan", {}))
	):
		return false
	_armed_rollback_plans[request_id] = {
		"empty": false,
		"key": _state_key(state),
		"plan": (record["plan"] as Dictionary).duplicate(),
	}
	return true


func _release_rollback_plan(
	request_id: int,
	capability: RefCounted,
) -> bool:
	if capability != _capability or request_id <= 0:
		return false
	return _rollback_cache.erase(request_id)


func _restore_state_matches_plan(state: Dictionary, prepared: Dictionary) -> bool:
	return (
		not prepared.is_empty()
		and absf(float(prepared.get("length", 0.0)) - float(state["length"]))
			<= SEEK_EPSILON
		and float(state["position"]) >= 0.0
		and float(state["position"]) < float(prepared.get("length", 0.0))
	)


func _capture_active_state() -> Dictionary:
	if _active.is_empty() or _player == null or not _player.is_playing():
		return {}
	var state: Dictionary = (_active.get("state", {}) as Dictionary).duplicate(true)
	var length := float(state.get("length", 0.0))
	var position := _player.stream_position
	if bool(state.get("loop", false)) and length > 0.0:
		position = fposmod(position, length)
	state["position"] = position
	return state if MovieChannelState.validate_snapshot_state(state, false) else {}


func _resolve_movie(asset: String) -> Dictionary:
	if not MovieChannelState.is_logical_id(asset):
		return {}
	var root := StellaRuntime.movies_path
	if not root.ends_with("/"):
		root += "/"
	var path := "%s%s.ogv" % [root, asset]
	if not ResourceLoader.exists(path, "VideoStream"):
		return {}
	var stream := ResourceLoader.load(path, "VideoStream", ResourceLoader.CACHE_MODE_REUSE)
	if not stream is VideoStreamTheora:
		return {}
	var probe := VideoStreamPlayer.new()
	probe.stream = stream
	var length := probe.get_stream_length()
	probe.stream = null
	probe.free()
	if not is_finite(length) or length <= 0.0:
		return {}
	return {"stream": stream, "length": length, "path": path}


func _on_settings_changed(key: String, _value: Variant) -> void:
	if key in ["master_volume", "movie_volume"]:
		_apply_volume()


func _apply_volume() -> void:
	if _player == null:
		return
	var master := clampf(float(StellaRuntime.get_setting("master_volume")), 0.0, 1.0)
	var movie := clampf(float(StellaRuntime.get_setting("movie_volume")), 0.0, 1.0)
	_player.volume = master * movie


func _cleanup_validation(request_key: int) -> void:
	_validation_cache.erase(request_key)


func _new_receipt(request_id: int) -> Dictionary:
	_token_serial += 1
	return {
		"request_id": request_id,
		"token": _token_serial,
		"generation": _generation,
	}


func _retire_receipt(outcome: StringName) -> void:
	if _active.is_empty():
		return
	var receipt: Dictionary = _active.get("receipt", {})
	_active["receipt"] = {}
	if receipt.is_empty():
		return
	SignalBus.movie_transition_terminal.emit(
		get_instance_id(),
		int(receipt.get("token", 0)),
		int(receipt.get("request_id", 0)),
		int(receipt.get("generation", 0)),
		outcome,
	)


func _retire_active(
	outcome: StringName,
	stop_player: bool = true,
) -> void:
	if _active.is_empty():
		return
	var receipt: Dictionary = _active.get("receipt", {})
	var retired_generation := int(_active.get("generation", 0))
	_active.clear()
	if stop_player and _player != null:
		_player.stop()
	if _player != null:
		_player.visible = false
		_player.stream = null
	if _backdrop != null:
		_backdrop.visible = false
	var completion_token := 0
	if (
		outcome == &"completed"
		and _capability != null
		and not _exiting
		and retired_generation > 0
	):
		completion_token = SignalBus.commit_movie_completion(self, _capability)
	if receipt.is_empty():
		if completion_token > 0:
			SignalBus.finish_movie_completion(self, _capability, completion_token)
		return
	# Terminal delivery is deliberately last: it may synchronously run the next
	# scenario command and install a replacement generation.
	SignalBus.movie_transition_terminal.emit(
		get_instance_id(),
		int(receipt.get("token", 0)),
		int(receipt.get("request_id", 0)),
		int(receipt.get("generation", 0)),
		outcome,
	)
	if completion_token > 0:
		SignalBus.finish_movie_completion(self, _capability, completion_token)


func _state_key(state: Dictionary) -> String:
	return JSON.stringify(state)


func _disconnect_runtime_signals() -> void:
	for connection: Dictionary in [
		{"signal": SignalBus.movie_validate_requested, "callable": _on_validate_requested},
		{"signal": SignalBus.movie_accept_requested, "callable": _on_accept_requested},
		{"signal": SignalBus.movie_apply_requested, "callable": _on_apply_requested},
		{"signal": SignalBus.movie_finish_requested, "callable": _on_finish_requested},
		{"signal": SignalBus.movie_projection_reset_requested, "callable": _on_projection_reset_requested},
		{"signal": SignalBus.movie_state_capture_requested, "callable": _on_state_capture_requested},
		{"signal": SignalBus.settings_changed, "callable": _on_settings_changed},
	]:
		var runtime_signal: Signal = connection["signal"]
		var callback: Callable = connection["callable"]
		if runtime_signal.is_connected(callback):
			runtime_signal.disconnect(callback)
