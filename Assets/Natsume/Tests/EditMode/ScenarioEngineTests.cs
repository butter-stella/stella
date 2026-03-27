using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ServiceLocator;
using Natsume.Core.VariableSystem;

namespace Natsume.Tests.EditMode
{
    public class ScenarioEngineTests
    {
        private ScenarioEngine _engine;
        private CommandRegistry _registry;
        private VariableStore _variables;
        private RecordingHandler _dialogueHandler;
        private RecordingHandler _bgHandler;

        private class RecordingHandler : ICommandHandler
        {
            public string CommandType { get; }
            public List<CommandData> ExecutedCommands { get; } = new List<CommandData>();

            public RecordingHandler(string type) { CommandType = type; }

            public Task ExecuteAsync(CommandData data, ScenarioContext context)
            {
                ExecutedCommands.Add(data);
                return Task.CompletedTask;
            }

            public void Rollback(CommandData data, ScenarioContext context) { }
        }

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            ServiceLocator.Clear();

            _registry = new CommandRegistry();
            _variables = new VariableStore();
            _dialogueHandler = new RecordingHandler("dialogue");
            _bgHandler = new RecordingHandler("bg");

            _registry.Register(_dialogueHandler);
            _registry.Register(_bgHandler);

            _engine = new ScenarioEngine(_registry, _variables);
        }

        private ScenarioData MakeSimpleScenario()
        {
            return new ScenarioData
            {
                Id = "test",
                Title = "Test",
                Scenes = new List<SceneData>
                {
                    new SceneData
                    {
                        Id = "start",
                        Commands = new List<CommandData>
                        {
                            new CommandData("bg", new Dictionary<string, object> { { "asset", "bg_school" } }),
                            new CommandData("dialogue", new Dictionary<string, object>
                            {
                                { "character", "sakura" },
                                { "text", "Hello!" }
                            }),
                            new CommandData("dialogue", new Dictionary<string, object>
                            {
                                { "character", "sakura" },
                                { "text", "Goodbye!" }
                            })
                        }
                    }
                }
            };
        }

        // === Load & Start ===

        [Test]
        public void LoadScenario_SetsCurrentScenario()
        {
            var scenario = MakeSimpleScenario();
            _engine.LoadScenario(scenario);

            Assert.AreEqual("test", _engine.Context.CurrentScenario.Id);
        }

        [Test]
        public async Task Start_ExecutesFirstScene()
        {
            _engine.LoadScenario(MakeSimpleScenario());
            await _engine.RunAsync();

            Assert.AreEqual(1, _bgHandler.ExecutedCommands.Count);
            Assert.AreEqual(2, _dialogueHandler.ExecutedCommands.Count);
        }

        [Test]
        public async Task Start_PublishesScenarioStartedEvent()
        {
            string receivedId = null;
            EventBus.Subscribe<ScenarioStartedEvent>(e => receivedId = e.ScenarioId);

            _engine.LoadScenario(MakeSimpleScenario());
            await _engine.RunAsync();

            Assert.AreEqual("test", receivedId);
        }

        [Test]
        public async Task Start_PublishesScenarioEndedEvent()
        {
            string receivedId = null;
            EventBus.Subscribe<ScenarioEndedEvent>(e => receivedId = e.ScenarioId);

            _engine.LoadScenario(MakeSimpleScenario());
            await _engine.RunAsync();

            Assert.AreEqual("test", receivedId);
        }

        // === Jump ===

        [Test]
        public async Task Jump_ChangesScene()
        {
            var scenario = new ScenarioData
            {
                Id = "test",
                Scenes = new List<SceneData>
                {
                    new SceneData
                    {
                        Id = "scene_a",
                        Commands = new List<CommandData>
                        {
                            new CommandData("jump", new Dictionary<string, object> { { "target", "scene_b" } })
                        }
                    },
                    new SceneData
                    {
                        Id = "scene_b",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "Arrived at B" } })
                        }
                    }
                }
            };

            _registry.Register(new JumpCommandHandler());
            _engine.LoadScenario(scenario);
            await _engine.RunAsync();

            Assert.AreEqual(1, _dialogueHandler.ExecutedCommands.Count);
            Assert.AreEqual("Arrived at B", _dialogueHandler.ExecutedCommands[0].GetString("text"));
        }

        // === Condition ===

        [Test]
        public async Task Condition_ThenBranch_WhenTrue()
        {
            _variables.Set("affection", 15, VariableScope.Scenario);

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
                            new CommandData("condition", new Dictionary<string, object>
                            {
                                { "if", "affection >= 10" },
                                { "then_jump", "good" },
                                { "else_jump", "bad" }
                            })
                        }
                    },
                    new SceneData
                    {
                        Id = "good",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "Good!" } })
                        }
                    },
                    new SceneData
                    {
                        Id = "bad",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "Bad!" } })
                        }
                    }
                }
            };

            _registry.Register(new ConditionCommandHandler(new ExpressionEvaluator(_variables)));
            _engine.LoadScenario(scenario);
            await _engine.RunAsync();

            Assert.AreEqual(1, _dialogueHandler.ExecutedCommands.Count);
            Assert.AreEqual("Good!", _dialogueHandler.ExecutedCommands[0].GetString("text"));
        }

        [Test]
        public async Task Condition_ElseBranch_WhenFalse()
        {
            _variables.Set("affection", 3, VariableScope.Scenario);

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
                            new CommandData("condition", new Dictionary<string, object>
                            {
                                { "if", "affection >= 10" },
                                { "then_jump", "good" },
                                { "else_jump", "bad" }
                            })
                        }
                    },
                    new SceneData
                    {
                        Id = "good",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "Good!" } })
                        }
                    },
                    new SceneData
                    {
                        Id = "bad",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "Bad!" } })
                        }
                    }
                }
            };

            _registry.Register(new ConditionCommandHandler(new ExpressionEvaluator(_variables)));
            _engine.LoadScenario(scenario);
            await _engine.RunAsync();

            Assert.AreEqual(1, _dialogueHandler.ExecutedCommands.Count);
            Assert.AreEqual("Bad!", _dialogueHandler.ExecutedCommands[0].GetString("text"));
        }

        // === Set variable ===

        [Test]
        public async Task SetCommand_SetsVariable()
        {
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
                            new CommandData("set", new Dictionary<string, object>
                            {
                                { "var", "talked" },
                                { "value", true }
                            })
                        }
                    }
                }
            };

            _registry.Register(new SetCommandHandler(_variables));
            _engine.LoadScenario(scenario);
            await _engine.RunAsync();

            Assert.IsTrue(_variables.GetBool("talked"));
        }

        // === Unknown command ===

        [Test]
        public async Task UnknownCommand_IsSkipped()
        {
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
                            new CommandData("unknown_type"),
                            new CommandData("dialogue", new Dictionary<string, object> { { "text", "After unknown" } })
                        }
                    }
                }
            };

            _engine.LoadScenario(scenario);
            await _engine.RunAsync();

            Assert.AreEqual(1, _dialogueHandler.ExecutedCommands.Count);
        }

        // === SceneChanged event ===

        [Test]
        public async Task RunAsync_PublishesSceneChangedEvent()
        {
            string receivedSceneId = null;
            EventBus.Subscribe<SceneChangedEvent>(e => receivedSceneId = e.SceneId);

            _engine.LoadScenario(MakeSimpleScenario());
            await _engine.RunAsync();

            Assert.AreEqual("start", receivedSceneId);
        }
    }
}
