extends Node
## Synthetic public-project owner for registry lifecycle integration tests.

var execute_count: int = 0


func execute_action(_context: Dictionary) -> bool:
	execute_count += 1
	return true
