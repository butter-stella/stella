using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "dialogue" command — publishes ShowDialogueEvent, then awaits
    /// AdvanceEvent before returning (blocks the engine until player advances).
    /// </summary>
    public class DialogueCommandHandler : ICommandHandler
    {
        public string CommandType => "dialogue";

        private readonly WaitController _wait = new WaitController();

        public async Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var character = data.GetString("character");
            var text = data.GetString("text");
            var voice = data.GetString("voice");
            var mode = data.GetString("mode", "adv");

            EventBus.EventBus.Publish(new ShowDialogueEvent(character, text, voice, mode));

            await _wait.WaitForAdvanceAsync();
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
