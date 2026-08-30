## Title screen — game title with start/continue/settings/quit buttons.
## This is a standalone scene, NOT part of the game scene.
## Starting a game switches to the game scene via StellaRuntime.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons

var _confirmation_dialog: ConfirmationDialog
var _pending_confirmation_action: StringName = &""
var _pending_confirmation_context: Dictionary = {}


func _ready():
	_confirmation_dialog = ConfirmationDialog.new()
	_confirmation_dialog.title = "确认操作"
	_confirmation_dialog.confirmed.connect(_on_confirmation_confirmed)
	add_child(_confirmation_dialog)
	StellaRuntime.action_registry.confirmation_requested.connect(
		_on_confirmation_requested)
	_build_ui()


func _build_ui():
	var cfg = StellaRuntime.config
	title_label.text = cfg.game_title

	for child in buttons_container.get_children():
		child.queue_free()

	var buttons = [
		{"id": StellaActionRegistry.ACTION_START_GAME},
		{
			"id": StellaActionRegistry.ACTION_CONTINUE_GAME,
			"hide_when_unavailable": true,
		},
		{"id": StellaActionRegistry.ACTION_LOAD},
		{"id": StellaActionRegistry.ACTION_SETTINGS},
		{"id": StellaActionRegistry.ACTION_QUIT},
	]

	for btn_info in buttons:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(250, 50)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var binding := StellaAction.new()
		binding.action_id = btn_info["id"]
		binding.sync_label = true
		binding.hide_when_unavailable = bool(
			btn_info.get("hide_when_unavailable", false))
		btn.add_child(binding)
		buttons_container.add_child(btn)


func _on_confirmation_requested(
	action_id: StringName,
	_policy: StringName,
	context: Dictionary,
) -> void:
	if action_id != StellaActionRegistry.ACTION_QUIT:
		return
	var auto_confirm_marker: Variant = context.get(
		StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY, null)
	if typeof(auto_confirm_marker) == TYPE_BOOL and auto_confirm_marker == true:
		return
	_pending_confirmation_action = action_id
	_pending_confirmation_context = context.duplicate(true)
	_confirmation_dialog.dialog_text = "确认%s？" % StellaRuntime.get_action_label(
		action_id)
	_confirmation_dialog.popup_centered()


func _on_confirmation_confirmed() -> void:
	if _pending_confirmation_action.is_empty():
		return
	var action_id := _pending_confirmation_action
	var context := _pending_confirmation_context.duplicate(true)
	_pending_confirmation_action = &""
	_pending_confirmation_context.clear()
	context["confirmation_granted"] = true
	StellaRuntime.execute_action(action_id, context)
