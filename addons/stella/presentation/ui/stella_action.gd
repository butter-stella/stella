## Declarative action binding — attach as a child of any BaseButton.
##
## `action_id` is the canonical authoring surface. The legacy enum remains a
## one-to-one adapter for existing Inspector-authored scenes; both paths always
## dispatch through StellaRuntime.action_registry.
class_name StellaAction
extends Node

enum Action {
	NONE,
	START_GAME,
	CONTINUE_GAME,
	RETURN_TO_TITLE,
	QUICK_SAVE,
	QUICK_LOAD,
	SHOW_SAVE,
	SHOW_LOAD,
	SHOW_SETTINGS,
	SHOW_BACKLOG,
	TOGGLE_AUTO_PLAY,
	TOGGLE_SKIP,
	QUIT,
}

const _LEGACY_ACTION_IDS := {
	Action.START_GAME: StellaActionRegistry.ACTION_START_GAME,
	Action.CONTINUE_GAME: StellaActionRegistry.ACTION_CONTINUE_GAME,
	Action.RETURN_TO_TITLE: StellaActionRegistry.ACTION_RETURN_TO_TITLE,
	Action.QUICK_SAVE: StellaActionRegistry.ACTION_QUICK_SAVE,
	Action.QUICK_LOAD: StellaActionRegistry.ACTION_QUICK_LOAD,
	Action.SHOW_SAVE: StellaActionRegistry.ACTION_SAVE,
	Action.SHOW_LOAD: StellaActionRegistry.ACTION_LOAD,
	Action.SHOW_SETTINGS: StellaActionRegistry.ACTION_SETTINGS,
	Action.SHOW_BACKLOG: StellaActionRegistry.ACTION_BACKLOG,
	Action.TOGGLE_AUTO_PLAY: StellaActionRegistry.ACTION_AUTO,
	Action.TOGGLE_SKIP: StellaActionRegistry.ACTION_SKIP,
	Action.QUIT: StellaActionRegistry.ACTION_QUIT,
}

## Stable built-in or project action ID (for example `voice_replay` or
## `my_game.open_codex`). This takes precedence over the legacy enum when set.
@export var action_id: StringName = &"":
	set(value):
		action_id = value
		_refresh_button_state()

## Compatibility-only Inspector field. New scenes should author `action_id`.
@export var action: Action = Action.NONE:
	set(value):
		action = value
		_refresh_button_state()

## Keep the authored Button label by default. Enable this for catalog-driven
## menus whose text should follow label_key/localization automatically.
@export var sync_label: bool = false
@export var sync_availability: bool = true
@export var hide_when_unavailable: bool = false
@export var sync_active_state: bool = true

var _button: BaseButton
var _authored_button_text: String = ""


func _ready() -> void:
	var parent := get_parent()
	if not parent is BaseButton:
		push_warning(
			"StellaAction: parent is not a BaseButton — action won't trigger")
		return
	_button = parent as BaseButton
	_authored_button_text = _button.text
	_button.pressed.connect(_on_pressed)
	if StellaRuntime.action_registry != null:
		StellaRuntime.action_registry.catalog_changed.connect(
			_on_catalog_changed)
		StellaRuntime.action_registry.action_state_changed.connect(
			_on_action_state_changed)
	_refresh_button_state()


func _exit_tree() -> void:
	if StellaRuntime == null or StellaRuntime.action_registry == null:
		return
	if StellaRuntime.action_registry.catalog_changed.is_connected(
		_on_catalog_changed):
		StellaRuntime.action_registry.catalog_changed.disconnect(
			_on_catalog_changed)
	if StellaRuntime.action_registry.action_state_changed.is_connected(
		_on_action_state_changed):
		StellaRuntime.action_registry.action_state_changed.disconnect(
			_on_action_state_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_refresh_button_state()


func get_action_id() -> StringName:
	if not action_id.is_empty():
		return action_id
	return StringName(_LEGACY_ACTION_IDS.get(action, &""))


func _on_pressed() -> void:
	var resolved_id := get_action_id()
	if resolved_id.is_empty():
		push_warning("StellaAction: no action selected")
		return
	if StellaRuntime.action_registry == null:
		push_warning("StellaAction: action registry is unavailable")
		return
	# Legacy enum scenes historically executed disruptive actions immediately.
	# Preserve that exact adapter behavior without a permanent policy bypass: a
	# temporary listener consumes only this dispatch's single-use receipt, then
	# both paths still execute through the canonical registry.
	if action_id.is_empty() and action != Action.NONE:
		var confirmation_callback := (
			_on_legacy_confirmation_requested.bind(resolved_id))
		StellaRuntime.action_registry.confirmation_requested.connect(
			confirmation_callback)
		StellaRuntime.execute_action(resolved_id, {
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY: true,
		})
		if StellaRuntime.action_registry.confirmation_requested.is_connected(
			confirmation_callback
		):
			StellaRuntime.action_registry.confirmation_requested.disconnect(
				confirmation_callback)
		return
	StellaRuntime.execute_action(resolved_id)


func _on_legacy_confirmation_requested(
	requested_id: StringName,
	_policy: StringName,
	context: Dictionary,
	expected_id: StringName,
) -> void:
	if requested_id != expected_id:
		return
	var confirmed_context := context.duplicate(true)
	confirmed_context["confirmation_granted"] = true
	StellaRuntime.execute_action(requested_id, confirmed_context)


func _on_catalog_changed() -> void:
	_refresh_button_state()


func _on_action_state_changed(changed_id: StringName) -> void:
	if changed_id == get_action_id():
		_refresh_button_state()


func _refresh_button_state() -> void:
	if _button == null or not is_instance_valid(_button):
		return
	var resolved_id := get_action_id()
	var metadata := StellaRuntime.get_action(resolved_id)
	var available := (
		not resolved_id.is_empty()
		and not metadata.is_empty()
		and StellaRuntime.can_execute_action(resolved_id)
	)
	if sync_availability:
		_button.disabled = not available
	if hide_when_unavailable:
		_button.visible = available
	if sync_label:
		_button.text = (
			StellaRuntime.get_action_label(resolved_id)
			if not metadata.is_empty()
			else _authored_button_text
		)
	if sync_active_state:
		var is_toggle := bool(metadata.get("toggle", false))
		_button.toggle_mode = is_toggle
		_button.set_pressed_no_signal(
			StellaRuntime.is_action_active(resolved_id) if is_toggle else false)
