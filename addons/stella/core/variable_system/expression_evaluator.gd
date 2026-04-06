## Evaluates condition expressions against a VariableStore.
## Supports: comparisons (>=, >, <, <=, ==, !=), logic (&&, ||, !), bool/numeric literals.
class_name ExpressionEvaluator extends RefCounted


func evaluate(expr: String, store: VariableStore) -> bool:
	expr = expr.strip_edges()

	# Logical OR (lowest precedence)
	var or_pos = expr.find("||")
	if or_pos != -1:
		var left = expr.substr(0, or_pos).strip_edges()
		var right = expr.substr(or_pos + 2).strip_edges()
		return evaluate(left, store) or evaluate(right, store)

	# Logical AND
	var and_pos = expr.find("&&")
	if and_pos != -1:
		var left = expr.substr(0, and_pos).strip_edges()
		var right = expr.substr(and_pos + 2).strip_edges()
		return evaluate(left, store) and evaluate(right, store)

	# Negation
	if expr.begins_with("!"):
		return not evaluate(expr.substr(1).strip_edges(), store)

	# Comparisons (check multi-char operators first)
	for op in [">=", "<=", "!=", "==", ">", "<"]:
		var op_pos = expr.find(op)
		if op_pos != -1:
			var left = _resolve_value(expr.substr(0, op_pos).strip_edges(), store)
			var right = _resolve_value(expr.substr(op_pos + op.length()).strip_edges(), store)
			return _compare(left, right, op)

	# Single value (bool literal or variable)
	return _is_truthy(_resolve_value(expr, store))


func _resolve_value(token: String, store: VariableStore) -> Variant:
	token = token.strip_edges()
	if token == "true":
		return true
	if token == "false":
		return false
	if token.is_valid_int():
		return token.to_int()
	if token.is_valid_float():
		return token.to_float()
	# Variable lookup
	return store.get_var(token)


func _compare(left: Variant, right: Variant, op: String) -> bool:
	# Coerce to float for numeric comparisons
	var l = float(left) if left != null else 0.0
	var r = float(right) if right != null else 0.0
	match op:
		">=": return l >= r
		">": return l > r
		"<=": return l <= r
		"<": return l < r
		"==": return _equals(left, right)
		"!=": return not _equals(left, right)
	return false


func _equals(left: Variant, right: Variant) -> bool:
	# Handle bool/int cross-comparison
	if left is bool and right is bool:
		return left == right
	if left is bool:
		return left == _is_truthy(right)
	if right is bool:
		return _is_truthy(left) == right
	# Numeric comparison
	var l = float(left) if left != null else 0.0
	var r = float(right) if right != null else 0.0
	return l == r


func _is_truthy(value: Variant) -> bool:
	if value == null:
		return false
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	if value is String:
		return value != "" and value != "false"
	return true
