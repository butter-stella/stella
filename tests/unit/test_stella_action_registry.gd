extends GutTest
## Public action-registry contract: catalog, ownership, reentrancy, and policy.


class ActionOwner extends Node:
	var registry: StellaActionRegistry
	var action_id: StringName
	var replacement: ActionOwner
	var can_mode: StringName = &""
	var execute_mode: StringName = &""
	var execute_result: Variant = true
	var can_result: Variant = null
	var active_result: Variant = null
	var available: bool = true
	var active: bool = false
	var execute_count: int = 0
	var arity_callback_count: int = 0

	func execute_action(_context: Dictionary) -> Variant:
		execute_count += 1
		if execute_mode == &"replace":
			registry.unregister_action(action_id, self)
			registry.register_action(
				action_id,
				_test_metadata(),
				replacement,
				Callable(replacement, "execute_action"),
			)
		elif execute_mode == &"unregister":
			registry.unregister_action(action_id, self)
		return execute_result

	func can_execute_action(_context: Dictionary) -> Variant:
		if can_mode == &"unregister":
			registry.unregister_action(action_id, self)
		elif can_mode == &"replace":
			registry.unregister_action(action_id, self)
			registry.register_action(
				action_id,
				_test_metadata(),
				replacement,
				Callable(replacement, "execute_action"),
			)
		return available if can_result == null else can_result

	func is_active_action(_context: Dictionary) -> Variant:
		return active if active_result == null else active_result

	func zero_arg_action() -> bool:
		arity_callback_count += 1
		return true

	func two_arg_action(_context: Dictionary, _bound: Variant) -> bool:
		arity_callback_count += 1
		return true

	func _test_metadata() -> Dictionary:
		return {
			"label": "Test action",
			"category": "test",
		}


var _owners: Array[Node] = []
var _saved_runtime_registry: StellaActionRegistry
var _fake_registry_nodes: Array[Node] = []


func after_each() -> void:
	await get_tree().process_frame
	for node: Node in _fake_registry_nodes:
		if is_instance_valid(node):
			node.free()
	_fake_registry_nodes.clear()
	if _saved_runtime_registry != null:
		StellaRuntime.action_registry = _saved_runtime_registry
		_saved_runtime_registry = null
	for owner: Node in _owners:
		if is_instance_valid(owner):
			owner.free()
	_owners.clear()
	await get_tree().process_frame


func _owner(registry: StellaActionRegistry, action_id: StringName) -> ActionOwner:
	var owner := ActionOwner.new()
	owner.registry = registry
	owner.action_id = action_id
	add_child(owner)
	_owners.append(owner)
	return owner


func _metadata(
	policy: StringName = StellaActionRegistry.CONFIRMATION_NONE,
) -> Dictionary:
	return {
		"label": "Test action",
		"label_key": "test.action.label",
		"category": "test",
		"confirmation_policy": policy,
		"order": 7,
	}


func _register(
	registry: StellaActionRegistry,
	owner: ActionOwner,
	with_can: bool = false,
	with_active: bool = false,
	policy: StringName = StellaActionRegistry.CONFIRMATION_NONE,
) -> bool:
	return registry.register_action(
		owner.action_id,
		_metadata(policy),
		owner,
		Callable(owner, "execute_action"),
		Callable(owner, "can_execute_action") if with_can else Callable(),
		Callable(owner, "is_active_action") if with_active else Callable(),
	)


func test_runtime_catalog_is_complete_ordered_and_defensive() -> void:
	var actions := StellaRuntime.get_actions()
	assert_eq(actions.size(), 18)
	var ids: Array[StringName] = []
	var prior_order: int = -1
	for metadata: Dictionary in actions:
		ids.append(StringName(metadata["id"]))
		assert_true(int(metadata["order"]) > prior_order)
		prior_order = int(metadata["order"])
		assert_true(bool(metadata["builtin"]))
		assert_false(String(metadata["label"]).is_empty())
		assert_false(String(metadata["label_key"]).is_empty())
	assert_has(ids, StellaActionRegistry.ACTION_VOICE_REPLAY)
	assert_has(ids, StellaActionRegistry.ACTION_QUIT)

	var copy := StellaRuntime.get_action(StellaActionRegistry.ACTION_AUTO)
	copy["label"] = "mutated"
	copy["nested"] = {"bad": true}
	assert_ne(
		StellaRuntime.get_action(StellaActionRegistry.ACTION_AUTO)["label"],
		"mutated",
	)
	assert_false(
		StellaRuntime.get_action(
			StellaActionRegistry.ACTION_AUTO).has("nested"))


