namespace Natsume.Core.ScriptParser
{
    public enum DslTokenType
    {
        SceneDirective,   // @scene id ["title"]
        AtCommand,        // @bg, @show, @hide, @expr, @set, @if, @else, @end, @jump, etc.
        Dialogue,         // sakura「text」 [#voice:id] [#face:expr]
        Narration,        // 「text」
        Monologue,        // sakura（text）
        ChoiceOption,     // - "text" -> target [{var op val}] [?if expr]
        Unknown,          // Unrecognized line — preserved for Parser to handle
    }

    public readonly struct DslToken
    {
        public readonly DslTokenType Type;
        public readonly string RawText;
        public readonly int Line;
        public readonly int Indent;

        public DslToken(DslTokenType type, string rawText, int line, int indent = 0)
        {
            Type = type;
            RawText = rawText;
            Line = line;
            Indent = indent;
        }

        public override string ToString()
        {
            return $"[L{Line}] {Type}: {RawText}";
        }
    }
}
