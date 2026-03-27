using System;
using System.Globalization;
using System.Threading.Tasks;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Handles "set" command — sets a variable value.
    /// Supports operators: "=" (default), "+=", "-=".
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

            var op = data.GetString("op", "=");
            if (op == "+=" || op == "-=")
            {
                var current = _variables.GetInt(name);
                int delta;
                try { delta = Convert.ToInt32(value, CultureInfo.InvariantCulture); }
                catch
                {
                    EventBus.EventBus.Logger?.Invoke(
                        $"[SetCommandHandler] Cannot convert '{value}' to int for '{name} {op}', defaulting to 0.");
                    delta = 0;
                }

                value = op == "+=" ? current + delta : current - delta;
            }

            _variables.Set(name, value, scope);
            return Task.CompletedTask;
        }

        public void Rollback(CommandData data, ScenarioContext context) { }
    }
}