func test_custom_action_requires_namespaced_id_and_tree_bound_owner() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.open_codex")
	assert_true(_register(registry, owner, true, true))
	assert_false(registry.register_action(
		&"open_codex", _metadata(), owner,
		Callable(owner, "execute_action")))
	assert_string_contains(registry.last_error, "namespaced")
	for malformed_id: StringName in [
		&".project.open_codex",
		&"project.open_codex.",
		&"project..open_codex",
	]:
		assert_false(registry.register_action(
			malformed_id, _metadata(), owner,
			Callable(owner, "execute_action")))
		assert_string_contains(registry.last_error, "namespaced")

	var ref_owner := RefCounted.new()
	assert_false(registry.register_action(
		&"project.ref_owner", _metadata(), ref_owner,
		Callable(owner, "execute_action")))
	assert_string_contains(registry.last_error, "tree-bound Node")

	var unattached := ActionOwner.new()
	unattached.registry = registry
	unattached.action_id = &"project.unattached"
	_owners.append(unattached)
	assert_false(registry.register_action(
		unattached.action_id, _metadata(), unattached,
		Callable(unattached, "execute_action")))
	assert_string_contains(registry.last_error, "tree-bound Node")

	var queued := _owner(registry, &"project.queued")
	queued.queue_free()
	assert_false(registry.register_action(
		queued.action_id, _metadata(), queued,
		Callable(queued, "execute_action")))
	assert_string_contains(registry.last_error, "tree-bound Node")

	assert_true(registry.can_execute(owner.action_id))
	assert_false(registry.is_active(owner.action_id))
	owner.active = true
	assert_true(registry.is_active(owner.action_id))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)


func test_custom_callbacks_require_one_effective_context_argument() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.callback_arity")
	assert_false(registry.register_action(
		owner.action_id,
		_metadata(),
		owner,
		Callable(owner, "zero_arg_action"),
	))
	assert_string_contains(registry.last_error, "exactly one context")
	assert_false(registry.register_action(
		owner.action_id,
		_metadata(),
		owner,
		Callable(owner, "two_arg_action"),
	))
	assert_string_contains(registry.last_error, "exactly one context")
	assert_false(registry.register_action(
		owner.action_id,
		_metadata(),
		owner,
		Callable(owner, "execute_action"),
		Callable(owner, "zero_arg_action"),
	))
	assert_string_contains(registry.last_error, "exactly one context")
	assert_false(registry.register_action(
		owner.action_id,
		_metadata(),
		owner,
		Callable(owner, "execute_action"),
		Callable(),
		Callable(owner, "two_arg_action"),
	))
	assert_string_contains(registry.last_error, "exactly one context")
	assert_eq(owner.arity_callback_count, 0,
		"registration validation must not invoke malformed callbacks")

	assert_true(registry.register_action(
		owner.action_id,
		_metadata(),
		owner,
		Callable(owner, "two_arg_action").bind(&"execute"),
		Callable(owner, "two_arg_action").bind(&"can"),
		Callable(owner, "two_arg_action").bind(&"active"),
	))
	assert_true(registry.can_execute(owner.action_id))
	assert_true(registry.is_active(owner.action_id))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.arity_callback_count, 4,
		"explicit can query plus execute admission each invoke the bound predicate")


func test_custom_action_conflict_unregister_and_owner_tree_exit() -> void:
	var registry := StellaActionRegistry.new()
	var first := _owner(registry, &"project.lifecycle")
	var second := _owner(registry, &"project.lifecycle")
	assert_true(_register(registry, first))
	assert_false(_register(registry, second))
	assert_false(registry.unregister_action(first.action_id, second))
	assert_true(registry.unregister_action(first.action_id, first))
	assert_true(_register(registry, second))

	var action_id := second.action_id
	second.queue_free()
	await second.tree_exited
	await get_tree().process_frame
	assert_true(registry.get_action(action_id).is_empty())
	assert_eq(
		registry.execute(action_id),
		StellaActionRegistry.ExecuteResult.NOT_FOUND,
	)


func test_queued_or_detached_owner_fails_closed_before_the_next_frame() -> void:
	var registry := StellaActionRegistry.new()
	var queued := _owner(registry, &"project.lifecycle.queued")
	queued.active = true
	assert_true(_register(registry, queued, true, true))
	var queued_owner_id := queued.get_instance_id()
	var queued_record: Dictionary = registry._owners[queued_owner_id]
	var queued_exit_callback: Callable = queued_record["tree_exit_callback"]
	assert_true(queued.tree_exiting.is_connected(queued_exit_callback))

	queued.queue_free()
	assert_true(registry.get_action(queued.action_id).is_empty())
	assert_false(registry.can_execute(queued.action_id))
	assert_false(registry.is_active(queued.action_id))
	assert_eq(
		registry.execute(queued.action_id),
		StellaActionRegistry.ExecuteResult.NOT_FOUND,
	)
	assert_eq(queued.execute_count, 0)
	assert_false(registry._owners.has(queued_owner_id))
	assert_false(queued.tree_exiting.is_connected(queued_exit_callback))

	var detached := _owner(registry, &"project.lifecycle.detached")
	assert_true(_register(registry, detached))
	var detached_owner_id := detached.get_instance_id()
	var detached_record: Dictionary = registry._owners[detached_owner_id]
	var detached_exit_callback: Callable = detached_record["tree_exit_callback"]
	remove_child(detached)
	assert_true(registry.get_action(detached.action_id).is_empty())
	assert_eq(
		registry.execute(detached.action_id),
		StellaActionRegistry.ExecuteResult.NOT_FOUND,
	)
	assert_false(registry._owners.has(detached_owner_id))
	assert_false(detached.tree_exiting.is_connected(detached_exit_callback))
	assert_true(registry._retiring_owner_ids.is_empty())


