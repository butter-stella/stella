## Parses DslToken list into ScenarioData.
## Fills smart defaults, expands @if/@else/@end into synthetic scenes.
class_name DslParser extends RefCounted


static func parse(tokens: Array, scenario_id: String = "unnamed") -> ScenarioData:
	var data = ScenarioData.new()
	data.id = scenario_id

	var current_scene: SceneData = null
	var pending_options: Array = []
	var choice_cmd: CommandData = null

	# @if/@else/@end state
	var if_stack: Array = []  # Array of IfContext

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

			DslToken.Type.AT_COMMAND:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []

				var cmd_name = _get_at_command_name(token.raw_text)

				if cmd_name == "choice":
					choice_cmd = _parse_choice_command(token)
				elif cmd_name == "if":
					if_stack.append(_create_if_context(token, current_scene, data))
				elif cmd_name == "else":
					if if_stack.size() > 0:
						if_stack[-1]["branch"] = "else"
				elif cmd_name == "end":
					if if_stack.size() > 0:
						current_scene = _close_if_block(if_stack.pop_back(), data)
					# else: @end at scene level, ignore
				else:
					var cmd = _parse_at_command(token)
					if cmd and current_scene:
						_add_command(cmd, current_scene, if_stack)

			DslToken.Type.DIALOGUE:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_dialogue(token)
				if cmd and current_scene:
					_add_command(cmd, current_scene, if_stack)

			DslToken.Type.NARRATION:
				_flush_choice(choice_cmd, pending_options, current_scene, if_stack)
				choice_cmd = null
				pending_options = []
				var cmd = _parse_narration(token)
				if cmd and current_scene:
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

static func _parse_dialogue(token: DslToken) -> CommandData:
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
		"mode": "adv",
	})


static func _parse_narration(token: DslToken) -> CommandData:
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
		"mode": "adv",
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


static func _close_if_block(ctx: Dictionary, data: ScenarioData) -> SceneData:
	var parent_scene: SceneData = ctx["parent_scene"]
	var base_id = "__if_%s_%d" % [ctx["scene_id"], ctx["line"]]

	# Create synthetic scenes
	var then_scene = SceneData.new()
	then_scene.id = base_id + "_then"
	for cmd in ctx["then_commands"]:
		then_scene.commands.append(cmd)

	var cont_scene = SceneData.new()
	cont_scene.id = base_id + "_cont"

	# Add jump to continuation at end of then branch
	var then_jump = _make_cmd("jump", {"target": cont_scene.id})
	then_scene.commands.append(then_jump)

	data.scenes.append(then_scene)

	var else_jump_target = cont_scene.id
	if ctx["else_commands"].size() > 0:
		var else_scene = SceneData.new()
		else_scene.id = base_id + "_else"
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
