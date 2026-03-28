## Demo bootstrap — configures asset paths and title screen.
## No longer auto-starts scenario; title screen handles that.
extends Node


func _ready():
	# Configure asset paths
	NatsumeRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	NatsumeRuntime.characters_path = "res://examples/demo/art/characters/"
	NatsumeRuntime.bgm_path = "res://examples/demo/audio/bgm/"
	NatsumeRuntime.se_path = "res://examples/demo/audio/se/"
	NatsumeRuntime.voice_path = "res://examples/demo/audio/voice/"

	# Configure title screen
	var title_screen = get_node_or_null("../TitleScreen")
	if title_screen:
		title_screen.game_title = "Natsume Demo"
		title_screen.scenario_path = "res://examples/demo/scenarios/poc_demo.ntm"
