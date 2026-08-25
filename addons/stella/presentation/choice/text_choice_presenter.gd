## Default choice presenter — text buttons in a vertical list.
## Subscribes to SignalBus.choice_show, emits choice_selected.
extends PanelContainer

@onready var prompt_label: Label = %PromptLabel
@onready var options_container: VBoxContainer = %OptionsContainer

var _choice_generation: int = 0
var _active_choice_generation: int = -1


func _ready():
	SignalBus.choice_show.connect(_on_choice_show)
	SignalBus.choice_hide.connect(_on_choice_hide)
	visible = false


func _on_choice_show(prompt: String, options: Array):
	if not StellaRuntime.is_choice_presentation_dispatch_current():
		return
	_choice_generation += 1
	_active_choice_generation = _choice_generation
	var generation := _active_choice_generation
	visible = true

	# Set prompt
	if prompt != "":
		prompt_label.text = prompt
		prompt_label.visible = true
	else:
		prompt_label.visible = false

	# Clear old buttons
	for child in options_container.get_children():
		options_container.remove_child(child)
		child.queue_free()

	# Create buttons
	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("label", "???")
		btn.custom_minimum_size = Vector2(400, 50)
		var opt_id = opt.get("id", opt.get("label", ""))
		btn.pressed.connect(
			_on_option_selected.bind(opt_id, generation, btn))
		options_container.add_child(btn)


func _on_option_selected(
	option_id: String,
	generation: int,
	button: Button,
):
	if (
		generation != _active_choice_generation
		or not visible
		or not is_instance_valid(button)
		or button.disabled
		or not button.is_visible_in_tree()
	):
		return
	# The semantic selection may synchronously resolve the choice and expose the
	# next blocker while this physical GUI event is still dispatching. Consume it
	# first so its tail cannot advance the successor command.
	get_viewport().set_input_as_handled()
	_hide()
	SignalBus.choice_selected.emit(option_id)


## InputHandler reaches this only when Godot GUI did not consume ui_accept on a
## focused option itself (notably Joy A on the default input map). Toolbar and
## unrelated Buttons have no presenter ancestor exposing this method.
func activate_focused_choice_option() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	if not focused is Button:
		return false
	var button := focused as Button
	if (
		_active_choice_generation < 0
		or not visible
		or button.get_parent() != options_container
		or button.disabled
		or not button.is_visible_in_tree()
	):
		return false
	button.pressed.emit()
	return true


## A stale hard-boundary HIDE may have listeners that synchronously publish a
## replacement choice before this presenter sees the old signal. Runtime policy
## ownership distinguishes that fresh generation without changing the public
## choice presentation payload.
func _on_choice_hide() -> void:
	if StellaRuntime.is_choice_active():
		return
	_hide()


func _hide() -> void:
	_choice_generation += 1
	_active_choice_generation = -1
	visible = false
	# Clear buttons
	for child in options_container.get_children():
		options_container.remove_child(child)
		child.queue_free()
