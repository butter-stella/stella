## Parses DslToken list into ScenarioData.
## Fills smart defaults, expands @if/@else/@end into synthetic scenes.
class_name DslParser extends RefCounted

const INTERNAL_DIALOGUE_MODE_EVENT := "__dialogue_mode_event"
const INTERNAL_IF_NODE := "__if_node"
const _PARALLEL_BLOCKING_COMMANDS := [
	"dialogue", "choice", "wait", "chapter_indicator", "presentation_batch",
	"presentation_clip", "recollection_exit",
]
const _CHAPTER_INDICATOR_ACTIONS := ["show", "hide"]
const _CHAPTER_INDICATOR_TRANSITIONS := ["cut", "none", "fade"]
const _DIALOGUE_VISIBILITY_TARGETS := ["surface", "quick_menu"]
const _DIALOGUE_VISIBILITY_ACTIONS := ["show", "hide"]
const _DIALOGUE_VISIBILITY_TRANSITIONS := ["cut", "fade"]
const _DIALOGUE_AVATAR_ACTIONS := ["set", "show", "hide", "remove"]
const _DIALOGUE_AVATAR_TRANSITIONS := ["cut", "fade"]
const _DIALOGUE_AVATAR_PAIR_KEYS := ["position", "origin", "scale"]
const _DIALOGUE_AVATAR_NUMBER_KEYS := ["rotation", "z_index", "opacity"]
const _DIALOGUE_AVATAR_STRING_KEYS := ["asset", "character", "expression"]
const _LOOP_SE_ACTIONS := ["play", "stop"]
const _BGM_ACTIONS := ["play", "mix", "pause", "resume", "stop"]
const _STAGE_FIT_MODES := ["native", "contain", "cover", "stretch"]
const _STAGE_PAIR_KEYS := [
	"position", "origin", "scale", "zoom",
	"asset_offset", "body_offset", "face_offset",
]
const _STAGE_NUMBER_KEYS := [
	"x", "y", "origin_x", "origin_y", "scale_x", "scale_y",
	"zoom_x", "zoom_y", "asset_x", "asset_y", "body_x", "body_y",
	"face_x", "face_y", "depth_scale", "rotation", "z", "z_index",
	"opacity",
]
const _STAGE_BOOL_KEYS := ["visible", "flip_x", "flip_y"]
const _STAGE_STRING_KEYS := ["kind", "asset", "body", "face"]


