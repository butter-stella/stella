## Parses DslToken list into ScenarioData.
## Fills smart defaults, expands @if/@else/@end into synthetic scenes.
class_name DslParser extends RefCounted


static func parse(tokens: Array, scenario_id: String = "unnamed") -> ScenarioData:
	var data = ScenarioData.new()
	data.id = scenario_id

	var current_scene: SceneData = null
	var pending_options: Array = []
	var choice_cmd: CommandData = null
	var current_mode: String = "adv"  # adv / nvl / overlay

	# @chapter state (issue #97). Tracks the most-recently-declared chapter so
	# subsequent @scene declarations can be assigned to it. null until the
	# first @chapter is seen.
	var current_chapter: ChapterData = null

	# @if/@else/@end state
	var if_stack: Array = []  # Array of IfContext

	# @parallel state
	var in_parallel: bool = false
	var parallel_commands: Array = []

	# @combine state — groups multiple dialogue lines with per-segment voice/expression
	# into a single dialogue command with a `segments` array.
	var in_combine: bool = false
	var combine_segments: Array = []
	var combine_character: String = ""
	var combine_character_set: bool = false
	var combine_pending_expr: String = ""

	var i = 0
	while i < tokens.size():
		var token: DslToken = tokens[i]

		match token.type:
			DslToken.Type.SCENE_DIRECTIVE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				current_scene = _parse_scene_directive(token)
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

			DslToken.Type.AT_COMMAND:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []

				var cmd_name = _get_at_command_name(token.raw_text)

				if cmd_name == "choice":
					choice_cmd = _parse_choice_command(token)
				elif cmd_name == "if":
					if_stack.append(_create_if_context(token, current_scene, data))
				elif cmd_name == "elif":
					if if_stack.size() > 0:
						# Close current if block's else into a new elif chain
						var elif_expr = token.raw_text.substr(6).strip_edges()
						var ctx = if_stack[-1]
						# Switch to else branch and create a nested if inside it
						ctx["branch"] = "else"
						# Create a new if context that will live inside the else branch
						var nested = {
							"expr": elif_expr,
							"scene_id": ctx["scene_id"],
							"line": token.line,
							"then_commands": [],
							"else_commands": [],
							"branch": "then",
							"parent_scene": ctx["parent_scene"],
							"is_elif": true,
							"parent_if": ctx,
						}
						if_stack.append(nested)
				elif cmd_name == "else":
					if if_stack.size() > 0:
						if_stack[-1]["branch"] = "else"
				elif cmd_name == "end":
					if in_combine:
						var combine_cmd = _build_combine_command(combine_character, combine_segments, current_mode)
						combine_segments = []
						combine_character = ""
						combine_character_set = false
						combine_pending_expr = ""
						in_combine = false
						if combine_cmd and current_scene:
							_add_command(combine_cmd, current_scene, if_stack)
					elif in_parallel:
						var parallel_cmd = _make_cmd("parallel", {"commands": parallel_commands.duplicate()})
						parallel_commands.clear()
						in_parallel = false
						if current_scene:
							_add_command(parallel_cmd, current_scene, if_stack)
					elif if_stack.size() > 0:
						# Close elif chain: pop all elif blocks, then the original if
						while if_stack.size() > 0 and if_stack[-1].get("is_elif", false):
							var elif_ctx = if_stack.pop_back()
							var parent_ctx = elif_ctx.get("parent_if")
							# Build the elif as a nested condition inside parent's else
							_close_elif_into_parent(elif_ctx, parent_ctx, data)
						# Now close the original @if block
						if if_stack.size() > 0:
							current_scene = _close_if_block(if_stack.pop_back(), data)
					# else: @end at scene level, ignore
				elif cmd_name == "nvl":
					var args = token.raw_text.substr(4).strip_edges()
					current_mode = "adv" if args == "off" else "nvl"
				elif cmd_name == "overlay":
					var args = token.raw_text.substr(8).strip_edges()
					current_mode = "adv" if args == "off" else "overlay"
				elif cmd_name == "parallel":
					in_parallel = true
					parallel_commands.clear()
				elif cmd_name == "combine":
					in_combine = true
					combine_segments = []
					combine_character = ""
					combine_character_set = false
					combine_pending_expr = ""
				else:
					var cmd = _parse_at_command(token)
					if cmd:
						cmd.declared_line = token.line
					if cmd and current_scene:
						if in_combine:
							# Inside @combine, only @expr is allowed and it binds to the next segment.
							if cmd.type == "char_expr":
								combine_pending_expr = cmd.get_string("expression", "")
							else:
								push_warning("DslParser: @%s is not allowed inside @combine block (line %d)" % [cmd_name, token.line])
						elif in_parallel:
							parallel_commands.append(cmd)
						else:
							_add_command(cmd, current_scene, if_stack)

			DslToken.Type.DIALOGUE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_dialogue(token, current_mode)
				if cmd and current_scene:
					if in_combine:
						var char_name = cmd.get_string("character", "")
						if not combine_character_set:
							combine_character = char_name
							combine_character_set = true
						elif char_name != combine_character:
							push_warning("DslParser: @combine block mixes characters '%s' and '%s' (line %d)" % [combine_character, char_name, token.line])
						combine_segments.append({
							"text": cmd.get_string("text", ""),
							"voice": cmd.get_string("voice", ""),
							"expression": combine_pending_expr,
						})
						combine_pending_expr = ""
					else:
						_add_command(cmd, current_scene, if_stack)

			DslToken.Type.NARRATION:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_narration(token, current_mode)
				if cmd and current_scene:
					if in_combine:
						if not combine_character_set:
							combine_character = ""
							combine_character_set = true
						elif combine_character != "":
							push_warning("DslParser: @combine block mixes narration and character '%s' (line %d)" % [combine_character, token.line])
						combine_segments.append({
							"text": cmd.get_string("text", ""),
							"voice": cmd.get_string("voice", ""),
							"expression": combine_pending_expr,
						})
						combine_pending_expr = ""
					else:
						_add_command(cmd, current_scene, if_stack)

			DslToken.Type.MONOLOGUE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_monologue(token)
				if cmd and current_scene:
					_add_command(cmd, current_scene, if_stack)

			DslToken.Type.CHOICE_OPTION:
				pending_options.append(_parse_choice_option(token))

		i += 1

	_flush_choice(choice_cmd, pending_options, current_scene, if_stack)

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

	return data


