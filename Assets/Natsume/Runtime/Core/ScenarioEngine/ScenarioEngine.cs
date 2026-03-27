using System;
using System.Threading.Tasks;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.VariableSystem;

namespace Natsume.Core.ScenarioEngine
{
    /// <summary>
    /// The main scenario engine. Drives the execution loop:
    /// LoadScenario → SetScene → FetchCommand → Dispatch → WaitForCompletion → Next
    /// </summary>
    public class ScenarioEngine
    {
        private readonly CommandRegistry _registry;
        private readonly VariableStore _variables;

        public ScenarioContext Context { get; private set; }

        public ScenarioEngine(CommandRegistry registry, VariableStore variables)
        {
            _registry = registry ?? throw new ArgumentNullException(nameof(registry));
            _variables = variables ?? throw new ArgumentNullException(nameof(variables));
            Context = new ScenarioContext();
        }

        public void LoadScenario(ScenarioData scenario)
        {
            if (scenario == null)
                throw new ArgumentNullException(nameof(scenario));
            Context.CurrentScenario = scenario;
            Context.CurrentSceneId = null;
            Context.CommandIndex = 0;
            Context.PendingJump = null;
            Context.IsFinished = false;
        }

        /// <summary>
        /// Run the loaded scenario from the first scene to completion.
        /// </summary>
        public async Task RunAsync()
        {
            if (Context.CurrentScenario == null)
                throw new InvalidOperationException("No scenario loaded. Call LoadScenario first.");

            EventBus.EventBus.Publish(new ScenarioStartedEvent(Context.CurrentScenario.Id));

            // Start with the first scene
            var firstScene = Context.CurrentScenario.Scenes[0];
            await SetSceneAsync(firstScene.Id);

            // Execute until finished
            while (!Context.IsFinished)
            {
                var scene = Context.CurrentScenario.GetScene(Context.CurrentSceneId);
                if (scene == null)
                {
                    Context.IsFinished = true;
                    break;
                }

                if (Context.CommandIndex >= scene.Commands.Count)
                {
                    // Scene exhausted, no more commands
                    Context.IsFinished = true;
                    break;
                }

                var command = scene.Commands[Context.CommandIndex];
                Context.CommandIndex++;

                await ExecuteCommandAsync(command);

                // Check for pending jump
                if (Context.PendingJump != null)
                {
                    var target = Context.PendingJump;
                    Context.PendingJump = null;
                    await SetSceneAsync(target);
                }
            }

            EventBus.EventBus.Publish(new ScenarioEndedEvent(Context.CurrentScenario.Id));
        }

        /// <summary>
        /// Jump to a specific scene by ID.
        /// </summary>
        public async Task JumpToSceneAsync(string sceneId)
        {
            await SetSceneAsync(sceneId);
        }

        private Task SetSceneAsync(string sceneId)
        {
            Context.CurrentSceneId = sceneId;
            Context.CommandIndex = 0;
            EventBus.EventBus.Publish(new SceneChangedEvent(Context.CurrentScenario.Id, sceneId));
            return Task.CompletedTask;
        }

        private async Task ExecuteCommandAsync(CommandData command)
        {
            var handler = _registry.GetHandler(command.Type);
            if (handler == null)
            {
                // Unknown command type — skip with a log
                EventBus.EventBus.Logger?.Invoke($"[ScenarioEngine] No handler for command type: {command.Type}");
                return;
            }

            await handler.ExecuteAsync(command, Context);
            EventBus.EventBus.Publish(new CommandExecutedEvent(command.Type));
        }
    }
}
