using System;
using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.Commands;
using Natsume.Core.Data;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Tests.EditMode
{
    public class CommandRegistryTests
    {
        private class FakeHandler : ICommandHandler
        {
            public string CommandType { get; }
            public int ExecuteCount { get; private set; }

            public FakeHandler(string type) { CommandType = type; }

            public Task ExecuteAsync(CommandData data, ScenarioContext context)
            {
                ExecuteCount++;
                return Task.CompletedTask;
            }

            public void Rollback(CommandData data, ScenarioContext context) { }
        }

        private CommandRegistry _registry;

        [SetUp]
        public void SetUp()
        {
            _registry = new CommandRegistry();
        }

        [Test]
        public void Register_And_GetHandler_ReturnsHandler()
        {
            var handler = new FakeHandler("dialogue");
            _registry.Register(handler);

            var result = _registry.GetHandler("dialogue");
            Assert.AreSame(handler, result);
        }

        [Test]
        public void GetHandler_Unregistered_ReturnsNull()
        {
            Assert.IsNull(_registry.GetHandler("unknown"));
        }

        [Test]
        public void Register_DuplicateType_OverwritesPrevious()
        {
            var first = new FakeHandler("bg");
            var second = new FakeHandler("bg");
            _registry.Register(first);
            _registry.Register(second);

            Assert.AreSame(second, _registry.GetHandler("bg"));
        }

        [Test]
        public void Register_NullHandler_ThrowsArgumentNullException()
        {
            Assert.Throws<ArgumentNullException>(() => _registry.Register(null));
        }

        [Test]
        public void HasHandler_ReturnsTrueWhenRegistered()
        {
            _registry.Register(new FakeHandler("test"));
            Assert.IsTrue(_registry.HasHandler("test"));
        }

        [Test]
        public void HasHandler_ReturnsFalseWhenNotRegistered()
        {
            Assert.IsFalse(_registry.HasHandler("missing"));
        }
    }
}
