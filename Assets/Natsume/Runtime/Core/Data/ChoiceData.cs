using System.Collections.Generic;

namespace Natsume.Core.Data
{
    /// <summary>
    /// Data for a choice command, supporting arbitrary presentation styles.
    /// </summary>
    public class ChoiceData
    {
        public string Style { get; set; }
        public string Prompt { get; set; }
        public List<ChoiceOption> Options { get; set; } = new List<ChoiceOption>();
        public Dictionary<string, object> Extra { get; set; } = new Dictionary<string, object>();
    }

    /// <summary>
    /// A single choice option.
    /// </summary>
    public class ChoiceOption
    {
        public string Id { get; set; }
        public string Label { get; set; }
        public string Jump { get; set; }
        public Dictionary<string, string> Set { get; set; } = new Dictionary<string, string>();
        public string Condition { get; set; }
        public Dictionary<string, object> Extra { get; set; } = new Dictionary<string, object>();
    }
}
