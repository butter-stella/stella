using System.Collections.Generic;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Line-oriented lexer for .ntm DSL files.
    /// Each non-empty, non-comment line maps to exactly one DslToken.
    /// </summary>
    public static class DslLexer
    {
        public static List<DslToken> Tokenize(string source)
        {
            var tokens = new List<DslToken>();
            if (string.IsNullOrEmpty(source))
                return tokens;

            // Normalize: strip CR, split by LF
            source = source.Replace("\r", "");
            var lines = source.Split('\n');

            for (int i = 0; i < lines.Length; i++)
            {
                var lineNum = i + 1;
                var raw = lines[i];

                // Convert tabs to 2 spaces
                raw = raw.Replace("\t", "  ");

                // Measure indent before trimming
                int indent = 0;
                while (indent < raw.Length && raw[indent] == ' ')
                    indent++;

                var trimmed = raw.Trim();

                // Skip blank lines and comments
                if (string.IsNullOrEmpty(trimmed))
                    continue;
                if (trimmed.StartsWith("//"))
                    continue;

                var token = ClassifyLine(trimmed, lineNum, indent);
                if (token.HasValue)
                    tokens.Add(token.Value);
            }

            return tokens;
        }

        private static DslToken? ClassifyLine(string trimmed, int line, int indent)
        {
            // 1. @scene directive
            if (trimmed.StartsWith("@scene ") || trimmed == "@scene")
                return new DslToken(DslTokenType.SceneDirective, trimmed, line, indent);

            // 2. Other @ commands
            if (trimmed.StartsWith("@"))
                return new DslToken(DslTokenType.AtCommand, trimmed, line, indent);

            // 3. Choice option: starts with - followed by quote
            if (IsChoiceOption(trimmed))
                return new DslToken(DslTokenType.ChoiceOption, trimmed, line, indent);

            // 4. Narration: starts with 「
            if (trimmed.StartsWith("\u300C")) // 「
                return new DslToken(DslTokenType.Narration, trimmed, line, indent);

            // 5. Dialogue: contains 「...」 with character prefix
            if (ContainsDialogueBrackets(trimmed))
                return new DslToken(DslTokenType.Dialogue, trimmed, line, indent);

            // 6. Monologue: contains （...） with character prefix
            if (ContainsMonologueBrackets(trimmed))
                return new DslToken(DslTokenType.Monologue, trimmed, line, indent);

            // Unknown line — skip silently for now
            // Future: could emit a warning via EventBus.Logger
            return null;
        }

        private static bool IsChoiceOption(string trimmed)
        {
            // - "text" or - "text" (Chinese/English quotes)
            if (!trimmed.StartsWith("- "))
                return false;

            var afterDash = trimmed.Substring(2).TrimStart();
            return afterDash.StartsWith("\"") ||   // ASCII double quote
                   afterDash.StartsWith("\u201C") || // "  left double quotation mark
                   afterDash.StartsWith("\uFF02");   // ＂ fullwidth quotation mark
        }

        private static bool ContainsDialogueBrackets(string text)
        {
            // Must contain both 「 and 」, and 「 must not be at position 0 (that's narration)
            int open = text.IndexOf('\u300C'); // 「
            int close = text.IndexOf('\u300D'); // 」
            return open > 0 && close > open;
        }

        private static bool ContainsMonologueBrackets(string text)
        {
            // Must contain both （ and ）, with character prefix before （
            int open = text.IndexOf('\uFF08'); // （
            int close = text.IndexOf('\uFF09'); // ）
            return open > 0 && close > open;
        }
    }
}