static func parse(
	tokens: Array,
	scenario_id: String = "unnamed",
	source_path: String = "",
) -> ScenarioData:
	var data = ScenarioData.new()
	data.id = scenario_id
	data.source_identity = ScenarioData.make_source_identity(source_path)
	data.source_path = source_path
	var profile_collection := DialogueProfileParser.collect(tokens, source_path)
	var dialogue_profiles: Dictionary = profile_collection["profiles"]
	_register_dialogue_profiles(data, dialogue_profiles)
	data.diagnostics.append_array(profile_collection["diagnostics"])

	var current_scene: SceneData = null
	var pending_options: Array = []
	var choice_cmd: CommandData = null
	# Mode directives that appear before the first scene are lowered onto that
	# scene's first addressable command once parsing is complete.
	var pending_root_mode_events: Array[CommandData] = []

	# @chapter state (issue #97). Tracks the most-recently-declared chapter so
	# subsequent @scene declarations can be assigned to it. null until the
	# first @chapter is seen.
	var current_chapter: ChapterData = null
	# current_scene intentionally retains the preceding scene while the next
	# chapter declaration waits for its first @scene. Commands in this gap must
	# not leak into that preceding scene.
	var chapter_needs_scene: bool = false

	# @if/@else/@end state
	var if_stack: Array = []  # Array of IfContext

	# @parallel state
	var in_parallel: bool = false
	var parallel_commands: Array = []
	var parallel_start_line: int = 0
	var parallel_invalid: bool = false

	# @combine state — groups multiple dialogue lines with per-segment named-stage
	# cues into a single dialogue command with a `segments` array.
	var in_combine: bool = false
	var combine_segments: Array = []
	var combine_character: String = ""
	var combine_character_set: bool = false
	var combine_pending_presentation_ops: Array = []
	var combine_pending_presentation_operation_lines: Array = []
	var combine_start_line: int = 0

	# @stage_batch state. Children are accumulated as canonical Dictionary
	# operations and published only when the complete block closes validly.
	var in_stage_batch: bool = false
	var stage_batch_policy: String = ""
	var stage_batch_operations: Array = []
	var stage_batch_operation_lines: Array = []
	var stage_batch_layer_ids: Dictionary = {}
	var stage_batch_start_line: int = 0
	var stage_batch_invalid: bool = false
	var stage_batch_nested_depth: int = 0
	var in_presentation_batch: bool = false
	var presentation_batch_policy: String = ""
	var presentation_batch_operations: Array = []
	var presentation_batch_operation_lines: Array = []
	var presentation_batch_stage_layer_ids: Dictionary = {}
	var presentation_batch_visibility_targets: Dictionary = {}
	var presentation_batch_loop_se_channels: Dictionary = {}
	var presentation_batch_has_dialogue_clear: bool = false
	var presentation_batch_has_chapter_indicator: bool = false
	var presentation_batch_has_bgm: bool = false
	var presentation_batch_has_dialogue_avatar: bool = false
	var presentation_batch_start_line: int = 0
	var presentation_batch_invalid: bool = false
	var presentation_batch_nested_depth: int = 0

	var i = 0
	while i < tokens.size():
		var token: DslToken = tokens[i]

		# A stage batch owns every token until its matching @end. Invalid nested
		# blocks are consumed structurally so their @end cannot accidentally close
		# the outer batch and leak a following sibling command.
		if in_presentation_batch:
			if token.type in [
				DslToken.Type.SCENE_DIRECTIVE,
				DslToken.Type.CHAPTER_DIRECTIVE,
			]:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @presentation_batch block opened at %s is missing @end before the next @scene/@chapter"
					% _source_location(data, presentation_batch_start_line),
					presentation_batch_start_line,
				)
				in_presentation_batch = false
				presentation_batch_policy = ""
				presentation_batch_operations.clear()
				presentation_batch_operation_lines.clear()
				presentation_batch_stage_layer_ids.clear()
				presentation_batch_visibility_targets.clear()
				presentation_batch_loop_se_channels.clear()
				presentation_batch_has_dialogue_clear = false
				presentation_batch_has_chapter_indicator = false
				presentation_batch_has_bgm = false
				presentation_batch_has_dialogue_avatar = false
				presentation_batch_start_line = 0
				presentation_batch_invalid = false
				presentation_batch_nested_depth = 0
			elif presentation_batch_nested_depth > 0:
				if token.type == DslToken.Type.AT_COMMAND:
					var nested_child_name := _get_at_command_name(token.raw_text)
					if nested_child_name in ["presentation_batch", "stage_batch", "parallel", "combine", "if"]:
						presentation_batch_nested_depth += 1
					elif nested_child_name == "end":
						presentation_batch_nested_depth -= 1
				i += 1
				continue
			elif token.type == DslToken.Type.AT_COMMAND:
				var child_name := _get_at_command_name(token.raw_text)
				if child_name == "stage":
					var stage_child := _parse_at_command(token, data)
					if stage_child == null or stage_child.type != "stage_layer":
						presentation_batch_invalid = true
					else:
						var payload: Dictionary = stage_child.params.duplicate(true)
						var action := String(payload.get("action", ""))
						var layer_id := String(payload.get("id", ""))
						if action != "clear" and presentation_batch_stage_layer_ids.has(layer_id):
							_record_diagnostic(
								data,
								"error",
								"DslParser: duplicate Stage layer '%s' at %s"
								% [layer_id, _source_location(data, token.line)],
								token.line,
							)
							presentation_batch_invalid = true
						elif action == "clear":
							for prior_value: Variant in presentation_batch_operations:
								var prior: Dictionary = prior_value
								if String(prior.get("kind", "")) != "stage":
									continue
								if String((prior.get("payload", {}) as Dictionary).get("action", "")) != "clear":
									_record_diagnostic(
										data,
										"error",
										"DslParser: @stage clear conflicts with another Stage sibling at %s"
										% _source_location(data, token.line),
										token.line,
									)
									presentation_batch_invalid = true
									break
						else:
							for prior_value: Variant in presentation_batch_operations:
								var prior: Dictionary = prior_value
								if String(prior.get("kind", "")) != "stage":
									continue
								if String((prior.get("payload", {}) as Dictionary).get("action", "")) == "clear":
									_record_diagnostic(
										data,
										"error",
										"DslParser: @stage clear conflicts with another Stage sibling at %s"
										% _source_location(data, token.line),
										token.line,
									)
									presentation_batch_invalid = true
									break
							presentation_batch_stage_layer_ids[layer_id] = true
						presentation_batch_operations.append({
							"kind": "stage",
							"payload": payload,
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "dialogue_visibility":
					var visibility_child := _parse_at_command(token, data)
					if visibility_child == null or visibility_child.type != "dialogue_visibility":
						presentation_batch_invalid = true
					else:
						var payload: Dictionary = visibility_child.params.duplicate(true)
						var target := String(payload.get("target", ""))
						if presentation_batch_visibility_targets.has(target):
							_record_diagnostic(
								data,
								"error",
								"DslParser: duplicate dialogue visibility target '%s' at %s"
								% [target, _source_location(data, token.line)],
								token.line,
							)
							presentation_batch_invalid = true
						else:
							presentation_batch_visibility_targets[target] = true
						presentation_batch_operations.append({
							"kind": "dialogue_visibility",
							"payload": payload,
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "dialogue_avatar":
					var avatar_child := _parse_at_command(token, data)
					if avatar_child == null or avatar_child.type != "dialogue_avatar":
						presentation_batch_invalid = true
					elif presentation_batch_has_dialogue_avatar:
						_record_diagnostic(
							data,
							"error",
							"DslParser: duplicate dialogue avatar channel at %s"
							% _source_location(data, token.line),
							token.line,
						)
						presentation_batch_invalid = true
					else:
						presentation_batch_has_dialogue_avatar = true
						presentation_batch_operations.append({
							"kind": "dialogue_avatar",
							"payload": avatar_child.params.duplicate(true),
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "dialogue_clear":
					var clear_child := _parse_at_command(token, data)
					if clear_child == null or clear_child.type != "dialogue_clear":
						presentation_batch_invalid = true
					elif presentation_batch_has_dialogue_clear:
						_record_diagnostic(
							data,
							"error",
							"DslParser: duplicate dialogue clear channel at %s"
							% _source_location(data, token.line),
							token.line,
						)
						presentation_batch_invalid = true
					else:
						presentation_batch_has_dialogue_clear = true
						presentation_batch_operations.append({
							"kind": "dialogue_clear",
							"payload": clear_child.params.duplicate(true),
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "chapter_indicator":
					var chapter_child := _parse_at_command(token, data)
					if chapter_child == null or chapter_child.type != "chapter_indicator":
						presentation_batch_invalid = true
					elif presentation_batch_has_chapter_indicator:
						_record_diagnostic(
							data,
							"error",
							"DslParser: duplicate chapter indicator channel at %s"
							% _source_location(data, token.line),
							token.line,
						)
						presentation_batch_invalid = true
					else:
						presentation_batch_has_chapter_indicator = true
						presentation_batch_operations.append({
							"kind": "chapter_indicator",
							"payload": chapter_child.params.duplicate(true),
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "loop_se":
					var loop_se_child := _parse_at_command(token, data)
					if loop_se_child == null or loop_se_child.type != "loop_se":
						presentation_batch_invalid = true
					else:
						var payload: Dictionary = loop_se_child.params.duplicate(true)
						var channel_id := String(payload.get("channel", ""))
						if presentation_batch_loop_se_channels.has(channel_id):
							_record_diagnostic(
								data,
								"error",
								"DslParser: duplicate loop-SE channel '%s' at %s"
								% [channel_id, _source_location(data, token.line)],
								token.line,
							)
							presentation_batch_invalid = true
						else:
							presentation_batch_loop_se_channels[channel_id] = true
						presentation_batch_operations.append({
							"kind": "loop_se",
							"payload": payload,
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "bgm":
					var bgm_child := _parse_at_command(token, data)
					if bgm_child == null or bgm_child.type != "bgm":
						presentation_batch_invalid = true
					elif presentation_batch_has_bgm:
						_record_diagnostic(
							data,
							"error",
							"DslParser: duplicate BGM channel at %s"
							% _source_location(data, token.line),
							token.line,
						)
						presentation_batch_invalid = true
					else:
						presentation_batch_has_bgm = true
						presentation_batch_operations.append({
							"kind": "bgm",
							"payload": bgm_child.params.duplicate(true),
						})
						presentation_batch_operation_lines.append(token.line)
				elif child_name == "end":
					if (
						presentation_batch_operations.is_empty()
						and not presentation_batch_invalid
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @presentation_batch cannot be empty at %s"
							% _source_location(data, presentation_batch_start_line),
							presentation_batch_start_line,
						)
						presentation_batch_invalid = true
					if (
						not presentation_batch_invalid
						and current_scene != null
						and not chapter_needs_scene
					):
						var batch_command := _make_cmd("presentation_batch", {
							"policy": presentation_batch_policy,
							"operations": presentation_batch_operations.duplicate(true),
							"operation_lines": presentation_batch_operation_lines.duplicate(),
						})
						batch_command.declared_line = presentation_batch_start_line
						_add_command(batch_command, current_scene, if_stack)
					in_presentation_batch = false
					presentation_batch_policy = ""
					presentation_batch_operations.clear()
					presentation_batch_operation_lines.clear()
					presentation_batch_stage_layer_ids.clear()
					presentation_batch_visibility_targets.clear()
					presentation_batch_loop_se_channels.clear()
					presentation_batch_has_dialogue_clear = false
					presentation_batch_has_chapter_indicator = false
					presentation_batch_has_bgm = false
					presentation_batch_has_dialogue_avatar = false
					presentation_batch_start_line = 0
					presentation_batch_invalid = false
					presentation_batch_nested_depth = 0
				elif child_name in ["presentation_batch", "stage_batch", "parallel", "combine", "if"]:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @%s is not allowed inside @presentation_batch at %s"
						% [child_name, _source_location(data, token.line)],
						token.line,
					)
					presentation_batch_invalid = true
					presentation_batch_nested_depth = 1
				else:
					_record_diagnostic(
						data,
						"error",
						"DslParser: only canonical @stage, @dialogue_avatar, @dialogue_visibility, @dialogue_clear, @chapter_indicator, @loop_se, and @bgm children are allowed inside @presentation_batch; found @%s at %s"
						% [child_name, _source_location(data, token.line)],
						token.line,
					)
					presentation_batch_invalid = true
				i += 1
				continue
			else:
				_record_diagnostic(
					data,
					"error",
					"DslParser: only canonical @stage, @dialogue_avatar, @dialogue_visibility, @dialogue_clear, @chapter_indicator, @loop_se, and @bgm children are allowed inside @presentation_batch at %s"
					% _source_location(data, token.line),
					token.line,
				)
				presentation_batch_invalid = true
				i += 1
				continue
		if in_stage_batch:
			if token.type in [
				DslToken.Type.SCENE_DIRECTIVE,
				DslToken.Type.CHAPTER_DIRECTIVE,
			]:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @stage_batch block opened at %s is missing @end before the next @scene/@chapter"
					% _source_location(data, stage_batch_start_line),
					stage_batch_start_line,
				)
				in_stage_batch = false
				stage_batch_policy = ""
				stage_batch_operations.clear()
				stage_batch_operation_lines.clear()
				stage_batch_layer_ids.clear()
				stage_batch_start_line = 0
				stage_batch_invalid = false
				stage_batch_nested_depth = 0
				# Continue into normal @scene handling below.
			elif token.type == DslToken.Type.AT_COMMAND:
				var batch_child_name := _get_at_command_name(token.raw_text)
				if stage_batch_nested_depth > 0:
					if batch_child_name in ["stage_batch", "parallel", "combine", "if"]:
						stage_batch_nested_depth += 1
					elif batch_child_name == "end":
						stage_batch_nested_depth -= 1
					i += 1
					continue
				if batch_child_name == "stage":
					var diagnostics_before: int = data.diagnostics.size()
					var stage_child := _parse_at_command(token, data)
					if stage_child == null or stage_child.type != "stage_layer":
						stage_batch_invalid = true
						var diagnostics_after: int = data.diagnostics.size()
						if diagnostics_after > diagnostics_before:
							for diagnostic_index in range(
								diagnostics_before, diagnostics_after
							):
								var diagnostic: Dictionary = (
									data.diagnostics[diagnostic_index]
								)
								if String(diagnostic.get("level", "")) != "error":
									diagnostic["level"] = "error"
									data.diagnostics[diagnostic_index] = diagnostic
						else:
							_record_diagnostic(
								data,
								"error",
								"DslParser: invalid @stage child in @stage_batch at %s"
								% _source_location(data, token.line),
								token.line,
							)
					else:
						var operation: Dictionary = stage_child.params.duplicate(true)
						var action := String(operation.get("action", ""))
						var layer_id := String(operation.get("id", ""))
						if action != "clear" and layer_id == "*":
							_record_diagnostic(
								data,
								"error",
								"DslParser: stage layer '*' is reserved for @stage clear at %s"
								% _source_location(data, token.line),
								token.line,
							)
							stage_batch_invalid = true
						if action == "clear":
							if not stage_batch_operations.is_empty():
								_record_diagnostic(
									data,
									"error",
									"DslParser: @stage clear must be the only @stage_batch child at %s"
									% _source_location(data, token.line),
									token.line,
								)
								stage_batch_invalid = true
						elif (
							stage_batch_layer_ids.has(layer_id)
							or (
								not stage_batch_operations.is_empty()
								and String((stage_batch_operations[0] as Dictionary).get(
									"action", "")) == "clear"
							)
						):
							_record_diagnostic(
								data,
								"error",
								"DslParser: duplicate or clear-conflicting stage layer '%s' at %s"
								% [layer_id, _source_location(data, token.line)],
								token.line,
							)
							stage_batch_invalid = true
						if action != "clear":
							stage_batch_layer_ids[layer_id] = true
						stage_batch_operations.append(operation)
						stage_batch_operation_lines.append(token.line)
				elif batch_child_name == "end":
					if stage_batch_operations.is_empty():
						_record_diagnostic(
							data,
							"error",
							"DslParser: @stage_batch cannot be empty at %s"
							% _source_location(data, stage_batch_start_line),
							stage_batch_start_line,
						)
						stage_batch_invalid = true
					if (
						not stage_batch_invalid
						and current_scene != null
						and not chapter_needs_scene
					):
						var stage_batch_command := _make_cmd("stage_batch", {
							"policy": stage_batch_policy,
							"operations": stage_batch_operations.duplicate(true),
							"operation_lines": stage_batch_operation_lines.duplicate(),
						})
						stage_batch_command.declared_line = stage_batch_start_line
						_add_command(stage_batch_command, current_scene, if_stack)
					in_stage_batch = false
					stage_batch_policy = ""
					stage_batch_operations.clear()
					stage_batch_operation_lines.clear()
					stage_batch_layer_ids.clear()
					stage_batch_start_line = 0
					stage_batch_invalid = false
					stage_batch_nested_depth = 0
				elif batch_child_name in ["stage_batch", "parallel", "combine", "if"]:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @%s is not allowed inside @stage_batch at %s"
						% [batch_child_name, _source_location(data, token.line)],
						token.line,
					)
					stage_batch_invalid = true
					stage_batch_nested_depth = 1
				else:
					_record_diagnostic(
						data,
						"error",
						"DslParser: only canonical @stage children are allowed inside @stage_batch; found @%s at %s"
						% [batch_child_name, _source_location(data, token.line)],
						token.line,
					)
					stage_batch_invalid = true
				i += 1
				continue
			else:
				_record_diagnostic(
					data,
					"error",
					"DslParser: only canonical @stage children are allowed inside @stage_batch at %s"
					% _source_location(data, token.line),
					token.line,
				)
				stage_batch_invalid = true
				i += 1
				continue

		match token.type:
			DslToken.Type.SCENE_DIRECTIVE:
				# Authoring blocks never cross scene boundaries. Report and discard an
				# unterminated block here so a later scene's @end cannot accidentally
				# close and compile commands from the previous scene.
				if in_combine:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @combine block opened on line %d is missing @end before the next @scene"
						% combine_start_line,
						combine_start_line,
					)
					in_combine = false
					combine_segments.clear()
					combine_pending_presentation_ops.clear()
					combine_pending_presentation_operation_lines.clear()
					combine_character = ""
					combine_character_set = false
					combine_start_line = 0
				if in_parallel:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @parallel block opened on line %d is missing @end before the next @scene"
						% parallel_start_line,
						parallel_start_line,
					)
					in_parallel = false
					parallel_commands.clear()
					parallel_start_line = 0
					parallel_invalid = false
				if not if_stack.is_empty():
					var unclosed_if_line := int(if_stack[0].get("line", 0))
					_record_diagnostic(
						data,
						"error",
						"DslParser: @if block opened on line %d is missing @end before the next @scene"
						% unclosed_if_line,
						unclosed_if_line,
					)
					if_stack.clear()
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				current_scene = _parse_scene_directive(token)
				chapter_needs_scene = false
				if not pending_root_mode_events.is_empty():
					current_scene.commands.append_array(pending_root_mode_events)
					pending_root_mode_events.clear()
				data.scenes.append(current_scene)
				# Issue #97: 强制规范化 — every scene must belong to a chapter.
				if current_chapter == null:
					_record_diagnostic(data, "error",
						"DslParser: scene '%s' declared before any @chapter (line %d)"
						% [current_scene.id, token.line], token.line)
					# Forgiving: still record the orphan scene with empty
					# chapter_id so the rest of the file parses; downstream
					# graph builder treats orphans as errors.
				else:
					current_scene.chapter_id = current_chapter.id
					current_chapter.scene_ids.append(current_scene.id)

			DslToken.Type.CHAPTER_DIRECTIVE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				# Chapters are top-level only — they cannot appear inside an
				# @if/@else block, @parallel block, or @combine block.
				if if_stack.size() > 0:
					_record_diagnostic(data, "error",
						"DslParser: @chapter cannot be used inside @if/@else block (line %d)"
						% token.line, token.line)
				elif in_parallel:
					_record_diagnostic(data, "error",
						"DslParser: @chapter cannot be used inside @parallel block (line %d)"
						% token.line, token.line)
				elif in_combine:
					_record_diagnostic(data, "error",
						"DslParser: @chapter cannot be used inside @combine block (line %d)"
						% token.line, token.line)
				else:
					var new_chapter = _parse_chapter_directive(token)
					if new_chapter.id == "":
						# Bare `@chapter` or quoted-only `@chapter "title"` —
						# no usable id. Reject the chapter entirely; an empty-id
						# chapter would silently break get_chapter_for_scene.
						_record_diagnostic(data, "error",
							"DslParser: @chapter is missing id (line %d)"
							% token.line, token.line)
						# Do NOT update current_chapter — subsequent scenes will
						# trigger "before any @chapter" until a valid one appears.
					elif data.get_chapter(new_chapter.id) != null:
						_record_diagnostic(data, "error",
							"DslParser: duplicate chapter id '%s' (line %d)"
							% [new_chapter.id, token.line], token.line)
						# Reject the duplicate; first one wins. current_chapter
						# stays on the previous one so subsequent scenes still
						# group sensibly under the original chapter.
					else:
						current_chapter = new_chapter
						data.chapters.append(current_chapter)
						chapter_needs_scene = true

			DslToken.Type.AT_COMMAND:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []

				var cmd_name = _get_at_command_name(token.raw_text)

				if cmd_name == "presentation_batch":
					in_presentation_batch = true
					presentation_batch_start_line = token.line
					presentation_batch_operations.clear()
					presentation_batch_operation_lines.clear()
					presentation_batch_stage_layer_ids.clear()
					presentation_batch_visibility_targets.clear()
					presentation_batch_loop_se_channels.clear()
					presentation_batch_has_dialogue_clear = false
					presentation_batch_has_chapter_indicator = false
					presentation_batch_has_bgm = false
					presentation_batch_has_dialogue_avatar = false
					presentation_batch_nested_depth = 0
					presentation_batch_invalid = false
					var name_position := token.raw_text.find(cmd_name, 1)
					var batch_args := _strip_inline_comment(
						token.raw_text.substr(
							name_position + cmd_name.length()
						).strip_edges()
					)
					var header := _parse_presentation_batch_header(
						_split_args(batch_args), token.line, data)
					presentation_batch_policy = String(header.get("policy", ""))
					presentation_batch_invalid = not bool(header.get("valid", false))
					if (
						current_scene == null
						or chapter_needs_scene
						or in_parallel
						or in_combine
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @presentation_batch requires an active @scene and cannot be nested in @parallel/@combine at %s"
							% _source_location(data, token.line),
							token.line,
						)
						presentation_batch_invalid = true
				elif cmd_name == "stage_batch":
					in_stage_batch = true
					stage_batch_start_line = token.line
					stage_batch_operations.clear()
					stage_batch_operation_lines.clear()
					stage_batch_layer_ids.clear()
					stage_batch_nested_depth = 0
					stage_batch_invalid = false
					var name_position := token.raw_text.find(cmd_name, 1)
					var batch_args := _strip_inline_comment(
						token.raw_text.substr(
							name_position + cmd_name.length()
						).strip_edges()
					)
					var header := _parse_stage_batch_header(
						_split_args(batch_args), token.line, data)
					stage_batch_policy = String(header.get("policy", ""))
					stage_batch_invalid = not bool(header.get("valid", false))
					if (
						current_scene == null
						or chapter_needs_scene
						or in_parallel
						or in_combine
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @stage_batch requires an active @scene and cannot be nested in @parallel/@combine at %s"
							% _source_location(data, token.line),
							token.line,
						)
						stage_batch_invalid = true
				elif in_combine and cmd_name not in ["stage", "dialogue_avatar", "end"]:
					var combine_message := (
						"DslParser: only @stage and @dialogue_avatar are allowed inside @combine block; @%s was ignored (line %d)"
						% [cmd_name, token.line]
					)
					if cmd_name in [
						"chapter_indicator", "loop_se", "bgm", "recollection_exit",
					]:
						combine_message = (
							"DslParser: @%s is not allowed inside @combine at %s"
							% [cmd_name, _source_location(data, token.line)]
						)
					_record_diagnostic(
						data,
						(
							"error"
							if cmd_name in [
								"chapter_indicator", "loop_se", "bgm", "recollection_exit",
							]
							else "warning"
						),
						combine_message,
						token.line,
					)
				elif cmd_name == "choice":
					if in_parallel:
						_record_parallel_blocking_diagnostic(
							data, "choice", token.line)
						parallel_invalid = true
					else:
						choice_cmd = _parse_choice_command(token)
				elif cmd_name == "if":
					var nested_if := _create_if_context(token, current_scene, data)
					if if_stack.size() > 0:
						_append_if_node(if_stack[-1], nested_if)
					if_stack.append(nested_if)
				elif cmd_name == "elif":
					if if_stack.is_empty():
						_record_diagnostic(
							data,
							"error",
							"DslParser: unmatched @elif (line %d)" % token.line,
							token.line,
						)
					elif bool(if_stack[-1].get("has_else", false)):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @elif cannot appear after @else (line %d)"
							% token.line,
							token.line,
						)
					else:
						# An elif is represented as the sole nested condition on the
						# previous condition's false branch. The complete tree is
						# compiled only when the chain's root @if closes.
						var elif_expr = token.raw_text.substr(6).strip_edges()
						var ctx = if_stack[-1]
						ctx["branch"] = "else"
						var nested_elif = {
							"node_kind": INTERNAL_IF_NODE,
							"expr": elif_expr,
							"scene_id": ctx["scene_id"],
							"line": token.line,
							"then_commands": [],
							"else_commands": [],
							"branch": "then",
							"parent_scene": ctx["parent_scene"],
							"is_elif": true,
							"has_else": false,
						}
						ctx["else_commands"].append(nested_elif)
						if_stack.append(nested_elif)
				elif cmd_name == "else":
					if if_stack.is_empty():
						_record_diagnostic(
							data,
							"error",
							"DslParser: unmatched @else (line %d)" % token.line,
							token.line,
						)
					elif bool(if_stack[-1].get("has_else", false)):
						_record_diagnostic(
							data,
							"error",
							"DslParser: duplicate @else (line %d)" % token.line,
							token.line,
						)
					else:
						if_stack[-1]["branch"] = "else"
						if_stack[-1]["has_else"] = true
				elif cmd_name == "end":
					if in_combine:
						if not combine_pending_presentation_ops.is_empty():
							_record_diagnostic(
								data,
								"warning",
								"DslParser: @combine ends with presentation cues that are not bound to a dialogue segment (line %d)"
								% token.line,
								token.line,
							)
						var combine_cmd = _build_combine_command(
							combine_character,
							combine_segments,
						)
						combine_segments = []
						combine_character = ""
						combine_character_set = false
						combine_pending_presentation_ops = []
						combine_pending_presentation_operation_lines = []
						combine_start_line = 0
						in_combine = false
						if combine_cmd and current_scene:
							_add_command(combine_cmd, current_scene, if_stack)
					elif in_parallel:
						var parallel_cmd: CommandData = null
						if not parallel_invalid:
							parallel_cmd = _make_cmd(
								"parallel", {"commands": parallel_commands.duplicate()}
							)
						parallel_commands.clear()
						parallel_start_line = 0
						in_parallel = false
						parallel_invalid = false
						if current_scene:
							if parallel_cmd != null:
								_add_command(parallel_cmd, current_scene, if_stack)
					elif if_stack.size() > 0:
						# One @end closes a complete @if/@elif chain. A nested root
						# remains as an AST node in its parent's active branch; only a
						# top-level root is compiled into synthetic CFG scenes here.
						while if_stack.size() > 0 and if_stack[-1].get("is_elif", false):
							if_stack.pop_back()
						if if_stack.size() > 0:
							var closed_if = if_stack.pop_back()
							if if_stack.is_empty():
								current_scene = _close_if_block(closed_if, data)
					else:
						_record_diagnostic(
							data,
							"error",
							"DslParser: unmatched @end (line %d)" % token.line,
							token.line,
						)
				elif cmd_name in ["adv", "nvl", "overlay"]:
					var selection := DialogueProfileParser.parse_mode_directive(
						token.raw_text, cmd_name, dialogue_profiles, token.line
					)
					data.diagnostics.append_array(selection["diagnostics"])
					var mode_event := _make_cmd(
						INTERNAL_DIALOGUE_MODE_EVENT,
						_build_dialogue_presentation_event(cmd_name, selection),
					)
					mode_event.declared_line = token.line
					if current_scene == null:
						pending_root_mode_events.append(mode_event)
					elif in_parallel:
						parallel_commands.append(mode_event)
					else:
						_add_command(mode_event, current_scene, if_stack)
				elif cmd_name == "dialogue_profile":
					# Compile-time declaration; already collected in a pre-pass so
					# profiles may be referenced before their declaration.
					pass
				elif cmd_name == "parallel":
					if in_parallel:
						_record_diagnostic(
							data,
							"error",
							"DslParser: nested @parallel is not allowed (line %d)"
							% token.line,
							token.line,
						)
						parallel_invalid = true
					else:
						in_parallel = true
						parallel_commands.clear()
						parallel_start_line = token.line
						parallel_invalid = false
				elif cmd_name == "combine":
					in_combine = true
					combine_segments = []
					combine_character = ""
					combine_character_set = false
					combine_pending_presentation_ops = []
					combine_pending_presentation_operation_lines = []
					combine_start_line = token.line
				else:
					var cmd = _parse_at_command(token, data, not in_combine)
					if cmd:
						cmd.declared_line = token.line
					if (
						cmd != null
						and _command_contains_chapter_indicator(cmd)
						and (current_scene == null or chapter_needs_scene)
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @chapter_indicator requires an active @scene at %s"
							% _source_location(data, token.line),
							token.line,
						)
						cmd = null
					if (
						cmd != null
						and _command_contains_operation_kind(cmd, "loop_se")
						and (current_scene == null or chapter_needs_scene)
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @loop_se requires an active @scene at %s"
							% _source_location(data, token.line),
							token.line,
						)
						cmd = null
					if (
						cmd != null
						and _command_contains_operation_kind(cmd, "bgm")
						and (current_scene == null or chapter_needs_scene)
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @bgm requires an active @scene at %s"
							% _source_location(data, token.line),
							token.line,
						)
						cmd = null
					if (
						cmd != null
						and cmd.type == "recollection_exit"
						and (current_scene == null or chapter_needs_scene)
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @recollection_exit requires an active @scene at %s"
							% _source_location(data, token.line),
							token.line,
						)
						cmd = null
					if cmd and current_scene:
						if in_combine:
							# Typed presentation cues retain their exact authored order
							# and source-line sidecar on the next dialogue segment.
							var cue_kind := (
								"stage" if cmd.type == "stage_layer" else "dialogue_avatar")
							combine_pending_presentation_ops.append({
								"kind": cue_kind,
								"payload": cmd.params.duplicate(true),
							})
							combine_pending_presentation_operation_lines.append(token.line)
						elif in_parallel:
							if cmd.type in _PARALLEL_BLOCKING_COMMANDS:
								var blocking_type: String = (
									"chapter_indicator"
									if _command_contains_chapter_indicator(cmd)
									else cmd.type
								)
								_record_parallel_blocking_diagnostic(
									data, blocking_type, token.line)
								parallel_invalid = true
							else:
								parallel_commands.append(cmd)
						else:
							_add_command(cmd, current_scene, if_stack)

			DslToken.Type.DIALOGUE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_dialogue(token, data)
				if cmd and current_scene:
					if in_combine:
						var char_name = cmd.get_string("character", "")
						if not combine_character_set:
							combine_character = char_name
							combine_character_set = true
						elif char_name != combine_character:
							_record_diagnostic(data, "warning",
								"DslParser: @combine block mixes characters '%s' and '%s' (line %d)"
								% [combine_character, char_name, token.line], token.line)
						combine_segments.append({
							"text": cmd.get_string("text", ""),
							"voice_layers": cmd.params.get(
								"voice_layers", []).duplicate(true),
							"presentation_ops": combine_pending_presentation_ops.duplicate(true),
							"presentation_operation_lines": (
								combine_pending_presentation_operation_lines.duplicate()),
						})
						combine_pending_presentation_ops = []
						combine_pending_presentation_operation_lines = []
					elif in_parallel:
						_record_parallel_blocking_diagnostic(
							data, "dialogue", token.line)
						parallel_invalid = true
					else:
						_add_command(cmd, current_scene, if_stack)

			DslToken.Type.NARRATION:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_narration(token, data)
				if cmd and current_scene:
					if in_combine:
						if not combine_character_set:
							combine_character = ""
							combine_character_set = true
						elif combine_character != "":
							_record_diagnostic(data, "warning",
								"DslParser: @combine block mixes narration and character '%s' (line %d)"
								% [combine_character, token.line], token.line)
						combine_segments.append({
							"text": cmd.get_string("text", ""),
							"voice_layers": cmd.params.get(
								"voice_layers", []).duplicate(true),
							"presentation_ops": combine_pending_presentation_ops.duplicate(true),
							"presentation_operation_lines": (
								combine_pending_presentation_operation_lines.duplicate()),
						})
						combine_pending_presentation_ops = []
						combine_pending_presentation_operation_lines = []
					elif in_parallel:
						_record_parallel_blocking_diagnostic(
							data, "dialogue", token.line)
						parallel_invalid = true
					else:
						_add_command(cmd, current_scene, if_stack)

			DslToken.Type.MONOLOGUE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				if in_combine:
					_record_diagnostic(
						data,
						"warning",
						"DslParser: monologue is not allowed inside @combine; it and any pending presentation cues were ignored (line %d)"
						% token.line,
						token.line,
					)
					combine_pending_presentation_ops.clear()
					combine_pending_presentation_operation_lines.clear()
				else:
					var cmd = _parse_monologue(token, data)
					if cmd and current_scene:
						if in_parallel:
							_record_parallel_blocking_diagnostic(
								data, "dialogue", token.line)
							parallel_invalid = true
						else:
							_add_command(cmd, current_scene, if_stack)

			DslToken.Type.CHOICE_OPTION:
				if in_combine:
					_record_diagnostic(
						data,
						"warning",
						"DslParser: choice option is not allowed inside @combine and was ignored (line %d)"
						% token.line,
						token.line,
					)
				elif not in_parallel:
					pending_options.append(_parse_choice_option(token))

		i += 1

	_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
	if in_stage_batch:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @stage_batch block opened at %s is missing @end"
			% _source_location(data, stage_batch_start_line),
			stage_batch_start_line,
		)
	if in_presentation_batch:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @presentation_batch block opened at %s is missing @end"
			% _source_location(data, presentation_batch_start_line),
			presentation_batch_start_line,
		)
	if in_combine:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @combine block opened on line %d is missing @end"
			% combine_start_line,
			combine_start_line,
		)
	if in_parallel:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @parallel block opened on line %d is missing @end"
			% parallel_start_line,
			parallel_start_line,
		)
	if not if_stack.is_empty():
		var unclosed_if_line := int(if_stack[0].get("line", 0))
		_record_diagnostic(
			data,
			"error",
			"DslParser: @if block opened on line %d is missing @end"
			% unclosed_if_line,
			unclosed_if_line,
		)
	_lower_dialogue_mode_events(data)

	# Issue #97: post-parse validation — every chapter must own at least one
	# scene. Use the chapter's declared_line so the error points back to the
	# original @chapter directive (not line 0).
	for ch in data.chapters:
		if ch.scene_ids.size() == 0:
			_record_diagnostic(data, "error",
				"DslParser: chapter '%s' contains no scenes (line %d)"
				% [ch.id, ch.declared_line], ch.declared_line)

	# Sort diagnostics by line so authors see issues in source order. Errors
	# from the in-line scan are already line-ordered, but post-parse errors
	# (empty chapter) get appended at the end and need reordering.
	data.diagnostics.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))
	data.content_fingerprint = _fingerprint_scenario(data)

	return data


