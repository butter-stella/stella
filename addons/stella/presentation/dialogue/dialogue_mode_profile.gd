## Runtime representation of one STLA dialogue presentation profile.
##
## DialogueProfileParser normally constructs this from .stla data. Exported
## fields remain available only for the advanced scene-side fallback.
## Every section is opt-in. Unset sections retain the authored scene state.
class_name DialogueModeProfile
extends Resource

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


## Build a runtime profile from validated STLA declaration data.
static func from_dictionary(data: Dictionary) -> DialogueModeProfile:
	var profile := DialogueModeProfile.new()
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
		&"background_visible":
			return override_background_visibility
		&"background_modulate":
			return override_background_modulate
	return false


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
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
