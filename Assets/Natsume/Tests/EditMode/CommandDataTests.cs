using System;
using System.Collections.Generic;
using NUnit.Framework;
using Natsume.Core.Data;

namespace Natsume.Tests.EditMode
{
    public class CommandDataTests
    {
        [Test]
        public void Constructor_SetsTypeAndParameters()
        {
            var parameters = new Dictionary<string, object> { { "key", "value" } };
            var cmd = new CommandData("dialogue", parameters);

            Assert.AreEqual("dialogue", cmd.Type);
            Assert.AreSame(parameters, cmd.Parameters);
        }

        [Test]
        public void Constructor_NullType_ThrowsArgumentNullException()
        {
            Assert.Throws<ArgumentNullException>(() => new CommandData(null));
        }

        [Test]
        public void Constructor_NullParameters_CreatesEmptyDictionary()
        {
            var cmd = new CommandData("bg");

            Assert.IsNotNull(cmd.Parameters);
            Assert.AreEqual(0, cmd.Parameters.Count);
        }

        [Test]
        public void GetString_ReturnsValue()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "name", "sakura" }
            });

            Assert.AreEqual("sakura", cmd.GetString("name"));
        }

        [Test]
        public void GetString_Missing_ReturnsDefault()
        {
            var cmd = new CommandData("test");

            Assert.AreEqual("fallback", cmd.GetString("name", "fallback"));
            Assert.IsNull(cmd.GetString("name"));
        }

        [Test]
        public void GetInt_ReturnsValue()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "count", 42 }
            });

            Assert.AreEqual(42, cmd.GetInt("count"));
        }

        [Test]
        public void GetInt_Missing_ReturnsDefault()
        {
            var cmd = new CommandData("test");

            Assert.AreEqual(10, cmd.GetInt("count", 10));
        }

        [Test]
        public void GetFloat_ReturnsValue()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "duration", 0.5f }
            });

            Assert.AreEqual(0.5f, cmd.GetFloat("duration"), 0.001f);
        }

        [Test]
        public void GetBool_ReturnsValue()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "flag", true }
            });

            Assert.IsTrue(cmd.GetBool("flag"));
        }

        [Test]
        public void Get_Generic_ReturnsTypedValue()
        {
            var list = new List<string> { "a", "b" };
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "items", list }
            });

            var result = cmd.Get<List<string>>("items");
            Assert.AreSame(list, result);
        }

        [Test]
        public void Get_Generic_WrongType_ReturnsDefault()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "value", "not an int" }
            });

            Assert.AreEqual(0, cmd.Get<int>("value"));
        }

        [Test]
        public void HasKey_ReturnsCorrectly()
        {
            var cmd = new CommandData("test", new Dictionary<string, object>
            {
                { "exists", 1 }
            });

            Assert.IsTrue(cmd.HasKey("exists"));
            Assert.IsFalse(cmd.HasKey("missing"));
        }
    }
}
