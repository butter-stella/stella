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
    public class DialogueCommandHandlerTests
    {
        private DialogueCommandHandler _handler;
        private ScenarioContext _context;

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
            _handler = new DialogueCommandHandler();
            _context = new ScenarioContext();
        }

        [Test]
        public void CommandType_IsDialogue()
        {
            Assert.AreEqual("dialogue", _handler.CommandType);
        }

        [Test]
        public async Task Execute_PublishesShowDialogueEvent()
        {
            ShowDialogueEvent? received = null;
            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "text", "Hello!" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNotNull(received);
            Assert.AreEqual("sakura", received.Value.Character);
            Assert.AreEqual("Hello!", received.Value.Text);
        }

        [Test]
        public async Task Execute_WithVoice_IncludesVoiceInEvent()
        {
            ShowDialogueEvent? received = null;
            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "text", "Hello!" },
                { "voice", "sakura_001" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("sakura_001", received.Value.VoiceAssetId);
        }

        [Test]
        public async Task Execute_WithMode_IncludesModeInEvent()
        {
            ShowDialogueEvent? received = null;
            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "text", "Narration text" },
                { "mode", "nvl" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("nvl", received.Value.Mode);
        }

        [Test]
        public async Task Execute_DefaultMode_IsAdv()
        {
            ShowDialogueEvent? received = null;
            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "character", "sakura" },
                { "text", "Hello!" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.AreEqual("adv", received.Value.Mode);
        }

        [Test]
        public async Task Execute_NoCharacter_DefaultsToNull()
        {
            ShowDialogueEvent? received = null;
            EventBus.Subscribe<ShowDialogueEvent>(e => received = e);

            var data = new CommandData("dialogue", new Dictionary<string, object>
            {
                { "text", "Narrator text" }
            });

            await _handler.ExecuteAsync(data, _context);

            Assert.IsNull(received.Value.Character);
        }
    }
}
