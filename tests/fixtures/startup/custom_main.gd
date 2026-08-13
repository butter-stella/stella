extends Node

const EXPECTED_TITLE = "Synthetic Custom Main Probe"
const CustomMainVerifier = preload(
	"res://tests/fixtures/startup/custom_main_verifier.gd"
)

var _title_from_initializer := _read_runtime_title()
var _title_from_init := ""
var _snapshot_phase := "alive"


func _init() -> void:
	_title_from_init = _read_runtime_title()


func _ready() -> void:
	var failures := PackedStringArray()
	if _title_from_initializer != EXPECTED_TITLE:
		failures.append("member initializer did not observe resolved config")
	if _title_from_init != EXPECTED_TITLE:
		failures.append("custom main _init did not observe resolved config")

	# The provider belongs to the outgoing scene. Its _exit_tree() mutation makes
	# the autosave ordering observable: a correct return captures "alive" before
	# change_scene_to_packed() synchronously removes this scene.
	var marker_path := OS.get_environment("STELLA_CUSTOM_MAIN_PROBE_MARKER")
	var isolated_save_dir := "user://tests/custom_main_probe_saves/"
	if marker_path != "":
		isolated_save_dir = marker_path.get_base_dir() + "/stella-custom-main-saves/"
	StellaRuntime.save_manager.save_dir = isolated_save_dir
	StellaRuntime.delete_auto_save()
	StellaRuntime.save_manager.register_provider(self)
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	# The verifier must outlive this current scene when return_to_title replaces
	# it. It resumes on SceneTree.scene_changed and checks the final current_scene.
	var verifier := CustomMainVerifier.new()
	_attach_verifier_and_return.call_deferred(verifier, failures)


func _attach_verifier_and_return(verifier: Node, failures: PackedStringArray) -> void:
	get_tree().root.add_child(verifier)
	verifier.verify_after_return(failures)
	StellaRuntime.return_to_title()


func _read_runtime_title() -> String:
	if StellaRuntime.config == null:
		return "<null>"
	return StellaRuntime.config.game_title


func get_provider_id() -> String:
	return "return_to_title_order_probe"


func capture_snapshot() -> Dictionary:
	return {"phase": _snapshot_phase}


func _exit_tree() -> void:
	_snapshot_phase = "exited"
