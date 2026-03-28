## POC bootstrap — starts the demo scenario on scene ready.
extends Node


func _ready():
	# Wait one frame for all autoloads and presenters to initialize
	await get_tree().process_frame
	NatsumeRuntime.start_scenario("res://game/scenarios/poc_demo.ntm")
