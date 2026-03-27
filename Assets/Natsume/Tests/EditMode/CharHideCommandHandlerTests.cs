using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;
using System.Collections.Generic;

namespace Natsume.Tests.EditMode
{
    public class CharHideCommandHandlerTests
    {
        private CharHideCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _handler = new CharHideCommandHandler();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsCharHide()
        {
            Assert.AreEqual("char_hide", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesCharHideEvent()
        {
            CharHideEvent? received = null;
            EventBus.Subscribe<CharHideEvent>(e => received = e);

            var data = new CommandData("char_hide", new Dictionary<string, object>
            {
                { "character", "sakura" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("sakura", received.Value.Character);
        }

        [Test]
        public async Task Execute_WithTransition_IncludesTransition()
        {
            CharHideEvent? received = null;
            EventBus.Subscribe<CharHideEvent>(e => received = e);

            var data = new CommandData("char_hide", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "transition", "fade" },
                { "duration", 0.3f }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("fade", received.Value.Transition);
            Assert.AreEqual(0.3f, received.Value.Duration, 0.001f);
        }

        [Test]
        public async Task Execute_MissingCharacter_SkipsAndLogs()
        {
            CharHideEvent? received = null;
            string logMessage = null;
            EventBus.Logger = msg => logMessage = msg;
            EventBus.Subscribe<CharHideEvent>(e => received = e);

            var data = new CommandData("char_hide");

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received);
            Assert.IsNotNull(logMessage);
            StringAssert.Contains("character", logMessage);
        }
    }
}
