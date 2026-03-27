using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Natsume.Core.Data;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Loads scenario data from YAML strings or files.
    /// Uses a lightweight built-in parser for the well-defined scenario YAML schema,
    /// avoiding external dependencies (YamlDotNet) for the core layer.
    /// </summary>
    public class YamlScenarioLoader : IScenarioLoader
    {
        private readonly Dictionary<string, string> _filePaths = new Dictionary<string, string>();

        /// <summary>
        /// Register a file path for a scenario ID, used by LoadAsync.
        /// </summary>
        public void RegisterPath(string scenarioId, string filePath)
        {
            _filePaths[scenarioId] = filePath;
        }

        public async Task<ScenarioData> LoadAsync(string scenarioId)
        {
            if (!_filePaths.TryGetValue(scenarioId, out var path))
                return null;

            var yaml = await ReadFileAsync(path);
            return LoadFromString(yaml);
        }

        /// <summary>
        /// Parse a YAML string into ScenarioData. Useful for testing.
        /// </summary>
        public Task<ScenarioData> LoadFromStringAsync(string yaml)
        {
            return Task.FromResult(LoadFromString(yaml));
        }

        private ScenarioData LoadFromString(string yaml)
        {
            if (string.IsNullOrWhiteSpace(yaml))
                return null;

            var root = SimpleYamlParser.Parse(yaml);
            if (root == null)
                return null;

            var scenario = new ScenarioData
            {
                Id = root.GetString("id"),
                Title = root.GetString("title")
            };

            var scenesNode = root.GetList("scenes");
            if (scenesNode != null)
            {
                foreach (var sceneNode in scenesNode)
                {
                    var scene = new SceneData
                    {
                        Id = sceneNode.GetString("id"),
                        Title = sceneNode.GetString("title")
                    };

                    var commandsNode = sceneNode.GetList("commands");
                    if (commandsNode != null)
                    {
                        foreach (var cmdNode in commandsNode)
                        {
                            var type = cmdNode.GetString("type");
                            var paramsNode = cmdNode.GetMap("params");
                            var parameters = new Dictionary<string, object>();

                            if (paramsNode != null)
                            {
                                parameters = paramsNode.ToDictionary();
                            }

                            scene.Commands.Add(new CommandData(type, parameters));
                        }
                    }

                    scenario.Scenes.Add(scene);
                }
            }

            return scenario;
        }

        /// <summary>
        /// Currently synchronous (File.ReadAllText wrapped in Task.FromResult).
        /// Scenario files are small enough that blocking is acceptable.
        /// Replace with truly async I/O if large files become a concern.
        /// </summary>
        private static Task<string> ReadFileAsync(string path)
        {
            return Task.FromResult(File.ReadAllText(path));
        }
    }
}
