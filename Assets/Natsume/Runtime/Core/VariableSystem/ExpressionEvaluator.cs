using System;
using System.Globalization;

namespace Natsume.Core.VariableSystem
{
    /// <summary>
    /// Evaluates conditional expressions used in scenario scripts.
    /// Supports: comparison (>=, >, <=, <, ==, !=), logical (&&, ||, !), bool/string literals.
    /// </summary>
    public class ExpressionEvaluator
    {
        private readonly VariableStore _variables;

        public ExpressionEvaluator(VariableStore variables)
        {
            _variables = variables ?? throw new ArgumentNullException(nameof(variables));
        }

        /// <summary>
        /// Evaluate an expression string and return a boolean result.
        /// </summary>
        public bool Evaluate(string expression)
        {
            if (string.IsNullOrWhiteSpace(expression))
                return false;

            expression = expression.Trim();

            // Handle logical OR (lowest precedence)
            int orIndex = FindLogicalOperator(expression, "||");
            if (orIndex >= 0)
            {
                var left = expression.Substring(0, orIndex).Trim();
                var right = expression.Substring(orIndex + 2).Trim();
                return Evaluate(left) || Evaluate(right);
            }

            // Handle logical AND
            int andIndex = FindLogicalOperator(expression, "&&");
            if (andIndex >= 0)
            {
                var left = expression.Substring(0, andIndex).Trim();
                var right = expression.Substring(andIndex + 2).Trim();
                return Evaluate(left) && Evaluate(right);
            }

            // Handle negation
            if (expression.StartsWith("!"))
            {
                return !Evaluate(expression.Substring(1).Trim());
            }

            // Handle comparison operators.
            // Limitation: only supports a single comparison per expression.
            // Chain comparisons (a >= b >= c) and parenthesized grouping are not supported.
            // For complex conditions, combine simple comparisons with && / ||,
            // or split into multiple condition commands.
            string[] operators = { ">=", "<=", "!=", "==", ">", "<" };
            foreach (var op in operators)
            {
                int idx = expression.IndexOf(op, StringComparison.Ordinal);
                if (idx > 0)
                {
                    var left = expression.Substring(0, idx).Trim();
                    var right = expression.Substring(idx + op.Length).Trim();
                    return EvaluateComparison(left, op, right);
                }
            }

            // Bare variable name → treat as boolean
            var value = _variables.GetRaw(expression);
            if (value == null) return false;
            if (value is bool b) return b;
            try { return Convert.ToBoolean(value); }
            catch { return false; }
        }

        private bool EvaluateComparison(string leftExpr, string op, string rightExpr)
        {
            var leftVal = ResolveValue(leftExpr);
            var rightVal = ResolveValue(rightExpr);

            // String comparison
            if (leftVal is string ls && rightVal is string rs)
            {
                switch (op)
                {
                    case "==": return string.Equals(ls, rs, StringComparison.Ordinal);
                    case "!=": return !string.Equals(ls, rs, StringComparison.Ordinal);
                    default: return false;
                }
            }

            // Bool comparison
            if (rightVal is bool rb)
            {
                bool lb;
                if (leftVal is bool b) lb = b;
                else if (leftVal == null) lb = false;
                else try { lb = Convert.ToBoolean(leftVal); } catch { lb = false; }

                switch (op)
                {
                    case "==": return lb == rb;
                    case "!=": return lb != rb;
                    default: return false;
                }
            }

            // Numeric comparison
            float leftNum = ToFloat(leftVal);
            float rightNum = ToFloat(rightVal);

            switch (op)
            {
                case ">=": return leftNum >= rightNum;
                case ">":  return leftNum > rightNum;
                case "<=": return leftNum <= rightNum;
                case "<":  return leftNum < rightNum;
                case "==": return Math.Abs(leftNum - rightNum) < 0.0001f;
                case "!=": return Math.Abs(leftNum - rightNum) >= 0.0001f;
                default: return false;
            }
        }

        private object ResolveValue(string expr)
        {
            // Bool literals
            if (expr.Equals("true", StringComparison.OrdinalIgnoreCase)) return true;
            if (expr.Equals("false", StringComparison.OrdinalIgnoreCase)) return false;

            // String literal (quoted)
            if (expr.Length >= 2 && expr[0] == '"' && expr[expr.Length - 1] == '"')
                return expr.Substring(1, expr.Length - 2);

            // Numeric literal
            if (float.TryParse(expr, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
                return expr;

            // Variable reference
            return _variables.GetRaw(expr);
        }

        private float ToFloat(object value)
        {
            if (value == null) return 0f;
            try { return Convert.ToSingle(value, CultureInfo.InvariantCulture); }
            catch
            {
                if (value is string s && float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var f))
                    return f;
                return 0f;
            }
        }

        /// <summary>
        /// Find a logical operator that is not inside quotes.
        /// </summary>
        private int FindLogicalOperator(string expr, string op)
        {
            bool inQuotes = false;
            for (int i = 0; i < expr.Length - op.Length + 1; i++)
            {
                if (expr[i] == '"') inQuotes = !inQuotes;
                if (!inQuotes && expr.Substring(i, op.Length) == op)
                    return i;
            }
            return -1;
        }
    }
}
