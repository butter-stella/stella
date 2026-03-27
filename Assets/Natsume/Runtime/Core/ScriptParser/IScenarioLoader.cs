using System.Threading.Tasks;
using Natsume.Core.Data;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Abstraction for loading scenario data from various sources (YAML files, in-memory, etc.).
    /// </summary>
    public interface IScenarioLoader
    {
        /// <summary>
        /// Loads a scenario by its identifier.
        /// Returns null if the scenario is not found. Callers must handle null
        /// (e.g., ScenarioEngine throws if the loaded scenario is null).
        /// </summary>
        Task<ScenarioData> LoadAsync(string scenarioId);
    }
}
