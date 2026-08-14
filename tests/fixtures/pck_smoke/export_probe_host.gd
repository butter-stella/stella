extends Node

const ExportProbeRunner = preload(
	"res://tests/fixtures/pck_smoke/export_probe_runner.gd"
)


func _ready() -> void:
	# Keep the probe outside current_scene so it survives the bootstrap's two
	# scene changes (probe host -> bootstrap -> resolved/fallback title).
	var runner := ExportProbeRunner.new()
	_attach_and_run.call_deferred(runner)


func _attach_and_run(runner: Node) -> void:
	get_tree().root.add_child(runner)
	runner.run()
