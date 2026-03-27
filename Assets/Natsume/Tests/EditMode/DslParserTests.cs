using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using Natsume.Core.Data;
using Natsume.Core.ScriptParser;

namespace Natsume.Tests.EditMode
{
    [TestFixture]
    public class DslParserTests
    {
        // ─── Helpers ───

        private ScenarioData Parse(string dsl, string scenarioId = "test")
        {
            var tokens = DslLexer.Tokenize(dsl);
            return DslParser.Parse(tokens, scenarioId);
        }

        private CommandData Cmd(ScenarioData data, string sceneId, int index)
        {
            var scene = data.GetScene(sceneId);
            Assert.IsNotNull(scene, $"Scene '{sceneId}' not found");
            Assert.IsTrue(index < scene.Commands.Count,
                $"Command index {index} out of range (scene '{sceneId}' has {scene.Commands.Count} commands)");
            return scene.Commands[index];
        }

        // ─── Empty / Minimal ───

        [Test]
        public void Parse_EmptyTokens_ReturnsEmptyScenario()
        {
            var result = Parse("");
            Assert.AreEqual("test", result.Id);
            Assert.AreEqual(0, result.Scenes.Count);
        }

        [Test]
        public void Parse_SingleScene_NoCommands()
        {
            var result = Parse("@scene start");
            Assert.AreEqual(1, result.Scenes.Count);
            Assert.AreEqual("start", result.Scenes[0].Id);
            Assert.AreEqual(0, result.Scenes[0].Commands.Count);
        }

        [Test]
        public void Parse_SceneWithTitle()
        {
            var result = Parse("@scene start \"序章\"");
            Assert.AreEqual("start", result.Scenes[0].Id);
            Assert.AreEqual("序章", result.Scenes[0].Title);
        }

        // ─── Dialogue ───

        [Test]
        public void Parse_BasicDialogue()
        {
            var result = Parse("@scene s\nsakura「你好。」");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("dialogue", cmd.Type);
            Assert.AreEqual("sakura", cmd.GetString("character"));
            Assert.AreEqual("你好。", cmd.GetString("text"));
            Assert.AreEqual("adv", cmd.GetString("mode"));
        }

        [Test]
        public void Parse_DialogueWithVoice()
        {
            var result = Parse("@scene s\nsakura「你好。」 #voice:sakura_001");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("sakura_001", cmd.GetString("voice"));
        }

        [Test]
        public void Parse_DialogueWithFace()
        {
            var result = Parse("@scene s\nsakura「你好。」 #face:happy");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("happy", cmd.GetString("face"));
        }

        [Test]
        public void Parse_DialogueWithVoiceAndFace()
        {
            var result = Parse("@scene s\nsakura「你好。」 #voice:sakura_001 #face:happy");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("sakura_001", cmd.GetString("voice"));
            Assert.AreEqual("happy", cmd.GetString("face"));
        }

        [Test]
        public void Parse_Narration()
        {
            var result = Parse("@scene s\n「窗外下起了雨。」");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("dialogue", cmd.Type);
            Assert.IsNull(cmd.GetString("character"));
            Assert.AreEqual("窗外下起了雨。", cmd.GetString("text"));
        }

        [Test]
        public void Parse_Monologue()
        {
            var result = Parse("@scene s\nsakura（这个人...好奇怪。）");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("dialogue", cmd.Type);
            Assert.AreEqual("sakura", cmd.GetString("character"));
            Assert.AreEqual("这个人...好奇怪。", cmd.GetString("text"));
            Assert.AreEqual("monologue", cmd.GetString("mode"));
        }

        // ─── Background ───

        [Test]
        public void Parse_Bg_Defaults()
        {
            var result = Parse("@scene s\n@bg bg_school");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("bg", cmd.Type);
            Assert.AreEqual("bg_school", cmd.GetString("asset"));
            Assert.AreEqual("fade", cmd.GetString("transition"));
            Assert.AreEqual(0.5f, cmd.GetFloat("duration"), 0.001f);
        }

        [Test]
        public void Parse_Bg_WithTransitionAndDuration()
        {
            var result = Parse("@scene s\n@bg bg_sunset dissolve 1.0");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("bg_sunset", cmd.GetString("asset"));
            Assert.AreEqual("dissolve", cmd.GetString("transition"));
            Assert.AreEqual(1.0f, cmd.GetFloat("duration"), 0.001f);
        }

        // ─── Show / Hide / Expr ───

