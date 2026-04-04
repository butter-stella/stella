## Loads .nat files as NatScript resources.
class_name NatFormatLoader extends ResourceFormatLoader


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["nat"])


func _get_resource_type(path: String) -> String:
	if path.get_extension() == "nat":
		return "NatScript"
	return ""


func _handles_type(type: StringName) -> bool:
	return type == &"NatScript"


func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var res = NatScript.new()
	res.source_code = file.get_as_text()
	file.close()
	return res
