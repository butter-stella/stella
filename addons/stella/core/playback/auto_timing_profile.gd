## Declarative Auto-play delay policy bound to Stella's canonical settings model.
##
## The profile is data-only. DialoguePresenter snapshots one validated profile
## for an accepted dialogue and evaluates it when that line creates its normal
## Auto timer tail. It never creates a timer, callback, or playback owner.
class_name AutoTimingProfile
extends Resource

const MAX_DELAY_SECONDS := 3600.0

## Registered numeric setting read when the next Auto tail is created.
@export var setting_key: String = ""
## delay = base + setting * setting_scale + visible_chars * character_scale
##       + (voiced ? voiced_line_addition : 0), clamped to min/max.
@export var base_delay_seconds: float = 0.0
@export var setting_scale_seconds: float = 1.0
@export var visible_character_scale_seconds: float = 0.0
@export var voiced_line_addition_seconds: float = 0.0
@export var minimum_delay_seconds: float = 0.0
@export var maximum_delay_seconds: float = MAX_DELAY_SECONDS


## Validate the authored formula and its live SettingsManager binding without
## reading or mutating a setting value.
func validation_errors(settings_manager: SettingsManager) -> PackedStringArray:
	var errors := PackedStringArray()
	if settings_manager == null:
		errors.append("settings manager is unavailable")
		return errors
	if setting_key.is_empty() or setting_key != setting_key.strip_edges():
		errors.append("setting_key must be a non-empty canonical setting key")
	elif not settings_manager.has_setting(setting_key):
		errors.append("setting_key '%s' is not registered" % setting_key)
	else:
		var definition := settings_manager.get_definition(setting_key)
		if String(definition.get("type", "")) not in ["integer", "number"]:
			errors.append("setting_key '%s' must reference an integer or number" % setting_key)

	for field in [
		["base_delay_seconds", base_delay_seconds],
		["setting_scale_seconds", setting_scale_seconds],
		["visible_character_scale_seconds", visible_character_scale_seconds],
		["voiced_line_addition_seconds", voiced_line_addition_seconds],
		["minimum_delay_seconds", minimum_delay_seconds],
		["maximum_delay_seconds", maximum_delay_seconds],
	]:
		if not is_finite(float(field[1])):
			errors.append("%s must be finite" % String(field[0]))
	if is_finite(minimum_delay_seconds) and minimum_delay_seconds < 0.0:
		errors.append("minimum_delay_seconds cannot be negative")
	if is_finite(maximum_delay_seconds) and maximum_delay_seconds > MAX_DELAY_SECONDS:
		errors.append(
			"maximum_delay_seconds cannot exceed %.0f" % MAX_DELAY_SECONDS)
	if (
		is_finite(minimum_delay_seconds)
		and is_finite(maximum_delay_seconds)
		and maximum_delay_seconds < minimum_delay_seconds
	):
		errors.append(
			"maximum_delay_seconds cannot be less than minimum_delay_seconds")
	return errors


## Resolve one deterministic delay from canonical dialogue metadata. The
## caller owns timer/cancellation semantics; this method performs no waits.
func resolve_delay(
	settings_manager: SettingsManager,
	visible_character_count: int,
	has_voice: bool,
) -> Dictionary:
	var errors := validation_errors(settings_manager)
	if visible_character_count < 0:
		errors.append("visible_character_count cannot be negative")
	if not errors.is_empty():
		return {"ok": false, "delay": 0.0, "error": "; ".join(errors)}

	var setting_value_raw: Variant = settings_manager.get_value(setting_key)
	if typeof(setting_value_raw) not in [TYPE_INT, TYPE_FLOAT]:
		return {
			"ok": false,
			"delay": 0.0,
			"error": "setting_key '%s' no longer contains a number" % setting_key,
		}
	var setting_value := float(setting_value_raw)
	if not is_finite(setting_value):
		return {
			"ok": false,
			"delay": 0.0,
			"error": "setting_key '%s' no longer contains a finite number" % setting_key,
		}
	var delay := (
		base_delay_seconds
		+ setting_value * setting_scale_seconds
		+ float(visible_character_count) * visible_character_scale_seconds
		+ (voiced_line_addition_seconds if has_voice else 0.0)
	)
	if not is_finite(delay):
		return {
			"ok": false,
			"delay": 0.0,
			"error": "the authored Auto timing formula produced a non-finite delay",
		}
	return {
		"ok": true,
		"delay": clampf(delay, minimum_delay_seconds, maximum_delay_seconds),
		"error": "",
	}
