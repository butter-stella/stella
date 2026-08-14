## Process-level regression fixture: a production scene may request a title
## return synchronously while its root is still busy in _ready().
extends Node


func _ready() -> void:
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	StellaRuntime.return_to_title()