## Hash normalized validated IR, not source spelling. Comments, line numbers,
## equivalent whitespace/quotes/numbers, and parser-generated condition scene
## names cannot change runtime behavior and therefore keep read history. Any
## change to the resulting commands, profiles, chapters, or scene topology
## changes the identity and fails closed.
static func _fingerprint_scenario(data: ScenarioData) -> String:
	var synthetic_scene_ids: Dictionary = {}
	var synthetic_index := 0
	for scene_value in data.scenes:
		var scene: SceneData = scene_value
		if (
			scene.declared_line == 0
			and (
				scene.id.begins_with("__if_")
				or scene.id.begins_with("__elif_")
			)
		):
			synthetic_scene_ids[scene.id] = "@synthetic:%d" % synthetic_index
			synthetic_index += 1

	var chapters: Array = []
	for chapter_value in data.chapters:
		var chapter: ChapterData = chapter_value
		chapters.append([
			chapter.id,
			chapter.display_name,
			_semantic_value(chapter.scene_ids, synthetic_scene_ids),
		])

	var scenes: Array = []
	for scene_value in data.scenes:
		var scene: SceneData = scene_value
		var commands: Array = []
		for command_value in scene.commands:
			if command_value is CommandData:
				commands.append(_semantic_command(
					command_value, synthetic_scene_ids))
		scenes.append([
			_normalize_scene_reference(scene.id, synthetic_scene_ids),
			scene.chapter_id,
			commands,
			_semantic_value(
				scene.dialogue_mode_events_on_exit, synthetic_scene_ids),
		])

	var semantic_ir := [
		["chapters", chapters],
		["dialogue_profiles", _semantic_value(
			data.dialogue_profiles, synthetic_scene_ids)],
		["scenes", scenes],
	]
	return JSON.stringify(semantic_ir).sha256_text()


static func _semantic_command(
	command: CommandData,
	synthetic_scene_ids: Dictionary,
) -> Array:
	var semantic_params := command.params.duplicate(true)
	if command.type in ["stage_batch", "presentation_batch"]:
		semantic_params.erase("operation_lines")
	if semantic_params.get("segments") is Array:
		var semantic_segments: Array = []
		for segment_value: Variant in semantic_params["segments"]:
			if not segment_value is Dictionary:
				semantic_segments.append(segment_value)
				continue
			var segment := (segment_value as Dictionary).duplicate(true)
			segment.erase("presentation_operation_lines")
			segment["voice_layers"] = _semantic_voice_layers(
				segment.get("voice_layers", []))
			semantic_segments.append(segment)
		semantic_params["segments"] = semantic_segments
	if semantic_params.has("voice_layers"):
		semantic_params["voice_layers"] = _semantic_voice_layers(
			semantic_params["voice_layers"])
	return [
		command.type,
		_semantic_value(semantic_params, synthetic_scene_ids),
		_semantic_value(
			command.dialogue_mode_events_before, synthetic_scene_ids),
		_semantic_value(
			command.dialogue_mode_events_after, synthetic_scene_ids),
		_semantic_value(
			command.dialogue_mode_events_on_true_branch, synthetic_scene_ids),
		_semantic_value(
		command.dialogue_mode_events_on_false_branch, synthetic_scene_ids),
	]


static func _semantic_voice_layers(value: Variant) -> Variant:
	if not value is Array:
		return value
	var result: Array = []
	for layer_value: Variant in value:
		if not layer_value is Dictionary:
			result.append(layer_value)
			continue
		var layer := (layer_value as Dictionary).duplicate(true)
		layer.erase("line")
		result.append(layer)
	return result


static func _semantic_value(
	value: Variant,
	synthetic_scene_ids: Dictionary,
	key_hint: String = "",
) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			var numeric: float = value
			return 0.0 if numeric == 0.0 else numeric
		TYPE_STRING, TYPE_STRING_NAME:
			var text := String(value)
			if key_hint in ["target", "then_jump", "else_jump", "jump"]:
				return _normalize_scene_reference(text, synthetic_scene_ids)
			if key_hint in ["if", "condition"]:
				return ExpressionEvaluator.semantic_key(text)
			return text
		TYPE_VECTOR2:
			var vector: Vector2 = value
			return ["Vector2", vector.x, vector.y]
		TYPE_VECTOR4:
			var vector: Vector4 = value
			return ["Vector4", vector.x, vector.y, vector.z, vector.w]
		TYPE_COLOR:
			var color: Color = value
			return ["Color", color.r, color.g, color.b, color.a]
		TYPE_ARRAY:
			var items: Array = []
			for item in value:
				items.append(_semantic_value(item, synthetic_scene_ids))
			return items
		TYPE_DICTIONARY:
			var dictionary: Dictionary = value
			var keys := dictionary.keys()
			keys.sort_custom(func(a, b): return String(a) < String(b))
			var entries: Array = []
			for key_value in keys:
				var key := String(key_value)
				entries.append([
					key,
					_semantic_value(
						dictionary[key_value], synthetic_scene_ids, key),
				])
			return entries
		TYPE_OBJECT:
			if value is CommandData:
				return _semantic_command(value, synthetic_scene_ids)
	return ["unsupported", type_string(typeof(value))]


static func _normalize_scene_reference(
	scene_id: String,
	synthetic_scene_ids: Dictionary,
) -> String:
	return String(synthetic_scene_ids.get(scene_id, scene_id))


static func _record_parallel_blocking_diagnostic(
	data: ScenarioData,
	command_type: String,
	line: int,
) -> void:
	var message := (
		"DslParser: blocking '%s' command is not allowed inside @parallel (line %d)"
		% [command_type, line]
	)
	if command_type == "chapter_indicator":
		message = (
			"DslParser: blocking 'chapter_indicator' command is not allowed inside @parallel at %s"
			% _source_location(data, line)
		)
	_record_diagnostic(
		data,
		"error",
		message,
		line,
	)


static func _command_contains_chapter_indicator(command: CommandData) -> bool:
	if command == null:
		return false
	if command.type == "chapter_indicator":
		return true
	if command.type != "presentation_batch":
		return false
	for operation_value: Variant in command.params.get("operations", []):
		if (
			operation_value is Dictionary
			and String((operation_value as Dictionary).get("kind", ""))
			== "chapter_indicator"
		):
			return true
	return false


static func _command_contains_operation_kind(
	command: CommandData,
	kind: String,
) -> bool:
	if command == null or command.type != "presentation_batch":
		return false
	for operation_value: Variant in command.params.get("operations", []):
		if (
			operation_value is Dictionary
			and String((operation_value as Dictionary).get("kind", "")) == kind
		):
			return true
	return false


static func _add_command(cmd: CommandData, scene: SceneData, if_stack: Array) -> void:
	if if_stack.size() > 0:
		var ctx = if_stack[-1]
		if ctx["branch"] == "then":
			ctx["then_commands"].append(cmd)
		else:
			ctx["else_commands"].append(cmd)
	else:
		scene.commands.append(cmd)


## Source dialogue-presentation directives participate in control flow but must not
## become addressable commands: inserting them into SceneData.commands would
## shift persisted command indices, read flags, @call return points, and UIDs.
## Parse with temporary sentinels, expand conditions, then lower each sentinel
## onto the next real command on that exact runtime path.
static func _lower_dialogue_mode_events(data: ScenarioData) -> void:
	for scene_value in data.scenes:
		var scene: SceneData = scene_value
		var trailing_events := _lower_dialogue_mode_events_in_list(scene.commands)
		scene.dialogue_mode_events_on_exit.append_array(trailing_events)


