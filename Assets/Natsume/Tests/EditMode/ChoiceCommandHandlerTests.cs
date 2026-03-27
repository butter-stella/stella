using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Tests.EditMode
{
    public class ChoiceCommandHandlerTests
    {
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsChoice()
        {
            var handler = new ChoiceCommandHandler();
            Assert.AreEqual("choice", handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesShowChoiceEvent()
        {
            var handler = new ChoiceCommandHandler();
            ShowChoiceEvent? received = null;

            // Auto-select first option when choice is shown
            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                received = e;
                EventBus.Publish(new ChoiceSelectedEvent(e.Options[0].Id));
            });

            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object> { { "text", "Option A" }, { "jump", "scene_a" } },
                new Dictionary<string, object> { { "text", "Option B" }, { "jump", "scene_b" } }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "prompt", "Choose:" },
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("Choose:", received.Value.Prompt);
            Assert.AreEqual(2, received.Value.Options.Count);
        }

        [Test]
        public async Task Execute_ParsesOptionFields()
        {
            var handler = new ChoiceCommandHandler();
            ShowChoiceEvent? received = null;

            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                received = e;
                EventBus.Publish(new ChoiceSelectedEvent(e.Options[0].Id));
            });

            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object>
                {
                    { "text", "Go left" },
                    { "jump", "scene_left" }
                }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "prompt", "Which way?" },
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            var opt = received.Value.Options[0];
            Assert.AreEqual("Go left", opt.Label);
            Assert.AreEqual("scene_left", opt.Jump);
        }

        [Test]
        public async Task Execute_NoPrompt_DefaultsToNull()
        {
            var handler = new ChoiceCommandHandler();
            ShowChoiceEvent? received = null;

            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                received = e;
                EventBus.Publish(new ChoiceSelectedEvent(e.Options[0].Id));
            });

            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object> { { "text", "OK" }, { "jump", "next" } }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            Assert.IsNull(received.Value.Prompt);
        }

        [Test]
        public async Task Execute_OptionWithSetVariables()
        {
            var handler = new ChoiceCommandHandler();
            ShowChoiceEvent? received = null;

            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                received = e;
                EventBus.Publish(new ChoiceSelectedEvent(e.Options[0].Id));
            });

            var setDict = new Dictionary<string, object> { { "affection", "+5" } };
            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object>
                {
                    { "text", "Be kind" },
                    { "jump", "scene_kind" },
                    { "set", setDict }
                }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            var opt = received.Value.Options[0];
            Assert.IsTrue(opt.Set.ContainsKey("affection"));
            Assert.AreEqual("+5", opt.Set["affection"]);
        }

        [Test]
        public async Task Execute_SetsPendingJump_OnSelection()
        {
            var handler = new ChoiceCommandHandler();

            // Auto-select option "1" (scene_b)
            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                EventBus.Publish(new ChoiceSelectedEvent("1"));
            });

            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object> { { "text", "Option A" }, { "jump", "scene_a" } },
                new Dictionary<string, object> { { "text", "Option B" }, { "jump", "scene_b" } }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            Assert.AreEqual("scene_b", _context.PendingJump);
        }

        [Test]
        public async Task Execute_AppliesSetVariables_OnSelection()
        {
            var variables = new VariableStore();
            var handler = new ChoiceCommandHandler(variables);

            EventBus.Subscribe<ShowChoiceEvent>(e =>
            {
                EventBus.Publish(new ChoiceSelectedEvent("0"));
            });

            var setDict = new Dictionary<string, object> { { "affection", "+5" } };
            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object>
                {
                    { "text", "Be kind" },
                    { "jump", "scene_kind" },
                    { "set", setDict }
                }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "options", options }
            });

            await handler.ExecuteAsync(data, _context);

            Assert.AreEqual("+5", variables.GetString("affection"));
            Assert.AreEqual("scene_kind", _context.PendingJump);
        }
    }
}
