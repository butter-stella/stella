using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "char_hide" command — publishes a CharHideEvent via EventBus.
    /// </summary>
    public class CharHideCommandHandler : ICommandHandler
    {
        public string CommandType => "char_hide";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var character = data.GetString("character");
            var transition = data.GetString("transition");
            var duration = data.GetFloat("duration");

            EventBus.EventBus.Publish(new CharHideEvent(character, transition, duration));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
