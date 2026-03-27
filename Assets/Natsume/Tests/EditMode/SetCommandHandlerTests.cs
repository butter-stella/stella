using System.Collections.Generic;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;
using Natsume.Core.VariableSystem;

namespace Natsume.Tests.EditMode
{
    [TestFixture]
    public class SetCommandHandlerTests
    {
        private VariableStore _variables;
        private SetCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            _variables = new VariableStore();
            _handler = new SetCommandHandler(_variables);
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_ReturnsSet()
        {
            Assert.AreEqual("set", _handler.CommandType);
        }

        [Test]
        public async Task Execute_SimpleAssignment_SetsVariable()
        {
            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "talked" },
                { "value", true }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(true, _variables.GetRaw("talked"));
        }

        [Test]
        public async Task Execute_MissingVar_DoesNothing()
        {
            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "value", 10 }
            });

            await _handler.ExecuteAsync(data, _context);
            // No exception, no variable set
        }

        [Test]
        public async Task Execute_PlusEquals_AddsToExistingValue()
        {
            _variables.Set("affection", 10, VariableScope.Scenario);

            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "affection" },
                { "value", 5 },
                { "op", "+=" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(15, _variables.GetInt("affection"));
        }

        [Test]
        public async Task Execute_PlusEquals_DefaultsToZeroWhenUndefined()
        {
            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "affection" },
                { "value", 5 },
                { "op", "+=" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(5, _variables.GetInt("affection"));
        }

        [Test]
        public async Task Execute_MinusEquals_SubtractsFromExistingValue()
        {
            _variables.Set("hp", 100, VariableScope.Scenario);

            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "hp" },
                { "value", 30 },
                { "op", "-=" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(70, _variables.GetInt("hp"));
        }

        [Test]
        public async Task Execute_PlusEquals_WithStringNumberValue()
        {
            _variables.Set("score", 20, VariableScope.Scenario);

            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "score" },
                { "value", "10" },
                { "op", "+=" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(30, _variables.GetInt("score"));
        }

        [Test]
        public async Task Execute_GlobalScope_SetsInGlobalScope()
        {
            var data = new CommandData("set", new Dictionary<string, object>
            {
                { "var", "cg_unlocked" },
                { "value", true },
                { "scope", "global" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual(true, _variables.GetRaw("cg_unlocked"));
        }
    }
}
