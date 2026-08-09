## Instruction data container used by all command handlers.
## Each command has a type string and a params dictionary.
class_name CommandData extends RefCounted

var type: String = ""
var params: Dictionary = {}
## Stable per-scenario monotonic id assigned at scenario load time.
## Used by BacklogManager as a position-stable command identity that
## survives `@call` reuse, dynamic insertion, and most edits — unlike
## (scene_index, command_index) which collides under those scenarios.
## Default -1 = unassigned (test fixtures that construct commands
## manually without going through ScenarioEngine.load_scenario).
var uid: int = -1
## Source line of the DSL token that produced this command (1-based).
## Set by DslParser; 0 for commands constructed manually (e.g. test
## fixtures or synthesized condition commands from @if expansion).
## Used by ScenarioGraphBuilder for click-to-source on graph edges (#97).
var declared_line: int = 0
## Runtime-only dialogue mode transitions that execute immediately before or
## after this addressable command. DslParser lowers source mode directives into
## these sidecars so @nvl boundaries retain execution order without inserting
## extra scene commands that would shift save/read-flag command indices.
var dialogue_mode_events_before: Array[String] = []
var dialogue_mode_events_after: Array[String] = []
## Condition-only sidecars applied on the selected edge before its jump. These
## keep mode-only branches non-addressable instead of synthesizing a scene just
## to carry a runtime transition.
var dialogue_mode_events_on_true_branch: Array[String] = []
var dialogue_mode_events_on_false_branch: Array[String] = []


func get_string(key: String, default: String = "") -> String:
	if not params.has(key):
		return default
	return str(params[key])


func get_float(key: String, default: float = 0.0) -> float:
	if not params.has(key):
		return default
	return float(params[key])


func get_int(key: String, default: int = 0) -> int:
	if not params.has(key):
		return default
	return int(params[key])


func get_bool(key: String, default: bool = false) -> bool:
	if not params.has(key):
		return default
	var val = params[key]
	if val is bool:
		return val
	if val is int or val is float:
		return val != 0
	return str(val).to_lower() == "true"


func has_param(key: String) -> bool:
	return params.has(key)
