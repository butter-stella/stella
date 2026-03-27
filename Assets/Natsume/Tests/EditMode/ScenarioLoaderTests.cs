using NUnit.Framework;
using Natsume.Core.Data;
using Natsume.Core.ScriptParser;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Natsume.Tests.EditMode
{
    public class ScenarioLoaderTests
    {
        [Test]
        public async Task InMemoryLoader_Load_ReturnsScenario()
        {
            var scenario = new ScenarioData
            {
                Id = "test",
                Title = "Test Scenario",
                Scenes = new List<SceneData>
                {
                    new SceneData
                    {
                        Id = "start",
                        Commands = new List<CommandData>
                        {
                            new CommandData("dialogue", new Dictionary<string, object>
                            {
                                { "text", "Hello!" }
                            })
                        }
                    }
                }
            };

            var loader = new InMemoryScenarioLoader();
            loader.Register("test", scenario);

            var result = await loader.LoadAsync("test");

            Assert.IsNotNull(result);
            Assert.AreEqual("test", result.Id);
            Assert.AreEqual("Test Scenario", result.Title);
            Assert.AreEqual(1, result.Scenes.Count);
        }

        [Test]
        public async Task InMemoryLoader_Load_UnknownId_ReturnsNull()
        {
            var loader = new InMemoryScenarioLoader();
            var result = await loader.LoadAsync("nonexistent");

            Assert.IsNull(result);
        }

        [Test]
        public async Task InMemoryLoader_Register_OverwritesPrevious()
        {
            var first = new ScenarioData { Id = "test", Title = "First" };
            var second = new ScenarioData { Id = "test", Title = "Second" };

            var loader = new InMemoryScenarioLoader();
            loader.Register("test", first);
            loader.Register("test", second);

            var result = await loader.LoadAsync("test");
            Assert.AreEqual("Second", result.Title);
        }

        [Test]
        public void InMemoryLoader_HasScenario_ReturnsTrueWhenRegistered()
        {
            var loader = new InMemoryScenarioLoader();
            loader.Register("test", new ScenarioData { Id = "test" });

            Assert.IsTrue(loader.HasScenario("test"));
            Assert.IsFalse(loader.HasScenario("missing"));
        }

        [Test]
        public void IScenarioLoader_Interface_IsImplemented()
        {
            IScenarioLoader loader = new InMemoryScenarioLoader();
            Assert.IsNotNull(loader);
        }
    }
}
