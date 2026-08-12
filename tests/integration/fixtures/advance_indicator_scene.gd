extends ColorRect
## Synthetic custom indicator used to verify the documented ready-state hook.

static var ready_callback: Callable

var advance_ready: bool = false
var advance_ready_history: Array[bool] = []


func set_advance_ready(ready: bool) -> void:
	advance_ready = ready
	advance_ready_history.append(ready)
	if ready_callback.is_valid():
		ready_callback.call(ready)
