using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "dialogue" command — publishes a ShowDialogueEvent via EventBus.
    /// </summary>
    public class DialogueCommandHandler : ICommandHandler
    {
        public string CommandType => "dialogue";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var character = data.GetString("character");
            var text = data.GetString("text");
            var voice = data.GetString("voice");
            var mode = data.GetString("mode", "adv");

            EventBus.EventBus.Publish(new ShowDialogueEvent(character, text, voice, mode));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
