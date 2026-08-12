## Runtime representation of one STLA dialogue presentation profile.
##
## DialogueProfileParser normally constructs this from .stla data. Exported
## fields remain available only for the advanced scene-side fallback.
## Every section is opt-in. Unset sections retain the authored scene state.
class_name DialogueModeProfile
extends Resource

const ADVANCE_INDICATOR_ANIMATIONS := ["none", "pulse", "bob"]

@export_group("Panel")
@export var override_panel_rect: bool = false
## left, top, right, bottom anchor values in the inclusive 0..1 range.
@export var panel_anchors: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
## left, top, right, bottom pixel offsets.
@export var panel_offsets: Vector4 = Vector4.ZERO
@export var override_panel_modulate: bool = false
@export var panel_modulate: Color = Color.WHITE

@export_group("Text Rectangle")
@export var override_text_rect: bool = false
## Applied to DialoguePresenter.text_rect_target_path, or TextLabel when empty.
@export var text_anchors: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
@export var text_offsets: Vector4 = Vector4.ZERO
## Positive left, top, right, bottom inset inside the configured text rectangle.
@export var text_margins: Vector4 = Vector4.ZERO

@export_group("Text Style")
@export var override_text_alignment: bool = false
@export_enum("Left:0", "Center:1", "Right:2", "Fill:3") var horizontal_alignment: int = HORIZONTAL_ALIGNMENT_LEFT
@export_enum("Top:0", "Center:1", "Bottom:2", "Fill:3") var vertical_alignment: int = VERTICAL_ALIGNMENT_TOP
@export var override_line_spacing: bool = false
@export var line_spacing: int = 0

@export_group("Text Overflow")
@export var override_text_overflow: bool = false
@export var fit_content: bool = true
@export var scroll_active: bool = true
@export var scroll_following: bool = false
@export_enum("Off:0", "Arbitrary:1", "Word:2", "Word Smart:3") var autowrap_mode: int = TextServer.AUTOWRAP_WORD_SMART
@export var clip_contents: bool = true

@export_group("Advance Indicator")
## Static marker source. Ignored when advance_indicator_scene is configured.
@export var advance_indicator_texture: Texture2D
## Custom marker source. Takes precedence over advance_indicator_texture.
@export var advance_indicator_scene: PackedScene
## Pixel offset from the final rendered text endpoint.
@export var advance_indicator_offset: Vector2 = Vector2.ZERO
## Engine-owned wrapper animation applied while the dialogue is ready to advance.
@export_enum("none", "pulse", "bob") var advance_indicator_animation: String = "none"

@export_group("NVL Entry Formatting")
## Prepended to every accumulated NVL dialogue record.
@export var override_entry_prefix: bool = false
@export_multiline var entry_prefix: String = ""
## Inserted between accumulated NVL dialogue records.
@export var override_entry_separator: bool = false
@export_multiline var entry_separator: String = "\n"

@export_group("Background")
@export var override_background_visibility: bool = false
@export var background_visible: bool = true
@export var override_background_modulate: bool = false
@export var background_modulate: Color = Color.WHITE

@export_group("Auxiliary UI")
## Maps Godot group names to their desired visibility in this mode.
## Only CanvasItem descendants of DialoguePanel are affected.
@export var visibility_groups: Dictionary = {}

## Exact property names supplied by STLA. Resource-authored fallback profiles
## leave this empty and continue to use their section-level override toggles.
var _stla_fields: Dictionary = {}
## STLA keeps portable paths in CommandData. Resolve them only in Presentation;
## Resource-authored fallback profiles instead use the typed exported fields.
var _stla_advance_indicator_texture_path: String = ""
var _stla_advance_indicator_scene_path: String = ""
## Runtime-only authoring provenance copied from SignalBus's synchronous
## presentation sidecar. It is never written to dialogue text or persistence.
var _stla_provenance: Dictionary = {}


