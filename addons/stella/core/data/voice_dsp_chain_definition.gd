## Ordered, validated Resource selected by one dialogue voice segment.
class_name VoiceDspChainDefinition extends Resource

const MAX_EFFECTS := 16
const MAX_TAIL_SECONDS := 60.0
const MIN_FILTER_HZ := 1.0
const MAX_FILTER_HZ := 20500.0
## AudioEffectDelay exposes a -60 dB floor. Values below this cannot be
## represented faithfully, so they fail closed instead of being clamped.
const MIN_NONZERO_LINEAR_GAIN := 0.001

@export var effects: Array[VoiceDspEffectDefinition] = []
@export_range(0.0, MAX_TAIL_SECONDS, 0.001) var tail_seconds: float = 0.0


static func is_logical_preset_id(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() or value.length() > 256:
		return false
	if (
		value.begins_with("/")
		or value.ends_with("/")
		or "//" in value
		or "\\" in value
	):
		return false
	if value.begins_with("res://") or value.begins_with("user://"):
		return false
	for part_value in value.split("/", false):
		var part := String(part_value)
		if part.is_empty() or part in [".", ".."]:
			return false
		for index in range(part.length()):
			var code := part.unicode_at(index)
			if not (
				(code >= 48 and code <= 57)
				or (code >= 65 and code <= 90)
				or (code >= 97 and code <= 122)
				or code in [45, 95]
			):
				return false
	return true


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not is_finite(tail_seconds) or tail_seconds < 0.0 \
		or tail_seconds > MAX_TAIL_SECONDS:
		errors.append("tail_seconds must be finite and in 0..60 seconds")
	if effects.is_empty():
		errors.append("effects must contain at least one supported primitive")
	elif effects.size() > MAX_EFFECTS:
		errors.append("effects exceeds the 16-effect limit")
	for index in range(effects.size()):
		var effect := effects[index]
		if effect == null:
			errors.append("effects[%d] is null" % index)
		elif effect is VoiceDspBandPassEffect:
			errors.append_array(_band_pass_errors(
				effect as VoiceDspBandPassEffect, index))
		elif effect is VoiceDspDelayEffect:
			errors.append_array(_delay_errors(
				effect as VoiceDspDelayEffect, index))
		else:
			errors.append(
				"effects[%d] uses an unsupported primitive type '%s'"
				% [index, effect.get_class()])
	return errors


func _band_pass_errors(
	effect: VoiceDspBandPassEffect,
	index: int,
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not is_finite(effect.center_hz) or not is_finite(effect.bandwidth_hz):
		errors.append("effects[%d] band_pass frequencies must be finite" % index)
		return errors
	var lower := effect.center_hz - effect.bandwidth_hz * 0.5
	var upper := effect.center_hz + effect.bandwidth_hz * 0.5
	if (
		effect.bandwidth_hz <= 0.0
		or lower < MIN_FILTER_HZ
		or upper > MAX_FILTER_HZ
	):
		errors.append(
			"effects[%d] band_pass edges must remain in 1..20500 Hz"
			% index)
	if effect.order < 1 or effect.order > 4:
		errors.append("effects[%d] band_pass order must be in 1..4" % index)
	return errors


func _delay_errors(
	effect: VoiceDspDelayEffect,
	index: int,
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not is_finite(effect.time_ms) or effect.time_ms < 0.0 \
		or effect.time_ms > 1500.0:
		errors.append("effects[%d] delay time_ms must be finite and in 0..1500" % index)
	for field_name in ["feedback", "mix"]:
		var value := float(effect.get(field_name))
		if not is_finite(value) or value < 0.0 or value > 1.0:
			errors.append(
				"effects[%d] delay %s must be finite and in 0..1"
				% [index, field_name])
		elif value > 0.0 and value < MIN_NONZERO_LINEAR_GAIN:
			errors.append(
				"effects[%d] delay %s must be 0 or at least 0.001 (-60 dB)"
				% [index, field_name])
	return errors