static func _lower_dialogue_mode_events_in_list(commands: Array) -> Array:
	var lowered_commands: Array = []
	var pending_events: Array = []
	for command_value in commands:
		var command: CommandData = command_value
		if command.type == INTERNAL_DIALOGUE_MODE_EVENT:
			pending_events.append(command.params.duplicate(true))
			continue

		if command.type == "parallel":
			var child_commands: Array = command.params.get("commands", [])
			var child_trailing := _lower_dialogue_mode_events_in_list(child_commands)
			command.params["commands"] = child_commands
			command.dialogue_mode_events_after.append_array(child_trailing)

		command.dialogue_mode_events_before.append_array(pending_events)
		pending_events.clear()
		lowered_commands.append(command)

	commands.clear()
	commands.append_array(lowered_commands)
	return pending_events


## A branch containing only presentation-selection sentinels has runtime meaning but no
## addressable commands. Move those transitions onto the condition edge before
## synthetic-scene construction decides whether the branch needs its own scene.
## Mixed branches remain untouched and are lowered normally after expansion.
static func _extract_mode_only_branch_events(commands: Array) -> Array:
	var events: Array = []
	if commands.is_empty():
		return events
	for command_value in commands:
		if not (command_value is CommandData):
			return []
		var command: CommandData = command_value
		if command.type != INTERNAL_DIALOGUE_MODE_EVENT:
			return []
		events.append(command.params.duplicate(true))
	commands.clear()
	return events


static func _flush_choice(choice_cmd: CommandData, options: Array, scene: SceneData, if_stack: Array) -> void:
	if choice_cmd and options.size() > 0:
		choice_cmd.params["options"] = options
		if scene:
			_add_command(choice_cmd, scene, if_stack)


# --- Scene directive ---

static func _parse_scene_directive(token: DslToken) -> SceneData:
	var scene = SceneData.new()
	scene.declared_line = token.line
	var text = token.raw_text.substr(7).strip_edges()  # Remove "@scene "
	# Extract quoted title if present
	var quote_start = text.find('"')
	if quote_start == -1:
		quote_start = text.find("\u201c")  # "
	if quote_start != -1:
		scene.id = text.substr(0, quote_start).strip_edges()
	else:
		scene.id = text.split(" ")[0] if text != "" else ""
	return scene


# --- Chapter directive (issue #97) ---

static func _parse_chapter_directive(token: DslToken) -> ChapterData:
	var ch = ChapterData.new()
	ch.declared_line = token.line
	var text = token.raw_text.substr(8).strip_edges()  # Remove "@chapter"
	# Extract quoted display name if present
	var quote_start = text.find('"')
	var quote_end = -1
	if quote_start != -1:
		quote_end = text.find('"', quote_start + 1)
	else:
		quote_start = text.find("\u201c")  # "
		if quote_start != -1:
			quote_end = text.find("\u201d", quote_start + 1)  # "
	if quote_start != -1 and quote_end != -1:
		ch.id = text.substr(0, quote_start).strip_edges()
		ch.display_name = text.substr(quote_start + 1, quote_end - quote_start - 1)
	else:
		ch.id = text.split(" ")[0] if text != "" else ""
		# Fallback: display name == id when no quoted title given
		ch.display_name = ch.id
	return ch


## Record a diagnostic into data.diagnostics. Parser is intentionally silent
## about console reporting — the integration layer (StellaRuntime) is
## responsible for surfacing errors/warnings to the developer after parsing.
## This keeps the parser pure-functional and testable: tests can construct
## small fragments without polluting Godot's error log.
static func _record_diagnostic(data: ScenarioData, level: String, message: String, line: int) -> void:
	data.diagnostics.append({"level": level, "message": message, "line": line})


# --- AT commands ---

static func _get_at_command_name(raw: String) -> String:
	var after_at = raw.substr(1).strip_edges()
	for index in range(after_at.length()):
		if _is_inline_whitespace(after_at.substr(index, 1)):
			return after_at.substr(0, index)
	return after_at


static func _parse_at_command(
	token: DslToken,
	data: ScenarioData,
	lower_standalone_presentation: bool = false,
) -> CommandData:
	var raw = token.raw_text
	var name = _get_at_command_name(raw)
	var name_position := raw.find(name, 1)
	var args = _strip_inline_comment(
		raw.substr(name_position + name.length()).strip_edges()
	)
	var parts = _split_args(args)

	match name:
		"recollection_exit":
			if not parts.is_empty():
				_record_diagnostic(
					data,
					"error",
					"DslParser: @recollection_exit does not accept arguments at %s"
					% _source_location(data, token.line),
					token.line,
				)
				return null
			return _make_cmd("recollection_exit", {})
		"presentation_clip":
			return _parse_presentation_clip_command(parts, token.line, data)
		"chapter_indicator":
			var chapter_command := _parse_chapter_indicator_command(
				parts, token.line, data)
			if chapter_command == null or not lower_standalone_presentation:
				return chapter_command
			var batch_command := _make_cmd("presentation_batch", {
				"policy": "join",
				"operations": [{
					"kind": "chapter_indicator",
					"payload": chapter_command.params.duplicate(true),
				}],
				"operation_lines": [token.line],
			})
			batch_command.declared_line = token.line
			return batch_command
		"dialogue_visibility":
			return _parse_dialogue_visibility_command(
				parts,
				token.line,
				data,
				lower_standalone_presentation,
			)
		"dialogue_avatar":
			return _parse_dialogue_avatar_command(
				parts,
				token.line,
				data,
				lower_standalone_presentation,
			)
		"dialogue_clear":
			return _parse_dialogue_clear_command(
				parts, token.line, data, lower_standalone_presentation)
		"stage":
			return _parse_stage_command(parts, token.line, data)
		"bg":
			return _make_cmd("bg", {
				"asset": parts[0] if parts.size() > 0 else "",
				"transition": parts[1] if parts.size() > 1 else "fade",
				"duration": float(parts[2]) if parts.size() > 2 else 0.5,
			})
		"jump":
			return _make_cmd("jump", {
				"target": parts[0] if parts.size() > 0 else "",
			})
		"call":
			return _make_cmd("call", {
				"target": parts[0] if parts.size() > 0 else "",
			})
		"set":
			return _parse_set_command(args)
		"bgm":
			var bgm_command := _parse_bgm_command(parts, token.line, data)
			if bgm_command == null or not lower_standalone_presentation:
				return bgm_command
			var batch_command := _make_cmd("presentation_batch", {
				"policy": "fire_and_forget",
				"operations": [{
					"kind": "bgm",
					"payload": bgm_command.params.duplicate(true),
				}],
				"operation_lines": [token.line],
			})
			batch_command.declared_line = token.line
			return batch_command
		"se":
			if parts.size() != 1 or String(parts[0]).strip_edges().is_empty():
				_record_diagnostic(
					data,
					"error",
					"DslParser: @se accepts exactly one one-shot asset at %s; use @loop_se <channel> play|stop for persistent audio"
					% _source_location(data, token.line),
					token.line,
				)
				return null
			return _make_cmd("se", {"asset": String(parts[0])})
		"loop_se":
			var loop_se_command := _parse_loop_se_command(
				parts, token.line, data)
			if loop_se_command == null or not lower_standalone_presentation:
				return loop_se_command
			var batch_command := _make_cmd("presentation_batch", {
				"policy": "fire_and_forget",
				"operations": [{
					"kind": "loop_se",
					"payload": loop_se_command.params.duplicate(true),
				}],
				"operation_lines": [token.line],
			})
			batch_command.declared_line = token.line
			return batch_command
		"voice":
			return _make_cmd("voice", {
				"asset": parts[0] if parts.size() > 0 else "",
			})
		"fade":
			return _make_cmd("fade", {
				"direction": parts[0] if parts.size() > 0 else "out",
				"duration": float(parts[1]) if parts.size() > 1 else 0.5,
			})
		"wait":
			return _parse_wait_command(parts, token.line, data)
		"effect":
			if parts.is_empty():
				_record_diagnostic(
					data,
					"error",
					"DslParser: @effect is missing an effect type (line %d)" % token.line,
					token.line,
				)
				return null
			var effect_type: String = parts[0]
			match effect_type:
				"off":
					if parts.size() > 1:
						_record_diagnostic(
							data,
							"error",
							"DslParser: @effect off does not accept arguments (line %d)"
							% token.line,
							token.line,
						)
						return null
					return _make_cmd("effect", {"off": true, "effect_type": "off"})
				"shake":
					if parts.size() > 3:
						_record_diagnostic(
							data,
							"error",
							"DslParser: @effect shake accepts at most intensity and duration (line %d)"
							% token.line,
							token.line,
						)
						return null
					var intensity_value: Variant = 10.0
					var duration_value: Variant = 0.3
					if parts.size() > 1:
						intensity_value = _parse_effect_number(
							parts[1], "shake", "intensity", token, data
						)
					if parts.size() > 2:
						duration_value = _parse_effect_number(
							parts[2], "shake", "duration", token, data
						)

					if intensity_value == null or duration_value == null:
						return null
					var intensity := float(intensity_value)
					var duration := float(duration_value)
					if intensity < 0.0:
						_record_diagnostic(
							data,
							"warning",
							"DslParser: @effect shake intensity is negative; using its absolute value (line %d)"
							% token.line,
							token.line,
						)
						intensity = absf(intensity)
					if duration < 0.0:
						_record_diagnostic(
							data,
							"error",
							"DslParser: @effect shake duration must be non-negative (line %d)"
							% token.line,
							token.line,
						)
						return null
					return _make_cmd("effect", {
						"effect_type": "shake",
						"intensity": intensity,
						"duration": duration,
					})
				"flash":
					if parts.size() > 3:
						_record_diagnostic(
							data,
							"error",
							"DslParser: @effect flash accepts at most color and duration (line %d)"
							% token.line,
							token.line,
						)
						return null
					var duration_value: Variant = 0.2
					if parts.size() > 2:
						duration_value = _parse_effect_number(
							parts[2], "flash", "duration", token, data
						)
					if duration_value == null:
						return null
					var duration := float(duration_value)
					if duration < 0.0:
						_record_diagnostic(
							data,
							"error",
							"DslParser: @effect flash duration must be non-negative (line %d)"
							% token.line,
							token.line,
						)
						return null
					return _make_cmd("effect", {
						"effect_type": "flash",
						"color": parts[1] if parts.size() > 1 else "white",
						"duration": duration,
					})
				_:
					_record_diagnostic(
						data,
						"warning",
						"DslParser: @effect '%s' is not built in; forwarding it to custom listeners (line %d)"
						% [effect_type, token.line],
						token.line,
					)
					return _make_cmd("effect", {
						"effect_type": effect_type,
						"args": parts.slice(1),
					})
		"end":
			return null  # Handled by if_stack or ignored
		_:
			_record_diagnostic(
				data,
				"error",
				"DslParser: unknown command '@%s' (line %d)" % [name, token.line],
				token.line,
			)
			return null


static func _parse_chapter_indicator_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty() or String(parts[0]).contains("="):
		_record_diagnostic(
			data,
			"error",
			"DslParser: @chapter_indicator requires a show or hide action at %s"
			% location,
			line,
		)
		return null
	var action := String(parts[0]).to_lower()
	if action not in _CHAPTER_INDICATOR_ACTIONS:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @chapter_indicator action '%s' at %s"
			% [parts[0], location],
			line,
		)
		return null

	var transition := "cut"
	var duration := 0.0
	var duration_was_set := false
	var seen: Dictionary = {}
	var invalid := false
	for index in range(1, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @chapter_indicator argument '%s' at %s; use key=value"
				% [encoded, location],
				line,
			)
			invalid = true
			continue
		var key := encoded.substr(0, equals_at).strip_edges().to_lower()
		var raw_value := encoded.substr(equals_at + 1).strip_edges()
		if seen.has(key):
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @chapter_indicator option '%s' at %s"
				% [key, location],
				line,
			)
			invalid = true
			continue
		seen[key] = true
		match key:
			"transition":
				if raw_value.to_lower() not in _CHAPTER_INDICATOR_TRANSITIONS:
					_record_diagnostic(
						data,
						"error",
						"DslParser: invalid @chapter_indicator transition '%s' at %s"
						% [raw_value, location],
						line,
					)
					invalid = true
				else:
					transition = raw_value.to_lower()
			"duration":
				duration_was_set = true
				var duration_result := _parse_non_negative_duration(raw_value)
				if not bool(duration_result.get("valid", false)):
					_record_diagnostic(
						data,
						"error",
						"DslParser: @chapter_indicator duration must be %s at %s"
						% [duration_result.get("requirement", "finite"), location],
						line,
					)
					invalid = true
				else:
					duration = float(duration_result.get("value", 0.0))
			_:
				_record_diagnostic(
					data,
					"error",
					"DslParser: unknown @chapter_indicator option '%s' at %s"
					% [key, location],
					line,
				)
				invalid = true

	if invalid:
		return null
	if transition == "none":
		transition = "cut"
	if transition == "fade" and not duration_was_set:
		duration = 0.25
	if transition == "cut" and duration != 0.0:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @chapter_indicator cut transition requires duration=0 at %s"
			% location,
			line,
		)
		return null
	return _make_cmd("chapter_indicator", {
		"action": action,
		"transition": transition,
		"duration": duration,
	})


static func _parse_wait_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @wait requires a duration or click at %s" % location,
			line,
		)
		return null

	var first := String(parts[0])
	if first == "click":
		if parts.size() != 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: @wait click does not accept options at %s" % location,
				line,
			)
			return null
		return _make_cmd("wait", {"mode": "click"})

	var duration_result := _parse_non_negative_duration(first)
	if not bool(duration_result.get("valid", false)):
		_record_diagnostic(
			data,
			"error",
			"DslParser: @wait duration must be finite and non-negative at %s"
			% location,
			line,
		)
		return null

	var skippable := false
	var seen_skippable := false
	var invalid := false
	for index in range(1, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @wait argument '%s' at %s; use skippable=true|false"
				% [encoded, location],
				line,
			)
			invalid = true
			continue
		var key := encoded.substr(0, equals_at).strip_edges()
		var raw_value := encoded.substr(equals_at + 1).strip_edges()
		if key != "skippable":
			_record_diagnostic(
				data,
				"error",
				"DslParser: unknown @wait option '%s' at %s" % [key, location],
				line,
			)
			invalid = true
			continue
		if seen_skippable:
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @wait option 'skippable' at %s" % location,
				line,
			)
			invalid = true
			continue
		seen_skippable = true
		if raw_value not in ["true", "false"]:
			_record_diagnostic(
				data,
				"error",
				"DslParser: @wait skippable must be true or false at %s" % location,
				line,
			)
			invalid = true
			continue
		skippable = raw_value == "true"
	if invalid:
		return null
	return _make_cmd("wait", {
		"duration": float(duration_result.get("value", 0.0)),
		"mode": "timer",
		"skippable": skippable,
	})


