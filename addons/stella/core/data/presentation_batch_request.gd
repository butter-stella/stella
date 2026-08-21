## Immutable authored batch plus authority-guarded exact settlement state.
class_name PresentationBatchRequest extends RefCounted

signal settled(batch_id: int, outcome: int)

enum Policy { JOIN, FIRE_AND_FORGET }
enum Outcome { COMPLETED, CANCELLED, FAILED }

var _policy: Policy
var _operations: Array
var _batch_id: int = 0
var _receipts: Array = []
var _outcome: Outcome = Outcome.CANCELLED
var _is_settled: bool = false
var _authority: Object
var _is_sealed: bool = false


func _init(policy: Policy = Policy.JOIN, operations: Array = []) -> void:
	_policy = policy
	_operations = operations.duplicate()


func get_policy() -> Policy:
	return _policy


func get_operations() -> Array:
	return _operations.duplicate()


func get_batch_id() -> int:
	return _batch_id


func get_receipts() -> Array:
	return _receipts.duplicate()


func get_outcome() -> Outcome:
	return _outcome


func is_settled() -> bool:
	return _is_settled


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _seal(batch_id: int, receipts: Array, authority: Object) -> bool:
	if authority == null or authority != _authority or _is_sealed:
		return false
	_batch_id = batch_id
	_receipts = receipts.duplicate()
	_is_sealed = true
	return true


func _settle(outcome: Outcome, authority: Object) -> bool:
	if authority == null or authority != _authority or _is_settled:
		return false
	_outcome = outcome
	_is_settled = true
	settled.emit(_batch_id, _outcome)
	return true
