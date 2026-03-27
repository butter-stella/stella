using System;
using NUnit.Framework;
using Natsume.Core.Data;
using Natsume.Core.VariableSystem;

namespace Natsume.Tests.EditMode
{
    public class VariableStoreTests
    {
        private VariableStore _store;

        [SetUp]
        public void SetUp()
        {
            _store = new VariableStore();
        }

        // === Basic Get/Set ===

        [Test]
        public void Set_And_Get_ReturnsValue()
        {
            _store.Set("hp", 100, VariableScope.Scenario);
            Assert.AreEqual(100, _store.GetInt("hp"));
        }

        [Test]
        public void Set_String_And_Get()
        {
            _store.Set("name", "sakura", VariableScope.Scenario);
            Assert.AreEqual("sakura", _store.GetString("name"));
        }

        [Test]
        public void Set_Bool_And_Get()
        {
            _store.Set("flag", true, VariableScope.Scenario);
            Assert.IsTrue(_store.GetBool("flag"));
        }

        [Test]
        public void Set_Float_And_Get()
        {
            _store.Set("ratio", 0.5f, VariableScope.Scenario);
            Assert.AreEqual(0.5f, _store.GetFloat("ratio"), 0.001f);
        }

        [Test]
        public void Get_Unset_ReturnsDefault()
        {
            Assert.AreEqual(0, _store.GetInt("missing"));
            Assert.IsNull(_store.GetString("missing"));
            Assert.IsFalse(_store.GetBool("missing"));
            Assert.AreEqual(0f, _store.GetFloat("missing"), 0.001f);
        }

        [Test]
        public void Set_OverwritesPreviousValue()
        {
            _store.Set("hp", 100, VariableScope.Scenario);
            _store.Set("hp", 50, VariableScope.Scenario);
            Assert.AreEqual(50, _store.GetInt("hp"));
        }

        // === Scope Isolation ===

        [Test]
        public void Scopes_AreIsolated()
        {
            _store.Set("x", 1, VariableScope.Global);
            _store.Set("x", 2, VariableScope.Scenario);
            _store.Set("x", 3, VariableScope.Temp);

            Assert.AreEqual(1, _store.GetInt("x", VariableScope.Global));
            Assert.AreEqual(2, _store.GetInt("x", VariableScope.Scenario));
            Assert.AreEqual(3, _store.GetInt("x", VariableScope.Temp));
        }

        [Test]
        public void Get_WithoutScope_SearchesInOrder_Temp_Scenario_Global()
        {
            _store.Set("x", 1, VariableScope.Global);
            Assert.AreEqual(1, _store.GetInt("x"));

            _store.Set("x", 2, VariableScope.Scenario);
            Assert.AreEqual(2, _store.GetInt("x"));

            _store.Set("x", 3, VariableScope.Temp);
            Assert.AreEqual(3, _store.GetInt("x"));
        }

        // === Clear by Scope ===

        [Test]
        public void ClearScope_OnlyClearsTargetScope()
        {
            _store.Set("a", 1, VariableScope.Global);
            _store.Set("b", 2, VariableScope.Scenario);
            _store.Set("c", 3, VariableScope.Temp);

            _store.ClearScope(VariableScope.Temp);

            Assert.AreEqual(1, _store.GetInt("a", VariableScope.Global));
            Assert.AreEqual(2, _store.GetInt("b", VariableScope.Scenario));
            Assert.AreEqual(0, _store.GetInt("c", VariableScope.Temp));
        }

        // === Has ===

        [Test]
        public void Has_ReturnsTrueWhenExists()
        {
            _store.Set("flag", true, VariableScope.Scenario);
            Assert.IsTrue(_store.Has("flag"));
        }

        [Test]
        public void Has_ReturnsFalseWhenNotExists()
        {
            Assert.IsFalse(_store.Has("missing"));
        }

        // === Snapshot ===

        [Test]
        public void CaptureSnapshot_And_Restore()
        {
            _store.Set("hp", 100, VariableScope.Scenario);
            _store.Set("flag", true, VariableScope.Scenario);

            var snapshot = _store.CaptureSnapshot();

            _store.Set("hp", 50, VariableScope.Scenario);
            _store.Set("new_var", "hello", VariableScope.Scenario);

            _store.RestoreSnapshot(snapshot);

            Assert.AreEqual(100, _store.GetInt("hp"));
            Assert.IsTrue(_store.GetBool("flag"));
            Assert.IsFalse(_store.Has("new_var"));
        }
    }
}