static func _parse_loop_se_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.size() < 2:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @loop_se requires <channel> play|stop at %s" % location,
			line,
		)
		return null
	var channel_id := String(parts[0])
	if not LoopSeChannelState.is_valid_channel_id(channel_id):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @loop_se channel '%s' at %s; use an ASCII identifier beginning with a letter or underscore"
			% [channel_id, location],
			line,
		)
		return null
	var action := String(parts[1])
	if action not in _LOOP_SE_ACTIONS:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @loop_se action '%s' at %s; expected play or stop"
			% [action, location],
			line,
		)
		return null

	var option_start := 2
	var asset := ""
	if action == "play":
		if parts.size() < 3 or String(parts[2]).contains("="):
			_record_diagnostic(
				data,
				"error",
				"DslParser: @loop_se play requires an asset at %s" % location,
				line,
			)
			return null
		asset = String(parts[2])
		option_start = 3

	var volume := 1.0
	var fade_duration := 0.0
	var seen: Dictionary = {}
	var invalid := false
	for index in range(option_start, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @loop_se argument '%s' at %s; use key=value"
				% [encoded, location],
				line,
			)
			invalid = true
			continue
		var key := encoded.substr(0, equals_at).strip_edges()
		var raw_value := encoded.substr(equals_at + 1).strip_edges()
		if key != key.to_lower():
			_record_diagnostic(
				data,
				"error",
				"DslParser: @loop_se option names are lowercase; found '%s' at %s"
				% [key, location],
				line,
			)
			invalid = true
			continue
		if seen.has(key):
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @loop_se option '%s' at %s" % [key, location],
				line,
			)
			invalid = true
			continue
		seen[key] = true
		var number_result := _parse_non_negative_duration(raw_value)
		match key:
			"fade":
				if not bool(number_result.get("valid", false)):
					_record_diagnostic(
						data,
						"error",
						"DslParser: @loop_se fade must be finite and non-negative at %s"
						% location,
						line,
					)
					invalid = true
				else:
					fade_duration = float(number_result.get("value", 0.0))
			"volume":
				if action != "play":
					_record_diagnostic(
						data,
						"error",
						"DslParser: @loop_se stop does not accept volume at %s" % location,
						line,
					)
					invalid = true
				elif (
					not bool(number_result.get("valid", false))
					or float(number_result.get("value", -1.0)) > 1.0
				):
					_record_diagnostic(
						data,
						"error",
						"DslParser: @loop_se volume must be finite and between 0 and 1 at %s"
						% location,
						line,
					)
					invalid = true
				else:
					volume = float(number_result.get("value", 1.0))
			_:
				_record_diagnostic(
					data,
					"error",
					"DslParser: unknown @loop_se option '%s' at %s" % [key, location],
					line,
				)
				invalid = true
	if invalid:
		return null
	var payload := {
		"action": action,
		"asset": asset,
		"channel": channel_id,
		"fade_duration": fade_duration,
		"resume_position": 0.0,
		"volume": volume,
	}
	if not LoopSeChannelState.validate_operation(payload, false):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid canonical @loop_se operation at %s" % location,
			line,
		)
		return null
	return _make_cmd("loop_se", payload)


static func _parse_bgm_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @bgm requires play, mix, pause, resume, or stop at %s"
			% location,
			line,
		)
		return null
	var action := String(parts[0])
	if action not in _BGM_ACTIONS:
		var message := (
			"DslParser: invalid @bgm action '%s' at %s; expected play, mix, pause, resume, or stop"
			% [action, location]
		)
		if action == "off" or action == action.to_lower():
			message = (
				"DslParser: legacy @bgm asset/off syntax is not supported at %s; use @bgm play <asset> or @bgm stop"
				% location
			)
		_record_diagnostic(data, "error", message, line)
		return null

	var option_start := 1
	var asset := ""
	var stem_mix: Dictionary = {}
	if action == "play":
		if parts.size() < 2 or String(parts[1]).contains("="):
			_record_diagnostic(
				data,
				"error",
				"DslParser: @bgm play requires an asset at %s" % location,
				line,
			)
			return null
		asset = String(parts[1])
		option_start = 2
	elif action == "mix":
		if parts.size() < 2 or String(parts[1]).contains("="):
			_record_diagnostic(
				data,
				"error",
				"DslParser: @bgm mix requires a stem mix at %s" % location,
				line,
			)
			return null
		var mix_result := _parse_bgm_stem_mix(String(parts[1]))
		if not bool(mix_result.get("valid", false)):
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @bgm stem mix at %s: %s"
				% [location, String(mix_result.get("error", "invalid stem mix"))],
				line,
			)
			return null
		stem_mix = (mix_result["value"] as Dictionary).duplicate(true)
		option_start = 2

	var cue := ""
	var fade_duration := 0.0
	var volume := 1.0
	var seen: Dictionary = {}
	var invalid := false
	for index in range(option_start, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @bgm argument '%s' at %s; use key=value"
				% [encoded, location],
				line,
			)
			invalid = true
			continue
		var key := encoded.substr(0, equals_at).strip_edges()
		var raw_value := encoded.substr(equals_at + 1).strip_edges()
		if key != key.to_lower():
			_record_diagnostic(
				data,
				"error",
				"DslParser: @bgm option names are lowercase; found '%s' at %s"
				% [key, location],
				line,
			)
			invalid = true
			continue
		if seen.has(key):
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @bgm option '%s' at %s" % [key, location],
				line,
			)
			invalid = true
			continue
		seen[key] = true
		match key:
			"fade":
				var duration_result := _parse_non_negative_duration(raw_value)
				if not bool(duration_result.get("valid", false)):
					_record_diagnostic(
						data,
						"error",
						"DslParser: @bgm fade must be finite and non-negative at %s"
						% location,
						line,
					)
					invalid = true
				else:
					fade_duration = float(duration_result.get("value", 0.0))
			"volume":
				if action != "play":
					_record_diagnostic(
						data,
						"error",
						"DslParser: @bgm %s does not accept volume at %s"
						% [action, location],
						line,
					)
					invalid = true
				else:
					var volume_result := _parse_non_negative_duration(raw_value)
					if (
						not bool(volume_result.get("valid", false))
						or float(volume_result.get("value", -1.0)) > 1.0
					):
						_record_diagnostic(
							data,
							"error",
							"DslParser: @bgm volume must be finite and between 0 and 1 at %s"
							% location,
							line,
						)
						invalid = true
					else:
						volume = float(volume_result.get("value", 1.0))
			"cue":
				if action != "play":
					_record_diagnostic(
						data,
						"error",
						"DslParser: @bgm %s does not accept cue at %s"
						% [action, location],
						line,
					)
					invalid = true
				elif not BgmChannelState.is_valid_cue_name(raw_value, false):
					_record_diagnostic(
						data,
						"error",
						"DslParser: invalid @bgm cue '%s' at %s"
						% [raw_value, location],
						line,
					)
					invalid = true
				else:
					cue = raw_value
			"mix":
				if action != "play":
					_record_diagnostic(
						data,
						"error",
						"DslParser: @bgm %s does not accept mix at %s"
						% [action, location],
						line,
					)
					invalid = true
				else:
					var mix_result := _parse_bgm_stem_mix(raw_value)
					if not bool(mix_result.get("valid", false)):
						_record_diagnostic(
							data,
							"error",
							"DslParser: invalid @bgm stem mix at %s: %s"
							% [location, String(mix_result.get(
								"error", "invalid stem mix"))],
							line,
						)
						invalid = true
					else:
						stem_mix = (mix_result["value"] as Dictionary).duplicate(true)
			_:
				_record_diagnostic(
					data,
					"error",
					"DslParser: unknown @bgm option '%s' at %s" % [key, location],
					line,
				)
				invalid = true
	if invalid:
		return null
	var payload := {
		"action": action,
		"asset": asset,
		"cue": cue,
		"fade_duration": fade_duration,
		"resume_position": 0.0,
		"stem_mix": stem_mix,
		"volume": volume,
	}
	if not BgmChannelState.validate_operation(payload, false):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid canonical @bgm operation at %s" % location,
			line,
		)
		return null
	return _make_cmd("bgm", payload)


static func _parse_bgm_stem_mix(encoded: String) -> Dictionary:
	if encoded.is_empty():
		return {"valid": false, "error": "stem mix must not be empty"}
	var parsed: Dictionary = {}
	var has_audible_stem := false
	for raw_entry: String in encoded.split(",", true):
		if raw_entry.is_empty():
			return {"valid": false, "error": "stem mix contains an empty stem"}
		var pieces := raw_entry.split(":", true)
		if pieces.size() > 2:
			return {"valid": false, "error": "stem entry must be name[:gain]"}
		var stem_name := String(pieces[0])
		if not BgmChannelState.is_valid_stem_name(stem_name):
			return {"valid": false, "error": "stem '%s' is invalid" % stem_name}
		if parsed.has(stem_name):
			return {"valid": false, "error": "duplicate stem '%s'" % stem_name}
		var gain := 1.0
		if pieces.size() == 2:
			var gain_result := _parse_non_negative_duration(String(pieces[1]))
			if not bool(gain_result.get("valid", false)):
				var requirement := String(gain_result.get("requirement", "finite"))
				return {
					"valid": false,
					"error": (
						"stem gain must be between 0 and 1"
						if requirement == "non-negative"
						else "stem gain must be finite"
					),
				}
			gain = float(gain_result.get("value", -1.0))
			if gain > 1.0:
				return {
					"valid": false,
					"error": "stem gain must be between 0 and 1",
				}
		parsed[stem_name] = gain
		has_audible_stem = has_audible_stem or gain > 0.0
	if not has_audible_stem:
		return {"valid": false, "error": "stem mix must not be all zero"}
	var names := parsed.keys()
	names.sort()
	var canonical: Dictionary = {}
	for stem_name: Variant in names:
		canonical[String(stem_name)] = float(parsed[stem_name])
	return {"valid": true, "value": canonical}


static func _parse_non_negative_duration(encoded: String) -> Dictionary:
	if not encoded.is_valid_float():
		return {"valid": false, "requirement": "finite"}
	var normalized := encoded.strip_edges().to_lower()
	var exponent_at := normalized.find("e")
	if exponent_at >= 0:
		var exponent_text := normalized.substr(exponent_at + 1)
		var exponent_negative := exponent_text.begins_with("-")
		if exponent_text.begins_with("+") or exponent_negative:
			exponent_text = exponent_text.substr(1)
		exponent_text = exponent_text.lstrip("0")
		# Godot reports an engine-level "Exponent too high" before returning INF
		# for gross positive exponents. Reject lexically before any conversion.
		var exponent_is_gross := (
			exponent_text.length() > 3
			or (
				exponent_text.length() == 3
				and exponent_text > "308"
			)
		)
		if exponent_is_gross:
			# Zero has no representational overflow or underflow regardless of
			# exponent spelling. Avoid Godot's noisy conversion path while retaining
			# the canonical legal duration=0 value.
			if not _float_spelling_has_nonzero_significand(normalized):
				return {"valid": true, "value": 0.0}
			if not exponent_negative:
				return {"valid": false, "requirement": "finite"}
			if _negative_nonzero_float_spelling(normalized):
				return {"valid": false, "requirement": "non-negative"}
			return {"valid": true, "value": 0.0}
	var value := normalized.to_float()
	if not is_finite(value):
		return {"valid": false, "requirement": "finite"}
	if value < 0.0 or (
		value == 0.0 and _negative_nonzero_float_spelling(normalized)
	):
		return {"valid": false, "requirement": "non-negative"}
	return {"valid": true, "value": value}


static func _negative_nonzero_float_spelling(encoded: String) -> bool:
	return (
		encoded.begins_with("-")
		and _float_spelling_has_nonzero_significand(encoded)
	)


static func _float_spelling_has_nonzero_significand(encoded: String) -> bool:
	var significand := encoded
	if significand.begins_with("-") or significand.begins_with("+"):
		significand = significand.substr(1)
	var exponent_at := significand.find("e")
	if exponent_at >= 0:
		significand = significand.substr(0, exponent_at)
	for character in significand:
		if character >= "1" and character <= "9":
			return true
	return false


static func _source_location(data: ScenarioData, line: int) -> String:
	var source := data.source_path
	if source.is_empty():
		source = data.id
	return "%s:%d" % [source, line]


static func _parse_stage_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	if parts.is_empty():
		_record_diagnostic(
			data,
			"warning",
			"DslParser: @stage requires a layer id or 'clear' (line %d)" % line,
			line,
		)
		return null

	var layer_id := str(parts[0]).strip_edges()
	var action := "show"
	var property_start := 1
	if layer_id == "clear":
		action = "clear"
		layer_id = ""
	elif parts.size() > 1:
		var action_candidate := str(parts[1]).to_lower()
		if action_candidate in ["show", "update", "hide", "remove"]:
			action = action_candidate
			property_start = 2
		elif not action_candidate.contains("="):
			_record_diagnostic(
				data,
				"warning",
				"DslParser: unknown @stage action '%s' (line %d)"
				% [action_candidate, line],
				line,
			)
			return null
	var properties: Dictionary = {}
	var redraw_effects: Array = []
	var redraw_seen := false
	var redraw_cleared := false
	var redraw_clip_seen := false
	var redraw_blur_count := 0
	var transition := "cut"
	var transition_params: Dictionary = {}
	var duration := 0.0
	var invalid_operation := false
	for index in range(property_start, parts.size()):
		var encoded := str(parts[index])
		var equals_at := encoded.find("=")
		if equals_at == -1:
			_record_diagnostic(
				data,
				"warning",
				"DslParser: invalid @stage argument '%s' (line %d); use key=value"
				% [encoded, line],
				line,
			)
			invalid_operation = true
			continue
		var key := encoded.substr(0, equals_at).strip_edges().to_lower()
		var raw_value := encoded.substr(equals_at + 1).strip_edges()
		if key == "":
			_record_diagnostic(
				data,
				"warning",
				"DslParser: @stage property name cannot be empty (line %d)" % line,
				line,
			)
			invalid_operation = true
			continue
		if key == "transition":
			var parsed_transition := _parse_stage_transition_expression(
				raw_value, line, data)
			if not bool(parsed_transition.get("valid", false)):
				_record_diagnostic(
					data,
					"warning",
					"DslParser: invalid @stage transition '%s': %s (line %d)"
					% [
						raw_value,
						String(parsed_transition.get("error", "invalid transition expression")),
						line,
					],
					line,
				)
				invalid_operation = true
				continue
			transition = String(parsed_transition["kind"])
			transition_params = (
				parsed_transition["params"] as Dictionary).duplicate(true)
		elif key == "duration":
			if (
				not _is_finite_stage_number(raw_value)
				or float(raw_value) < 0.0
			):
				_record_diagnostic(
					data,
					"warning",
					"DslParser: @stage duration must be a finite non-negative number, got '%s' (line %d)"
					% [raw_value, line],
					line,
				)
				invalid_operation = true
				continue
			duration = float(raw_value)
		elif key == "redraw":
			if action in ["hide", "remove", "clear"]:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @stage %s does not accept layer property 'redraw' (line %d)"
					% [action, line],
					line,
				)
				invalid_operation = true
				continue
			if raw_value.to_lower() == "clear":
				if redraw_seen:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @stage redraw=clear cannot be mixed with other redraw values (line %d)"
						% line,
						line,
					)
					invalid_operation = true
				redraw_seen = true
				redraw_cleared = true
				continue
			if redraw_cleared:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @stage redraw=clear cannot be mixed with other redraw values (line %d)"
					% line,
					line,
				)
				invalid_operation = true
				continue
			redraw_seen = true
			var redraw_effect = _parse_stage_redraw_effect(
				raw_value,
				line,
				data,
			)
			if redraw_effect == null:
				invalid_operation = true
				continue
			var redraw_effect_type := String(redraw_effect.get("type", ""))
			if redraw_effect_type == "clip":
				if redraw_clip_seen:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @stage redraw accepts at most one clip effect (line %d)"
						% line,
						line,
					)
					invalid_operation = true
					continue
				redraw_clip_seen = true
			elif redraw_effect_type == "blur":
				redraw_blur_count += 1
				if redraw_blur_count > StageLayerState.MAX_BLUR_PASSES:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @stage redraw accepts at most %d blur effects (line %d)"
						% [StageLayerState.MAX_BLUR_PASSES, line],
						line,
					)
					invalid_operation = true
					continue
			redraw_effects.append(redraw_effect)
			if redraw_effects.size() > StageLayerState.MAX_REDRAW_EFFECTS:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @stage accepts at most %d redraw effects (line %d)"
					% [StageLayerState.MAX_REDRAW_EFFECTS, line],
					line,
				)
				invalid_operation = true
		else:
			if not _is_known_stage_property(key):
				_record_diagnostic(
					data,
					"error",
					"DslParser: unknown @stage property '%s' (line %d)"
					% [key, line],
					line,
				)
				invalid_operation = true
				continue
			if action in ["hide", "remove", "clear"]:
				_record_diagnostic(
					data,
					"error",
					"DslParser: @stage %s does not accept layer property '%s' (line %d)"
					% [action, key, line],
					line,
				)
				invalid_operation = true
				continue
			var parsed_value = _parse_stage_property_value(
				key, raw_value, line, data
			)
			if parsed_value == null:
				invalid_operation = true
				continue
			if not _is_stage_property_in_range(key, parsed_value, line, data):
				invalid_operation = true
				continue
			properties[key] = parsed_value

	if invalid_operation:
		return null
	if transition == "cut" and duration != 0.0:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @stage cut/none transition requires duration=0 (line %d)" % line,
			line,
		)
		return null
	if redraw_seen:
		properties["redraw"] = redraw_effects

	var operation := {
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition": transition,
		"transition_params": transition_params,
		"duration": duration,
	}
	if not StageLayerState.validate_operation(operation, false):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @stage operation (line %d)" % line,
			line,
		)
		return null
	return _make_cmd("stage_layer", operation)