func test_owner_exit_reentry_cannot_leave_multi_action_zombies() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.lifecycle.first")
	assert_true(_register(registry, owner))
	assert_true(registry.register_action(
		&"project.lifecycle.second",
		_metadata(),
		owner,
		Callable(owner, "execute_action"),
	))
	var reentry_attempts := [0]
	var reentry_successes := [0]
	var catalog_listener := func() -> void:
		reentry_attempts[0] += 1
		if registry.register_action(
			&"project.lifecycle.zombie",
			_metadata(),
			owner,
			Callable(owner, "execute_action"),
		):
			reentry_successes[0] += 1
	registry.catalog_changed.connect(catalog_listener)

	owner.queue_free()
	await owner.tree_exited
	assert_eq(reentry_attempts[0], 2)
	assert_eq(reentry_successes[0], 0)
	assert_true(registry.list_actions().is_empty())
	assert_true(registry._owners.is_empty())
	assert_true(registry._retiring_owner_ids.is_empty())


func test_non_boolean_custom_callbacks_fail_closed() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.non_bool")
	owner.execute_result = "not a bool"
	assert_true(_register(registry, owner, true, true))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	owner.execute_result = true
	owner.can_result = "not a bool"
	assert_false(registry.can_execute(owner.action_id))
	owner.can_result = null
	owner.active_result = "not a bool"
	assert_false(registry.is_active(owner.action_id))


func test_can_callback_unregister_cannot_execute_retired_entry() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.can_unregister")
	owner.can_mode = &"unregister"
	assert_true(_register(registry, owner, true))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	assert_eq(owner.execute_count, 0)


func test_can_callback_replace_cannot_execute_either_generation() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.can_replace")
	var replacement := _owner(registry, owner.action_id)
	owner.replacement = replacement
	owner.can_mode = &"replace"
	assert_true(_register(registry, owner, true))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	assert_eq(owner.execute_count, 0)
	assert_eq(replacement.execute_count, 0)
	assert_same(
		registry._get_live_entry(owner.action_id)["owner_ref"].get_ref(),
		replacement,
	)


func test_execute_callback_replace_does_not_emit_for_new_generation() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.execute_replace")
	var replacement := _owner(registry, owner.action_id)
	owner.replacement = replacement
	owner.execute_mode = &"replace"
	assert_true(_register(registry, owner))
	var state_events: Array[StringName] = []
	registry.action_state_changed.connect(
		func(action_id: StringName) -> void: state_events.append(action_id))

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	assert_eq(owner.execute_count, 1)
	assert_eq(replacement.execute_count, 0)
	assert_eq(state_events.size(), 2,
		"unregister and replacement registration publish; outer execute does not")


func test_confirmation_listener_can_confirm_exactly_once() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.destructive")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var requests: Array[StringName] = []
	var confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		requests.append(action_id)
		var confirmed_context := context.duplicate(true)
		confirmed_context["confirmation_granted"] = true
		registry.execute(action_id, confirmed_context)
	registry.confirmation_requested.connect(confirmation_listener)

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(requests, [owner.action_id])
	assert_eq(owner.execute_count, 1)
	registry.confirmation_requested.disconnect(confirmation_listener)


func test_confirmation_token_allows_only_one_of_multiple_consumers() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.multi_confirm")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var results: Array[int] = []
	var first_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		var confirmed_context := context.duplicate(true)
		confirmed_context["confirmation_granted"] = true
		results.append(registry.execute(action_id, confirmed_context))
	var second_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		var confirmed_context := context.duplicate(true)
		confirmed_context["confirmation_granted"] = true
		results.append(registry.execute(action_id, confirmed_context))
	registry.confirmation_requested.connect(first_listener)
	registry.confirmation_requested.connect(second_listener)

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)
	assert_eq(results, [
		StellaActionRegistry.ExecuteResult.EXECUTED,
		StellaActionRegistry.ExecuteResult.FAILED,
	])
	registry.confirmation_requested.disconnect(first_listener)
	registry.confirmation_requested.disconnect(second_listener)