## Build a runtime profile from validated STLA declaration data.
static func from_dictionary(
	data: Dictionary,
	provenance: Dictionary = {},
) -> DialogueModeProfile:
	var profile := DialogueModeProfile.new()
	profile._stla_provenance = provenance.duplicate(true)
	for field_name in data:
		profile._stla_fields[StringName(field_name)] = true
	if data.has("panel_anchors") or data.has("panel_offsets"):
		profile.override_panel_rect = true
		profile.panel_anchors = data.get("panel_anchors", profile.panel_anchors)
		profile.panel_offsets = data.get("panel_offsets", profile.panel_offsets)
	if data.has("panel_modulate"):
		profile.override_panel_modulate = true
		profile.panel_modulate = data["panel_modulate"]
	if (data.has("text_anchors") or data.has("text_offsets")
		or data.has("text_margins")):
		profile.override_text_rect = true
		profile.text_anchors = data.get("text_anchors", profile.text_anchors)
		profile.text_offsets = data.get("text_offsets", profile.text_offsets)
		profile.text_margins = data.get("text_margins", profile.text_margins)
	if data.has("horizontal_alignment") or data.has("vertical_alignment"):
		profile.override_text_alignment = true
		profile.horizontal_alignment = data.get(
			"horizontal_alignment", profile.horizontal_alignment)
		profile.vertical_alignment = data.get(
			"vertical_alignment", profile.vertical_alignment)
	if data.has("line_spacing"):
		profile.override_line_spacing = true
		profile.line_spacing = data["line_spacing"]
	if (data.has("fit_content") or data.has("scroll_active")
		or data.has("scroll_following") or data.has("autowrap_mode")
		or data.has("clip_contents")):
		profile.override_text_overflow = true
		profile.fit_content = data.get("fit_content", profile.fit_content)
		profile.scroll_active = data.get("scroll_active", profile.scroll_active)
		profile.scroll_following = data.get(
			"scroll_following", profile.scroll_following)
		profile.autowrap_mode = data.get("autowrap_mode", profile.autowrap_mode)
		profile.clip_contents = data.get("clip_contents", profile.clip_contents)
	if data.has("advance_indicator_texture"):
		profile._stla_advance_indicator_texture_path = String(
			data["advance_indicator_texture"])
	if data.has("advance_indicator_scene"):
		profile._stla_advance_indicator_scene_path = String(
			data["advance_indicator_scene"])
	if data.has("advance_indicator_offset"):
		profile.advance_indicator_offset = data["advance_indicator_offset"]
	if data.has("advance_indicator_animation"):
		profile.advance_indicator_animation = data["advance_indicator_animation"]
	if data.has("entry_prefix"):
		profile.override_entry_prefix = true
		profile.entry_prefix = data["entry_prefix"]
	if data.has("entry_separator"):
		profile.override_entry_separator = true
		profile.entry_separator = data["entry_separator"]
	if data.has("background_visible"):
		profile.override_background_visibility = true
		profile.background_visible = data["background_visible"]
	if data.has("background_modulate"):
		profile.override_background_modulate = true
		profile.background_modulate = data["background_modulate"]
	profile.visibility_groups = data.get("visibility_groups", {}).duplicate(true)
	return profile


## STLA properties are independently opt-in: writing text_margins must not
## silently reset authored anchors, alignment, or overflow values. Advanced
## Resource profiles retain the original section-level override semantics.
func overrides_property(property_name: StringName) -> bool:
	if not _stla_fields.is_empty():
		return _stla_fields.has(property_name)
	match property_name:
		&"panel_anchors", &"panel_offsets":
			return override_panel_rect
		&"panel_modulate":
			return override_panel_modulate
		&"text_anchors", &"text_offsets", &"text_margins":
			return override_text_rect
		&"horizontal_alignment", &"vertical_alignment":
			return override_text_alignment
		&"line_spacing":
			return override_line_spacing
		&"fit_content", &"scroll_active", &"scroll_following", \
		&"autowrap_mode", &"clip_contents":
			return override_text_overflow
		&"advance_indicator_texture":
			return advance_indicator_texture != null
		&"advance_indicator_scene":
			return advance_indicator_scene != null
		&"advance_indicator_offset", &"advance_indicator_animation":
			return has_advance_indicator()
		&"entry_prefix":
			return override_entry_prefix
		&"entry_separator":
			return override_entry_separator
		&"background_visible":
			return override_background_visibility
		&"background_modulate":
			return override_background_modulate
	return false