static func _parse_stage_transition_expression(
	encoded: String,
	_line: int,
	_data: ScenarioData,
) -> Dictionary:
	var normalized := encoded.strip_edges()
	if normalized.is_empty():
		return {"valid": false, "error": "transition kind cannot be empty"}
	var kind := normalized
	var raw_params := {}
	var open_at := normalized.find("(")
	if open_at >= 0:
		if (
			open_at == 0
			or not normalized.ends_with(")")
			or normalized.find("(", open_at + 1) >= 0
			or normalized.substr(open_at + 1, normalized.length() - open_at - 2).contains(")")
		):
			return {"valid": false, "error": "malformed transition expression"}
		kind = normalized.substr(0, open_at).strip_edges()
		var body := normalized.substr(
			open_at + 1,
			normalized.length() - open_at - 2,
		).strip_edges()
		if body.is_empty():
			return {"valid": false, "error": "transition expression requires parameters"}
		for item_value: Variant in body.split(",", true):
			var item := String(item_value).strip_edges()
			if item.is_empty():
				return {"valid": false, "error": "empty transition parameter"}
			var equals_at := item.find("=")
			if equals_at <= 0:
				return {
					"valid": false,
					"error": "transition parameter '%s' must use key=value" % item,
				}
			var parameter_name := item.substr(0, equals_at).strip_edges()
			var raw_value := item.substr(equals_at + 1).strip_edges()
			if raw_params.has(parameter_name):
				return {
					"valid": false,
					"error": "duplicate transition parameter '%s'" % parameter_name,
				}
			if raw_value.is_empty():
				return {
					"valid": false,
					"error": "transition parameter '%s' cannot be empty" % parameter_name,
				}
			var typed_value := _parse_stage_transition_parameter(raw_value)
			if not bool(typed_value.get("valid", false)):
				return {
					"valid": false,
					"error": "transition parameter '%s' %s" % [
						parameter_name,
						String(typed_value.get("error", "is invalid")),
					],
				}
			raw_params[parameter_name] = typed_value["value"]
	elif normalized.contains(")"):
		return {"valid": false, "error": "malformed transition expression"}
	return StageTransitionSpec.canonicalize(kind, raw_params)


static func _parse_stage_transition_parameter(encoded: String) -> Dictionary:
	if encoded == "true":
		return {"valid": true, "value": true}
	if encoded == "false":
		return {"valid": true, "value": false}
	if encoded.is_valid_int():
		return {"valid": true, "value": int(encoded)}
	if encoded.is_valid_float():
		var number := float(encoded)
		if not is_finite(number):
			return {"valid": false, "error": "must be finite"}
		return {"valid": true, "value": number}
	return {"valid": true, "value": encoded}


static func _parse_stage_redraw_effect(
	encoded: String,
	line: int,
	data: ScenarioData,
) -> Variant:
	var open_paren := encoded.find("(")
	if open_paren <= 0 or not encoded.ends_with(")"):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @stage redraw effect '%s' (line %d)"
			% [encoded, line],
			line,
		)
		return null
	var effect_type := encoded.substr(0, open_paren).strip_edges().to_lower()
	var arguments_text := encoded.substr(
		open_paren + 1,
		encoded.length() - open_paren - 2,
	)
	var arguments: Array = []
	if not arguments_text.is_empty():
		for argument in arguments_text.split(",", true):
			arguments.append(String(argument).strip_edges())

	match effect_type:
		"color_overlay":
			if arguments.size() not in [1, 2]:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			var color := _canonical_stage_redraw_color(String(arguments[0]))
			if color == "":
				return _invalid_stage_redraw_value(
					effect_type, "color", String(arguments[0]), line, data
				)
			var blend := (
				String(arguments[1]).to_lower()
				if arguments.size() == 2
				else "normal"
			)
			if blend not in StageLayerState.VALID_COLOR_OVERLAY_BLEND_MODES:
				return _invalid_stage_redraw_value(
					effect_type, "blend", blend, line, data
				)
			return {"type": effect_type, "color": color, "blend": blend}
		"tint":
			if arguments.size() != 1:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			var color := _canonical_stage_redraw_color(String(arguments[0]))
			if color == "":
				return _invalid_stage_redraw_value(
					effect_type, "color", String(arguments[0]), line, data
				)
			return {"type": effect_type, "color": color}
		"brightness_contrast":
			if arguments.size() != 2:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			if (
				not String(arguments[0]).is_valid_int()
				or int(arguments[0]) < -255
				or int(arguments[0]) > 255
			):
				return _invalid_stage_redraw_value(
					effect_type, "brightness", String(arguments[0]), line, data
				)
			if (
				not String(arguments[1]).is_valid_int()
				or int(arguments[1]) < -100
				or int(arguments[1]) > 100
			):
				return _invalid_stage_redraw_value(
					effect_type, "contrast", String(arguments[1]), line, data
				)
			return {
				"type": effect_type,
				"brightness": int(arguments[0]),
				"contrast": int(arguments[1]),
			}
		"grayscale":
			if arguments.size() != 1:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			if (
				not _is_finite_stage_number(String(arguments[0]))
				or float(arguments[0]) < 0.0
				or float(arguments[0]) > 1.0
			):
				return _invalid_stage_redraw_value(
					effect_type, "amount", String(arguments[0]), line, data
				)
			return {"type": effect_type, "amount": float(arguments[0])}
		"blur":
			if arguments.size() != 2:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			for argument in arguments:
				if (
					not String(argument).is_valid_int()
					or int(argument) < 0
					or int(argument) > StageLayerState.MAX_BLUR_RADIUS
				):
					return _invalid_stage_redraw_value(
						effect_type, "radius", String(argument), line, data
					)
			return {
				"type": effect_type,
				"radius": [int(arguments[0]), int(arguments[1])],
			}
		"clip":
			if arguments.size() not in [3, 4]:
				return _invalid_stage_redraw_arguments(effect_type, line, data)
			var asset := String(arguments[0]).strip_edges()
			if asset == "":
				return _invalid_stage_redraw_value(
					effect_type, "asset", asset, line, data
				)
			for argument_index in [1, 2]:
				if not _is_finite_stage_number(String(arguments[argument_index])):
					return _invalid_stage_redraw_value(
						effect_type,
						"offset",
						String(arguments[argument_index]),
						line,
						data,
					)
			var clip_fit := (
				String(arguments[3]).to_lower()
				if arguments.size() == 4
				else "native"
			)
			if clip_fit not in _STAGE_FIT_MODES:
				return _invalid_stage_redraw_value(
					effect_type, "fit", clip_fit, line, data
				)
			return {
				"type": effect_type,
				"asset": asset,
				"offset": [float(arguments[1]), float(arguments[2])],
				"fit": clip_fit,
			}
		_:
			_record_diagnostic(
				data,
				"error",
				"DslParser: unknown @stage redraw effect '%s' (line %d)"
				% [effect_type, line],
				line,
			)
			return null


static func _invalid_stage_redraw_arguments(
	effect_type: String,
	line: int,
	data: ScenarioData,
) -> Variant:
	_record_diagnostic(
		data,
		"error",
		"DslParser: invalid arguments for @stage redraw %s (line %d)"
		% [effect_type, line],
		line,
	)
	return null


static func _parse_stage_batch_header(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> Dictionary:
	var policy := ""
	var policy_seen := false
	var valid := true
	for raw_part: Variant in parts:
		var encoded := String(raw_part)
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @stage_batch argument '%s' at %s; use policy=value"
				% [encoded, _source_location(data, line)],
				line,
			)
			valid = false
			continue
		var key := encoded.substr(0, equals_at).strip_edges()
		var value := encoded.substr(equals_at + 1).strip_edges()
		if key != "policy":
			_record_diagnostic(
				data,
				"error",
				"DslParser: unknown @stage_batch option '%s' at %s"
				% [key, _source_location(data, line)],
				line,
			)
			valid = false
			continue
		if policy_seen:
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @stage_batch policy at %s"
				% _source_location(data, line),
				line,
			)
			valid = false
			continue
		policy_seen = true
		policy = value
	if not policy_seen or policy.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @stage_batch policy is required at %s"
			% _source_location(data, line),
			line,
		)
		valid = false
	elif policy not in ["join", "fire_and_forget"]:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @stage_batch policy '%s' at %s"
			% [policy, _source_location(data, line)],
			line,
		)
		valid = false
	return {"valid": valid, "policy": policy}


static func _parse_presentation_batch_header(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> Dictionary:
	var result := _parse_stage_batch_header(parts, line, data)
	if not bool(result.get("valid", false)):
		return result
	return result


static func _parse_presentation_clip_command(
	parts: Array,
	line: int,
	data: ScenarioData,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty() or parts.size() > 2:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @presentation_clip requires one logical definition id and optional policy=join|fire_and_forget at %s"
			% location,
			line,
		)
		return null
	var asset := String(parts[0])
	if not PresentationClipDefinition.is_logical_id(asset):
		_record_diagnostic(
			data,
			"error",
			"DslParser: @presentation_clip definition id is not canonical at %s"
			% location,
			line,
		)
		return null
	var policy := "join"
	if parts.size() == 2:
		var option := String(parts[1])
		if not option.begins_with("policy="):
			_record_diagnostic(
				data,
				"error",
				"DslParser: @presentation_clip only accepts policy=join|fire_and_forget at %s"
				% location,
				line,
			)
			return null
		policy = option.trim_prefix("policy=")
		if policy not in ["join", "fire_and_forget"]:
			_record_diagnostic(
				data,
				"error",
				"DslParser: @presentation_clip policy must be join or fire_and_forget at %s"
				% location,
				line,
			)
			return null
	var command := _make_cmd("presentation_clip", {
		"asset": asset,
		"policy": policy,
	})
	command.declared_line = line
	return command


static func _parse_dialogue_visibility_command(
	parts: Array,
	line: int,
	data: ScenarioData,
	lower_to_presentation_batch: bool = false,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @dialogue_visibility requires an action at %s"
			% location,
			line,
		)
		return null
	var first := String(parts[0])
	var target := "surface"
	var action := ""
	var option_start := 1
	if first in _DIALOGUE_VISIBILITY_ACTIONS:
		action = first
	elif first in _DIALOGUE_VISIBILITY_TARGETS:
		target = first
		if parts.size() < 2:
			_record_diagnostic(
				data,
				"error",
				"DslParser: @dialogue_visibility requires an action after target '%s' at %s"
				% [target, location],
				line,
			)
			return null
		action = String(parts[1])
		option_start = 2
	else:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @dialogue_visibility first token '%s' at %s; expected show|hide or surface|quick_menu"
			% [first, location],
			line,
		)
		return null
	if action not in _DIALOGUE_VISIBILITY_ACTIONS:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @dialogue_visibility action '%s' at %s"
			% [action, location],
			line,
		)
		return null
	var transition := "cut"
	var duration := 0.0
	var duration_set := false
	var seen: Dictionary = {}
	for index in range(option_start, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @dialogue_visibility argument '%s' at %s; use key=value"
				% [encoded, location],
				line,
			)
			return null
		var key := encoded.substr(0, equals_at).strip_edges()
		var value := encoded.substr(equals_at + 1).strip_edges()
		if seen.has(key):
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @dialogue_visibility option '%s' at %s"
				% [key, location],
				line,
			)
			return null
		seen[key] = true
		match key:
			"transition":
				if value not in _DIALOGUE_VISIBILITY_TRANSITIONS:
					_record_diagnostic(
						data,
						"error",
						"DslParser: invalid @dialogue_visibility transition '%s' at %s"
						% [value, location],
						line,
					)
					return null
				transition = value
			"duration":
				if not value.is_valid_float() or not is_finite(value.to_float()) or value.to_float() < 0.0:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @dialogue_visibility duration must be finite and non-negative at %s"
						% location,
						line,
					)
					return null
				duration_set = true
				duration = value.to_float()
			_:
				_record_diagnostic(
					data,
					"error",
					"DslParser: unknown @dialogue_visibility option '%s' at %s"
					% [key, location],
					line,
				)
				return null
	if transition == "fade" and not duration_set:
		duration = 0.25
	if transition == "cut" and duration != 0.0:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @dialogue_visibility cut transition requires duration=0 at %s"
			% location,
			line,
		)
		return null
	var payload := {
		"target": target,
		"action": action,
		"transition": transition,
		"duration": duration,
	}
	if lower_to_presentation_batch:
		var batch_command := _make_cmd("presentation_batch", {
			"policy": "join",
			"operations": [{
				"kind": "dialogue_visibility",
				"payload": payload.duplicate(true),
			}],
			"operation_lines": [line],
		})
		batch_command.declared_line = line
		return batch_command
	return _make_cmd("dialogue_visibility", payload)


