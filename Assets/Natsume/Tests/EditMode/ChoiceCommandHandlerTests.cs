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
    public class ChoiceCommandHandlerTests
    {
        private ChoiceCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _handler = new ChoiceCommandHandler();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsChoice()
        {
            Assert.AreEqual("choice", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesShowChoiceEvent()
        {
            ShowChoiceEvent? received = null;
            EventBus.Subscribe<ShowChoiceEvent>(e => received = e);

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

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("Choose:", received.Value.Prompt);
            Assert.AreEqual(2, received.Value.Options.Count);
        }

        [Test]
        public async Task Execute_ParsesOptionFields()
        {
            ShowChoiceEvent? received = null;
            EventBus.Subscribe<ShowChoiceEvent>(e => received = e);

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

            await _handler.ExecuteAsync(data, _context);

            var opt = received.Value.Options[0];
            Assert.AreEqual("Go left", opt.Label);
            Assert.AreEqual("scene_left", opt.Jump);
        }

        [Test]
        public async Task Execute_NoPrompt_DefaultsToNull()
        {
            ShowChoiceEvent? received = null;
            EventBus.Subscribe<ShowChoiceEvent>(e => received = e);

            var options = new List<Dictionary<string, object>>
            {
                new Dictionary<string, object> { { "text", "OK" }, { "jump", "next" } }
            };

            var data = new CommandData("choice", new Dictionary<string, object>
            {
                { "options", options }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received.Value.Prompt);
        }

        [Test]
        public async Task Execute_OptionWithSetVariables()
        {
            ShowChoiceEvent? received = null;
            EventBus.Subscribe<ShowChoiceEvent>(e => received = e);

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

            await _handler.ExecuteAsync(data, _context);

            var opt = received.Value.Options[0];
            Assert.IsTrue(opt.Set.ContainsKey("affection"));
            Assert.AreEqual("+5", opt.Set["affection"]);
        }
    }
}
