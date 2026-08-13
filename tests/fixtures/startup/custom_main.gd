extends Node

const EXPECTED_TITLE = "Synthetic Custom Main Probe"
const CustomMainVerifier = preload(
	"res://tests/fixtures/startup/custom_main_verifier.gd"
)

var _title_from_initializer := _read_runtime_title()
var _title_from_init := ""


func _init() -> void:
	_title_from_init = _read_runtime_title()


func _ready() -> void:
	var failures := PackedStringArray()
	if _title_from_initializer != EXPECTED_TITLE:
		failures.append("member initializer did not observe resolved config")
	if _title_from_init != EXPECTED_TITLE:
		failures.append("custom main _init did not observe resolved config")

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
