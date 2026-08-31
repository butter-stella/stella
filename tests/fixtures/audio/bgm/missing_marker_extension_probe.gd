extends Node
## Clean-clone probe: a marker track fails closed with one actionable diagnostic
## before the build-generated .gdextension descriptor exists.


func _ready() -> void:
	var presenter := AudioPresenter.new()
	var definition := ResourceLoader.load(
		"res://tests/fixtures/audio/bgm/synthetic_marker_stems.tres"
	) as BgmTrackDefinition
	var prepared: Dictionary = presenter.call(
		"_prepare_bgm_definition", definition, "", {})
	presenter.free()
	get_tree().quit(0 if prepared.is_empty() else 1)
