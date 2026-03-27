using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "condition" command — evaluates an expression and jumps accordingly.
    /// </summary>
    public class ConditionCommandHandler : ICommandHandler
    {
        public string CommandType => "condition";

        private readonly ExpressionEvaluator _evaluator;

        public ConditionCommandHandler(ExpressionEvaluator evaluator)
        {
            _evaluator = evaluator;
        }

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var expression = data.GetString("if");
            var thenJump = data.GetString("then_jump");
            var elseJump = data.GetString("else_jump");

            if (_evaluator.Evaluate(expression))
            {
                if (thenJump != null)
                    context.PendingJump = thenJump;
            }
            else
            {
                if (elseJump != null)
                    context.PendingJump = elseJump;
            }

            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