static func _parse_dialogue_avatar_command(
	parts: Array,
	line: int,
	data: ScenarioData,
	lower_to_presentation_batch: bool = false,
) -> CommandData:
	var location := _source_location(data, line)
	if parts.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @dialogue_avatar requires set|show|hide|remove at %s"
			% location,
			line,
		)
		return null
	var action := String(parts[0])
	if action not in _DIALOGUE_AVATAR_ACTIONS:
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @dialogue_avatar action '%s' at %s"
			% [action, location],
			line,
		)
		return null
	var transition := "cut"
	var duration := 0.0
	var duration_set := false
	var properties: Dictionary = {}
	var seen: Dictionary = {}
	for index in range(1, parts.size()):
		var encoded := String(parts[index])
		var equals_at := encoded.find("=")
		if equals_at < 1:
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @dialogue_avatar argument '%s' at %s; use key=value"
				% [encoded, location],
				line,
			)
			return null
		var key := encoded.substr(0, equals_at).strip_edges()
		var value := encoded.substr(equals_at + 1).strip_edges()
		if seen.has(key):
			_record_diagnostic(
				data,
				"error",
				"DslParser: duplicate @dialogue_avatar option '%s' at %s"
				% [key, location],
				line,
			)
			return null
		seen[key] = true
		match key:
			"transition":
				if value not in _DIALOGUE_AVATAR_TRANSITIONS:
					_record_diagnostic(
						data,
						"error",
						"DslParser: invalid @dialogue_avatar transition '%s' at %s"
						% [value, location],
						line,
					)
					return null
				transition = value
			"duration":
				if not value.is_valid_float() or not is_finite(value.to_float()) or value.to_float() < 0.0:
					_record_diagnostic(
						data,
						"error",
						"DslParser: @dialogue_avatar duration must be finite and non-negative at %s"
						% location,
						line,
					)
					return null
				duration = value.to_float()
				duration_set = true
			_:
				var parsed := _parse_dialogue_avatar_property(
					key, value, line, data)
				if not bool(parsed.get("valid", false)):
					return null
				properties[key] = parsed["value"]
	if transition == "fade" and not duration_set:
		duration = 0.25
	if transition == "cut" and duration != 0.0:
		_record_diagnostic(
			data,
			"error",
			"DslParser: @dialogue_avatar cut transition requires duration=0 at %s"
			% location,
			line,
		)
		return null
	var payload := {
		"action": action,
		"properties": properties,
		"transition": transition,
		"duration": duration,
	}
	if not DialogueAvatarState.validate_operation(payload, false):
		_record_diagnostic(
			data,
			"error",
			"DslParser: invalid @dialogue_avatar operation at %s" % location,
			line,
		)
		return null
	if lower_to_presentation_batch:
		var batch_command := _make_cmd("presentation_batch", {
			"policy": "join",
			"operations": [{
				"kind": "dialogue_avatar",
				"payload": payload.duplicate(true),
			}],
			"operation_lines": [line],
		})
		batch_command.declared_line = line
		return batch_command
	return _make_cmd("dialogue_avatar", payload)


static func _parse_dialogue_avatar_property(
	key: String,
	value: String,
	line: int,
	data: ScenarioData,
) -> Dictionary:
	if key in _DIALOGUE_AVATAR_STRING_KEYS:
		if value.is_empty() or value != value.strip_edges():
			_record_diagnostic(
				data,
				"error",
				"DslParser: @dialogue_avatar %s must be a canonical non-empty logical id at %s"
				% [key, _source_location(data, line)],
				line,
			)
			return {"valid": false}
		return {"valid": true, "value": value}
	if key == "visible":
		if value not in ["true", "false"]:
			_record_diagnostic(
				data,
				"error",
				"DslParser: @dialogue_avatar visible must be true or false at %s"
				% _source_location(data, line),
				line,
			)
			return {"valid": false}
		return {"valid": true, "value": value == "true"}
	if key in _DIALOGUE_AVATAR_PAIR_KEYS:
		var pair := value.split(",", false)
		if (
			pair.size() != 2
			or not _is_finite_stage_number(String(pair[0]))
			or not _is_finite_stage_number(String(pair[1]))
			or (
				key == "scale"
				and (float(pair[0]) <= 0.0 or float(pair[1]) <= 0.0)
			)
		):
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @dialogue_avatar %s pair at %s"
				% [key, _source_location(data, line)],
				line,
			)
			return {"valid": false}
		return {"valid": true, "value": [float(pair[0]), float(pair[1])]}
	if key in _DIALOGUE_AVATAR_NUMBER_KEYS:
		if not _is_finite_stage_number(value):
			_record_diagnostic(
				data,
				"error",
				"DslParser: invalid @dialogue_avatar %s at %s"
				% [key, _source_location(data, line)],
				line,
			)
			return {"valid": false}
		var numeric: Variant = int(value) if value.is_valid_int() else float(value)
		return {"valid": true, "value": numeric}
	_record_diagnostic(
		data,
		"error",
		"DslParser: unknown @dialogue_avatar option '%s' at %s"
		% [key, _source_location(data, line)],
		line,
	)
	return {"valid": false}


static func _parse_dialogue_clear_command(
	parts: Array,
	line: int,
	data: ScenarioData,
	lower_to_presentation_batch: bool = false,
) -> CommandData:
	var location := _source_location(data, line)
	if not parts.is_empty():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @dialogue_clear accepts no arguments at %s" % location,
			line,
		)
		return null
	var payload := {"scope": "page"}
	if lower_to_presentation_batch:
		var batch_command := _make_cmd("presentation_batch", {
			"policy": "join",
			"operations": [{
				"kind": "dialogue_clear",
				"payload": payload.duplicate(true),
			}],
			"operation_lines": [line],
		})
		batch_command.declared_line = line
		return batch_command
	return _make_cmd("dialogue_clear", payload)


static func _invalid_stage_redraw_value(
	effect_type: String,
	field: String,
	value: String,
	line: int,
	data: ScenarioData,
) -> Variant:
	_record_diagnostic(
		data,
		"error",
		"DslParser: invalid @stage redraw %s %s '%s' (line %d)"
		% [effect_type, field, value, line],
		line,
	)
	return null


static func _canonical_stage_redraw_color(encoded: String) -> String:
	var color := encoded.strip_edges().to_lower()
	if not color.begins_with("#") or color.length() not in [7, 9]:
		return ""
	for index in range(1, color.length()):
		if color.substr(index, 1) not in "0123456789abcdef":
			return ""
	if color.length() == 7:
		color += "ff"
	return color


static func _parse_stage_property_value(
	key: String,
	encoded: String,
	line: int,
	data: ScenarioData,
) -> Variant:
	var lower := encoded.to_lower()
	if key in ["asset", "body", "face"]:
		if encoded == "":
			_record_diagnostic(
				data,
				"warning",
				"DslParser: @stage %s cannot be empty; use 'none' to clear it (line %d)"
				% [key, line],
				line,
			)
			return null
		if lower == "none":
			return ""
		if lower in ["null", "off"]:
			_record_diagnostic(
				data,
				"warning",
				"DslParser: invalid @stage %s clear value '%s'; use 'none' (line %d)"
				% [key, encoded, line],
				line,
			)
			return null
		return encoded
	if key == "kind":
		if encoded == "":
			_record_diagnostic(
				data,
				"warning",
				"DslParser: @stage kind cannot be empty (line %d)" % line,
				line,
			)
			return null
		return encoded
	if key == "fit":
		if lower in _STAGE_FIT_MODES:
			return lower
		_record_diagnostic(
			data,
			"warning",
			"DslParser: invalid @stage fit '%s' (line %d)"
			% [encoded, line],
			line,
		)
		return null
	if key in _STAGE_BOOL_KEYS:
		if lower == "true":
			return true
		if lower == "false":
			return false
		_record_diagnostic(
			data,
			"warning",
			"DslParser: invalid boolean for @stage %s='%s' (line %d)"
			% [key, encoded, line],
			line,
		)
		return null
	if key in _STAGE_PAIR_KEYS:
		if "," in encoded:
			var pair = encoded.split(",", false)
			if (
				pair.size() == 2
				and _is_finite_stage_number(str(pair[0]))
				and _is_finite_stage_number(str(pair[1]))
			):
				return [float(pair[0]), float(pair[1])]
		elif _is_finite_stage_number(encoded):
			return float(encoded)
		_record_diagnostic(
			data,
			"warning",
			"DslParser: invalid numeric pair for @stage %s='%s' (line %d)"
			% [key, encoded, line],
			line,
		)
		return null
	if key in _STAGE_NUMBER_KEYS:
		if not _is_finite_stage_number(encoded):
			_record_diagnostic(
				data,
				"warning",
				"DslParser: invalid number for @stage %s='%s' (line %d)"
				% [key, encoded, line],
				line,
			)
			return null
		return int(encoded) if encoded.is_valid_int() else float(encoded)
	if encoded.is_valid_int():
		return int(encoded)
	if _is_finite_stage_number(encoded):
		return float(encoded)
	return encoded


static func _is_known_stage_property(key: String) -> bool:
	return (
		key in _STAGE_STRING_KEYS
		or key in _STAGE_BOOL_KEYS
		or key in _STAGE_PAIR_KEYS
		or key in _STAGE_NUMBER_KEYS
		or key == "fit"
	)


static func _is_stage_property_in_range(
	key: String,
	value: Variant,
	line: int,
	data: ScenarioData,
) -> bool:
	var valid := true
	if key in ["scale", "zoom"]:
		var pair: Array = value if value is Array else [value, value]
		valid = float(pair[0]) > 0.0 and float(pair[1]) > 0.0
	elif key in ["scale_x", "scale_y", "zoom_x", "zoom_y", "depth_scale"]:
		valid = float(value) > 0.0
	elif key == "opacity":
		valid = float(value) >= 0.0 and float(value) <= 1.0
	elif key in ["z", "z_index"]:
		valid = (
			float(value) == floorf(float(value))
			and int(value) >= StageLayerState.MIN_Z_INDEX
			and int(value) <= StageLayerState.MAX_Z_INDEX
		)
	if not valid:
		_record_diagnostic(
			data,
			"warning",
			"DslParser: @stage %s value '%s' is outside its supported range (line %d)"
			% [key, str(value), line],
			line,
		)
	return valid


static func _is_finite_stage_number(encoded: String) -> bool:
	return encoded.is_valid_float() and is_finite(float(encoded))


static func _parse_effect_number(
	raw_value: String,
	effect_type: String,
	parameter_name: String,
	token: DslToken,
	data: ScenarioData,
) -> Variant:
	if not raw_value.is_valid_float():
		_record_diagnostic(
			data,
			"error",
			"DslParser: @effect %s %s must be a finite number, got '%s' (line %d)"
			% [effect_type, parameter_name, raw_value, token.line],
			token.line,
		)
		return null
	var value := raw_value.to_float()
	if not is_finite(value):
		_record_diagnostic(
			data,
			"error",
			"DslParser: @effect %s %s must be finite, got '%s' (line %d)"
			% [effect_type, parameter_name, raw_value, token.line],
			token.line,
		)
		return null
	return value


static func _parse_set_command(args: String) -> CommandData:
	# Formats: "var = value", "var += value", "var -= value"
	for op in ["+=", "-=", "="]:
		var pos = args.find(op)
		if pos != -1:
			var var_name = args.substr(0, pos).strip_edges()
			var value = args.substr(pos + op.length()).strip_edges()
			return _make_cmd("set", {"var": var_name, "value": value, "op": op})
	return null


static func _parse_choice_command(token: DslToken) -> CommandData:
	var raw = token.raw_text
	var args = raw.substr(7).strip_edges()  # Remove "@choice"
	var prompt = ""
	# Extract quoted prompt
	var q_start = args.find('"')
	if q_start != -1:
		var q_end = args.find('"', q_start + 1)
		if q_end != -1:
			prompt = args.substr(q_start + 1, q_end - q_start - 1)
	else:
		q_start = args.find("\u201c")
		if q_start != -1:
			var q_end = args.find("\u201d", q_start + 1)
			if q_end != -1:
				prompt = args.substr(q_start + 1, q_end - q_start - 1)

	var cmd = _make_cmd("choice", {"prompt": prompt, "options": []})
	return cmd


# --- Choice option ---

static func _parse_choice_option(token: DslToken) -> Dictionary:
	var raw = token.raw_text.strip_edges()
	# Remove leading "- "
	raw = raw.substr(2).strip_edges()

	var result: Dictionary = {}

	# Extract label (quoted text)
	var label_start = raw.find('"')
	var label_end = -1
	if label_start != -1:
		label_end = raw.find('"', label_start + 1)
	else:
		label_start = raw.find("\u201c")
		if label_start != -1:
			label_end = raw.find("\u201d", label_start + 1)

	if label_start != -1 and label_end != -1:
		result["label"] = raw.substr(label_start + 1, label_end - label_start - 1)
		raw = raw.substr(label_end + 1).strip_edges()

	# Extract jump target (-> target)
	var arrow_pos = raw.find("->")
	if arrow_pos != -1:
		var after_arrow = raw.substr(arrow_pos + 2).strip_edges()
		# Target is the next word before { or ?if
		var target_end = after_arrow.find(" ")
		if target_end == -1:
			target_end = after_arrow.length()
		result["jump"] = after_arrow.substr(0, target_end).strip_edges()
		raw = after_arrow.substr(target_end).strip_edges()

	# Extract set ({var op val})
	var brace_start = raw.find("{")
	var brace_end = raw.find("}")
	if brace_start != -1 and brace_end != -1:
		var set_expr = raw.substr(brace_start + 1, brace_end - brace_start - 1).strip_edges()
		result["set"] = _parse_set_expression(set_expr)
		raw = raw.substr(brace_end + 1).strip_edges()

	# Extract condition (?if expr)
	var if_pos = raw.find("?if ")
	if if_pos != -1:
		result["condition"] = raw.substr(if_pos + 4).strip_edges()

	# Generate id from label
	result["id"] = result.get("label", "").to_lower().replace(" ", "_")

	return result


static func _parse_set_expression(expr: String) -> Dictionary:
	for op in ["+=", "-=", "="]:
		var pos = expr.find(op)
		if pos != -1:
			var var_name = expr.substr(0, pos).strip_edges()
			var value = expr.substr(pos + op.length()).strip_edges()
			return {var_name: "%s %s" % [op, value]}
	return {}


# --- Dialogue ---

static func _parse_dialogue(token: DslToken, data: ScenarioData) -> CommandData:
	var raw = token.raw_text
	var bracket_start = raw.find("\u300c")  # 「
	var bracket_end = raw.rfind("\u300d")    # 」

	if bracket_start == -1 or bracket_end == -1:
		return null

	var character = raw.substr(0, bracket_start).strip_edges()
	var text = raw.substr(bracket_start + 1, bracket_end - bracket_start - 1)

	var metadata := _parse_dialogue_metadata(
		raw, bracket_end, character, token, data)
	if not bool(metadata["valid"]):
		return null

	var params := {
		"character": character,
		"text": text,
		"voice_layers": metadata["voice_layers"],
		"presentation_from_context": true,
	}
	var command := _make_cmd("dialogue", params)
	command.declared_line = token.line
	return command