static func _add_command(cmd: CommandData, scene: SceneData, if_stack: Array) -> void:
	if if_stack.size() > 0:
		var ctx = if_stack[-1]
		if ctx["branch"] == "then":
			ctx["then_commands"].append(cmd)
		else:
			ctx["else_commands"].append(cmd)
	else:
		scene.commands.append(cmd)


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
	var space_pos = after_at.find(" ")
	if space_pos == -1:
		return after_at
	return after_at.substr(0, space_pos)


static func _parse_at_command(token: DslToken) -> CommandData:
	var raw = token.raw_text
	var name = _get_at_command_name(raw)
	var args = raw.substr(raw.find(name) + name.length()).strip_edges()
	var parts = _split_args(args)

	match name:
		"bg":
			return _make_cmd("bg", {
				"asset": parts[0] if parts.size() > 0 else "",
				"transition": parts[1] if parts.size() > 1 else "fade",
				"duration": float(parts[2]) if parts.size() > 2 else 0.5,
			})
		"show":
			return _make_cmd("char_show", {
				"character": parts[0] if parts.size() > 0 else "",
				"expression": parts[1] if parts.size() > 1 else "default",
				"position": parts[2] if parts.size() > 2 else "center",
			})
		"hide":
			return _make_cmd("char_hide", {
				"character": parts[0] if parts.size() > 0 else "",
			})
		"expr":
			return _make_cmd("char_expr", {
				"character": parts[0] if parts.size() > 0 else "",
				"expression": parts[1] if parts.size() > 1 else "default",
			})
		"jump":
			return _make_cmd("jump", {
				"target": parts[0] if parts.size() > 0 else "",
			})
		"anim":
			return _make_cmd("char_anim", {
				"character": parts[0] if parts.size() > 0 else "",
				"anim": parts[1] if parts.size() > 1 else "",
				"intensity": parts[2] if parts.size() > 2 else "normal",
			})
		"move":
			return _make_cmd("char_move", {
				"character": parts[0] if parts.size() > 0 else "",
				"position": parts[1] if parts.size() > 1 else "center",
				"duration": float(parts[2]) if parts.size() > 2 else 0.5,
			})
		"call":
			return _make_cmd("call", {
				"target": parts[0] if parts.size() > 0 else "",
			})
		"set":
			return _parse_set_command(args)
		"bgm":
			if parts.size() > 0 and parts[0] == "off":
				return _make_cmd("bgm", {
					"off": true,
					"fade_duration": float(parts[1]) if parts.size() > 1 else 1.0,
				})
			return _make_cmd("bgm", {
				"asset": parts[0] if parts.size() > 0 else "",
				"fade_duration": float(parts[1]) if parts.size() > 1 else 1.0,
			})
		"se":
			if parts.size() > 1 and parts[1] == "off":
				return _make_cmd("se", {"asset": parts[0], "off": true})
			return _make_cmd("se", {
				"asset": parts[0] if parts.size() > 0 else "",
				"loop": parts[1] == "loop" if parts.size() > 1 else false,
			})
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
			if parts.size() > 0 and parts[0] == "click":
				return _make_cmd("wait", {"mode": "click"})
			return _make_cmd("wait", {
				"duration": float(parts[0]) if parts.size() > 0 else 1.0,
			})
		"cg":
			if parts.size() > 0 and parts[0] == "off":
				return _make_cmd("cg", {
					"off": true,
					"transition": parts[1] if parts.size() > 1 else "fade",
					"duration": float(parts[2]) if parts.size() > 2 else 0.5,
				})
			var cg_mode = "fullscreen"
			if parts.size() > 1 and parts[1] in ["sd", "animated"]:
				cg_mode = parts[1]
			return _make_cmd("cg", {
				"asset": parts[0] if parts.size() > 0 else "",
				"mode": cg_mode,
				"transition": "fade",
				"duration": 0.5,
			})
		"effect":
			if parts.size() > 0 and parts[0] == "off":
				return _make_cmd("effect", {"off": true, "effect_type": "off"})
			var effect_type = parts[0] if parts.size() > 0 else ""
			match effect_type:
				"shake":
					return _make_cmd("effect", {
						"effect_type": "shake",
						"intensity": float(parts[1]) if parts.size() > 1 else 10.0,
						"duration": float(parts[2]) if parts.size() > 2 else 0.3,
					})
				"flash":
					return _make_cmd("effect", {
						"effect_type": "flash",
						"color": parts[1] if parts.size() > 1 else "white",
						"duration": float(parts[2]) if parts.size() > 2 else 0.2,
					})
				_:
					return _make_cmd("effect", {"effect_type": effect_type})
		"end":
			return null  # Handled by if_stack or ignored
		_:
			return null


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

