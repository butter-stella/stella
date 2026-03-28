extends GutTest
## Tests for ScenarioData, SceneData, and ChoiceData.
## These classes are globally registered via class_name, no preload needed.


# --- ScenarioData ---

func test_scenario_data_has_id_and_title():
	var s = ScenarioData.new()
	s.id = "chapter_01"
	s.title = "First Chapter"
	assert_eq(s.id, "chapter_01")
	assert_eq(s.title, "First Chapter")


func test_scenario_data_holds_scenes():
	var s = ScenarioData.new()
	var scene = SceneData.new()
	scene.id = "start"
	s.scenes.append(scene)
	assert_eq(s.scenes.size(), 1)
	assert_eq(s.scenes[0].id, "start")


func test_scenario_get_scene_by_id():
	var s = ScenarioData.new()
	var scene1 = SceneData.new()
	scene1.id = "start"
	var scene2 = SceneData.new()
	scene2.id = "ending"
	s.scenes.append(scene1)
	s.scenes.append(scene2)
	assert_eq(s.get_scene("ending").id, "ending")
	assert_eq(s.get_scene("start").id, "start")


func test_scenario_get_scene_returns_null_for_missing():
	var s = ScenarioData.new()
	assert_null(s.get_scene("nonexistent"))


func test_scenario_get_scene_index():
	var s = ScenarioData.new()
	var scene1 = SceneData.new()
	scene1.id = "start"
	var scene2 = SceneData.new()
	scene2.id = "ending"
	s.scenes.append(scene1)
	s.scenes.append(scene2)
	assert_eq(s.get_scene_index("start"), 0)
	assert_eq(s.get_scene_index("ending"), 1)
	assert_eq(s.get_scene_index("missing"), -1)


# --- SceneData ---

func test_scene_data_holds_commands():
	var scene = SceneData.new()
	scene.id = "test_scene"
	var cmd = CommandData.new()
	cmd.type = "dialogue"
	cmd.params = {"text": "Hello"}
	scene.commands.append(cmd)
	assert_eq(scene.commands.size(), 1)
	assert_eq(scene.commands[0].type, "dialogue")


func test_scene_data_empty_commands():
	var scene = SceneData.new()
	scene.id = "empty"
	assert_eq(scene.commands.size(), 0)


# --- ChoiceData ---

func test_choice_data_has_prompt_and_options():
	var choice = ChoiceData.new()
	choice.prompt = "What do you do?"
	var opt = ChoiceData.ChoiceOption.new()
	opt.id = "go"
	opt.label = "Go"
	opt.jump = "scene_go"
	choice.options.append(opt)
	assert_eq(choice.prompt, "What do you do?")
	assert_eq(choice.options.size(), 1)
	assert_eq(choice.options[0].id, "go")
	assert_eq(choice.options[0].label, "Go")
	assert_eq(choice.options[0].jump, "scene_go")


func test_choice_option_set_field():
	var opt = ChoiceData.ChoiceOption.new()
	opt.set_vars = {"affection": "+5"}
	assert_eq(opt.set_vars["affection"], "+5")


func test_choice_option_condition():
	var opt = ChoiceData.ChoiceOption.new()
	opt.condition = "affection >= 5"
	assert_eq(opt.condition, "affection >= 5")


func test_choice_option_defaults():
	var opt = ChoiceData.ChoiceOption.new()
	assert_eq(opt.id, "")
	assert_eq(opt.label, "")
	assert_eq(opt.jump, "")
	assert_eq(opt.condition, "")
	assert_eq(opt.set_vars.size(), 0)