func test_confirmation_context_types_fail_closed_without_consuming_token() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirmation_types")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var request_contexts: Array[Dictionary] = []
	registry.confirmation_requested.connect(func(
		_action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void: request_contexts.append(context.duplicate(true)))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	)
	assert_eq(request_contexts.size(), 1)
	var exact_context: Dictionary = request_contexts[0]
	var non_bool := exact_context.duplicate(true)
	non_bool["confirmation_granted"] = "true"
	assert_eq(
		registry.execute(owner.action_id, non_bool),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	var non_int := exact_context.duplicate(true)
	non_int["confirmation_granted"] = true
	non_int[StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY] = (
		str(exact_context[
			StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY]))
	assert_eq(
		registry.execute(owner.action_id, non_int),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	var wrong_token := exact_context.duplicate(true)
	wrong_token["confirmation_granted"] = true
	wrong_token[StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY] = (
		int(exact_context[
			StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY]) + 1)
	assert_eq(
		registry.execute(owner.action_id, wrong_token),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	exact_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, exact_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)


func test_valid_confirmation_is_retired_when_availability_changes() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_availability")
	assert_true(_register(
		registry, owner, true, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var contexts: Array[Dictionary] = []
	registry.confirmation_requested.connect(func(
		_action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void: contexts.append(context.duplicate(true)))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	)
	assert_eq(contexts.size(), 1)
	var stale_context: Dictionary = contexts[0].duplicate(true)
	stale_context["confirmation_granted"] = true
	owner.available = false
	assert_eq(
		registry.execute(owner.action_id, stale_context),
		StellaActionRegistry.ExecuteResult.UNAVAILABLE,
	)
	owner.available = true
	assert_eq(
		registry.execute(owner.action_id, stale_context),
		StellaActionRegistry.ExecuteResult.FAILED,
		"availability recovery cannot revive a consumed user decision",
	)
	assert_eq(owner.execute_count, 0)

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	)
	assert_eq(contexts.size(), 2)
	assert_ne(
		contexts[0][StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY],
		contexts[1][StellaActionRegistry.CONFIRMATION_TOKEN_CONTEXT_KEY],
	)
	var fresh_context := contexts[1].duplicate(true)
	fresh_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, fresh_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)


func test_confirmed_can_reentry_cannot_transfer_receipt_to_replacement() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_can_replace")
	var replacement := _owner(registry, owner.action_id)
	owner.replacement = replacement
	assert_true(_register(
		registry, owner, true, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var contexts: Array[Dictionary] = []
	registry.confirmation_requested.connect(func(
		_action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void: contexts.append(context.duplicate(true)))
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	)
	owner.can_mode = &"replace"
	var confirmed_context := contexts[0].duplicate(true)
	confirmed_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, confirmed_context),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	assert_eq(owner.execute_count, 0)
	assert_eq(replacement.execute_count, 0)
	var replacement_entry := registry._get_live_entry(owner.action_id)
	assert_true((replacement_entry["pending_confirmation_tokens"] as Dictionary).is_empty())
	assert_same(replacement_entry["owner_ref"].get_ref(), replacement)


func test_confirmation_listener_replacement_invalidates_outer_receipt() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_replace")
	var replacement := _owner(registry, owner.action_id)
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		_context: Dictionary,
	) -> void:
		registry.unregister_action(action_id, owner)
		_register(registry, replacement)
	registry.confirmation_requested.connect(confirmation_listener)
	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	assert_eq(owner.execute_count, 0)
	assert_eq(replacement.execute_count, 0)
	registry.confirmation_requested.disconnect(confirmation_listener)


func test_nested_confirmation_requests_keep_independent_exact_tokens() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_nested")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var reentered := [false]
	var nested_results: Array[int] = []
	var nested_contexts: Array[Dictionary] = []
	var confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		if not reentered[0]:
			reentered[0] = true
			nested_results.append(registry.execute(action_id, {}))
		else:
			nested_contexts.append(context.duplicate(true))
	registry.confirmation_requested.connect(confirmation_listener)

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
		"a nested request does not retire the still-pending outer decision",
	)
	assert_eq(nested_results, [
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	])
	assert_eq(owner.execute_count, 0)
	assert_eq(nested_contexts.size(), 1)
	var confirmed_context := nested_contexts[0].duplicate(true)
	confirmed_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, confirmed_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)
	registry.confirmation_requested.disconnect(confirmation_listener)