static func _parse_dialogue(token: DslToken, mode: String = "adv") -> CommandData:
	var raw = token.raw_text
	var bracket_start = raw.find("\u300c")  # 「
	var bracket_end = raw.rfind("\u300d")    # 」

	if bracket_start == -1 or bracket_end == -1:
		return null

	var character = raw.substr(0, bracket_start).strip_edges()
	var text = raw.substr(bracket_start + 1, bracket_end - bracket_start - 1)

	# Extract voice tag
	var voice = ""
	var after_bracket = raw.substr(bracket_end + 1).strip_edges()
	var voice_match = "#voice:"
	var voice_pos = after_bracket.find(voice_match)
	if voice_pos != -1:
		voice = after_bracket.substr(voice_pos + voice_match.length()).strip_edges()

	return _make_cmd("dialogue", {
		"character": character,
		"text": text,
		"voice": voice,
		"mode": mode,
	})


static func _parse_narration(token: DslToken, mode: String = "adv") -> CommandData:
	var raw = token.raw_text
	var bracket_start = raw.find("\u300c")
	var bracket_end = raw.rfind("\u300d")

	if bracket_start == -1 or bracket_end == -1:
		return null

	var text = raw.substr(bracket_start + 1, bracket_end - bracket_start - 1)

	return _make_cmd("dialogue", {
		"character": "",
		"text": text,
		"voice": "",
		"mode": mode,
	})


static func _parse_monologue(token: DslToken) -> CommandData:
	var raw = token.raw_text
	var paren_start = raw.find("\uff08")  # （
	var paren_end = raw.rfind("\uff09")    # ）

	if paren_start == -1 or paren_end == -1:
		return null

	var character = raw.substr(0, paren_start).strip_edges()
	var text = raw.substr(paren_start + 1, paren_end - paren_start - 1)

	return _make_cmd("dialogue", {
		"character": character,
		"text": text,
		"voice": "",
		"mode": "monologue",
	})


# --- @if/@else/@end ---

static func _create_if_context(token: DslToken, current_scene: SceneData, _data: ScenarioData) -> Dictionary:
	var expr = token.raw_text.substr(4).strip_edges()  # Remove "@if "
	return {
		"expr": expr,
		"scene_id": current_scene.id if current_scene else "unknown",
		"line": token.line,
		"then_commands": [],
		"else_commands": [],
		"branch": "then",
		"parent_scene": current_scene,
	}


