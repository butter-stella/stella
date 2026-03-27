using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "jump" command — sets the engine's pending jump target.
    /// The ScenarioEngine checks for pending jumps after each command.
    /// </summary>
    public class JumpCommandHandler : ICommandHandler
    {
        public string CommandType => "jump";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            context.PendingJump = data.GetString("target");
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
