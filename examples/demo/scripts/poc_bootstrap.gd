## Demo bootstrap — configures asset paths and starts the demo scenario.
extends Node


func _ready():
	# Configure asset paths for the demo
	NatsumeRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	NatsumeRuntime.characters_path = "res://examples/demo/art/characters/"
	NatsumeRuntime.bgm_path = "res://examples/demo/audio/bgm/"
	NatsumeRuntime.se_path = "res://examples/demo/audio/se/"
	NatsumeRuntime.voice_path = "res://examples/demo/audio/voice/"

	# Wait one frame for all autoloads and presenters to initialize
	await get_tree().process_frame
	NatsumeRuntime.start_scenario("res://examples/demo/scenarios/poc_demo.ntm")
