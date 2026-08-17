## Tracks presentation-layer state (background, named stage layers, BGM) for save/load.
## Listens to SignalBus to mirror visual state; restores via signals on load.
class_name PresentationState extends RefCounted

var current_bg: String = ""
var stage_layers: Dictionary = {}  # stable layer id -> canonical StageLayerState
var current_bgm: String = ""

var _connected: bool = false


func get_provider_id() -> String:
	return "presentation_state"


func connect_signals() -> void:
	if _connected:
		return
	SignalBus.bg_changed.connect(_on_bg_changed)
	SignalBus.stage_operations_requested.connect(_on_stage_operations)
	SignalBus.bgm_play.connect(_on_bgm_play)
	SignalBus.bgm_stop.connect(_on_bgm_stop)
	_connected = true


func disconnect_signals() -> void:
	if not _connected:
		return
	SignalBus.bg_changed.disconnect(_on_bg_changed)
	SignalBus.stage_operations_requested.disconnect(_on_stage_operations)
	SignalBus.bgm_play.disconnect(_on_bgm_play)
	SignalBus.bgm_stop.disconnect(_on_bgm_stop)
	_connected = false


func clear() -> void:
	current_bg = ""
	stage_layers.clear()
	current_bgm = ""


func capture_snapshot() -> Dictionary:
	return {
		"bg": current_bg,
		"stage_layers": stage_layers.duplicate(true),
		"bgm": current_bgm,
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_bg = snapshot.get("bg", "")
	current_bgm = snapshot.get("bgm", "")
	stage_layers.clear()
	var restored_layers = snapshot.get("stage_layers", {})
	if restored_layers is Dictionary:
		for id in restored_layers:
			var layer_id := str(id).strip_edges()
			if layer_id == "":
				push_warning("PresentationState: ignored empty stage layer id")
				continue
			var layer_state = restored_layers[id]
			if layer_state is Dictionary:
				stage_layers[layer_id] = StageLayerState.normalize_full(layer_state)
			else:
				push_warning(
					"PresentationState: invalid stage layer '%s' in snapshot"
					% str(id)
				)


## Project the current PresentationState onto the visual presenters by
## emitting background/stage/BGM signals with snap-to parameters.
##
## Idempotent complete projection for save/load restore, backlog jump replay,
## or any other context that needs visuals to match freshly-restored state.
## In-flight and queued authored stage operations are invalidated first so a
## stale mutation cannot land after the restored checkpoint.
func apply_to_presenters() -> void:
	# This is a complete projection, not a patch. Reset invalidates operation
	# delivery but does not mutate this snapshot's canonical stage_layers. Keep
	# the cut projection inside the same reset transaction so a lifecycle
	# callback's winning Stage submission is dispatched only after the old
	# snapshot has finished projecting.
	SignalBus.reset_and_apply_stage_state(stage_layers)
	SignalBus.bg_changed.emit(current_bg, "none", 0.0)
	if current_bgm != "":
		SignalBus.bgm_play.emit(current_bgm, 0.0)
	else:
		SignalBus.bgm_stop.emit(0.0)


# ─── Signal callbacks ───

func _on_bg_changed(asset: String, _transition: String, _duration: float) -> void:
	current_bg = asset


func _on_stage_operations(operations: Array, _force_cut: bool) -> void:
	if not SignalBus.is_current_stage_operation_valid():
		return
	stage_layers = StageLayerState.reduce(stage_layers, operations)


func _on_bgm_play(asset: String, _fade_duration: float) -> void:
	current_bgm = asset


func _on_bgm_stop(_fade_duration: float) -> void:
	current_bgm = ""
