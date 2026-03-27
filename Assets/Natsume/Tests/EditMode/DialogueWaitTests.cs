using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Tests.EditMode
{
    public class DialogueWaitTests
    {
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _context = new ScenarioContext();
        }

        [Test]
        public async Task DialogueHandler_WaitsForAdvance()
        {
            var handler = new DialogueCommandHandler();
            ShowDialogueEvent? received = null;

            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "text", "Hello!" }
            });

            var task = handler.ExecuteAsync(data, _context);

            // Event should be published immediately
            Assert.IsNotNull(received);
            Assert.AreEqual("sakura", received.Value.Character);

            // But handler should not have completed yet (waiting for advance)
            Assert.IsFalse(task.IsCompleted);

            // Simulate player click
            EventBus.Publish(new AdvanceEvent());

            await task;
            Assert.IsTrue(task.IsCompleted);
        }

        [Test]
        public async Task Engine_DialoguesExecuteSequentially_WithAdvance()
        {
            var registry = new CommandRegistry();
            var variables = new Natsume.Core.VariableSystem.VariableStore();
            registry.Register(new DialogueCommandHandler());

            var engine = new ScenarioEngine(registry, variables);
            var dialogues = new List<string>();

            EventBus.Subscribe<ShowDialogueEvent>(e =>
            {
                dialogues.Add(e.Text);
                // Auto-advance after each dialogue
                EventBus.Publish(new AdvanceEvent());
            });

            var scenario = new ScenarioData
            {
                Id = "test",
                Scenes = new List<SceneData>
                {
                    new SceneData
                    {
                        Id = "start",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object>
                            {
                                { "character", "sakura" },
                                { "text", "Line 1" }
                            }),
                            new CommandData("dialogue", new Dictionary<string, object>
                            {
                                { "character", "sakura" },
                                { "text", "Line 2" }
                            })
                        }
                    }
                }
            };

            engine.LoadScenario(scenario);
            await engine.RunAsync();

            Assert.AreEqual(2, dialogues.Count);
            Assert.AreEqual("Line 1", dialogues[0]);
            Assert.AreEqual("Line 2", dialogues[1]);
        }

        [Test]
        public async Task BgCommand_DoesNotWaitForAdvance()
        {
            var handler = new BgCommandHandler();
            ShowBgEvent? received = null;

            EventBus.Subscribe<ShowBgEvent>(e => received = e);

            var data = new CommandData("bg", new Dictionary<string, object>
            {
                { "asset", "bg_school" }
            });

            var task = handler.ExecuteAsync(data, _context);

            // bg should complete immediately (no wait)
            Assert.IsTrue(task.IsCompleted);
            Assert.IsNotNull(received);
        }
    }
}