        [Test]
        public void Parse_Show_Defaults()
        {
            var result = Parse("@scene s\n@show sakura");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("char_show", cmd.Type);
            Assert.AreEqual("sakura", cmd.GetString("character"));
            Assert.AreEqual("default", cmd.GetString("expression"));
            Assert.AreEqual("center", cmd.GetString("position"));
        }

        [Test]
        public void Parse_Show_FullParams()
        {
            var result = Parse("@scene s\n@show sakura smile left");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("sakura", cmd.GetString("character"));
            Assert.AreEqual("smile", cmd.GetString("expression"));
            Assert.AreEqual("left", cmd.GetString("position"));
        }

        [Test]
        public void Parse_Hide_SingleCharacter()
        {
            var result = Parse("@scene s\n@hide sakura");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("char_hide", cmd.Type);
            Assert.AreEqual("sakura", cmd.GetString("character"));
        }

        [Test]
        public void Parse_Hide_All()
        {
            var result = Parse("@scene s\n@hide all");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("char_hide", cmd.Type);
            Assert.AreEqual("all", cmd.GetString("character"));
        }

        [Test]
        public void Parse_Expr()
        {
            var result = Parse("@scene s\n@expr sakura surprised");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("char_expr", cmd.Type);
            Assert.AreEqual("sakura", cmd.GetString("character"));
            Assert.AreEqual("surprised", cmd.GetString("expression"));
        }

        // ─── Set ───

        [Test]
        public void Parse_Set_SimpleAssignment()
        {
            var result = Parse("@scene s\n@set talked_to_sakura = true");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("set", cmd.Type);
            Assert.AreEqual("talked_to_sakura", cmd.GetString("var"));
            Assert.AreEqual("true", cmd.GetString("value"));
        }

        [Test]
        public void Parse_Set_PlusEquals()
        {
            var result = Parse("@scene s\n@set sakura_affection += 5");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("set", cmd.Type);
            Assert.AreEqual("sakura_affection", cmd.GetString("var"));
            Assert.AreEqual("5", cmd.GetString("value"));
            Assert.AreEqual("+=", cmd.GetString("op"));
        }

        [Test]
        public void Parse_Set_MinusEquals()
        {
            var result = Parse("@scene s\n@set hp -= 10");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("-=", cmd.GetString("op"));
            Assert.AreEqual("10", cmd.GetString("value"));
        }

        // ─── Jump ───

        [Test]
        public void Parse_Jump()
        {
            var result = Parse("@scene s\n@jump scene_002");
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("jump", cmd.Type);
            Assert.AreEqual("scene_002", cmd.GetString("target"));
        }

        // ─── Choice ───

        [Test]
        public void Parse_Choice_Basic()
        {
            var dsl = @"@scene s
@choice
  - ""一起走吧"" -> scene_go
  - ""今天有点忙..."" -> scene_busy";

            var result = Parse(dsl);
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("choice", cmd.Type);
            var options = cmd.Get<List<Dictionary<string, object>>>("options");
            Assert.IsNotNull(options);
            Assert.AreEqual(2, options.Count);
            Assert.AreEqual("一起走吧", options[0]["text"]);
            Assert.AreEqual("scene_go", options[0]["jump"]);
            Assert.AreEqual("今天有点忙...", options[1]["text"]);
            Assert.AreEqual("scene_busy", options[1]["jump"]);
        }

        [Test]
        public void Parse_Choice_WithPrompt()
        {
            var dsl = @"@scene s
@choice ""你该怎么回应？""
  - ""走吧"" -> go";

            var result = Parse(dsl);
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("你该怎么回应？", cmd.GetString("prompt"));
        }

        [Test]
        public void Parse_Choice_WithSetAndCondition()
        {
            var dsl = @"@scene s
@choice
  - ""一起走吧"" -> scene_go {sakura_affection += 5}
  - ""特别选项"" -> scene_special ?if sakura_affection >= 10";

            var result = Parse(dsl);
            var cmd = Cmd(result, "s", 0);

            var options = cmd.Get<List<Dictionary<string, object>>>("options");

            // First option has structured set: { var, op, value }
            var set0 = options[0]["set"] as Dictionary<string, string>;
            Assert.IsNotNull(set0);
            Assert.AreEqual("sakura_affection", set0["var"]);
            Assert.AreEqual("+=", set0["op"]);
            Assert.AreEqual("5", set0["value"]);

            // Second option has condition
            Assert.AreEqual("sakura_affection >= 10", options[1]["condition"]);
        }

