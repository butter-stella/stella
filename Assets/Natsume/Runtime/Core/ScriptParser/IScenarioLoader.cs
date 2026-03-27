using System.Threading.Tasks;
using Natsume.Core.Data;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Abstraction for loading scenario data from various sources (YAML files, in-memory, etc.).
    /// </summary>
    public interface IScenarioLoader
    {
        Task<ScenarioData> LoadAsync(string scenarioId);
    }
}
