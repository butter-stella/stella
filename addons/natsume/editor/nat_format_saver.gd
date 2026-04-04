## Saves NatScript resources back to .nat files.
class_name NatFormatSaver extends ResourceFormatSaver


func _get_recognized_extensions(resource: Resource) -> PackedStringArray:
	if resource is NatScript:
		return PackedStringArray(["nat"])
	return PackedStringArray()


func _recognize(resource: Resource) -> bool:
	return resource is NatScript


func _save(resource: Resource, path: String, _flags: int) -> Error:
	var nat := resource as NatScript
	if nat == null:
		return ERR_INVALID_PARAMETER
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(nat.source_code)
	return OK
