## Manages macro game state transitions.
## Title → Playing ↔ Paused / SaveLoad / Backlog / Settings
class_name GameStateMachine extends RefCounted

signal state_changed(from_state: int, to_state: int)

enum State {
	TITLE,
	PLAYING,
	PAUSED,
	SAVE_LOAD,
	BACKLOG,
	SETTINGS,
}

var current_state: int = State.TITLE


func transition_to(new_state: int) -> void:
	if new_state == current_state:
		return
	var old_state = current_state
	current_state = new_state
	state_changed.emit(old_state, new_state)


func is_playing() -> bool:
	return current_state == State.PLAYING
