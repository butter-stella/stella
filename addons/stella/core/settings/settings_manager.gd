## Manages game settings — read, write, persist, notify.
class_name SettingsManager extends RefCounted

signal settings_changed(key: String, value: Variant)

const _TYPEWRITER_MILLISECOND_KEYS := [
	"character_interval",
	"punctuation_pause",
]
const _MOVIE_BOOL_KEYS := ["movie_right_click_skip", "movie_skip_on_skip"]

var settings: GameSettings = GameSettings.new()
var settings_path: String = "user://settings.json"


func set_value(key: String, value: Variant) -> void:
	if key in settings:
		if key == "effect_enabled" and typeof(value) != TYPE_BOOL:
			_warn_invalid_effect_enabled()
			return
		if key == "movie_volume" and not _movie_volume_is_valid(value):
			_warn_invalid_movie_setting(key)
			return
		if key in _MOVIE_BOOL_KEYS and typeof(value) != TYPE_BOOL:
			_warn_invalid_movie_setting(key)
			return
		var normalized_value := value
		if key in _TYPEWRITER_MILLISECOND_KEYS:
			normalized_value = _validated_typewriter_milliseconds(
				key, value, false)
		settings[key] = normalized_value
		_emit_current_value(key)


func save() -> void:
	var file = FileAccess.open(settings_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(settings.to_dict()))


func load_settings() -> void:
	if not FileAccess.file_exists(settings_path):
		return
	var file = FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		return
	var data = JSON.parse_string(file.get_as_text())
	if data is Dictionary:
		var normalized_data: Dictionary = data.duplicate(true)
		# `effect_enabled` is the policy fence for live presentation state. Do
		# not let the typed GameSettings property coerce persisted 0/1/string
		# values, and do not partially apply sibling keys when that fence is
		# invalid.
		if (
			"effect_enabled" in normalized_data
			and typeof(normalized_data["effect_enabled"]) != TYPE_BOOL
		):
			_warn_invalid_effect_enabled()
			return
		if (
			"movie_volume" in normalized_data
			and not _movie_volume_is_valid(normalized_data["movie_volume"])
		):
			_warn_invalid_movie_setting("movie_volume")
			return
		for key in _MOVIE_BOOL_KEYS:
			if key in normalized_data and typeof(normalized_data[key]) != TYPE_BOOL:
				_warn_invalid_movie_setting(key)
				return
		for key in _TYPEWRITER_MILLISECOND_KEYS:
			if key in normalized_data:
				normalized_data[key] = _validated_typewriter_milliseconds(
					key, normalized_data[key], true)

		var previous_values := settings.to_dict()
		# Ignore unknown future keys. Assign only present canonical fields so an
		# omitted mutable setting keeps both its value and its reference identity.
		# No notification is emitted until this complete candidate pass finishes.
		for key in previous_values:
			if key in normalized_data:
				settings[key] = normalized_data[key]

		# Every present field is now applied before the first notification, so
		# synchronous observers can never see a half-loaded settings combination.
		var applied_values := settings.to_dict()
		for key in applied_values:
			if previous_values[key] != applied_values[key]:
				_emit_current_value(key)


func reset_to_default() -> void:
	var previous_values := settings.to_dict()
	var default_values := GameSettings.new().to_dict()

	# Keep the long-lived data model stable for consumers that retain a direct
	# reference. Restore every field before notifying so observers never see a
	# half-reset combination of settings.
	for key in default_values:
		settings[key] = default_values[key]

	# GameSettings.to_dict() is the canonical public-field order. Emit only real
	# changes after the atomic restore, keeping reset side effects deterministic.
	# Read each value at emission time because signal listeners may synchronously
	# write settings again while this loop is running.
	for key in default_values:
		if previous_values[key] != default_values[key]:
			_emit_current_value(key)


func set_character_voice_volume(character_id: String, volume: float) -> void:
	settings.character_voice_volume[character_id] = volume
	_emit_current_value("character_voice_volume")


func get_character_voice_volume(character_id: String) -> float:
	return settings.character_voice_volume.get(character_id, 1.0)


func set_character_voice_enabled(character_id: String, enabled: bool) -> void:
	settings.character_voice_enabled[character_id] = enabled
	_emit_current_value("character_voice_enabled")


func is_character_voice_enabled(character_id: String) -> bool:
	return settings.character_voice_enabled.get(character_id, true)


func _emit_current_value(key: String) -> void:
	var value: Variant = settings[key]
	# Mutable settings use stable, complete snapshots. Consumers can treat every
	# payload as the current value instead of distinguishing patches from resets.
	if value is Dictionary:
		value = value.duplicate(true)
	settings_changed.emit(key, value)


func _warn_invalid_effect_enabled() -> void:
	push_warning(
		"SettingsManager: effect_enabled must be a bool; keeping current settings"
	)


func _movie_volume_is_valid(value: Variant) -> bool:
	return (
		(value is int or value is float)
		and is_finite(float(value))
		and float(value) >= 0.0
		and float(value) <= 1.0
	)


func _warn_invalid_movie_setting(key: String) -> void:
	push_warning(
		"SettingsManager: %s has an invalid type or range; keeping current settings"
		% key)


func _validated_typewriter_milliseconds(
	key: String,
	value: Variant,
	allow_serialized_integral_float: bool,
) -> int:
	var valid := typeof(value) == TYPE_INT and int(value) >= 0
	if allow_serialized_integral_float and typeof(value) == TYPE_FLOAT:
		var number := float(value)
		valid = (
			is_finite(number)
			and number >= 0.0
			and number == floor(number)
		)
	if valid:
		return int(value)

	var defaults := GameSettings.new()
	var fallback_ms: int = (
		defaults.character_interval
		if key == "character_interval"
		else defaults.punctuation_pause
	)
	push_warning((
		"SettingsManager: %s must be a non-negative integer in "
		+ "milliseconds; using GameSettings default %d ms"
	) % [key, fallback_ms])
	return fallback_ms
