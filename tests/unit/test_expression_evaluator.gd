extends GutTest
## Tests for ExpressionEvaluator — condition expression evaluation.


var _eval: ExpressionEvaluator
var _store: VariableStore


func before_each():
	_store = VariableStore.new()
	_eval = ExpressionEvaluator.new()


func test_compare_greater_equal_true():
	_store.set_var("affection", 10)
	assert_true(_eval.evaluate("affection >= 10", _store))


func test_compare_greater_equal_false():
	_store.set_var("affection", 5)
	assert_false(_eval.evaluate("affection >= 10", _store))


func test_compare_greater():
	_store.set_var("hp", 50)
	assert_true(_eval.evaluate("hp > 30", _store))
	assert_false(_eval.evaluate("hp > 50", _store))


func test_compare_less():
	_store.set_var("hp", 20)
	assert_true(_eval.evaluate("hp < 30", _store))
	assert_false(_eval.evaluate("hp < 20", _store))


func test_compare_less_equal():
	_store.set_var("hp", 20)
	assert_true(_eval.evaluate("hp <= 20", _store))
	assert_true(_eval.evaluate("hp <= 30", _store))
	assert_false(_eval.evaluate("hp <= 10", _store))


func test_compare_equal():
	_store.set_var("flag", true)
	assert_true(_eval.evaluate("flag == true", _store))
	_store.set_var("count", 5)
	assert_true(_eval.evaluate("count == 5", _store))


func test_compare_not_equal():
	_store.set_var("flag", false)
	assert_true(_eval.evaluate("flag != true", _store))


func test_bool_literal_true():
	assert_true(_eval.evaluate("true", _store))


func test_bool_literal_false():
	assert_false(_eval.evaluate("false", _store))


func test_variable_as_bool():
	_store.set_var("has_key", true)
	assert_true(_eval.evaluate("has_key", _store))
	_store.set_var("has_key", false)
	assert_false(_eval.evaluate("has_key", _store))


func test_undefined_variable_is_falsy():
	assert_false(_eval.evaluate("nonexistent", _store))


func test_logical_and():
	_store.set_var("a", true)
	_store.set_var("b", true)
	assert_true(_eval.evaluate("a && b", _store))
	_store.set_var("b", false)
	assert_false(_eval.evaluate("a && b", _store))


func test_logical_or():
	_store.set_var("a", false)
	_store.set_var("b", true)
	assert_true(_eval.evaluate("a || b", _store))
	_store.set_var("b", false)
	assert_false(_eval.evaluate("a || b", _store))


func test_negation():
	_store.set_var("flag", false)
	assert_true(_eval.evaluate("!flag", _store))
	_store.set_var("flag", true)
	assert_false(_eval.evaluate("!flag", _store))


func test_numeric_comparison_with_zero():
	_store.set_var("count", 0)
	assert_true(_eval.evaluate("count == 0", _store))
	assert_true(_eval.evaluate("count >= 0", _store))
	assert_false(_eval.evaluate("count > 0", _store))


func test_semantic_key_normalizes_runtime_equivalent_expression_spelling() -> void:
	assert_eq(
		ExpressionEvaluator.semantic_key(
			"score==1 && !flag || ratio >= 01.500"),
		ExpressionEvaluator.semantic_key(
			" score  ==  1.0  &&  ! flag  ||  ratio>=1.5 "),
		"the fingerprint representation must use the evaluator's normalized IR",
	)
	assert_ne(
		ExpressionEvaluator.semantic_key("score == 1"),
		ExpressionEvaluator.semantic_key("score != 1"),
	)
