## Evaluates condition expressions against a VariableStore.
## Supports: comparisons (>=, >, <, <=, ==, !=), logic (&&, ||, !), bool/numeric literals.
class_name ExpressionEvaluator extends RefCounted


func evaluate(expr: String, store: VariableStore) -> bool:
	return _evaluate_ir(_parse_expression(expr), store)


## Returns an exact, JSON-safe projection of the runtime expression IR.
## Fingerprints can therefore distinguish every runtime Float value without
## depending on source spacing or equivalent numeric spelling.
static func semantic_key(expr: String) -> Array:
	return _semantic_ir(_parse_expression(expr))


static func _semantic_ir(ir: Array) -> Array:
	match String(ir[0]):
		"or", "and":
			return [ir[0], _semantic_ir(ir[1]), _semantic_ir(ir[2])]
		"not", "value":
			return [ir[0], _semantic_value_ir(ir[1])]
		"compare":
			return [
				ir[0],
				ir[1],
				_semantic_value_ir(ir[2]),
				_semantic_value_ir(ir[3]),
			]
	return ir.duplicate(true)


static func _semantic_value_ir(value_ir: Array) -> Array:
	if String(value_ir[0]) == "number":
		# Variant's binary encoding preserves the exact Float used by evaluate(),
		# while equivalent decimal/scientific spellings share the same bytes.
		return ["number", var_to_bytes(float(value_ir[1])).hex_encode()]
	return value_ir.duplicate(true)


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
		var numeric := _parse_number(token)
		if numeric == 0.0:
			numeric = 0.0
		return ["number", numeric]
	return ["variable", token]


static func _parse_number(token: String) -> float:
	# Godot's plain-decimal conversion can round very small values to zero while
	# its exponent parser reports raw errors for large-but-valid exponents. Parse
	# the exponent lexically with a bound derived from the token length, combine
	# it with the normalized mantissa exponent, and invoke Godot conversion only
	# inside the IEEE-754 Float range.
	var unsigned := token
	var sign_prefix := ""
	if unsigned.begins_with("+") or unsigned.begins_with("-"):
		sign_prefix = unsigned.left(1)
		unsigned = unsigned.substr(1)

	var explicit_exponent := 0
	var exponent_pos := unsigned.findn("e")
	if exponent_pos != -1:
		var exponent_text := unsigned.substr(exponent_pos + 1)
		unsigned = unsigned.left(exponent_pos)
		# The mantissa adjustment is bounded by token.length(). Clamping beyond
		# that plus the Float boundary therefore cannot change overflow/underflow.
		explicit_exponent = _parse_bounded_decimal_exponent(
			exponent_text, token.length() + 400)

	var decimal_pos := unsigned.find(".")
	var fractional_digits := 0
	if decimal_pos != -1:
		fractional_digits = unsigned.length() - decimal_pos - 1
		unsigned = unsigned.erase(decimal_pos, 1)

	unsigned = unsigned.lstrip("0")
	if unsigned.is_empty():
		return 0.0

	var normalized_exponent := (
		explicit_exponent - fractional_digits + unsigned.length() - 1)
	if normalized_exponent > 308:
		return -INF if sign_prefix == "-" else INF
	if normalized_exponent < -324:
		return 0.0
	var scientific := sign_prefix + unsigned.left(1)
	if unsigned.length() > 1:
		scientific += "." + unsigned.substr(1)
	scientific += "e" + str(normalized_exponent)
	return scientific.to_float()


static func _parse_bounded_decimal_exponent(text: String, limit: int) -> int:
	var sign := 1
	if text.begins_with("+") or text.begins_with("-"):
		if text.begins_with("-"):
			sign = -1
		text = text.substr(1)
	text = text.lstrip("0")
	if text.is_empty():
		return 0

	var limit_text := str(limit)
	if (
		text.length() > limit_text.length()
		or (
			text.length() == limit_text.length()
			and text > limit_text
		)
	):
		return sign * (limit + 1)
	return sign * int(text)


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
			return float(value_ir[1])
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
