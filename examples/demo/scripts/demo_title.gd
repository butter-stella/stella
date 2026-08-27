## Demo title screen — shows declarative buttons over the public action catalog.
## Copy and modify this for your own game.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons

var _confirmation_dialog: ConfirmationDialog
var _pending_confirmation_context: Dictionary = {}


func _ready():
	_confirmation_dialog = ConfirmationDialog.new()
	_confirmation_dialog.title = "确认操作"
	_confirmation_dialog.confirmed.connect(_on_quit_confirmed)
	add_child(_confirmation_dialog)
	StellaRuntime.action_registry.confirmation_requested.connect(
		_on_confirmation_requested)
	title_label.text = StellaRuntime.config.game_title

	_add_button(StellaActionRegistry.ACTION_START_GAME)
	_add_button(StellaActionRegistry.ACTION_CONTINUE_GAME, true)
	_add_button(StellaActionRegistry.ACTION_LOAD)
	_add_button(StellaActionRegistry.ACTION_SETTINGS)
	_add_button(StellaActionRegistry.ACTION_QUIT)


func _add_button(
	action_id: StringName,
	hide_when_unavailable: bool = false,
) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(250, 50)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var binding := StellaAction.new()
	binding.action_id = action_id
	binding.sync_label = true
	binding.hide_when_unavailable = hide_when_unavailable
	btn.add_child(binding)
	buttons_container.add_child(btn)


func _on_confirmation_requested(
	action_id: StringName,
	_policy: StringName,
	context: Dictionary,
) -> void:
	if (
		action_id != StellaActionRegistry.ACTION_QUIT
		or bool(context.get(
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY,
			false,
		))
	):
		return
	_pending_confirmation_context = context.duplicate(true)
	_confirmation_dialog.dialog_text = "确认%s？" % StellaRuntime.get_action_label(
		action_id)
	_confirmation_dialog.popup_centered()


func _on_quit_confirmed() -> void:
	if _pending_confirmation_context.is_empty():
		return
	var context := _pending_confirmation_context.duplicate(true)
	_pending_confirmation_context.clear()
	context["confirmation_granted"] = true
	StellaRuntime.execute_action(StellaActionRegistry.ACTION_QUIT, context)
