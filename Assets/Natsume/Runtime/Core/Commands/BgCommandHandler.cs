using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "bg" command — publishes a ShowBgEvent via EventBus.
    /// </summary>
    public class BgCommandHandler : ICommandHandler
    {
        public string CommandType => "bg";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var asset = data.GetString("asset");
            var transition = data.GetString("transition");
            var duration = data.GetFloat("duration");

            EventBus.EventBus.Publish(new ShowBgEvent(asset, transition, duration));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
