extends GutTest
## Tests for SaveManager — save/load with snapshot providers.


var _manager: SaveManager
var _save_dir: String = "user://test_saves/"


func before_each():
	_manager = SaveManager.new()
	_manager.save_dir = _save_dir


func after_each():
	# Clean up test save files
	var dir = DirAccess.open("user://")
	if dir and dir.dir_exists("test_saves"):
		var saves = DirAccess.open(_save_dir)
		if saves:
			saves.list_dir_begin()
			var file_name = saves.get_next()
			while file_name != "":
				if not saves.current_is_dir():
					saves.remove(file_name)
				file_name = saves.get_next()
		dir.remove("test_saves")


# --- Mock snapshot provider ---
class MockProvider:
	var id: String
	var data: Dictionary = {}

	func _init(p_id: String = "mock"):
		id = p_id

	func get_provider_id() -> String:
		return id

	func capture_snapshot() -> Dictionary:
		return data.duplicate()

	func restore_snapshot(snapshot: Dictionary) -> void:
		data = snapshot.duplicate()


func test_register_provider():
	var provider = MockProvider.new("test")
	_manager.register_provider(provider)
	assert_eq(_manager.get_provider_count(), 1)


func test_save_creates_file():
	var provider = MockProvider.new("vars")
	provider.data = {"hp": 100, "name": "sakura"}
	_manager.register_provider(provider)

	_manager.save(1)

	assert_true(FileAccess.file_exists(_save_dir + "save_1.json"))


func test_save_and_load_restores_state():
	var provider = MockProvider.new("vars")
	provider.data = {"hp": 100, "location": "school"}
	_manager.register_provider(provider)

	_manager.save(1)

	# Modify state
	provider.data = {"hp": 50, "location": "home"}

	# Load should restore
	_manager.load_save(1)

	assert_eq(provider.data["hp"], 100)
	assert_eq(provider.data["location"], "school")


func test_multiple_providers():
	var vars_provider = MockProvider.new("vars")
	vars_provider.data = {"hp": 100}
	var engine_provider = MockProvider.new("engine")
	engine_provider.data = {"scene": "start", "cmd": 3}

	_manager.register_provider(vars_provider)
	_manager.register_provider(engine_provider)

	_manager.save(1)

	vars_provider.data = {"hp": 0}
	engine_provider.data = {"scene": "ending", "cmd": 0}

	_manager.load_save(1)

	assert_eq(vars_provider.data["hp"], 100)
	assert_eq(engine_provider.data["scene"], "start")


func test_multiple_save_slots():
	var provider = MockProvider.new("vars")
	provider.data = {"slot": "first"}
	_manager.register_provider(provider)
	_manager.save(1)

	provider.data = {"slot": "second"}
	_manager.save(2)

	_manager.load_save(1)
	assert_eq(provider.data["slot"], "first")

	_manager.load_save(2)
	assert_eq(provider.data["slot"], "second")


func test_load_nonexistent_slot_returns_false():
	assert_false(_manager.load_save(999))


func test_has_save():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	assert_false(_manager.has_save(1))
	_manager.save(1)
	assert_true(_manager.has_save(1))


func test_delete_save():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)
	assert_true(_manager.has_save(1))

	_manager.delete_save(1)
	assert_false(_manager.has_save(1))


func test_get_save_list():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)
	_manager.save(3)

	var saves = _manager.get_save_list()
	assert_true(saves.size() >= 2)


func test_save_includes_timestamp():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)

	var file = FileAccess.open(_save_dir + "save_1.json", FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text())
	assert_true(data.has("timestamp"))
	assert_true(data["timestamp"] > 0)