        // ─── @if / @else / @end — Flattening ───

        [Test]
        public void Parse_IfElseEnd_GeneratesSyntheticScenes()
        {
            var dsl = @"@scene start
@if has_key
  sakura「有钥匙！」
@else
  sakura「没钥匙...」
@end";

            var result = Parse(dsl);

            // Original scene should have a condition command
            var condCmd = Cmd(result, "start", 0);
            Assert.AreEqual("condition", condCmd.Type);
            Assert.AreEqual("has_key", condCmd.GetString("if"));

            var thenJump = condCmd.GetString("then_jump");
            var elseJump = condCmd.GetString("else_jump");
            Assert.IsNotNull(thenJump);
            Assert.IsNotNull(elseJump);

            // Synthetic then-scene should have the dialogue
            var thenScene = result.GetScene(thenJump);
            Assert.IsNotNull(thenScene);
            Assert.AreEqual("dialogue", thenScene.Commands[0].Type);
            Assert.AreEqual("有钥匙！", thenScene.Commands[0].GetString("text"));

            // Synthetic else-scene should have the dialogue
            var elseScene = result.GetScene(elseJump);
            Assert.IsNotNull(elseScene);
            Assert.AreEqual("dialogue", elseScene.Commands[0].Type);
            Assert.AreEqual("没钥匙...", elseScene.Commands[0].GetString("text"));
        }

        [Test]
        public void Parse_IfEnd_NoElse_BothBranchesJoinContinuation()
        {
            var dsl = @"@scene start
@if has_key
  sakura「有钥匙！」
@end
sakura「继续对话。」";

            var result = Parse(dsl);

            var condCmd = Cmd(result, "start", 0);
            var thenJump = condCmd.GetString("then_jump");
            var elseJump = condCmd.GetString("else_jump");

            // Then scene has dialogue + jump to continuation
            var thenScene = result.GetScene(thenJump);
            Assert.IsNotNull(thenScene);
            Assert.AreEqual("dialogue", thenScene.Commands[0].Type);
            Assert.AreEqual("有钥匙！", thenScene.Commands[0].GetString("text"));
            Assert.AreEqual("jump", thenScene.Commands[1].Type);

            // Else scene (empty body) jumps directly to continuation
            var elseScene = result.GetScene(elseJump);
            Assert.IsNotNull(elseScene);
            Assert.AreEqual(1, elseScene.Commands.Count);
            Assert.AreEqual("jump", elseScene.Commands[0].Type);

            // Both jump to the same continuation scene
            var contTarget = thenScene.Commands[1].GetString("target");
            Assert.AreEqual(contTarget, elseScene.Commands[0].GetString("target"));

            // Continuation scene has the remaining dialogue
            var contScene = result.GetScene(contTarget);
            Assert.IsNotNull(contScene);
            Assert.AreEqual("dialogue", contScene.Commands[0].Type);
            Assert.AreEqual("继续对话。", contScene.Commands[0].GetString("text"));
        }

        [Test]
        public void Parse_IfWithJumpInBranch()
        {
            var dsl = @"@scene start
@if score >= 10
  @jump good_ending
@else
  @jump bad_ending
@end";

            var result = Parse(dsl);
            var condCmd = Cmd(result, "start", 0);

            var thenScene = result.GetScene(condCmd.GetString("then_jump"));
            Assert.AreEqual("jump", thenScene.Commands[0].Type);
            Assert.AreEqual("good_ending", thenScene.Commands[0].GetString("target"));

            var elseScene = result.GetScene(condCmd.GetString("else_jump"));
            Assert.AreEqual("jump", elseScene.Commands[0].Type);
            Assert.AreEqual("bad_ending", elseScene.Commands[0].GetString("target"));
        }

        // ─── NVL / Overlay mode ───

        [Test]
        public void Parse_NvlMode_SetsDialogueMode()
        {
            var dsl = @"@scene s
@nvl
「旁白一。」
「旁白二。」
@nvl off
sakura「普通对话。」";

            var result = Parse(dsl);
            var cmds = result.GetScene("s").Commands;

            Assert.AreEqual("nvl", cmds[0].GetString("mode"));
            Assert.AreEqual("nvl", cmds[1].GetString("mode"));
            Assert.AreEqual("adv", cmds[2].GetString("mode"));
        }

        [Test]
        public void Parse_OverlayMode()
        {
            var dsl = @"@scene s
@overlay
「（独白文字）」
@overlay off";

            var result = Parse(dsl);
            var cmd = Cmd(result, "s", 0);

            Assert.AreEqual("overlay", cmd.GetString("mode"));
        }

