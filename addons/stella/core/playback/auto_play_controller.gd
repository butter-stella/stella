## Controls auto-play mode — automatically advances dialogue after a delay.
class_name AutoPlayController extends RefCounted

signal active_changed(active: bool)
signal effective_changed(effective: bool)

var _suspension_owners: Dictionary = {}

var is_active: bool = false:
	set(value):
		if is_active == value:
			return
		var was_effective := is_effective()
		is_active = value
		active_changed.emit(is_active)
		_emit_effective_change(was_effective)


func toggle() -> void:
	is_active = not is_active


func stop() -> void:
	is_active = false


## Temporarily suppress automatic progression without changing the user's
## active intent. Owners are explicit tokens so a stale choice cannot release a
## newer choice's suspension.
func acquire_suspension(owner: Variant) -> void:
	if _suspension_owners.has(owner):
		return
	var was_effective := is_effective()
	_suspension_owners[owner] = true
	_emit_effective_change(was_effective)


func release_suspension(owner: Variant) -> void:
	if not _suspension_owners.has(owner):
		return
	var was_effective := is_effective()
	_suspension_owners.erase(owner)
	_emit_effective_change(was_effective)


func clear_suspensions() -> void:
	if _suspension_owners.is_empty():
		return
	var was_effective := is_effective()
	_suspension_owners.clear()
	_emit_effective_change(was_effective)


## Hard execution boundaries clear every retired owner while preserving a
## choice that was synchronously installed by the replacement context. State is
## mutated before the edge is emitted, so a reentrant new owner is never swept
## by the old boundary's cleanup tail.
func clear_suspensions_except(owner: Variant) -> void:
	var was_effective := is_effective()
	for existing_owner in _suspension_owners.keys():
		if existing_owner != owner:
			_suspension_owners.erase(existing_owner)
	_emit_effective_change(was_effective)


func is_effective() -> bool:
	return is_active and _suspension_owners.is_empty()


func _emit_effective_change(was_effective: bool) -> void:
	var effective := is_effective()
	if effective != was_effective:
		effective_changed.emit(effective)
