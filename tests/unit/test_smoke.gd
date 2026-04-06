extends GutTest
## Smoke test to verify GUT framework is working.


func test_gut_works():
	assert_true(true, "GUT framework is functional")


func test_signal_bus_exists():
	var bus = load("res://addons/stella/autoload/signal_bus.gd")
	assert_not_null(bus, "SignalBus script should be loadable")
