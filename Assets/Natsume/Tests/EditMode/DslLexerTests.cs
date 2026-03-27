using System.Collections.Generic;
using NUnit.Framework;
using Natsume.Core.ScriptParser;

namespace Natsume.Tests.EditMode
{
    public class DslLexerTests
    {
        [Test]
        public void Tokenize_EmptyString_ReturnsEmptyList()
        {
            var tokens = DslLexer.Tokenize("");
            Assert.AreEqual(0, tokens.Count);
        }

        [Test]
        public void Tokenize_Null_ReturnsEmptyList()
        {
            var tokens = DslLexer.Tokenize(null);
            Assert.AreEqual(0, tokens.Count);
        }

        [Test]
        public void Tokenize_CommentsOnly_ReturnsEmptyList()
        {
            var tokens = DslLexer.Tokenize("// this is a comment\n// another comment");
            Assert.AreEqual(0, tokens.Count);
        }

        [Test]
        public void Tokenize_BlankLines_ReturnsEmptyList()
        {
            var tokens = DslLexer.Tokenize("\n\n   \n\t\n");
            Assert.AreEqual(0, tokens.Count);
        }

        // === SceneDirective ===

        [Test]
        public void Tokenize_SceneDirective_WithTitle()
        {
            var tokens = DslLexer.Tokenize("@scene start \"初次相遇\"");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.SceneDirective, tokens[0].Type);
            Assert.AreEqual("@scene start \"初次相遇\"", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_SceneDirective_WithoutTitle()
        {
            var tokens = DslLexer.Tokenize("@scene ending");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.SceneDirective, tokens[0].Type);
            Assert.AreEqual("@scene ending", tokens[0].RawText);
        }

        // === AtCommand ===