## Whether this mode has either a declarative STLA source or a typed Resource
## fallback source. A missing/unloadable path still returns true here so the
## caller can surface advance_indicator_validation_errors() instead of silently
## treating a broken configuration as absent.
func has_advance_indicator() -> bool:
	return _has_advance_indicator_scene_source() \
		or _has_advance_indicator_texture_source()


## Resolve the custom scene source. Scene always has priority over texture.
func resolve_advance_indicator_scene() -> PackedScene:
	if not _stla_advance_indicator_scene_path.is_empty():
		if not ResourceLoader.exists(_stla_advance_indicator_scene_path):
			return null
		return ResourceLoader.load(
			_stla_advance_indicator_scene_path) as PackedScene
	return advance_indicator_scene


## Resolve the texture source only when no scene source is configured.
func resolve_advance_indicator_texture() -> Texture2D:
	if _has_advance_indicator_scene_source():
		return null
	if not _stla_advance_indicator_texture_path.is_empty():
		if not ResourceLoader.exists(_stla_advance_indicator_texture_path):
			return null
		return ResourceLoader.load(
			_stla_advance_indicator_texture_path) as Texture2D
	return advance_indicator_texture


## Indicator failures are local presentation failures. DialoguePresenter uses
## these diagnostics to hide only the indicator; they intentionally do not flow
## through validation_errors(), whose errors trigger whole-profile layout
## fallback for legacy Resource profiles.
func advance_indicator_validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not advance_indicator_offset.is_finite():
		errors.append("advance_indicator_offset must contain only finite values")
	if advance_indicator_animation not in ADVANCE_INDICATOR_ANIMATIONS:
		errors.append(
			"advance_indicator_animation has unsupported value '%s'"
			% advance_indicator_animation)
	_validate_stla_advance_indicator_resource(
		_stla_advance_indicator_texture_path, false, "advance_indicator_texture", errors)
	_validate_stla_advance_indicator_resource(
		_stla_advance_indicator_scene_path, true, "advance_indicator_scene", errors)
	return errors


## Non-blocking authoring diagnostics. Resolution remains deterministic and
## keeps the scene source when both source fields are configured.
func advance_indicator_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _has_advance_indicator_scene_source() \
		and _has_advance_indicator_texture_source():
		warnings.append(
			"advance_indicator_texture and advance_indicator_scene are mutually exclusive; " \
			+ "scene takes precedence")
	return warnings


## Structured context used only for runtime authoring diagnostics. STLA paths
## and lines come from the parser sidecar; Resource fallbacks identify their
## concrete resource or explicitly state that it exists only in memory.
func advance_indicator_diagnostic_provenance() -> Dictionary:
	var source_field := (
		"advance_indicator_scene"
		if _has_advance_indicator_scene_source()
		else "advance_indicator_texture"
	)
	var source_path := ""
	if source_field == "advance_indicator_scene":
		source_path = _stla_advance_indicator_scene_path
		if source_path.is_empty() and advance_indicator_scene != null:
			source_path = _diagnostic_resource_path(
				advance_indicator_scene, "PackedScene")
	else:
		source_path = _stla_advance_indicator_texture_path
		if source_path.is_empty() and advance_indicator_texture != null:
			source_path = _diagnostic_resource_path(
				advance_indicator_texture, "Texture2D")

	if String(_stla_provenance.get("kind", "")) == "stla":
		var field_lines: Dictionary = _stla_provenance.get("field_lines", {})
		var declaration_line := int(field_lines.get(source_field, 0))
		var profile_source := String(_stla_provenance.get("source_path", ""))
		if profile_source.is_empty():
			profile_source = "<unknown STLA>"
		return {
			"kind": "stla",
			"profile_name": String(_stla_provenance.get("profile_name", "<unnamed>")),
			"profile_source": profile_source,
			"declaration_line": declaration_line,
			"indicator_field": source_field,
			"indicator_source": source_path,
		}

	return {
		"kind": "resource_fallback",
		"mode_profile_source": (
			resource_path if not resource_path.is_empty()
			else "<in-memory DialogueModeProfile>"
		),
		"indicator_field": source_field,
		"indicator_source": source_path,
	}