func test_sequential_confirmation_requests_keep_one_fresh_receipt() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_bounded")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var contexts: Array[Dictionary] = []
	registry.confirmation_requested.connect(func(
		_action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void: contexts.append(context.duplicate(true)))

	for request_index: int in range(32):
		assert_eq(
			registry.execute(owner.action_id),
			StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
			"top-level request %d is admitted" % request_index,
		)
		var entry := registry._get_live_entry(owner.action_id)
		assert_eq(
			(entry["pending_confirmation_tokens"] as Dictionary).size(), 1,
			"a fresh top-level request supersedes every older receipt",
		)

	var stale_context := contexts[0].duplicate(true)
	stale_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, stale_context),
		StellaActionRegistry.ExecuteResult.FAILED,
	)
	var fresh_context: Dictionary = contexts.back().duplicate(true)
	fresh_context["confirmation_granted"] = true
	assert_eq(
		registry.execute(owner.action_id, fresh_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 1)
	assert_true((registry._get_live_entry(owner.action_id)[
		"pending_confirmation_tokens"] as Dictionary).is_empty())


func test_nested_confirmation_receipts_fail_closed_at_explicit_bound() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.confirm_nested_bound")
	assert_true(_register(
		registry, owner, false, false,
		StellaActionRegistry.CONFIRMATION_DESTRUCTIVE))
	var nested_results: Array[int] = []
	var confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		_context: Dictionary,
	) -> void:
		nested_results.append(registry.execute(action_id))
	registry.confirmation_requested.connect(confirmation_listener)

	assert_eq(
		registry.execute(owner.action_id),
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	)
	assert_eq(nested_results.size(),
		StellaActionRegistry._MAX_NESTED_CONFIRMATION_RECEIPTS)
	assert_eq(
		nested_results.front(),
		StellaActionRegistry.ExecuteResult.FAILED,
		"the deepest request beyond the receipt ceiling fails without emitting",
	)
	var entry := registry._get_live_entry(owner.action_id)
	assert_eq(
		(entry["pending_confirmation_tokens"] as Dictionary).size(),
		StellaActionRegistry._MAX_NESTED_CONFIRMATION_RECEIPTS,
	)
	assert_eq(int(entry["confirmation_dispatch_depth"]), 0)
	registry.confirmation_requested.disconnect(confirmation_listener)


func test_action_state_notification_is_read_only_dispatch_boundary() -> void:
	var registry := StellaActionRegistry.new()
	var source := _owner(registry, &"project.state_source")
	var target := _owner(registry, &"project.state_target")
	target.active = true
	assert_true(_register(registry, source))
	assert_true(_register(registry, target, true, true))
	var nested_results: Array[int] = []
	var listener := func(action_id: StringName) -> void:
		if action_id != source.action_id:
			return
		assert_false(registry.get_action(target.action_id).is_empty())
		assert_true(registry.can_execute(target.action_id))
		assert_true(registry.is_active(target.action_id))
		nested_results.append(registry.execute(target.action_id))
	registry.action_state_changed.connect(listener)

	registry.notify_action_state_changed(source.action_id)
	assert_eq(nested_results, [StellaActionRegistry.ExecuteResult.FAILED])
	assert_eq(target.execute_count, 0)
	assert_eq(registry._state_notification_depth, 0)
	registry.action_state_changed.disconnect(listener)


func test_notify_all_skips_replaced_snapshot_generation() -> void:
	var registry := StellaActionRegistry.new()
	var first := _owner(registry, &"project.a")
	var second := _owner(registry, &"project.b")
	var replacement := _owner(registry, second.action_id)
	assert_true(_register(registry, first))
	assert_true(_register(registry, second))
	var first_events := [0]
	var second_events := [0]
	var mutated := [false]
	var state_listener := func(action_id: StringName) -> void:
		if action_id == first.action_id:
			first_events[0] += 1
			if not mutated[0]:
				mutated[0] = true
				registry.unregister_action(second.action_id, second)
				_register(registry, replacement)
		elif action_id == second.action_id:
			second_events[0] += 1
	registry.action_state_changed.connect(state_listener)

	registry.notify_all_action_states_changed()
	assert_eq(first_events[0], 1)
	assert_eq(second_events[0], 2,
		"replacement gets its nested remove/add events, not the stale snapshot event")
	registry.action_state_changed.disconnect(state_listener)


func test_catalog_reentry_never_sends_retired_state_to_replacement() -> void:
	var registry := StellaActionRegistry.new()
	var owner := _owner(registry, &"project.catalog_reentry")
	var replacement := _owner(registry, owner.action_id)
	var replaced := [false]
	var state_events := [0]
	var catalog_listener := func() -> void:
		if replaced[0] or registry.get_action(owner.action_id).is_empty():
			return
		replaced[0] = true
		registry.unregister_action(owner.action_id, owner)
		_register(registry, replacement)
	registry.catalog_changed.connect(catalog_listener)
	var state_listener := func(_action_id: StringName) -> void:
		state_events[0] += 1
	registry.action_state_changed.connect(state_listener)

	assert_true(_register(registry, owner))
	assert_eq(state_events[0], 2,
		"nested remove/add events publish; outer registration skips its retired receipt")
	registry.catalog_changed.disconnect(catalog_listener)
	registry.action_state_changed.disconnect(state_listener)


