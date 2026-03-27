using System;
using System.Collections.Generic;
using System.Globalization;
using Natsume.Core.Data;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Parses a DslToken stream into ScenarioData.
    /// Handles default value injection, @if/@else/@end flattening, and mode tracking.
    /// </summary>
    public static class DslParser
    {
        public static ScenarioData Parse(List<DslToken> tokens, string scenarioId)
        {
            var scenario = new ScenarioData { Id = scenarioId };
            if (tokens == null || tokens.Count == 0)
                return scenario;

            var ctx = new ParseContext(scenario);

            for (ctx.Index = 0; ctx.Index < tokens.Count; ctx.Index++)
            {
                var token = tokens[ctx.Index];

                switch (token.Type)
                {
                    case DslTokenType.SceneDirective:
                        HandleSceneDirective(token, ctx);
                        break;

                    case DslTokenType.AtCommand:
                        HandleAtCommand(token, ctx, tokens);
                        break;

                    case DslTokenType.Dialogue:
                        RequireScene(token, ctx);
                        ctx.CurrentCommands.Add(ParseDialogue(token, ctx.CurrentMode));
                        break;

                    case DslTokenType.Narration:
                        RequireScene(token, ctx);
                        ctx.CurrentCommands.Add(ParseNarration(token, ctx.CurrentMode));
                        break;

                    case DslTokenType.Monologue:
                        RequireScene(token, ctx);
                        ctx.CurrentCommands.Add(ParseMonologue(token));
                        break;

                    case DslTokenType.ChoiceOption:
                        // Choice options are consumed by HandleChoice; stray option is an error
                        throw new DslParseException(token.Line, "Choice option outside of @choice block.");

                    case DslTokenType.Unknown:
                        throw new DslParseException(token.Line, $"Unrecognized line: {token.RawText}");
                }
            }

            return scenario;
        }

        // ─── Scene ───

        private static void HandleSceneDirective(DslToken token, ParseContext ctx)
        {
            // @scene id ["title"]
            var rest = token.RawText.Substring("@scene".Length).Trim();
            string id;
            string title = null;

            int quoteStart = rest.IndexOf('"');
            if (quoteStart >= 0)
            {
                id = rest.Substring(0, quoteStart).Trim();
                int quoteEnd = rest.IndexOf('"', quoteStart + 1);
                if (quoteEnd > quoteStart)
                    title = rest.Substring(quoteStart + 1, quoteEnd - quoteStart - 1);
            }
            else
            {
                id = rest;
            }

            if (string.IsNullOrEmpty(id))
                throw new DslParseException(token.Line, "@scene requires an id.");

            var scene = new SceneData { Id = id, Title = title };
            ctx.Scenario.Scenes.Add(scene);
            ctx.CurrentScene = scene;
            ctx.CurrentCommands = scene.Commands;
            ctx.CurrentMode = "adv";
        }

        // ─── AtCommand dispatch ───

        private static void HandleAtCommand(DslToken token, ParseContext ctx, List<DslToken> tokens)
        {
            var raw = token.RawText;
            var parts = SplitCommand(raw);
            var directive = parts[0]; // e.g. "@bg"

            switch (directive)
            {
                case "@bg":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseBg(parts, token));
                    break;

                case "@show":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseShow(parts, token));
                    break;

                case "@hide":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseHide(parts, token));
                    break;

                case "@expr":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseExpr(parts, token));
                    break;

                case "@set":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseSet(raw, token));
                    break;

                case "@jump":
                    RequireScene(token, ctx);
                    ctx.CurrentCommands.Add(ParseJump(parts, token));
                    break;

                case "@choice":
                    RequireScene(token, ctx);
                    HandleChoice(token, ctx, tokens);
                    break;

                case "@if":
                    RequireScene(token, ctx);
                    HandleIf(token, ctx, tokens);
                    break;

                case "@else":
                    throw new DslParseException(token.Line, "@else without matching @if.");

                case "@end":
                    // @end at scene level (outside @if) is a no-op; engine stops at end of commands.
                    // If we're not in an if-block, just ignore it.
                    // But if there's a stray @end with no scene, that's an error.
                    if (ctx.CurrentScene == null)
                        throw new DslParseException(token.Line, "@end without matching @if or @scene.");
                    break;

                case "@nvl":
                    RequireScene(token, ctx);
                    if (parts.Length >= 2 && parts[1] == "off")
                        ctx.CurrentMode = "adv";
                    else
                        ctx.CurrentMode = "nvl";
                    break;

                case "@overlay":
                    RequireScene(token, ctx);
                    if (parts.Length >= 2 && parts[1] == "off")
                        ctx.CurrentMode = "adv";
                    else
                        ctx.CurrentMode = "overlay";
                    break;

                default:
                    throw new DslParseException(token.Line, $"Unknown directive: {directive}");
            }
        }

        // ─── Dialogue / Narration / Monologue ───

        private static CommandData ParseDialogue(DslToken token, string mode)
        {
            var raw = token.RawText;
            int openBracket = raw.IndexOf('\u300C'); // 「
            int closeBracket = raw.LastIndexOf('\u300D'); // 」

            var character = raw.Substring(0, openBracket).Trim();
            var text = raw.Substring(openBracket + 1, closeBracket - openBracket - 1);

            var afterClose = raw.Substring(closeBracket + 1).Trim();
            var tags = ParseInlineTags(afterClose);

            var p = new Dictionary<string, object>
            {
                { "character", character },
                { "text", text },
                { "mode", mode }
            };

            if (tags.TryGetValue("voice", out var voice))
                p["voice"] = voice;
            if (tags.TryGetValue("face", out var face))
                p["face"] = face;

            return new CommandData("dialogue", p);
        }

        private static CommandData ParseNarration(DslToken token, string mode)
        {
            var raw = token.RawText;
            int open = raw.IndexOf('\u300C');
            int close = raw.LastIndexOf('\u300D');
            var text = raw.Substring(open + 1, close - open - 1);

            return new CommandData("dialogue", new Dictionary<string, object>
            {
                { "text", text },
                { "mode", mode }
            });
        }

        private static CommandData ParseMonologue(DslToken token)
        {
            var raw = token.RawText;
            int open = raw.IndexOf('\uFF08'); // （
            int close = raw.LastIndexOf('\uFF09'); // ）

            var character = raw.Substring(0, open).Trim();
            var text = raw.Substring(open + 1, close - open - 1);

            return new CommandData("dialogue", new Dictionary<string, object>
            {
                { "character", character },
                { "text", text },
                { "mode", "monologue" }
            });
        }

        // ─── @bg ───

        private static CommandData ParseBg(string[] parts, DslToken token)
        {
            if (parts.Length < 2)
                throw new DslParseException(token.Line, "@bg requires an asset name.");

            var p = new Dictionary<string, object>
            {
                { "asset", parts[1] },
                { "transition", parts.Length >= 3 ? parts[2] : "fade" },
                { "duration", parts.Length >= 4 ? ParseFloat(parts[3], token) : 0.5f }
            };

            return new CommandData("bg", p);
        }

        // ─── @show ───

        private static CommandData ParseShow(string[] parts, DslToken token)
        {
            if (parts.Length < 2)
                throw new DslParseException(token.Line, "@show requires a character name.");

            var p = new Dictionary<string, object>
            {
                { "character", parts[1] },
                { "expression", parts.Length >= 3 ? parts[2] : "default" },
                { "position", parts.Length >= 4 ? parts[3] : "center" }
            };

            return new CommandData("char_show", p);
        }

        // ─── @hide ───

        private static CommandData ParseHide(string[] parts, DslToken token)
        {
            if (parts.Length < 2)
                throw new DslParseException(token.Line, "@hide requires a character name or 'all'.");

            return new CommandData("char_hide", new Dictionary<string, object>
            {
                { "character", parts[1] }
            });
        }

        // ─── @expr ───

        private static CommandData ParseExpr(string[] parts, DslToken token)
        {
            if (parts.Length < 3)
                throw new DslParseException(token.Line, "@expr requires character and expression.");

            return new CommandData("char_expr", new Dictionary<string, object>
            {
                { "character", parts[1] },
                { "expression", parts[2] }
            });
        }

        // ─── @set ───

        private static CommandData ParseSet(string raw, DslToken token)
        {
            // @set var = value | @set var += value | @set var -= value
            var rest = raw.Substring("@set".Length).Trim();

            string op = "=";
            int opIdx = -1;
            int opLen = 1;

            // Check compound operators first
            foreach (var compOp in new[] { "+=", "-=" })
            {
                var idx = rest.IndexOf(compOp, StringComparison.Ordinal);
                if (idx > 0)
                {
                    op = compOp;
                    opIdx = idx;
                    opLen = 2;
                    break;
                }
            }

            if (opIdx < 0)
            {
                opIdx = rest.IndexOf('=');
                if (opIdx < 0)
                    throw new DslParseException(token.Line, "@set requires an assignment operator.");
            }

            var varName = rest.Substring(0, opIdx).Trim();
            var value = rest.Substring(opIdx + opLen).Trim();

            var p = new Dictionary<string, object>
            {
                { "var", varName },
                { "value", value }
            };

            if (op != "=")
                p["op"] = op;

            return new CommandData("set", p);
        }

        // ─── @jump ───

        private static CommandData ParseJump(string[] parts, DslToken token)
        {
            if (parts.Length < 2)
                throw new DslParseException(token.Line, "@jump requires a target scene id.");

            return new CommandData("jump", new Dictionary<string, object>
            {
                { "target", parts[1] }
            });
        }

        // ─── @choice ───

        private static void HandleChoice(DslToken token, ParseContext ctx, List<DslToken> tokens)
        {
            // Parse prompt from @choice line
            var rest = token.RawText.Substring("@choice".Length).Trim();
            string prompt = null;
            if (rest.Length > 0)
                prompt = StripQuotes(rest);

            // Collect subsequent ChoiceOption tokens
            var options = new List<Dictionary<string, object>>();
            while (ctx.Index + 1 < tokens.Count && tokens[ctx.Index + 1].Type == DslTokenType.ChoiceOption)
            {
                ctx.Index++;
                options.Add(ParseChoiceOption(tokens[ctx.Index]));
            }

            var p = new Dictionary<string, object>
            {
                { "options", options }
            };
            if (prompt != null)
                p["prompt"] = prompt;

            ctx.CurrentCommands.Add(new CommandData("choice", p));
        }

        private static Dictionary<string, object> ParseChoiceOption(DslToken token)
        {
            // - "text" -> target [{var op val}] [?if expr]
            var raw = token.RawText;

            // Skip "- "
            var content = raw.Substring(raw.IndexOf('-') + 1).Trim();

            // Extract text (in quotes)
            string text;
            int afterText;
            ExtractQuotedString(content, out text, out afterText);

            var remaining = content.Substring(afterText).Trim();

            var option = new Dictionary<string, object> { { "text", text } };

            // Extract -> target
            int arrowIdx = remaining.IndexOf("->", StringComparison.Ordinal);
            if (arrowIdx >= 0)
            {
                var afterArrow = remaining.Substring(arrowIdx + 2).Trim();

                // Find the end of target (next space, {, or end)
                int targetEnd = afterArrow.Length;
                for (int i = 0; i < afterArrow.Length; i++)
                {
                    if (afterArrow[i] == ' ' || afterArrow[i] == '{' || afterArrow[i] == '?')
                    {
                        targetEnd = i;
                        break;
                    }
                }

                option["jump"] = afterArrow.Substring(0, targetEnd).Trim();
                remaining = afterArrow.Substring(targetEnd).Trim();
            }

            // Extract {var op val}
            int braceOpen = remaining.IndexOf('{');
            int braceClose = remaining.IndexOf('}');
            if (braceOpen >= 0 && braceClose > braceOpen)
            {
                var setContent = remaining.Substring(braceOpen + 1, braceClose - braceOpen - 1).Trim();
                option["set"] = ParseSetExpression(setContent);
                remaining = remaining.Substring(braceClose + 1).Trim();
            }

            // Extract ?if expr
            int ifIdx = remaining.IndexOf("?if", StringComparison.Ordinal);
            if (ifIdx >= 0)
            {
                option["condition"] = remaining.Substring(ifIdx + 3).Trim();
            }

            return option;
        }

        private static Dictionary<string, string> ParseSetExpression(string content)
        {
            // "sakura_affection += 5" → { "sakura_affection": "+= 5" }
            var result = new Dictionary<string, string>();

            foreach (var compOp in new[] { "+=", "-=", "=" })
            {
                var idx = content.IndexOf(compOp, StringComparison.Ordinal);
                if (idx > 0)
                {
                    var varName = content.Substring(0, idx).Trim();
                    var rest = content.Substring(idx).Trim(); // includes operator
                    result[varName] = rest;
                    return result;
                }
            }

            return result;
        }

        // ─── @if / @else / @end flattening ───

        private static void HandleIf(DslToken ifToken, ParseContext ctx, List<DslToken> tokens)
        {
            var expression = ifToken.RawText.Substring("@if".Length).Trim();
            if (string.IsNullOrEmpty(expression))
                throw new DslParseException(ifToken.Line, "@if requires a condition expression.");

            var sceneId = ctx.CurrentScene.Id;
            var lineNum = ifToken.Line;
            var prefix = $"__if_{sceneId}_{lineNum}";

            var thenCommands = new List<CommandData>();
            var elseCommands = new List<CommandData>();
            var afterCommands = new List<CommandData>();

            var currentBranch = thenCommands;
            bool foundEnd = false;

            while (ctx.Index + 1 < tokens.Count)
            {
                ctx.Index++;
                var t = tokens[ctx.Index];

                // Check for @else
                if (t.Type == DslTokenType.AtCommand && t.RawText.Trim() == "@else")
                {
                    currentBranch = elseCommands;
                    continue;
                }

                // Check for @end
                if (t.Type == DslTokenType.AtCommand && t.RawText.Trim() == "@end")
                {
                    foundEnd = true;
                    // Collect remaining commands in this scene until next @scene or EOF
                    while (ctx.Index + 1 < tokens.Count &&
                           tokens[ctx.Index + 1].Type != DslTokenType.SceneDirective)
                    {
                        ctx.Index++;
                        var remaining = tokens[ctx.Index];
                        var cmd = ParseSingleToken(remaining, ctx, tokens);
                        if (cmd != null)
                            afterCommands.Add(cmd);
                    }
                    break;
                }

                // Check for nested @scene (end of current scene scope)
                if (t.Type == DslTokenType.SceneDirective)
                {
                    // Push back — let the main loop handle it
                    ctx.Index--;
                    foundEnd = true;
                    break;
                }

                // Parse command and add to current branch
                var parsed = ParseSingleToken(t, ctx, tokens);
                if (parsed != null)
                    currentBranch.Add(parsed);
            }

            if (!foundEnd)
                throw new DslParseException(ifToken.Line, "@if without matching @end.");

            // Generate synthetic scenes
            var thenSceneId = $"{prefix}_then";
            var elseSceneId = $"{prefix}_else";
            var contSceneId = $"{prefix}_cont";

            bool hasAfter = afterCommands.Count > 0;
            var jumpTarget = hasAfter ? contSceneId : null;

            // Then scene
            var thenScene = new SceneData { Id = thenSceneId };
            thenScene.Commands.AddRange(thenCommands);
            if (jumpTarget != null && !EndsWithJump(thenCommands))
                thenScene.Commands.Add(MakeJump(jumpTarget));
            ctx.Scenario.Scenes.Add(thenScene);

            // Else scene (even if empty — @else branch might be empty or absent)
            var elseScene = new SceneData { Id = elseSceneId };
            elseScene.Commands.AddRange(elseCommands);
            if (jumpTarget != null && !EndsWithJump(elseCommands))
                elseScene.Commands.Add(MakeJump(jumpTarget));
            ctx.Scenario.Scenes.Add(elseScene);

            // Continuation scene (only if there are commands after @end)
            if (hasAfter)
            {
                var contScene = new SceneData { Id = contSceneId };
                contScene.Commands.AddRange(afterCommands);
                ctx.Scenario.Scenes.Add(contScene);
            }

            // Insert condition command in current scene
            ctx.CurrentCommands.Add(new CommandData("condition", new Dictionary<string, object>
            {
                { "if", expression },
                { "then_jump", thenSceneId },
                { "else_jump", elseSceneId }
            }));
        }

        private static bool EndsWithJump(List<CommandData> commands)
        {
            if (commands.Count == 0) return false;
            var last = commands[commands.Count - 1];
            return last.Type == "jump";
        }

        private static CommandData MakeJump(string target)
        {
            return new CommandData("jump", new Dictionary<string, object>
            {
                { "target", target }
            });
        }

        /// <summary>
        /// Parse a single token into a CommandData (used inside @if blocks).
        /// Returns null for mode-switch directives (@nvl, @overlay).
        /// </summary>
        private static CommandData ParseSingleToken(DslToken token, ParseContext ctx, List<DslToken> tokens)
        {
            switch (token.Type)
            {
                case DslTokenType.Dialogue:
                    return ParseDialogue(token, ctx.CurrentMode);

                case DslTokenType.Narration:
                    return ParseNarration(token, ctx.CurrentMode);

                case DslTokenType.Monologue:
                    return ParseMonologue(token);

                case DslTokenType.AtCommand:
                    var parts = SplitCommand(token.RawText);
                    switch (parts[0])
                    {
                        case "@bg": return ParseBg(parts, token);
                        case "@show": return ParseShow(parts, token);
                        case "@hide": return ParseHide(parts, token);
                        case "@expr": return ParseExpr(parts, token);
                        case "@set": return ParseSet(token.RawText, token);
                        case "@jump": return ParseJump(parts, token);
                        case "@nvl":
                            ctx.CurrentMode = (parts.Length >= 2 && parts[1] == "off") ? "adv" : "nvl";
                            return null;
                        case "@overlay":
                            ctx.CurrentMode = (parts.Length >= 2 && parts[1] == "off") ? "adv" : "overlay";
                            return null;
                        default:
                            throw new DslParseException(token.Line, $"Unknown directive in @if block: {parts[0]}");
                    }

                case DslTokenType.ChoiceOption:
                    throw new DslParseException(token.Line, "Choice option inside @if block is not supported.");

                default:
                    throw new DslParseException(token.Line, $"Unexpected token: {token.RawText}");
            }
        }

        // ─── Utilities ───

        private static void RequireScene(DslToken token, ParseContext ctx)
        {
            if (ctx.CurrentScene == null)
                throw new DslParseException(token.Line, "Command before any @scene directive.");
        }

        private static string[] SplitCommand(string raw)
        {
            // Split on whitespace, but be careful with quoted strings
            var parts = new List<string>();
            int i = 0;
            while (i < raw.Length)
            {
                // Skip whitespace
                while (i < raw.Length && raw[i] == ' ') i++;
                if (i >= raw.Length) break;

                if (raw[i] == '"')
                {
                    // Quoted string
                    int end = raw.IndexOf('"', i + 1);
                    if (end < 0) end = raw.Length - 1;
                    parts.Add(raw.Substring(i, end - i + 1));
                    i = end + 1;
                }
                else
                {
                    // Unquoted word
                    int start = i;
                    while (i < raw.Length && raw[i] != ' ') i++;
                    parts.Add(raw.Substring(start, i - start));
                }
            }
            return parts.ToArray();
        }

        private static Dictionary<string, string> ParseInlineTags(string text)
        {
            // Parse #key:value tags
            var tags = new Dictionary<string, string>();
            int i = 0;
            while (i < text.Length)
            {
                int hashIdx = text.IndexOf('#', i);
                if (hashIdx < 0) break;

                int colonIdx = text.IndexOf(':', hashIdx);
                if (colonIdx < 0) break;

                var key = text.Substring(hashIdx + 1, colonIdx - hashIdx - 1).Trim();

                // Value goes until next # or end
                int valueEnd = text.IndexOf('#', colonIdx + 1);
                if (valueEnd < 0) valueEnd = text.Length;
                var value = text.Substring(colonIdx + 1, valueEnd - colonIdx - 1).Trim();

                tags[key] = value;
                i = valueEnd;
            }
            return tags;
        }

        private static string StripQuotes(string s)
        {
            s = s.Trim();
            if (s.Length >= 2)
            {
                if ((s[0] == '"' && s[s.Length - 1] == '"') ||
                    (s[0] == '\u201C' && s[s.Length - 1] == '\u201D'))
                    return s.Substring(1, s.Length - 2);
            }
            return s;
        }

        private static void ExtractQuotedString(string content, out string text, out int afterIndex)
        {
            // Find opening quote (ASCII or Chinese)
            int openIdx = -1;
            char closeChar = '"';

            for (int i = 0; i < content.Length; i++)
            {
                if (content[i] == '"')
                {
                    openIdx = i;
                    closeChar = '"';
                    break;
                }
                if (content[i] == '\u201C') // "
                {
                    openIdx = i;
                    closeChar = '\u201D'; // "
                    break;
                }
                if (content[i] == '\uFF02') // ＂
                {
                    openIdx = i;
                    closeChar = '\uFF02';
                    break;
                }
            }

            if (openIdx < 0)
            {
                text = content;
                afterIndex = content.Length;
                return;
            }

            int closeIdx = content.IndexOf(closeChar, openIdx + 1);
            if (closeIdx < 0)
            {
                text = content.Substring(openIdx + 1);
                afterIndex = content.Length;
                return;
            }

            text = content.Substring(openIdx + 1, closeIdx - openIdx - 1);
            afterIndex = closeIdx + 1;
        }

        private static float ParseFloat(string s, DslToken token)
        {
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var f))
                return f;
            throw new DslParseException(token.Line, $"Expected a number, got '{s}'.");
        }

        // ─── Parse Context ───

        private class ParseContext
        {
            public readonly ScenarioData Scenario;
            public SceneData CurrentScene;
            public List<CommandData> CurrentCommands;
            public string CurrentMode = "adv";
            public int Index;

            public ParseContext(ScenarioData scenario)
            {
                Scenario = scenario;
            }
        }
    }
}