func _has_advance_indicator_texture_source() -> bool:
	return advance_indicator_texture != null \
		or not _stla_advance_indicator_texture_path.is_empty()


func _has_advance_indicator_scene_source() -> bool:
	return advance_indicator_scene != null \
		or not _stla_advance_indicator_scene_path.is_empty()


func _diagnostic_resource_path(resource: Resource, type_name: String) -> String:
	if resource != null and not resource.resource_path.is_empty():
		return resource.resource_path
	return "<in-memory %s>" % type_name


func _validate_stla_advance_indicator_resource(
	resource_path: String,
	expects_scene: bool,
	field_name: String,
	errors: PackedStringArray,
) -> void:
	if resource_path.is_empty():
		return
	if not ResourceLoader.exists(resource_path):
		errors.append("%s resource no longer exists: '%s'" % [field_name, resource_path])
		return
	var resource := ResourceLoader.load(resource_path)
	var valid_type := (resource is PackedScene) if expects_scene else (resource is Texture2D)
	if not valid_type:
		var expected_name := "PackedScene" if expects_scene else "Texture2D"
		var actual_name := resource.get_class() if resource != null else "unloadable resource"
		errors.append("%s must resolve to a %s, got %s"
			% [field_name, expected_name, actual_name])


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if override_entry_prefix \
		and (entry_prefix.contains("[") or entry_prefix.contains("]")):
		errors.append("entry_prefix is plain text and cannot contain BBCode brackets")
	if override_entry_separator \
		and (entry_separator.contains("[") or entry_separator.contains("]")):
		errors.append("entry_separator is plain text and cannot contain BBCode brackets")
	if override_panel_rect:
		_validate_anchor_rect(panel_anchors, "panel_anchors", errors)
		if not panel_offsets.is_finite():
			errors.append("panel_offsets must contain only finite values")
	if override_text_rect:
		_validate_anchor_rect(text_anchors, "text_anchors", errors)
		if not text_offsets.is_finite():
			errors.append("text_offsets must contain only finite values")
		if not text_margins.is_finite():
			errors.append("text_margins must contain only finite values")
		elif minf(minf(text_margins.x, text_margins.y), minf(text_margins.z, text_margins.w)) < 0.0:
			errors.append("text_margins cannot contain negative values")
	if override_text_alignment:
		if horizontal_alignment < HORIZONTAL_ALIGNMENT_LEFT or horizontal_alignment > HORIZONTAL_ALIGNMENT_FILL:
			errors.append("horizontal_alignment is outside the supported enum range")
		if vertical_alignment < VERTICAL_ALIGNMENT_TOP or vertical_alignment > VERTICAL_ALIGNMENT_FILL:
			errors.append("vertical_alignment is outside the supported enum range")
	if override_text_overflow:
		if autowrap_mode < TextServer.AUTOWRAP_OFF or autowrap_mode > TextServer.AUTOWRAP_WORD_SMART:
			errors.append("autowrap_mode is outside the supported enum range")
	for group_name in visibility_groups:
		if typeof(group_name) != TYPE_STRING and typeof(group_name) != TYPE_STRING_NAME:
			errors.append("visibility_groups keys must be String or StringName group names")
		if String(group_name).strip_edges().is_empty():
			errors.append("visibility_groups contains an empty group name")
		if typeof(visibility_groups[group_name]) != TYPE_BOOL:
			errors.append("visibility_groups['%s'] must be a bool" % group_name)
	return errors


func _validate_anchor_rect(rect: Vector4, field_name: String, errors: PackedStringArray) -> void:
	if not rect.is_finite():
		errors.append("%s must contain only finite values" % field_name)
		return
	var minimum := minf(minf(rect.x, rect.y), minf(rect.z, rect.w))
	var maximum := maxf(maxf(rect.x, rect.y), maxf(rect.z, rect.w))
	if minimum < 0.0 or maximum > 1.0:
		errors.append("%s must stay inside the 0..1 anchor range" % field_name)
	if rect.x > rect.z or rect.y > rect.w:
		errors.append("%s must be ordered left <= right and top <= bottom" % field_name)