func test_runtime_registry_rejects_hostile_builtin_registration() -> void:
	var registry := StellaRuntime.action_registry
	var before := StellaRuntime.get_actions()
	assert_false(registry.has_method("_register_builtin_action"))
	assert_false(registry.register_action(
		&"hostile",
		_metadata(),
		StellaRuntime,
		Callable(StellaRuntime, "_action_execute_auto"),
	))
	assert_false(registry.register_action(
		StellaActionRegistry.ACTION_AUTO,
		_metadata(),
		StellaRuntime,
		Callable(StellaRuntime, "_action_execute_auto"),
	))
	assert_false(registry.register_action(
		&"host.quit_now",
		_metadata(),
		StellaRuntime,
		Callable(StellaRuntime, "_action_execute_quit"),
	))
	assert_string_contains(registry.last_error, "owner is sealed")
	assert_false(registry._register_action(
		&"hostile_builtin",
		_metadata(),
		StellaRuntime,
		Callable(StellaRuntime, "_action_execute_auto"),
		Callable(),
		Callable(),
		true,
		RefCounted.new(),
	))
	assert_string_contains(registry.last_error, "sealed")
	assert_eq(StellaRuntime.get_actions(), before)


func test_runtime_registry_construction_is_all_or_nothing() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.builder")
	var valid := _builtin_definitions(owner)

	var missing := valid.duplicate(true)
	missing.pop_back()
	var missing_registry := StellaActionRegistry._create_runtime_registry(
		owner, missing)
	assert_false(missing_registry.is_ready())
	assert_true(missing_registry.list_actions().is_empty())

	var duplicate := valid.duplicate(true)
	duplicate[-1]["id"] = duplicate[0]["id"]
	var duplicate_registry := StellaActionRegistry._create_runtime_registry(
		owner, duplicate)
	assert_false(duplicate_registry.is_ready())
	assert_true(duplicate_registry.list_actions().is_empty())

	var malformed := valid.duplicate(true)
	malformed[7]["metadata"]["label"] = ""
	var malformed_registry := StellaActionRegistry._create_runtime_registry(
		owner, malformed)
	assert_false(malformed_registry.is_ready())
	assert_true(malformed_registry.list_actions().is_empty())


func test_legacy_destructive_enum_button_consumes_exact_receipt_once() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.legacy_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry

	for legacy_action: StellaAction.Action in [
		StellaAction.Action.QUIT,
		StellaAction.Action.RETURN_TO_TITLE,
	]:
		var button := Button.new()
		var binding := StellaAction.new()
		binding.action = legacy_action
		button.add_child(binding)
		add_child(button)
		_fake_registry_nodes.append(button)
		button.pressed.emit()
		assert_eq(owner.execute_count, 1,
			"one real legacy Button press dispatches exactly once")
		owner.execute_count = 0
		_fake_registry_nodes.erase(button)
		button.free()


func test_legacy_enum_binding_is_presentation_passive() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.legacy_visual_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var button := Button.new()
	button.text = "Authored legacy"
	button.disabled = true
	button.visible = false
	button.toggle_mode = true
	button.button_pressed = true
	button.modulate = Color(0.2, 0.4, 0.6, 0.35)
	var binding := StellaAction.new()
	binding.action = StellaAction.Action.TOGGLE_AUTO_PLAY
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)

	fake_registry.notify_all_action_states_changed()
	fake_registry.catalog_changed.emit()
	assert_eq(button.text, "Authored legacy")
	assert_true(button.disabled)
	assert_false(button.visible)
	assert_true(button.toggle_mode)
	assert_true(button.button_pressed)
	assert_eq(button.modulate, Color(0.2, 0.4, 0.6, 0.35))
	button.pressed.emit()
	assert_eq(owner.execute_count, 1,
		"legacy presentation remains passive while dispatch stays one-to-one")

	_fake_registry_nodes.erase(button)
	button.free()


func test_default_title_quit_confirms_exact_registry_receipt_once() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.title_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var title: Node = load(
		"res://addons/stella/scenes/title.tscn").instantiate()
	add_child(title)
	_fake_registry_nodes.append(title)
	var quit_button := _find_action_button(
		title, StellaActionRegistry.ACTION_QUIT)
	assert_not_null(quit_button)
	if quit_button != null:
		quit_button.pressed.emit()
	assert_eq(owner.execute_count, 0,
		"canonical action_id waits at the confirmation boundary")
	var dialog: ConfirmationDialog = null
	for child: Node in title.get_node("TitleScreen").get_children():
		if child is ConfirmationDialog:
			dialog = child as ConfirmationDialog
			break
	assert_not_null(dialog)
	if dialog != null:
		dialog.confirmed.emit()
	assert_eq(owner.execute_count, 1)

	_fake_registry_nodes.erase(title)
	title.free()


func test_legacy_auto_confirm_marker_prevents_stale_project_popup() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.coexist_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var popup_count := [0]
	var project_confirmation_listener := func(
		_action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		var marker: Variant = context.get(
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY, null)
		if typeof(marker) != TYPE_BOOL or marker != true:
			popup_count[0] += 1
	fake_registry.confirmation_requested.connect(project_confirmation_listener)

	var button := Button.new()
	var binding := StellaAction.new()
	binding.action = StellaAction.Action.QUIT
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)
	button.pressed.emit()
	assert_eq(owner.execute_count, 1)
	assert_eq(popup_count[0], 0,
		"a normal confirmation UI ignores legacy's exact auto-confirm receipt")

	_fake_registry_nodes.erase(button)
	button.free()
	fake_registry.confirmation_requested.disconnect(
		project_confirmation_listener)


