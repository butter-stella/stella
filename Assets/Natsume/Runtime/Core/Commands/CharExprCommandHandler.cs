using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "char_expr" command — publishes ChangeExpressionEvent.
    /// Used for @expr DSL directive to change a displayed character's expression.
    /// </summary>
    public class CharExprCommandHandler : ICommandHandler
    {
        public string CommandType => "char_expr";

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var character = data.GetString("character");
            var expression = data.GetString("expression");

            if (string.IsNullOrEmpty(character) || string.IsNullOrEmpty(expression))
            {
                EventBus.EventBus.Logger?.Invoke(
                    "[CharExprCommandHandler] Missing required 'character' or 'expression' parameter, skipping.");
                return Task.CompletedTask;
            }

            EventBus.EventBus.Publish(new ChangeExpressionEvent(character, expression));
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