static func _parse_narration(token: DslToken, data: ScenarioData) -> CommandData:
	var raw = token.raw_text
	var bracket_start = raw.find("\u300c")
	var bracket_end = raw.rfind("\u300d")

	if bracket_start == -1 or bracket_end == -1:
		return null

	var text = raw.substr(bracket_start + 1, bracket_end - bracket_start - 1)
	var metadata := _parse_dialogue_metadata(raw, bracket_end, "", token, data)
	if not bool(metadata["valid"]):
		return null

	var params := {
		"character": "",
		"text": text,
		"voice_layers": metadata["voice_layers"],
		"presentation_from_context": true,
	}
	var command := _make_cmd("dialogue", params)
	command.declared_line = token.line
	return command


static func _parse_monologue(token: DslToken, data: ScenarioData) -> CommandData:
	var raw = token.raw_text
	var paren_start = raw.find("\uff08")  # （
	var paren_end = raw.rfind("\uff09")    # ）

	if paren_start == -1 or paren_end == -1:
		return null

	var character = raw.substr(0, paren_start).strip_edges()
	var text = raw.substr(paren_start + 1, paren_end - paren_start - 1)
	var metadata := _parse_dialogue_metadata(
		raw, paren_end, character, token, data)
	if not bool(metadata["valid"]):
		return null

	var command := _make_cmd("dialogue", {
		"character": character,
		"text": text,
		"voice_layers": metadata["voice_layers"],
		"mode": "monologue",
	})
	command.declared_line = token.line
	return command


static func _parse_dialogue_metadata(
	raw: String,
	closing_index: int,
	default_character: String,
	token: DslToken,
	data: ScenarioData,
) -> Dictionary:
	var trailing := _strip_inline_comment(
		raw.substr(closing_index + 1).strip_edges())
	var result := {
		"valid": true,
		"voice_layers": [],
	}
	if trailing.is_empty():
		return result
	var seen_voice := false
	var seen_dsp := false
	var shorthand_dsp := ""
	var explicit_layers: Array = []
	for token_value in _split_args(trailing):
		var metadata_token := String(token_value)
		if metadata_token.begins_with("#voice:"):
			if seen_voice or not explicit_layers.is_empty():
				_record_dialogue_metadata_error(
					data, token,
					"#voice shorthand cannot be duplicated or mixed with #voice_layer")
				result["valid"] = false
				continue
			var voice := metadata_token.substr("#voice:".length())
			if not VoicePlaybackRequest.is_logical_asset_id(voice):
				_record_dialogue_metadata_error(
					data, token, "#voice asset must use a bounded Stella logical id")
				result["valid"] = false
			seen_voice = true
			result["voice_layers"] = [{
				"id": "main",
				"asset": voice,
				"character": default_character,
				"dsp": shorthand_dsp,
				"line": token.line,
			}]
		elif metadata_token.begins_with("#voice_dsp:"):
			if seen_dsp or not explicit_layers.is_empty():
				_record_dialogue_metadata_error(
					data, token,
					"#voice_dsp cannot be duplicated or mixed with #voice_layer")
				result["valid"] = false
				continue
			var preset := metadata_token.substr("#voice_dsp:".length())
			if not VoiceDspChainDefinition.is_logical_preset_id(preset):
				_record_dialogue_metadata_error(
					data, token,
					"#voice_dsp must use a bounded Stella logical preset id")
				result["valid"] = false
			seen_dsp = true
			shorthand_dsp = preset
			if not (result["voice_layers"] as Array).is_empty():
				(result["voice_layers"] as Array)[0]["dsp"] = preset
		elif metadata_token.begins_with("#voice_layer:"):
			if seen_voice or seen_dsp:
				_record_dialogue_metadata_error(
					data, token,
					"#voice_layer cannot be mixed with #voice/#voice_dsp shorthand")
				result["valid"] = false
				continue
			var parsed_layer := _parse_voice_layer_metadata_token(
				metadata_token, token.line)
			if not bool(parsed_layer.get("valid", false)):
				_record_dialogue_metadata_error(
					data, token, String(parsed_layer.get("error", "invalid #voice_layer")))
				result["valid"] = false
				continue
			var layer: Dictionary = parsed_layer["layer"]
			var duplicate_layer := false
			for existing_value: Variant in explicit_layers:
				var existing: Dictionary = existing_value
				if String(existing.get("id", "")) == String(layer.get("id", "")):
					duplicate_layer = true
					break
			if duplicate_layer:
				_record_dialogue_metadata_error(
					data, token,
					"duplicate #voice_layer id '%s'" % String(layer.get("id", "")))
				result["valid"] = false
				continue
			if explicit_layers.size() >= VoicePlaybackRequest.MAX_LAYERS:
				_record_dialogue_metadata_error(
					data, token,
					"voice layer count exceeds the bounded limit of %d"
						% VoicePlaybackRequest.MAX_LAYERS)
				result["valid"] = false
				continue
			explicit_layers.append(layer)
			result["voice_layers"] = explicit_layers
		else:
			_record_dialogue_metadata_error(
				data, token,
				"unknown dialogue metadata '%s'" % metadata_token)
			result["valid"] = false
	if seen_dsp and not seen_voice:
		_record_dialogue_metadata_error(
			data, token, "#voice_dsp requires #voice on the same dialogue")
		result["valid"] = false
	return result


static func _parse_voice_layer_metadata_token(
	metadata_token: String,
	line: int,
) -> Dictionary:
	var body := metadata_token.substr("#voice_layer:".length())
	var open_paren := body.find("(")
	if open_paren <= 0 or not body.ends_with(")"):
		return {
			"valid": false,
			"error": "#voice_layer must use id(character=...,asset=...[,dsp=...])",
		}
	var layer_id := body.substr(0, open_paren)
	if not VoicePlaybackRequest.is_layer_id(layer_id):
		return {"valid": false, "error": "#voice_layer id is not canonical"}
	var params_text := body.substr(
		open_paren + 1, body.length() - open_paren - 2)
	if params_text.is_empty():
		return {"valid": false, "error": "#voice_layer parameters cannot be empty"}
	var params: Dictionary = {}
	for part_value: Variant in params_text.split(",", true):
		var part := String(part_value)
		if part.is_empty() or part.count("=") != 1:
			return {"valid": false, "error": "#voice_layer parameters are malformed"}
		var equals := part.find("=")
		var key := part.substr(0, equals)
		var value := part.substr(equals + 1)
		if not key in ["character", "asset", "dsp"]:
			return {
				"valid": false,
				"error": "#voice_layer has unknown parameter '%s'" % key,
			}
		if params.has(key):
			return {
				"valid": false,
				"error": "#voice_layer duplicates parameter '%s'" % key,
			}
		if value.is_empty():
			return {
				"valid": false,
				"error": "#voice_layer parameter '%s' cannot be empty" % key,
			}
		params[key] = value
	for required_key in ["character", "asset"]:
		if not params.has(required_key):
			return {
				"valid": false,
				"error": "#voice_layer requires '%s'" % required_key,
			}
	var character := String(params["character"])
	if (
		character != character.strip_edges()
		or character.length() > VoicePlaybackRequest.MAX_LOGICAL_ID_LENGTH
	):
		return {"valid": false, "error": "#voice_layer character is not canonical"}
	var asset := String(params["asset"])
	if not VoicePlaybackRequest.is_logical_asset_id(asset):
		return {"valid": false, "error": "#voice_layer asset is not a Stella logical id"}
	var dsp := String(params.get("dsp", ""))
	if not dsp.is_empty() and not VoiceDspChainDefinition.is_logical_preset_id(dsp):
		return {"valid": false, "error": "#voice_layer DSP is not a Stella logical preset id"}
	return {
		"valid": true,
		"layer": {
			"id": layer_id,
			"asset": asset,
			"character": character,
			"dsp": dsp,
			"line": line,
		},
	}


static func _record_dialogue_metadata_error(
	data: ScenarioData,
	token: DslToken,
	detail: String,
) -> void:
	_record_diagnostic(
		data,
		"error",
		"DslParser: %s at %s"
			% [detail, _source_location(data, token.line)],
		token.line,
	)


# --- @if/@else/@end ---

static func _create_if_context(token: DslToken, current_scene: SceneData, _data: ScenarioData) -> Dictionary:
	var expr = token.raw_text.substr(4).strip_edges()  # Remove "@if "
	return {
		"node_kind": INTERNAL_IF_NODE,
		"expr": expr,
		"scene_id": current_scene.id if current_scene else "unknown",
		"line": token.line,
		"then_commands": [],
		"else_commands": [],
		"branch": "then",
		"parent_scene": current_scene,
		"has_else": false,
	}


static func _close_if_block(ctx: Dictionary, data: ScenarioData) -> SceneData:
	var parent_scene: SceneData = ctx["parent_scene"]
	var base_id := _if_node_base_id(ctx)
	# Synthetic scenes inherit chapter_id from the enclosing scene's chapter so
	# the flow graph treats them as part of the authored chapter.
	var inherit_chapter_id := parent_scene.chapter_id if parent_scene else ""
	var cont_scene := _make_synthetic_scene(base_id + "_cont", inherit_chapter_id)
	_compile_condition_node(ctx, parent_scene, cont_scene.id, data, inherit_chapter_id)
	# The root continuation is physically last. Every earlier synthetic branch
	# either ends in a jump or a condition, so ScenarioEngine can never reach a
	# sibling branch through sequential scene fallthrough.
	data.scenes.append(cont_scene)
	return cont_scene


static func _append_if_node(parent_ctx: Dictionary, child_ctx: Dictionary) -> void:
	if parent_ctx["branch"] == "then":
		parent_ctx["then_commands"].append(child_ctx)
	else:
		parent_ctx["else_commands"].append(child_ctx)


static func _is_if_node(value) -> bool:
	return value is Dictionary and value.get("node_kind", "") == INTERNAL_IF_NODE


static func _if_node_base_id(ctx: Dictionary) -> String:
	var prefix := "__elif" if ctx.get("is_elif", false) else "__if"
	return "%s_%s_%d" % [prefix, ctx["scene_id"], ctx["line"]]


static func _make_synthetic_scene(scene_id: String, chapter_id: String) -> SceneData:
	var scene := SceneData.new()
	scene.id = scene_id
	scene.chapter_id = chapter_id
	return scene


## Compile one condition node in continuation-passing style. All branch tails
## jump to continuation_id. An @elif child is compiled directly in its parent's
## false-entry scene and receives the same continuation, so every branch in the
## chain joins the root @if continuation rather than deriving a target from the
## immediately preceding @elif.
static func _compile_condition_node(
	ctx: Dictionary,
	parent_scene: SceneData,
	continuation_id: String,
	data: ScenarioData,
	chapter_id: String,
) -> void:
	var base_id := _if_node_base_id(ctx)
	var false_branch_mode_events := _extract_mode_only_branch_events(
		ctx["else_commands"])

	var then_scene := _make_synthetic_scene(base_id + "_then", chapter_id)
	data.scenes.append(then_scene)
	_compile_condition_sequence(
		ctx["then_commands"], then_scene, continuation_id, data, chapter_id)

	var else_target := continuation_id
	if not ctx["else_commands"].is_empty():
		var else_scene := _make_synthetic_scene(base_id + "_else", chapter_id)
		data.scenes.append(else_scene)
		else_target = else_scene.id
		if ctx["else_commands"].size() == 1 \
			and _is_if_node(ctx["else_commands"][0]) \
			and ctx["else_commands"][0].get("is_elif", false):
			_compile_condition_node(
				ctx["else_commands"][0], else_scene, continuation_id, data, chapter_id)
		else:
			_compile_condition_sequence(
				ctx["else_commands"], else_scene, continuation_id, data, chapter_id)

	var condition_cmd := _make_cmd("condition", {
		"if": ctx["expr"],
		"then_jump": then_scene.id,
		"else_jump": else_target,
	})
	condition_cmd.dialogue_mode_events_on_false_branch.append_array(
		false_branch_mode_events)
	parent_scene.commands.append(condition_cmd)


## Compile a linear branch sequence. A nested @if splits the current scene and
## resumes the remaining commands in that nested block's continuation. The
## final tail always jumps explicitly to the caller-provided continuation.
static func _compile_condition_sequence(
	commands: Array,
	entry_scene: SceneData,
	continuation_id: String,
	data: ScenarioData,
	chapter_id: String,
) -> void:
	var current_scene := entry_scene
	for item in commands:
		if _is_if_node(item):
			var nested_cont := _make_synthetic_scene(
				_if_node_base_id(item) + "_cont", chapter_id)
			_compile_condition_node(
				item, current_scene, nested_cont.id, data, chapter_id)
			data.scenes.append(nested_cont)
			current_scene = nested_cont
		else:
			current_scene.commands.append(item)
	current_scene.commands.append(_make_cmd("jump", {"target": continuation_id}))


# --- Helpers ---

static func _build_combine_command(
	character: String,
	segments: Array,
) -> CommandData:
	if segments.size() == 0:
		return null
	# Concatenate segment text for typewriter display / backlog
	var full_text := ""
	for seg in segments:
		full_text += String(seg.get("text", ""))
	var params := {
		"character": character,
		"text": full_text,
		"segments": segments.duplicate(true),
		"presentation_from_context": true,
	}
	return _make_cmd("dialogue", params)


static func _register_dialogue_profiles(
	data: ScenarioData,
	compiled_profiles: Dictionary,
) -> void:
	for profile_name_value in compiled_profiles:
		var profile_name := str(profile_name_value)
		var runtime_profile: Dictionary = (
			compiled_profiles[profile_name_value] as Dictionary
		).duplicate(true)
		var provenance: Dictionary = runtime_profile.get(
			DialogueProfileParser.RUNTIME_PROVENANCE_KEY, {}).duplicate(true)
		runtime_profile.erase(DialogueProfileParser.RUNTIME_PROVENANCE_KEY)
		data.dialogue_profiles[profile_name] = runtime_profile
		if not provenance.is_empty():
			data.dialogue_profile_provenance[profile_name] = provenance


static func _build_dialogue_presentation_event(
	command_name: String,
	selection: Dictionary,
) -> Dictionary:
	if command_name == "adv":
		return {
			"action": "select_adv",
			"mode": "adv",
			"profile_name": str(selection.get("profile_name", "")),
		}
	if str(selection.get("mode", command_name)) == "adv":
		return {
			"action": "restore_adv",
			"mode": "adv",
		}
	return {
		"action": "select_mode",
		"mode": str(selection.get("mode", command_name)),
		"profile_name": str(selection.get("profile_name", "")),
	}


static func _make_cmd(type: String, params: Dictionary) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


static func _split_args(text: String) -> Array:
	var result: Array = []
	var current := ""
	for index in range(text.length()):
		var character := text.substr(index, 1)
		if _is_inline_whitespace(character):
			if not current.is_empty():
				result.append(current)
				current = ""
		else:
			current += character
	if not current.is_empty():
		result.append(current)
	return result


static func _strip_inline_comment(text: String) -> String:
	if text.length() < 2:
		return text
	var closing_quote := ""
	var escaped := false
	for index in range(text.length() - 1):
		var character := text.substr(index, 1)
		if not closing_quote.is_empty():
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == closing_quote:
				closing_quote = ""
			continue
		match character:
			"\"", "'":
				closing_quote = character
			"“":
				closing_quote = "”"
			"/":
				if text.substr(index + 1, 1) == "/" \
					and (index == 0 or _is_inline_whitespace(text.substr(index - 1, 1))):
					return text.substr(0, index).strip_edges()
	return text


static func _is_inline_whitespace(character: String) -> bool:
	return not character.is_empty() and character.strip_edges().is_empty()
