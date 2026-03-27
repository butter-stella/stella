using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "set" command — sets a variable value.
    /// </summary>
    public class SetCommandHandler : ICommandHandler
    {
        public string CommandType => "set";

        private readonly VariableStore _variables;

        public SetCommandHandler(VariableStore variables)
        {
            _variables = variables;
        }

        public Task ExecuteAsync(CommandData data, ScenarioContext context)
        {
            var name = data.GetString("var");
            if (string.IsNullOrEmpty(name))
                return Task.CompletedTask;
            var value = data.Parameters.ContainsKey("value") ? data.Parameters["value"] : null;
            var scopeStr = data.GetString("scope", "scenario");

            VariableScope scope;
            switch (scopeStr.ToLowerInvariant())
            {
                case "global": scope = VariableScope.Global; break;
                case "temp": scope = VariableScope.Temp; break;
                default: scope = VariableScope.Scenario; break;
            }

            _variables.Set(name, value, scope);
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
