## Demo bootstrap — configures NatsumeRuntime paths and title screen.
## Attached to both title and game scenes (safe to run in either context).
extends Node


func _ready():
	# Configure asset paths
	NatsumeRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	NatsumeRuntime.characters_path = "res://examples/demo/art/characters/"
	NatsumeRuntime.bgm_path = "res://examples/demo/audio/bgm/"
	NatsumeRuntime.se_path = "res://examples/demo/audio/se/"
	NatsumeRuntime.voice_path = "res://examples/demo/audio/voice/"
	NatsumeRuntime.title_scene_path = "res://examples/demo/scenes/title.tscn"

	# Configure title screen if present
	var title_screen = get_parent().get_node_or_null("TitleScreen")
	if title_screen:
		title_screen.game_title = "Natsume Demo"
		title_screen.scenario_path = "res://examples/demo/scenarios/poc_demo.ntm"
		title_screen.game_scene_path = "res://examples/demo/scenes/game.tscn"
