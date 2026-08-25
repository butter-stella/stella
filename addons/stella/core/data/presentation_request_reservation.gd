## Director-issued single-use capability for a pre-reserved presentation id.
##
## The numeric id is readable so a caller can register exact local ownership
## before synchronous dispatch. Only the issuing Director can consume or
## retire the capability; constructing or rebinding a lookalike never creates
## an admitted reservation.
class_name PresentationRequestReservation extends RefCounted

enum State {
	UNBOUND,
	ACTIVE,
	CONSUMED,
	ABANDONED,
	CANCELLED,
}

var _request_id := 0
var _authority: Object
var _state: State = State.UNBOUND


func get_request_id() -> int:
	return _request_id


func is_active() -> bool:
	return _state == State.ACTIVE


func _bind(request_id: int, authority: Object) -> bool:
	if (
		request_id <= 0
		or authority == null
		or _state != State.UNBOUND
		or _authority != null
	):
		return false
	_request_id = request_id
	_authority = authority
	_state = State.ACTIVE
	return true


func _consume(authority: Object) -> bool:
	if authority == null or authority != _authority or _state != State.ACTIVE:
		return false
	_state = State.CONSUMED
	return true


func _retire(authority: Object, cancelled: bool) -> bool:
	if authority == null or authority != _authority or _state != State.ACTIVE:
		return false
	_state = State.CANCELLED if cancelled else State.ABANDONED
	return true
