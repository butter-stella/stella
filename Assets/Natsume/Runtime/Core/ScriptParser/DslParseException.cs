using System;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Exception thrown when the DSL parser encounters invalid syntax.
    /// Carries the source line number for error reporting.
    /// </summary>
    public class DslParseException : Exception
    {
        public int Line { get; }

        public DslParseException(int line, string message)
            : base($"Line {line}: {message}")
        {
            Line = line;
        }

        public DslParseException(int line, string message, Exception innerException)
            : base($"Line {line}: {message}", innerException)
        {
            Line = line;
        }
    }
}
