using System.Collections.Generic;
using System.Threading.Tasks;
using Natsume.Core.Data;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// In-memory scenario loader for testing and prototyping.
    /// Scenarios are registered programmatically rather than loaded from files.
    /// </summary>
    public class InMemoryScenarioLoader : IScenarioLoader
    {
        private readonly Dictionary<string, ScenarioData> _scenarios = new Dictionary<string, ScenarioData>();

        public void Register(string scenarioId, ScenarioData scenario)
        {
            _scenarios[scenarioId] = scenario;
        }

        public Task<ScenarioData> LoadAsync(string scenarioId)
        {
            _scenarios.TryGetValue(scenarioId, out var scenario);
            return Task.FromResult(scenario);
        }

        public bool HasScenario(string scenarioId)
        {
            return _scenarios.ContainsKey(scenarioId);
        }
    }
}
