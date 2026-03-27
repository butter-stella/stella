using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "char_show" command — publishes a CharShowEvent via EventBus.
    /// </summary>
    public class CharShowCommandHandler : ICommandHandler
    {
        public string CommandType => "char_show";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var character = data.GetString("character");
            if (string.IsNullOrEmpty(character))
            {
                EventBus.EventBus.Logger?.Invoke("[CharShowCommandHandler] Missing required 'character' parameter, skipping.");
                return Task.CompletedTask;
            }

            var expression = data.GetString("expression");
            var position = data.GetString("position", "center");
            var transition = data.GetString("transition");
            var duration = data.GetFloat("duration");

            EventBus.EventBus.Publish(new CharShowEvent(character, expression, position, transition, duration));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
