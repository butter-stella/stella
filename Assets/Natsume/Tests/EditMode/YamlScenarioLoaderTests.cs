using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Data;
using Natsume.Core.ScriptParser;

namespace Natsume.Tests.EditMode
{
    public class YamlScenarioLoaderTests
    {
        [Test]
        public async Task Load_SimpleScenario_ParsesCorrectly()
        {
            var yaml = @"
id: chapter_01
title: First Chapter
scenes:
  - id: start
    commands:
      - type: dialogue
        params:
          character: sakura
          text: Hello!
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            Assert.IsNotNull(result);
            Assert.AreEqual("chapter_01", result.Id);
            Assert.AreEqual("First Chapter", result.Title);
            Assert.AreEqual(1, result.Scenes.Count);
            Assert.AreEqual("start", result.Scenes[0].Id);
        }

        [Test]
        public async Task Load_ParsesCommands()
        {
            var yaml = @"
id: test
scenes:
  - id: start
    commands:
      - type: bg
        params:
          asset: bg_school
          transition: fade
          duration: 0.8
      - type: dialogue
        params:
          character: sakura
          text: Hello!
          voice: sakura_001
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            Assert.AreEqual(2, result.Scenes[0].Commands.Count);

            var bgCmd = result.Scenes[0].Commands[0];
            Assert.AreEqual("bg", bgCmd.Type);
            Assert.AreEqual("bg_school", bgCmd.GetString("asset"));
            Assert.AreEqual("fade", bgCmd.GetString("transition"));

            var dlgCmd = result.Scenes[0].Commands[1];
            Assert.AreEqual("dialogue", dlgCmd.Type);
            Assert.AreEqual("sakura", dlgCmd.GetString("character"));
            Assert.AreEqual("Hello!", dlgCmd.GetString("text"));
            Assert.AreEqual("sakura_001", dlgCmd.GetString("voice"));
        }

        [Test]
        public async Task Load_MultipleScenes()
        {
            var yaml = @"
id: test
scenes:
  - id: scene_a
    commands:
      - type: dialogue
        params:
          text: A
  - id: scene_b
    commands:
      - type: dialogue
        params:
          text: B
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            Assert.AreEqual(2, result.Scenes.Count);
            Assert.AreEqual("scene_a", result.Scenes[0].Id);
            Assert.AreEqual("scene_b", result.Scenes[1].Id);
        }

        [Test]
        public async Task Load_ChoiceWithOptions()
        {
            var yaml = @"
id: test
scenes:
  - id: start
    commands:
      - type: choice
        params:
          prompt: Choose wisely
          options:
            - text: Option A
              jump: scene_a
            - text: Option B
              jump: scene_b
              set:
                affection: '+5'
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            var cmd = result.Scenes[0].Commands[0];
            Assert.AreEqual("choice", cmd.Type);
            Assert.AreEqual("Choose wisely", cmd.GetString("prompt"));
            Assert.IsTrue(cmd.HasKey("options"));
        }

        [Test]
        public async Task Load_EmptyYaml_ReturnsNull()
        {
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync("");

            Assert.IsNull(result);
        }

        [Test]
        public async Task Load_CommandWithNoParams()
        {
            var yaml = @"
id: test
scenes:
  - id: start
    commands:
      - type: end
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            var cmd = result.Scenes[0].Commands[0];
            Assert.AreEqual("end", cmd.Type);
            Assert.AreEqual(0, cmd.Parameters.Count);
        }

        [Test]
        public async Task Load_NumericValues_ParsedCorrectly()
        {
            var yaml = @"
id: test
scenes:
  - id: start
    commands:
      - type: bg
        params:
          asset: bg_school
          duration: 1.5
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            var cmd = result.Scenes[0].Commands[0];
            Assert.AreEqual(1.5f, cmd.GetFloat("duration"), 0.001f);
        }

        [Test]
        public async Task Load_DialogueWithColonInText()
        {
            var yaml = @"
id: test
scenes:
  - id: start
    commands:
      - type: dialogue
        params:
          character: sakura
          text: 樱：你好啊，初次见面
";
            var loader = new YamlScenarioLoader();
            var result = await loader.LoadFromStringAsync(yaml);

            var cmd = result.Scenes[0].Commands[0];
            Assert.AreEqual("樱：你好啊，初次见面", cmd.GetString("text"));
        }
    }
}
