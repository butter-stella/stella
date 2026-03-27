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
    }

    public struct DslToken
    {
        public DslTokenType Type;
        public string RawText;
        public int Line;
        public int Indent;

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