        [Test]
        public void Tokenize_AtCommand_Bg()
        {
            var tokens = DslLexer.Tokenize("@bg bg_school fade 0.8");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
            Assert.AreEqual("@bg bg_school fade 0.8", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_AtCommand_Show()
        {
            var tokens = DslLexer.Tokenize("@show sakura smile left");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Hide()
        {
            var tokens = DslLexer.Tokenize("@hide sakura");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_HideAll()
        {
            var tokens = DslLexer.Tokenize("@hide all");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
            Assert.AreEqual("@hide all", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_AtCommand_Expr()
        {
            var tokens = DslLexer.Tokenize("@expr sakura surprised");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Set()
        {
            var tokens = DslLexer.Tokenize("@set talked_to_sakura = true");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_If()
        {
            var tokens = DslLexer.Tokenize("@if sakura_affection >= 10");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Else()
        {
            var tokens = DslLexer.Tokenize("@else");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_End()
        {
            var tokens = DslLexer.Tokenize("@end");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Jump()
        {
            var tokens = DslLexer.Tokenize("@jump good_ending");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Choice()
        {
            var tokens = DslLexer.Tokenize("@choice \"你该怎么回应？\"");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Bgm()
        {
            var tokens = DslLexer.Tokenize("@bgm bgm_spring 1.5");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        [Test]
        public void Tokenize_AtCommand_Cg()
        {
            var tokens = DslLexer.Tokenize("@cg sakura_chibi sd 2s");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
        }

        // === Dialogue ===

        [Test]
        public void Tokenize_Dialogue_Basic()
        {
            var tokens = DslLexer.Tokenize("sakura「你好，初次见面。」");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
            Assert.AreEqual("sakura「你好，初次见面。」", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_Dialogue_WithVoiceTag()
        {
            var tokens = DslLexer.Tokenize("sakura「你好。」 #voice:sakura_001");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
            Assert.AreEqual("sakura「你好。」 #voice:sakura_001", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_Dialogue_WithFaceTag()
        {
            var tokens = DslLexer.Tokenize("sakura「太好了！」 #face:happy");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
        }

        [Test]
        public void Tokenize_Dialogue_WithMultipleTags()
        {
            var tokens = DslLexer.Tokenize("sakura「你好。」 #voice:sakura_001 #face:smile");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
        }

        [Test]
        public void Tokenize_Dialogue_WithInlineExpression()
        {
            var tokens = DslLexer.Tokenize("sakura「开心...[surprised]但是...[cry]呜呜」");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
        }

        [Test]
        public void Tokenize_Dialogue_WithInlineEffects()
        {
            var tokens = DslLexer.Tokenize("sakura「那个人就是..{wait:500}{speed:0.3}你吗？」");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[0].Type);
        }

        // === Narration ===

        [Test]
        public void Tokenize_Narration_Basic()
        {
            var tokens = DslLexer.Tokenize("「窗外下起了雨。」");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Narration, tokens[0].Type);
            Assert.AreEqual("「窗外下起了雨。」", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_Narration_WithParentheses()
        {
            var tokens = DslLexer.Tokenize("「（第一天就这样结束了。）」");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Narration, tokens[0].Type);
        }

        // === Monologue ===

        [Test]
        public void Tokenize_Monologue_Basic()
        {
            var tokens = DslLexer.Tokenize("sakura（这个人...好奇怪。）");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Monologue, tokens[0].Type);
            Assert.AreEqual("sakura（这个人...好奇怪。）", tokens[0].RawText);
        }

        // === ChoiceOption ===

        [Test]
        public void Tokenize_ChoiceOption_Basic()
        {
            var tokens = DslLexer.Tokenize("  - \"你好\" -> scene_a");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.ChoiceOption, tokens[0].Type);
        }

        [Test]
        public void Tokenize_ChoiceOption_WithSet()
        {
            var tokens = DslLexer.Tokenize("  - \"你好\" -> scene_a {affection += 5}");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.ChoiceOption, tokens[0].Type);
        }

        [Test]
        public void Tokenize_ChoiceOption_WithCondition()
        {
            var tokens = DslLexer.Tokenize("  - \"一起走吧\" -> scene_go {affection += 5} ?if affection >= 5");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.ChoiceOption, tokens[0].Type);
        }

        [Test]
        public void Tokenize_ChoiceOption_PreservesIndent()
        {
            var tokens = DslLexer.Tokenize("    - \"选项\" -> target");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(4, tokens[0].Indent);
        }

        [Test]
        public void Tokenize_ChoiceOption_ChineseQuotes()
        {
            var tokens = DslLexer.Tokenize("  - "你好" -> scene_a");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.ChoiceOption, tokens[0].Type);
        }

        // === Line Numbers ===

        [Test]
        public void Tokenize_PreservesLineNumbers()
        {
            var input = "// comment\n@scene start\nsakura「你好。」\n\n@jump ending";
            var tokens = DslLexer.Tokenize(input);
            Assert.AreEqual(3, tokens.Count);
            Assert.AreEqual(2, tokens[0].Line); // @scene on line 2
            Assert.AreEqual(3, tokens[1].Line); // dialogue on line 3
            Assert.AreEqual(5, tokens[2].Line); // @jump on line 5
        }

        // === Unknown ===

        [Test]
        public void Tokenize_UnrecognizedLine_ReturnsUnknownToken()
        {
            var tokens = DslLexer.Tokenize("some random text without brackets");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.Unknown, tokens[0].Type);
            Assert.AreEqual("some random text without brackets", tokens[0].RawText);
        }

        [Test]
        public void Tokenize_UnknownLine_PreservesLineNumber()
        {
            var tokens = DslLexer.Tokenize("@bg bg_school\nunknown line here\nsakura「你好。」");
            Assert.AreEqual(3, tokens.Count);
            Assert.AreEqual(DslTokenType.Unknown, tokens[1].Type);
            Assert.AreEqual(2, tokens[1].Line);
        }

        // === Mixed Scenario ===

        [Test]
        public void Tokenize_FullPocDemo()
        {
            var input = @"// poc_demo.ntm

@scene start ""初次相遇""

@bg bg_school_gate fade 0.8
@show sakura smile center

sakura「你好，初次见面！我叫樱。」
sakura「你是新转来的同学吧？」

@choice ""你该怎么回应？""
  - ""你好，请多关照！"" -> friendly {affection += 5}
  - ""……嗯。"" -> cold

//========================================
@scene friendly

@expr sakura happy
sakura「太好了，感觉我们能成为好朋友！」
@jump ending

//========================================
@scene cold

@expr sakura sad
sakura「啊……这样啊。那、那我先走了。」
@jump ending

//========================================
@scene ending

「（第一天就这样结束了。）」
@hide sakura
@bg bg_black fade 1.0
@end";

            var tokens = DslLexer.Tokenize(input);

            // Count by type
            int scenes = 0, commands = 0, dialogues = 0, narrations = 0, choices = 0;
            foreach (var t in tokens)
            {
                switch (t.Type)
                {
                    case DslTokenType.SceneDirective: scenes++; break;
                    case DslTokenType.AtCommand: commands++; break;
                    case DslTokenType.Dialogue: dialogues++; break;
                    case DslTokenType.Narration: narrations++; break;
                    case DslTokenType.ChoiceOption: choices++; break;
                }
            }

            Assert.AreEqual(4, scenes);     // start, friendly, cold, ending
            // @bg, @show, @choice, @expr, @jump, @expr, @jump, @hide, @bg, @end = 10
            Assert.AreEqual(10, commands);
            Assert.AreEqual(4, dialogues);   // 2 in start + 1 in friendly + 1 in cold
            Assert.AreEqual(1, narrations);  // ending narration
            Assert.AreEqual(2, choices);     // 2 choice options
        }

        [Test]
        public void Tokenize_CommentsInterspersed_AreSkipped()
        {
            var input = "@bg bg_school\n// this is a comment\nsakura「你好。」\n// another";
            var tokens = DslLexer.Tokenize(input);
            Assert.AreEqual(2, tokens.Count);
            Assert.AreEqual(DslTokenType.AtCommand, tokens[0].Type);
            Assert.AreEqual(DslTokenType.Dialogue, tokens[1].Type);
        }

        [Test]
        public void Tokenize_WindowsLineEndings_Handled()
        {
            var input = "@scene start\r\nsakura「你好。」\r\n@end";
            var tokens = DslLexer.Tokenize(input);
            Assert.AreEqual(3, tokens.Count);
        }

        [Test]
        public void Tokenize_TabIndentation_ConvertedToSpaces()
        {
            var tokens = DslLexer.Tokenize("\t- \"选项\" -> target");
            Assert.AreEqual(1, tokens.Count);
            Assert.AreEqual(DslTokenType.ChoiceOption, tokens[0].Type);
            Assert.AreEqual(2, tokens[0].Indent); // tab → 2 spaces
        }
    }
}
