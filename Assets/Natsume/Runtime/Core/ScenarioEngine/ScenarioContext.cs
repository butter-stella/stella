using Natsume.Core.Data;

namespace Natsume.Core.ScenarioEngine
{
    /// <summary>
    /// Runtime context for scenario execution.
    /// Holds the current execution state (scenario, scene, command pointer).
    /// Will be expanded in Sprint 2 with VariableStore, call stack, etc.
    /// </summary>
    public class ScenarioContext
    {
        public ScenarioData CurrentScenario { get; set; }
        public string CurrentSceneId { get; set; }
        public int CommandIndex { get; set; }
    }
}
