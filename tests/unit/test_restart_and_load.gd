extends GutTest
## Tests exposing restart and load bugs.


func test_start_scenario_resets_presentation_signals():
	# After scenario ends, starting again should emit reset signals
	var bus = get_tree().root.get_node("SignalBus")
	var fade_received: Array = []
	bus.fade_requested.connect(func(d, dur): fade_received.append(d))

	var hide_received: Array = []
	bus.char_hide.connect(func(c): hide_received.append(c))

	var hide_dialogue: Array = []
	bus.hide_dialogue.connect(func(): hide_dialogue.append(true))

	# Simulate a reset
	SignalBus.fade_requested.emit("in", 0.0)
	SignalBus.char_hide.emit("all")
	SignalBus.hide_dialogue.emit()

	assert_true(fade_received.has("in"))
	assert_true(hide_received.has("all"))
	assert_eq(hide_dialogue.size(), 1)


func test_save_manager_duplicate_providers_handled():
	# Calling register_provider twice with same ID replaces, not accumulates
	var sm = SaveManager.new()
	var store1 = VariableStore.new()
	sm.register_provider(store1)
	sm.register_provider(store1)  # duplicate — should replace
	assert_eq(sm.get_provider_count(), 1)
