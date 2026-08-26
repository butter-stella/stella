## Typed synchronous request from DialoguePresenter to AudioPresenter.
## One request owns one authored, ordered group of independently rendered voice
## layers. AudioPresenter resolves it exactly once through SignalBus. The
## request has no mutable response fields; callers receive a separate
## VoicePlaybackResponse.
class_name VoicePlaybackRequest extends RefCounted

const MAX_LAYERS := 8
const MAX_LOGICAL_ID_LENGTH := 256
const MAX_LAYER_ID_LENGTH := 64

var _layers: Array = []
var _validation_error: String = ""
var _owner_validator: Callable
var _has_owner_validator: bool = false


func _init(
	p_asset: String = "",
	p_character: String = "",
	p_owner_validator: Callable = Callable(),
	p_dsp_preset: String = "",
	p_source: Dictionary = {},
) -> void:
	var canonical := canonicalize_layers([{
		"id": "main",
		"asset": p_asset,
		"character": p_character,
		"dsp": p_dsp_preset,
		"source": p_source,
	}])
	_layers = canonical.get("layers", [])
	_validation_error = String(canonical.get("error", ""))
	_owner_validator = p_owner_validator
	_has_owner_validator = not p_owner_validator.is_null()


static func from_layers(
	p_layers: Variant,
	p_owner_validator: Callable = Callable(),
) -> VoicePlaybackRequest:
	var request := VoicePlaybackRequest.new()
	var canonical := canonicalize_layers(p_layers)
	request._layers = canonical.get("layers", [])
	request._validation_error = String(canonical.get("error", ""))
	request._owner_validator = p_owner_validator
	request._has_owner_validator = not p_owner_validator.is_null()
	return request


static func canonicalize_layers(value: Variant) -> Dictionary:
	if not value is Array:
		return {"layers": [], "error": "voice layers must be an Array"}
	var raw_layers: Array = value
	if raw_layers.is_empty():
		return {"layers": [], "error": "voice layers cannot be empty"}
	if raw_layers.size() > MAX_LAYERS:
		return {
			"layers": [],
			"error": "voice layer count exceeds the bounded limit of %d" % MAX_LAYERS,
		}
	var canonical_layers: Array = []
	var seen_ids: Dictionary = {}
	for index in range(raw_layers.size()):
		var layer_value: Variant = raw_layers[index]
		if not layer_value is Dictionary:
			return {
				"layers": [],
				"error": "voice layer %d must be a Dictionary" % index,
			}
		var layer: Dictionary = layer_value
		var expected_keys := ["id", "asset", "character", "dsp", "source"]
		for key_value: Variant in layer.keys():
			var key := String(key_value)
			if not key in expected_keys:
				return {
					"layers": [],
					"error": "voice layer %d has unknown field '%s'" % [index, key],
				}
		for required_key in ["id", "asset", "character", "dsp", "source"]:
			if not layer.has(required_key):
				return {
					"layers": [],
					"error": "voice layer %d is missing '%s'" % [index, required_key],
				}
		if (
			not layer["id"] is String
			or not layer["asset"] is String
			or not layer["character"] is String
			or not layer["dsp"] is String
			or not layer["source"] is Dictionary
		):
			return {
				"layers": [],
				"error": "voice layer %d has invalid field types" % index,
			}
		var layer_id := String(layer["id"])
		var asset := String(layer["asset"])
		var character := String(layer["character"])
		var dsp := String(layer["dsp"])
		var source: Dictionary = layer["source"]
		if not is_layer_id(layer_id):
			return {
				"layers": [],
				"error": "voice layer %d id is not a bounded canonical id" % index,
			}
		if seen_ids.has(layer_id):
			return {
				"layers": [],
				"error": "duplicate voice layer id '%s'" % layer_id,
			}
		if not is_logical_asset_id(asset):
			return {
				"layers": [],
				"error": "voice layer '%s' asset is not a Stella logical id" % layer_id,
			}
		if (
			character != character.strip_edges()
			or character.length() > MAX_LOGICAL_ID_LENGTH
		):
			return {
				"layers": [],
				"error": "voice layer '%s' character is not a bounded canonical id" % layer_id,
			}
		if not dsp.is_empty() and not VoiceDspChainDefinition.is_logical_preset_id(dsp):
			return {
				"layers": [],
				"error": "voice layer '%s' DSP preset is not a Stella logical id" % layer_id,
			}
		var line_value: Variant = source.get("line", 0)
		if not line_value is int or int(line_value) < 0:
			return {
				"layers": [],
				"error": "voice layer '%s' source line must be a nonnegative int" % layer_id,
			}
		seen_ids[layer_id] = true
		canonical_layers.append({
			"id": layer_id,
			"asset": asset,
			"character": character,
			"dsp": dsp,
			"source": source.duplicate(true),
		})
	return {"layers": canonical_layers, "error": ""}


static func is_layer_id(value: String) -> bool:
	if value.is_empty() or value.length() > MAX_LAYER_ID_LENGTH:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var valid := (
			(code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code == 95
			or (index > 0 and ((code >= 48 and code <= 57) or code == 45))
		)
		if not valid:
			return false
	return true


static func is_logical_asset_id(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() \
		or value.length() > MAX_LOGICAL_ID_LENGTH:
		return false
	if (
		value.begins_with("/")
		or value.ends_with("/")
		or "//" in value
		or "\\" in value
		or value.begins_with("res://")
		or value.begins_with("user://")
	):
		return false
	for part_value: Variant in value.split("/", false):
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


func get_asset() -> String:
	return String(_layers[0].get("asset", "")) if not _layers.is_empty() else ""


func get_character() -> String:
	return String(_layers[0].get("character", "")) if not _layers.is_empty() else ""


func get_dsp_preset() -> String:
	return String(_layers[0].get("dsp", "")) if not _layers.is_empty() else ""


func get_source() -> Dictionary:
	return (
		(_layers[0].get("source", {}) as Dictionary).duplicate(true)
		if not _layers.is_empty()
		else {}
	)


func get_layers() -> Array:
	return _layers.duplicate(true)


func get_validation_error() -> String:
	return _validation_error


func is_valid() -> bool:
	return _validation_error.is_empty()


func has_owner_validator() -> bool:
	return _has_owner_validator


func is_current() -> bool:
	if not is_valid():
		return false
	if not _has_owner_validator:
		return true
	return _owner_validator.is_valid() and bool(_owner_validator.call())