        // ─── Multiple scenes ───

        [Test]
        public void Parse_MultipleScenes()
        {
            var dsl = @"@scene scene_a
sakura「你好。」
@scene scene_b
kaito「再见。」";

            var result = Parse(dsl);
            Assert.AreEqual(2, result.Scenes.Count);
            Assert.AreEqual("scene_a", result.Scenes[0].Id);
            Assert.AreEqual("scene_b", result.Scenes[1].Id);

            Assert.AreEqual("sakura", Cmd(result, "scene_a", 0).GetString("character"));
            Assert.AreEqual("kaito", Cmd(result, "scene_b", 0).GetString("character"));
        }

        // ─── @end (scenario end) ───

        [Test]
        public void Parse_End_AsScenarioEnd()
        {
            var dsl = @"@scene s
「结束。」
@end";

            var result = Parse(dsl);
            var scene = result.GetScene("s");

            // @end at scene level (not inside @if) is just a marker; no extra command needed
            // The engine naturally stops when commands run out
            Assert.AreEqual(1, scene.Commands.Count);
            Assert.AreEqual("dialogue", scene.Commands[0].Type);
        }

        // ─── Full demo (DSL.md POC) ───

        [Test]
        public void Parse_PocDemo_FullScenario()
        {
            var dsl = @"@scene start ""初次相遇""

@bg bg_school_gate fade 0.8
@show sakura smile center

sakura「你好，初次见面！我叫樱。」
sakura「你是新转来的同学吧？」

@choice ""你该怎么回应？""
  - ""你好，请多关照！"" -> friendly {affection += 5}
  - ""……嗯。"" -> cold

@scene friendly

@expr sakura happy
sakura「太好了，感觉我们能成为好朋友！」
@jump ending

@scene cold

@expr sakura sad
sakura「啊……这样啊。那、那我先走了。」
@jump ending

@scene ending

「（第一天就这样结束了。）」
@hide sakura
@bg bg_black fade 1.0
@end";

            var result = Parse(dsl);

            // Verify scene count (4 user-defined scenes, no synthetic needed)
            Assert.AreEqual(4, result.Scenes.Count);

            // Scene: start
            var startScene = result.GetScene("start");
            Assert.AreEqual("初次相遇", startScene.Title);
            Assert.AreEqual("bg", startScene.Commands[0].Type);
            Assert.AreEqual("bg_school_gate", startScene.Commands[0].GetString("asset"));
            Assert.AreEqual("char_show", startScene.Commands[1].Type);
            Assert.AreEqual("dialogue", startScene.Commands[2].Type);
            Assert.AreEqual("dialogue", startScene.Commands[3].Type);
            Assert.AreEqual("choice", startScene.Commands[4].Type);

            // Choice options
            var options = startScene.Commands[4].Get<List<Dictionary<string, object>>>("options");
            Assert.AreEqual(2, options.Count);
            Assert.AreEqual("friendly", options[0]["jump"]);
            Assert.AreEqual("cold", options[1]["jump"]);

            // Scene: friendly
            var friendlyScene = result.GetScene("friendly");
            Assert.AreEqual("char_expr", friendlyScene.Commands[0].Type);
            Assert.AreEqual("happy", friendlyScene.Commands[0].GetString("expression"));
            Assert.AreEqual("dialogue", friendlyScene.Commands[1].Type);
            Assert.AreEqual("jump", friendlyScene.Commands[2].Type);

            // Scene: ending
            var endingScene = result.GetScene("ending");
            Assert.AreEqual("dialogue", endingScene.Commands[0].Type);
            Assert.IsNull(endingScene.Commands[0].GetString("character"));
            Assert.AreEqual("char_hide", endingScene.Commands[1].Type);
            Assert.AreEqual("bg", endingScene.Commands[2].Type);
        }

        // ─── Error handling ───

        [Test]
        public void Parse_CommandBeforeAnyScene_ThrowsParseException()
        {
            Assert.Throws<DslParseException>(() => Parse("sakura「你好。」"));
        }

        [Test]
        public void Parse_EndBeforeScene_ThrowsParseException()
        {
            Assert.Throws<DslParseException>(() => Parse("@end"));
        }

        [Test]
        public void Parse_UnmatchedElse_ThrowsParseException()
        {
            Assert.Throws<DslParseException>(() => Parse("@scene s\n@else"));
        }
    }
}