static func _close_elif_into_parent(elif_ctx: Dictionary, parent_ctx: Dictionary, data: ScenarioData) -> void:
	var base_id = "__elif_%s_%d" % [elif_ctx["scene_id"], elif_ctx["line"]]
	# The parent if's continuation scene ID (created later by _close_if_block)
	var parent_cont_id = "__if_%s_%d_cont" % [parent_ctx["scene_id"], parent_ctx["line"]]
	# Synthetic scenes inherit chapter_id from the enclosing scene's chapter
	# (issue #97) — otherwise PR-B's flowchart graph builder sees them as
	# orphans and they pollute "scene before any @chapter" detection.
	var inherit_chapter_id := ""
	var parent_scene = parent_ctx.get("parent_scene")
	if parent_scene != null:
		inherit_chapter_id = parent_scene.chapter_id

	var then_scene = SceneData.new()
	then_scene.id = base_id + "_then"
	then_scene.chapter_id = inherit_chapter_id
	for cmd in elif_ctx["then_commands"]:
		then_scene.commands.append(cmd)
	# Jump to parent's continuation after elif branch executes
	then_scene.commands.append(_make_cmd("jump", {"target": parent_cont_id}))
	data.scenes.append(then_scene)

	var else_target = parent_cont_id
	if elif_ctx["else_commands"].size() > 0:
		var else_scene = SceneData.new()
		else_scene.id = base_id + "_else"
		else_scene.chapter_id = inherit_chapter_id
		for cmd in elif_ctx["else_commands"]:
			else_scene.commands.append(cmd)
		else_scene.commands.append(_make_cmd("jump", {"target": parent_cont_id}))
		data.scenes.append(else_scene)
		else_target = else_scene.id

	var condition_cmd = _make_cmd("condition", {
		"if": elif_ctx["expr"],
		"then_jump": then_scene.id,
		"else_jump": else_target,
	})
	parent_ctx["else_commands"].append(condition_cmd)


static func _close_if_block(ctx: Dictionary, data: ScenarioData) -> SceneData:
	var parent_scene: SceneData = ctx["parent_scene"]
	var base_id = "__if_%s_%d" % [ctx["scene_id"], ctx["line"]]
	# Synthetic scenes inherit chapter_id from the enclosing scene's chapter
	# (issue #97) — see _close_elif_into_parent for rationale.
	var inherit_chapter_id := parent_scene.chapter_id if parent_scene else ""

	# Create synthetic scenes
	var then_scene = SceneData.new()
	then_scene.id = base_id + "_then"
	then_scene.chapter_id = inherit_chapter_id
	for cmd in ctx["then_commands"]:
		then_scene.commands.append(cmd)

	var cont_scene = SceneData.new()
	cont_scene.id = base_id + "_cont"
	cont_scene.chapter_id = inherit_chapter_id

	# Add jump to continuation at end of then branch
	var then_jump = _make_cmd("jump", {"target": cont_scene.id})
	then_scene.commands.append(then_jump)

	data.scenes.append(then_scene)

	var else_jump_target = cont_scene.id
	if ctx["else_commands"].size() > 0:
		var else_scene = SceneData.new()
		else_scene.id = base_id + "_else"
		else_scene.chapter_id = inherit_chapter_id
		for cmd in ctx["else_commands"]:
			else_scene.commands.append(cmd)
		var else_jump = _make_cmd("jump", {"target": cont_scene.id})
		else_scene.commands.append(else_jump)
		data.scenes.append(else_scene)
		else_jump_target = else_scene.id

	# Add condition command to parent scene
	var condition_cmd = _make_cmd("condition", {
		"if": ctx["expr"],
		"then_jump": then_scene.id,
		"else_jump": else_jump_target,
	})
	parent_scene.commands.append(condition_cmd)

	# Continuation scene becomes the new current scene
	data.scenes.append(cont_scene)
	return cont_scene


# --- Helpers ---

static func _build_combine_command(character: String, segments: Array, mode: String) -> CommandData:
	if segments.size() == 0:
		return null
	# Concatenate segment text for typewriter display / backlog
	var full_text := ""
	for seg in segments:
		full_text += String(seg.get("text", ""))
	# Primary voice = first segment's voice (used by #voice: field / replay button)
	var primary_voice := String(segments[0].get("voice", ""))
	return _make_cmd("dialogue", {
		"character": character,
		"text": full_text,
		"voice": primary_voice,
		"mode": mode,
		"segments": segments.duplicate(true),
	})


static func _make_cmd(type: String, params: Dictionary) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


static func _split_args(text: String) -> Array:
	var result: Array = []
	for part in text.split(" "):
		var stripped = part.strip_edges()
		if stripped != "":
			result.append(stripped)
	return result
