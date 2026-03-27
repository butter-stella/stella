using Natsume.Core.Data;

namespace Natsume.Core.ScenarioEngine
{
    /// <summary>
    /// Runtime context for scenario execution.
    /// Holds current execution state and is passed to every command handler.
    /// </summary>
    public class ScenarioContext
    {
        public ScenarioData CurrentScenario { get; set; }
        public string CurrentSceneId { get; set; }
        public int CommandIndex { get; set; }

        /// <summary>
        /// Set by jump/condition handlers. The engine checks this after each command
        /// and performs the scene transition if non-null.
        /// </summary>
        public string PendingJump { get; set; }

        /// <summary>
        /// Set to true by an "end" command or when there are no more scenes to execute.
        /// </summary>
        public bool IsFinished { get; set; }
    }
}
