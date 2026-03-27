using System;
using System.Collections.Generic;
using System.Linq;

namespace Natsume.Core.Data
{
    /// <summary>
    /// Top-level scenario data: metadata + ordered list of scenes.
    /// </summary>
    public class ScenarioData
    {
        public string Id { get; set; }
        public string Title { get; set; }
        public List<SceneData> Scenes { get; set; } = new List<SceneData>();

        public SceneData GetScene(string sceneId)
        {
            return Scenes.FirstOrDefault(s =>
                string.Equals(s.Id, sceneId, StringComparison.Ordinal));
        }
    }
}
