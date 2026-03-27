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
    public class BgCommandHandlerTests
    {
        private BgCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _handler = new BgCommandHandler();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsBg()
        {
            Assert.AreEqual("bg", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesShowBgEvent()
        {
            ShowBgEvent? received = null;
            EventBus.Subscribe<ShowBgEvent>(e => received = e);

            var data = new CommandData("bg", new Dictionary<string, object>
            {
                { "asset", "bg_school" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("bg_school", received.Value.Asset);
        }

        [Test]
        public async Task Execute_WithTransition_IncludesTransitionInfo()
        {
            ShowBgEvent? received = null;
            EventBus.Subscribe<ShowBgEvent>(e => received = e);

            var data = new CommandData("bg", new Dictionary<string, object>
            {
                { "asset", "bg_sunset" },
                { "transition", "fade" },
                { "duration", 0.8f }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("fade", received.Value.Transition);
            Assert.AreEqual(0.8f, received.Value.Duration, 0.001f);
        }

        [Test]
        public async Task Execute_DefaultTransition_IsNone()
        {
            ShowBgEvent? received = null;
            EventBus.Subscribe<ShowBgEvent>(e => received = e);

            var data = new CommandData("bg", new Dictionary<string, object>
            {
                { "asset", "bg_park" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received.Value.Transition);
            Assert.AreEqual(0f, received.Value.Duration, 0.001f);
        }

        [Test]
        public async Task Execute_MissingAsset_SkipsAndLogs()
        {
            ShowBgEvent? received = null;
            string logMessage = null;
            EventBus.Logger = msg => logMessage = msg;
            EventBus.Subscribe<ShowBgEvent>(e => received = e);

            var data = new CommandData("bg");

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received);
            Assert.IsNotNull(logMessage);
            StringAssert.Contains("asset", logMessage);
        }
    }
}
