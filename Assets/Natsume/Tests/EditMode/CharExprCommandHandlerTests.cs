using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Tests.EditMode
{
    [TestFixture]
    public class CharExprCommandHandlerTests
    {
        private CharExprCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            Core.EventBus.EventBus.Clear();
            _handler = new CharExprCommandHandler();
            _context = new ScenarioContext();
        }

        [TearDown]
        public void TearDown()
        {
            Core.EventBus.EventBus.Clear();
        }

        [Test]
        public void CommandType_ReturnsCharExpr()
        {
            Assert.AreEqual("char_expr", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesChangeExpressionEvent()
        {
            ChangeExpressionEvent received = default;
            bool fired = false;
            Core.EventBus.EventBus.Subscribe<ChangeExpressionEvent>(e =>
            {
                received = e;
                fired = true;
            });

            var data = new CommandData("char_expr", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "expression", "surprised" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsTrue(fired);
            Assert.AreEqual("sakura", received.CharacterName);
            Assert.AreEqual("surprised", received.Expression);
        }

        [Test]
        public async Task Execute_MissingCharacter_DoesNotPublish()
        {
            bool fired = false;
            Core.EventBus.EventBus.Subscribe<ChangeExpressionEvent>(_ => fired = true);

            var data = new CommandData("char_expr", new Dictionary<string, object>
            {
                { "expression", "smile" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsFalse(fired);
        }

        [Test]
        public async Task Execute_MissingExpression_DoesNotPublish()
        {
            bool fired = false;
            Core.EventBus.EventBus.Subscribe<ChangeExpressionEvent>(_ => fired = true);

            var data = new CommandData("char_expr", new Dictionary<string, object>
            {
                { "character", "sakura" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsFalse(fired);
        }
    }
}
