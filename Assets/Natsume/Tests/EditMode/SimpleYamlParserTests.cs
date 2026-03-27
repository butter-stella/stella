using NUnit.Framework;
using Natsume.Core.ScriptParser;

namespace Natsume.Tests.EditMode
{
    public class SimpleYamlParserTests
    {
        [Test]
        public void Parse_SimpleMap()
        {
            var yaml = "id: test\ntitle: Hello";
            var node = SimpleYamlParser.Parse(yaml);

            Assert.IsNotNull(node);
            Assert.AreEqual("test", node.GetString("id"));
            Assert.AreEqual("Hello", node.GetString("title"));
        }

        [Test]
        public void Parse_NestedMap()
        {
            var yaml = "root:\n  child: value";
            var node = SimpleYamlParser.Parse(yaml);

            var child = node.GetMap("root");
            Assert.IsNotNull(child);
            Assert.AreEqual("value", child.GetString("child"));
        }

        [Test]
        public void Parse_List()
        {
            var yaml = "items:\n  - id: a\n  - id: b";
            var node = SimpleYamlParser.Parse(yaml);

            var items = node.GetList("items");
            Assert.IsNotNull(items);
            Assert.AreEqual(2, items.Count);
        }

        [Test]
        public void Parse_BooleanValues()
        {
            var yaml = "flag: true\nother: false";
            var node = SimpleYamlParser.Parse(yaml);
            var dict = node.ToDictionary();

            Assert.AreEqual(true, dict["flag"]);
            Assert.AreEqual(false, dict["other"]);
        }

        [Test]
        public void Parse_NumericValues()
        {
            var yaml = "count: 42\nratio: 1.5";
            var node = SimpleYamlParser.Parse(yaml);
            var dict = node.ToDictionary();

            Assert.AreEqual(42, dict["count"]);
            Assert.AreEqual(1.5f, (float)dict["ratio"], 0.001f);
        }

        [Test]
        public void Parse_QuotedStrings()
        {
            var yaml = "name: 'hello world'\nother: \"quoted\"";
            var node = SimpleYamlParser.Parse(yaml);

            Assert.AreEqual("hello world", node.GetString("name"));
            Assert.AreEqual("quoted", node.GetString("other"));
        }

        [Test]
        public void Parse_EmptyInput_ReturnsNull()
        {
            Assert.IsNull(SimpleYamlParser.Parse(""));
            Assert.IsNull(SimpleYamlParser.Parse(null));
            Assert.IsNull(SimpleYamlParser.Parse("   "));
        }

        [Test]
        public void Parse_SkipsComments()
        {
            var yaml = "# comment\nid: test\n# another comment";
            var node = SimpleYamlParser.Parse(yaml);

            Assert.AreEqual("test", node.GetString("id"));
        }

        [Test]
        public void Parse_ListOfMaps()
        {
            var yaml = "scenes:\n  - id: a\n    title: Scene A\n  - id: b\n    title: Scene B";
            var node = SimpleYamlParser.Parse(yaml);

            var scenes = node.GetList("scenes");
            Assert.AreEqual(2, scenes.Count);
            Assert.AreEqual("a", scenes[0].GetString("id"));
            Assert.AreEqual("Scene A", scenes[0].GetString("title"));
            Assert.AreEqual("b", scenes[1].GetString("id"));
            Assert.AreEqual("Scene B", scenes[1].GetString("title"));
        }
    }
}
