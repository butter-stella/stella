using System.Collections.Generic;
using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "choice" command — parses options from CommandData and publishes a ShowChoiceEvent.
    /// </summary>
    public class ChoiceCommandHandler : ICommandHandler
    {
        public string CommandType => "choice";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var prompt = data.GetString("prompt");
            var rawOptions = data.Get<List<Dictionary<string, object>>>("options");
            var options = new List<ChoiceOption>();

            if (rawOptions != null)
            {
                for (int i = 0; i < rawOptions.Count; i++)
                {
                    var raw = rawOptions[i];
                    var option = new ChoiceOption
                    {
                        Id = raw.ContainsKey("id") ? raw["id"]?.ToString() : i.ToString(),
                        Label = raw.ContainsKey("text") ? raw["text"]?.ToString() : null,
                        Jump = raw.ContainsKey("jump") ? raw["jump"]?.ToString() : null,
                        Condition = raw.ContainsKey("condition") ? raw["condition"]?.ToString() : null
                    };

                    if (raw.ContainsKey("set") && raw["set"] is Dictionary<string, object> setDict)
                    {
                        foreach (var kv in setDict)
                        {
                            option.Set[kv.Key] = kv.Value?.ToString();
                        }
                    }

                    options.Add(option);
                }
            }

            EventBus.EventBus.Publish(new ShowChoiceEvent(prompt, options));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
