## Evaluates condition expressions against a VariableStore.
## Supports: comparisons (>=, >, <, <=, ==, !=), logic (&&, ||, !), bool/numeric literals.
class_name ExpressionEvaluator extends RefCounted


func evaluate(expr: String, store: VariableStore) -> bool:
	return _evaluate_ir(_parse_expression(expr), store)


## Returns the normalized expression IR used by evaluate(). Fingerprints can
## therefore distinguish runtime behavior without depending on source spacing
## or equivalent numeric spelling.
static func semantic_key(expr: String) -> Array:
	return _parse_expression(expr)


static func _parse_expression(expr: String) -> Array:
	expr = expr.strip_edges()

	# Logical OR (lowest precedence)
	var or_pos = expr.find("||")
	if or_pos != -1:
		var left = expr.substr(0, or_pos).strip_edges()
		var right = expr.substr(or_pos + 2).strip_edges()
		return ["or", _parse_expression(left), _parse_expression(right)]

	# Logical AND
	var and_pos = expr.find("&&")
	if and_pos != -1:
		var left = expr.substr(0, and_pos).strip_edges()
		var right = expr.substr(and_pos + 2).strip_edges()
		return ["and", _parse_expression(left), _parse_expression(right)]

	# Negation
	if expr.begins_with("!"):
		return ["not", _parse_expression(expr.substr(1).strip_edges())]

	# Comparisons (check multi-char operators first)
	for op in [">=", "<=", "!=", "==", ">", "<"]:
		var op_pos = expr.find(op)
		if op_pos != -1:
			return [
				"compare",
				op,
				_parse_value(expr.substr(0, op_pos)),
				_parse_value(expr.substr(op_pos + op.length())),
			]

	# Single value (bool literal or variable)
	return ["value", _parse_value(expr)]


static func _parse_value(token: String) -> Array:
	token = token.strip_edges()
	if token == "true":
		return ["literal", true]
	if token == "false":
		return ["literal", false]
	if token.is_valid_int() or token.is_valid_float():
		var numeric := token.to_float()
		if numeric == 0.0:
			numeric = 0.0
		return ["number", String.num(numeric, 17)]
	return ["variable", token]


func _evaluate_ir(ir: Array, store: VariableStore) -> bool:
	match String(ir[0]):
		"or":
			return _evaluate_ir(ir[1], store) or _evaluate_ir(ir[2], store)
		"and":
			return _evaluate_ir(ir[1], store) and _evaluate_ir(ir[2], store)
		"not":
			return not _evaluate_ir(ir[1], store)
		"compare":
			return _compare(
				_resolve_value(ir[2], store),
				_resolve_value(ir[3], store),
				String(ir[1]),
			)
		"value":
			return _is_truthy(_resolve_value(ir[1], store))
	return false


func _resolve_value(value_ir: Array, store: VariableStore) -> Variant:
	match String(value_ir[0]):
		"literal":
			return value_ir[1]
		"number":
			return String(value_ir[1]).to_float()
		"variable":
			return store.get_var(String(value_ir[1]))
	return null


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
