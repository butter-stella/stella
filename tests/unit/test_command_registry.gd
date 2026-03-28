extends GutTest
## Tests for CommandRegistry — handler registration and lookup.


var _registry: CommandRegistry


func before_each():
	_registry = CommandRegistry.new()


# --- Stub handler for testing ---
class StubHandler extends CommandHandler:
	var _type: String

	func _init(type: String = "stub"):
		_type = type

	func get_command_type() -> String:
		return _type


func test_register_and_get_handler():
	var handler = StubHandler.new("dialogue")
	_registry.register(handler)
	var result = _registry.get_handler("dialogue")
	assert_eq(result, handler)


func test_get_handler_returns_null_for_unregistered():
	assert_null(_registry.get_handler("nonexistent"))


func test_register_multiple_handlers():
	var h1 = StubHandler.new("dialogue")
	var h2 = StubHandler.new("bg")
	_registry.register(h1)
	_registry.register(h2)
	assert_eq(_registry.get_handler("dialogue"), h1)
	assert_eq(_registry.get_handler("bg"), h2)


func test_register_overwrites_existing():
	var h1 = StubHandler.new("dialogue")
	var h2 = StubHandler.new("dialogue")
	_registry.register(h1)
	_registry.register(h2)
	assert_eq(_registry.get_handler("dialogue"), h2)


func test_has_handler():
	var handler = StubHandler.new("bg")
	_registry.register(handler)
	assert_true(_registry.has_handler("bg"))
	assert_false(_registry.has_handler("missing"))
