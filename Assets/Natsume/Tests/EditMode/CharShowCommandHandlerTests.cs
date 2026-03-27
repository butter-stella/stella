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
    public class CharShowCommandHandlerTests
    {
        private CharShowCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _handler = new CharShowCommandHandler();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsCharShow()
        {
            Assert.AreEqual("char_show", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesCharShowEvent()
        {
            CharShowEvent? received = null;
            EventBus.Subscribe<CharShowEvent>(e => received = e);

            var data = new CommandData("char_show", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "expression", "smile" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("sakura", received.Value.Character);
            Assert.AreEqual("smile", received.Value.Expression);
        }

        [Test]
        public async Task Execute_WithPosition_IncludesPosition()
        {
            CharShowEvent? received = null;
            EventBus.Subscribe<CharShowEvent>(e => received = e);

            var data = new CommandData("char_show", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "position", "left" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("left", received.Value.Position);
        }

        [Test]
        public async Task Execute_DefaultPosition_IsCenter()
        {
            CharShowEvent? received = null;
            EventBus.Subscribe<CharShowEvent>(e => received = e);

            var data = new CommandData("char_show", new Dictionary<string, object>
            {
                { "character", "sakura" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("center", received.Value.Position);
        }

        [Test]
        public async Task Execute_DefaultExpression_IsNull()
        {
            CharShowEvent? received = null;
            EventBus.Subscribe<CharShowEvent>(e => received = e);

            var data = new CommandData("char_show", new Dictionary<string, object>
            {
                { "character", "sakura" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received.Value.Expression);
        }

        [Test]
        public async Task Execute_WithTransition_IncludesTransition()
        {
            CharShowEvent? received = null;
            EventBus.Subscribe<CharShowEvent>(e => received = e);

            var data = new CommandData("char_show", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "transition", "dissolve" },
                { "duration", 0.5f }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("dissolve", received.Value.Transition);
            Assert.AreEqual(0.5f, received.Value.Duration, 0.001f);
        }
    }
}
