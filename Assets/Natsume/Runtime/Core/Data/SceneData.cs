using System.Collections.Generic;

namespace Natsume.Core.Data
{
    /// <summary>
    /// A single scene containing an ordered list of commands.
    /// </summary>
    public class SceneData
    {
        public string Id { get; set; }
        public string Title { get; set; }
        public List<CommandData> Commands { get; set; } = new List<CommandData>();
    }
}