func test_legacy_button_does_not_consume_reentrant_ordinary_receipt() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.reentrant_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var reentered := [false]
	var nested_results: Array[int] = []
	var ordinary_contexts: Array[Dictionary] = []
	var project_confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		var marker: Variant = context.get(
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY, null)
		if typeof(marker) == TYPE_BOOL and marker == true and not reentered[0]:
			reentered[0] = true
			nested_results.append(fake_registry.execute(action_id, {}))
		elif typeof(marker) != TYPE_BOOL or marker != true:
			ordinary_contexts.append(context.duplicate(true))
	fake_registry.confirmation_requested.connect(project_confirmation_listener)

	var button := Button.new()
	var binding := StellaAction.new()
	binding.action = StellaAction.Action.QUIT
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)
	button.pressed.emit()
	assert_eq(nested_results, [
		StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
	])
	assert_eq(owner.execute_count, 1,
		"legacy executes its marked receipt without consuming the nested ordinary one")
	assert_eq(ordinary_contexts.size(), 1)
	assert_false(ordinary_contexts[0].has(
		StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY))
	var confirmed_context := ordinary_contexts[0].duplicate(true)
	confirmed_context["confirmation_granted"] = true
	assert_eq(
		fake_registry.execute(
			StellaActionRegistry.ACTION_QUIT, confirmed_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 2,
		"the ordinary receipt remains available to the project confirmation UI")

	_fake_registry_nodes.erase(button)
	button.free()
	fake_registry.confirmation_requested.disconnect(
		project_confirmation_listener)


func test_legacy_button_rejects_truthy_non_boolean_marker() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.marker_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var reentered := [false]
	var malformed_contexts: Array[Dictionary] = []
	var project_confirmation_listener := func(
		action_id: StringName,
		_policy: StringName,
		context: Dictionary,
	) -> void:
		var marker: Variant = context.get(
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY, null)
		if typeof(marker) == TYPE_BOOL and marker == true and not reentered[0]:
			reentered[0] = true
			fake_registry.execute(action_id, {
				StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY: "true",
			})
		elif typeof(marker) != TYPE_BOOL:
			malformed_contexts.append(context.duplicate(true))
	fake_registry.confirmation_requested.connect(project_confirmation_listener)

	var button := Button.new()
	var binding := StellaAction.new()
	binding.action = StellaAction.Action.QUIT
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)
	button.pressed.emit()
	assert_eq(owner.execute_count, 1,
		"legacy confirms only its strict boolean-marked outer receipt")
	assert_eq(malformed_contexts.size(), 1)
	assert_eq(
		malformed_contexts[0][
			StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY],
		"true",
	)
	var confirmed_context := malformed_contexts[0].duplicate(true)
	confirmed_context["confirmation_granted"] = true
	assert_eq(
		fake_registry.execute(
			StellaActionRegistry.ACTION_QUIT, confirmed_context),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_eq(owner.execute_count, 2)

	_fake_registry_nodes.erase(button)
	button.free()
	fake_registry.confirmation_requested.disconnect(
		project_confirmation_listener)


func test_title_consumers_treat_malformed_marker_as_ordinary() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.title_marker_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry
	var expected_execute_count := 0
	for scene_path: String in [
		"res://addons/stella/scenes/title.tscn",
		"res://examples/demo/scenes/title.tscn",
	]:
		var title: Node = load(scene_path).instantiate()
		add_child(title)
		_fake_registry_nodes.append(title)
		assert_eq(
			fake_registry.execute(StellaActionRegistry.ACTION_QUIT, {
				StellaActionRegistry.CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY: "true",
			}),
			StellaActionRegistry.ExecuteResult.CONFIRMATION_REQUIRED,
		)
		var dialog: ConfirmationDialog = null
		var title_screen := title.get_node("TitleScreen")
		for child: Node in title_screen.get_children():
			if child is ConfirmationDialog:
				dialog = child as ConfirmationDialog
				break
		assert_not_null(dialog)
		if dialog != null:
			assert_true(dialog.visible,
				"truthy non-bool marker must not suppress normal confirmation")
			dialog.confirmed.emit()
		expected_execute_count += 1
		assert_eq(owner.execute_count, expected_execute_count)
		_fake_registry_nodes.erase(title)
		title.free()


func test_binding_reprojects_toggle_and_label_when_builtin_id_changes() -> void:
	var owner := _owner(StellaActionRegistry.new(), &"project.binding_probe")
	owner.active = true
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		owner, _builtin_definitions(owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry

	var button := Button.new()
	button.text = "Authored fallback"
	var binding := StellaAction.new()
	binding.action_id = StellaActionRegistry.ACTION_AUTO
	binding.sync_label = true
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)
	assert_eq(button.text, "Label auto")
	assert_true(button.toggle_mode)
	assert_true(button.button_pressed)

	binding.action_id = StellaActionRegistry.ACTION_SAVE
	assert_eq(button.text, "Label save")
	assert_false(button.toggle_mode)
	assert_false(button.button_pressed)


func test_binding_restores_authored_label_across_custom_toggle_replacement() -> void:
	var builtin_owner := _owner(
		StellaActionRegistry.new(), &"project.builtin_probe")
	var fake_registry := StellaActionRegistry._create_runtime_registry(
		builtin_owner, _builtin_definitions(builtin_owner))
	assert_true(fake_registry.is_ready())
	_saved_runtime_registry = StellaRuntime.action_registry
	StellaRuntime.action_registry = fake_registry

	var first := _owner(fake_registry, &"project.replaceable")
	first.active = true
	var toggle_metadata := _metadata()
	toggle_metadata["label"] = "Project toggle"
	toggle_metadata["toggle"] = true
	assert_true(fake_registry.register_action(
		first.action_id,
		toggle_metadata,
		first,
		Callable(first, "execute_action"),
		Callable(),
		Callable(first, "is_active_action"),
	))
	var button := Button.new()
	button.text = "Authored fallback"
	var binding := StellaAction.new()
	binding.action_id = first.action_id
	binding.sync_label = true
	button.add_child(binding)
	add_child(button)
	_fake_registry_nodes.append(button)
	assert_eq(button.text, "Project toggle")
	assert_true(button.toggle_mode)
	assert_true(button.button_pressed)

	assert_true(fake_registry.unregister_action(first.action_id, first))
	assert_eq(button.text, "Authored fallback")
	assert_false(button.toggle_mode)
	assert_false(button.button_pressed)
	assert_true(button.disabled)

	var second := _owner(fake_registry, first.action_id)
	var command_metadata := _metadata()
	command_metadata["label"] = "Project command"
	assert_true(fake_registry.register_action(
		second.action_id,
		command_metadata,
		second,
		Callable(second, "execute_action"),
	))
	assert_eq(button.text, "Project command")
	assert_false(button.toggle_mode)
	assert_false(button.button_pressed)
	assert_false(button.disabled)


func _find_action_button(root: Node, action_id: StringName) -> Button:
	for binding_node: Node in root.find_children("*", "StellaAction", true, false):
		var binding := binding_node as StellaAction
		if binding.get_action_id() == action_id:
			return binding.get_parent() as Button
	return null


func _builtin_definitions(owner: ActionOwner) -> Array[Dictionary]:
	var ids: Array[StringName] = [
		StellaActionRegistry.ACTION_VOICE_REPLAY,
		StellaActionRegistry.ACTION_AUTO,
		StellaActionRegistry.ACTION_SKIP,
		StellaActionRegistry.ACTION_BACKLOG,
		StellaActionRegistry.ACTION_PREV_CHOICE,
		StellaActionRegistry.ACTION_QUICK_SAVE,
		StellaActionRegistry.ACTION_QUICK_LOAD,
		StellaActionRegistry.ACTION_SAVE,
		StellaActionRegistry.ACTION_LOAD,
		StellaActionRegistry.ACTION_SETTINGS,
		StellaActionRegistry.ACTION_START_GAME,
		StellaActionRegistry.ACTION_CONTINUE_GAME,
		StellaActionRegistry.ACTION_RETURN_TO_TITLE,
		StellaActionRegistry.ACTION_QUIT,
		StellaActionRegistry.ACTION_ADVANCE,
		StellaActionRegistry.ACTION_HIDE_UI,
		StellaActionRegistry.ACTION_FLOWCHART,
		StellaActionRegistry.ACTION_CANCEL,
	]
	var definitions: Array[Dictionary] = []
	for action_id: StringName in ids:
		var policy := (
			StellaActionRegistry.CONFIRMATION_DESTRUCTIVE
			if action_id in [
				StellaActionRegistry.ACTION_RETURN_TO_TITLE,
				StellaActionRegistry.ACTION_QUIT,
			]
			else StellaActionRegistry.CONFIRMATION_NONE
		)
		var metadata := _metadata(policy)
		metadata["label"] = "Label %s" % action_id
		metadata["toggle"] = action_id in [
			StellaActionRegistry.ACTION_AUTO,
			StellaActionRegistry.ACTION_SKIP,
		]
		definitions.append({
			"id": action_id,
			"metadata": metadata,
			"execute": Callable(owner, "execute_action"),
			"can_execute": Callable(owner, "can_execute_action"),
			"is_active": Callable(owner, "is_active_action"),
		})
	return definitions
