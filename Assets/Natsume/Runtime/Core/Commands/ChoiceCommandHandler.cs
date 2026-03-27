using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "choice" command — parses options, publishes ShowChoiceEvent,
    /// then awaits ChoiceSelectedEvent to apply jump and variable assignments.
    /// </summary>
    public class ChoiceCommandHandler : ICommandHandler
    {
        public string CommandType => "choice";

        private readonly VariableStore _variables;

        public ChoiceCommandHandler(VariableStore variables = null)
        {
            _variables = variables;
        }

        public async Task ExecuteAsync(CommandData data, ScenarioContext context)
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

            var tcs = new TaskCompletionSource<string>();
            Action<ChoiceSelectedEvent> handler = null;
            handler = e =>
            {
                EventBus.EventBus.Unsubscribe(handler);
                tcs.TrySetResult(e.SelectedOptionId);
            };
            EventBus.EventBus.Subscribe(handler);

            EventBus.EventBus.Publish(new ShowChoiceEvent(prompt, options));

            var selectedId = await tcs.Task;

            // Find selected option and apply jump/set
            var selected = options.Find(o => o.Id == selectedId);
            if (selected != null)
            {
                if (!string.IsNullOrEmpty(selected.Jump))
                {
                    context.PendingJump = selected.Jump;
                }

                if (_variables != null && selected.Set != null)
                {
                    foreach (var kv in selected.Set)
                    {
                        _variables.Set(kv.Key, kv.Value, VariableScope.Scenario);
                    }
                }
            }
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
