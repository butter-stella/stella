using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Interface for handling a specific command type.
    /// Each command type (dialogue, bg, char_show, etc.) has its own handler.
    /// </summary>
    public interface ICommandHandler
    {
        /// <summary>
        /// The command type this handler processes (corresponds to YAML "type" field).
        /// </summary>
        string CommandType { get; }

        /// <summary>
        /// Execute the command asynchronously.
        /// </summary>
        Task ExecuteAsync(CommandData data, ScenarioContext context);

        /// <summary>
        /// Rollback the command's effects (used for undo/backtrack).
        /// </summary>
        void Rollback(CommandData data, ScenarioContext context);
    }
}
