## Default choice presenter — text buttons in a vertical list.
## Subscribes to SignalBus.choice_show, emits choice_selected.
extends PanelContainer

@onready var prompt_label: Label = %PromptLabel
@onready var options_container: VBoxContainer = %OptionsContainer


func _ready():
	SignalBus.choice_show.connect(_on_choice_show)
	visible = false


func _on_choice_show(prompt: String, options: Array):
	visible = true

	# Set prompt
	if prompt != "":
		prompt_label.text = prompt
		prompt_label.visible = true
	else:
		prompt_label.visible = false

	# Clear old buttons
	for child in options_container.get_children():
		child.queue_free()

	# Create buttons
	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("label", "???")
		btn.custom_minimum_size = Vector2(400, 50)
		var opt_id = opt.get("id", opt.get("label", ""))
		btn.pressed.connect(func(): _on_option_selected(opt_id))
		options_container.add_child(btn)


func _on_option_selected(option_id: String):
	visible = false
	# Clear buttons
	for child in options_container.get_children():
		child.queue_free()
	SignalBus.choice_selected.emit(option_id)
