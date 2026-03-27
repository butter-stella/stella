using NUnit.Framework;
using Natsume.Core.Data;
using Natsume.Core.VariableSystem;

namespace Natsume.Tests.EditMode
{
    public class ExpressionEvaluatorTests
    {
        private VariableStore _store;
        private ExpressionEvaluator _evaluator;

        [SetUp]
        public void SetUp()
        {
            _store = new VariableStore();
            _evaluator = new ExpressionEvaluator(_store);
        }

        // === Comparison ===

        [Test]
        public void Evaluate_GreaterThanOrEqual_True()
        {
            _store.Set("affection", 10, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("affection >= 10"));
        }

        [Test]
        public void Evaluate_GreaterThanOrEqual_False()
        {
            _store.Set("affection", 5, VariableScope.Scenario);
            Assert.IsFalse(_evaluator.Evaluate("affection >= 10"));
        }

        [Test]
        public void Evaluate_GreaterThan()
        {
            _store.Set("hp", 50, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("hp > 49"));
            Assert.IsFalse(_evaluator.Evaluate("hp > 50"));
        }

        [Test]
        public void Evaluate_LessThan()
        {
            _store.Set("hp", 30, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("hp < 50"));
            Assert.IsFalse(_evaluator.Evaluate("hp < 30"));
        }

        [Test]
        public void Evaluate_LessThanOrEqual()
        {
            _store.Set("hp", 30, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("hp <= 30"));
            Assert.IsFalse(_evaluator.Evaluate("hp <= 29"));
        }

        [Test]
        public void Evaluate_Equal_Int()
        {
            _store.Set("count", 5, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("count == 5"));
            Assert.IsFalse(_evaluator.Evaluate("count == 6"));
        }

        [Test]
        public void Evaluate_NotEqual()
        {
            _store.Set("count", 5, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("count != 6"));
            Assert.IsFalse(_evaluator.Evaluate("count != 5"));
        }

        // === Boolean ===

        [Test]
        public void Evaluate_BoolVariable_True()
        {
            _store.Set("has_key", true, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("has_key"));
        }

        [Test]
        public void Evaluate_BoolVariable_False()
        {
            _store.Set("has_key", false, VariableScope.Scenario);
            Assert.IsFalse(_evaluator.Evaluate("has_key"));
        }

        [Test]
        public void Evaluate_UndefinedVariable_ReturnsFalse()
        {
            Assert.IsFalse(_evaluator.Evaluate("undefined_var"));
        }

        // === Equal with bool literal ===

        [Test]
        public void Evaluate_Equal_Bool()
        {
            _store.Set("flag", true, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("flag == true"));
            Assert.IsFalse(_evaluator.Evaluate("flag == false"));
        }

        // === Logical operators ===

        [Test]
        public void Evaluate_And()
        {
            _store.Set("has_key", true, VariableScope.Scenario);
            _store.Set("hp", 50, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("has_key && hp > 30"));
            Assert.IsFalse(_evaluator.Evaluate("has_key && hp > 60"));
        }

        [Test]
        public void Evaluate_Or()
        {
            _store.Set("has_key", false, VariableScope.Scenario);
            _store.Set("hp", 50, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("has_key || hp > 30"));
            Assert.IsFalse(_evaluator.Evaluate("has_key || hp > 60"));
        }

        // === Negation ===

        [Test]
        public void Evaluate_Not()
        {
            _store.Set("locked", false, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("!locked"));

            _store.Set("locked", true, VariableScope.Scenario);
            Assert.IsFalse(_evaluator.Evaluate("!locked"));
        }

        // === Whitespace tolerance ===

        [Test]
        public void Evaluate_TrimsWhitespace()
        {
            _store.Set("x", 10, VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("  x  >=  10  "));
        }

        // === String comparison ===

        [Test]
        public void Evaluate_StringEqual()
        {
            _store.Set("route", "good", VariableScope.Scenario);
            Assert.IsTrue(_evaluator.Evaluate("route == \"good\""));
            Assert.IsFalse(_evaluator.Evaluate("route == \"bad\""));
        }
    }
}
