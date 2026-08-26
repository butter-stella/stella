extends GutTest
## Native OGV frame and authoritative media/flash layer evidence for issue #179.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const MOVIE_ROOT := "res://tests/fixtures/movies/"

var _runtime: Node
var _presenter: MoviePresenter
var _original_movies_path := ""
var _context: ScenarioContext
var _flash: CanvasLayer


func before_all() -> void:
	assert_ne(DisplayServer.get_name(), "headless")
	var method := RenderingServer.get_current_rendering_method()
	assert_true(method in ["mobile", "forward_plus", "gl_compatibility"])
	var expected := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected.is_empty():
		assert_eq(method, expected)


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_movies_path = _runtime.movies_path
	_runtime.movies_path = MOVIE_ROOT
	_presenter = _runtime.movie_presenter
	var scenario := ScenarioData.new()
	scenario.id = "movie_render"
	scenario.source_path = "res://tests/rendering/test_movie_render.gd"
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes = [scene]
	_context = ScenarioContext.new(scenario)
	_context.variable_store = VariableStore.new()
	var engine := ScenarioEngine.new()
	engine.registry = _runtime.registry
	engine.context = _context
	_runtime.engine = engine


func after_each() -> void:
	if _flash != null and is_instance_valid(_flash):
		_flash.queue_free()
		await _flash.tree_exited
	_flash = null
	SignalBus.reset_movie_presentation()
	_runtime.presentation_director.cancel_all()
	_runtime.movies_path = _original_movies_path
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _render() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


func test_native_frame_renders_and_flash_layer_wins_reverse_insertion() -> void:
	_flash = CanvasLayer.new()
	_flash.layer = PresentationLayerOrder.SCREEN_FLASH
	get_tree().root.add_child(_flash)
	get_tree().root.move_child(_flash, 0)
	assert_lt(_flash.get_index(), _runtime.get_index(),
		"flash is deliberately earlier than the Runtime movie surface")
	var flash_rect := ColorRect.new()
	flash_rect.color = Color(1.0, 0.0, 1.0, 1.0)
	flash_rect.size = get_viewport().get_visible_rect().size
	flash_rect.visible = false
	_flash.add_child(flash_rect)

	var operation := MoviePresentationOperation.new({
		"action": "play",
		"asset": "synthetic_movie",
		"loop": false,
		"skippable": true,
	}, {"source_path": "res://tests/rendering/test_movie_render.gd", "line": 1})
	var operations: Array[PresentationOperation] = [operation]
	var request: PresentationBatchRequest = _runtime.presentation_director.submit(
		operations, PresentationBatchRequest.Policy.FIRE_AND_FORGET, _context,
		operation.get_source())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	for _frame in range(12):
		await get_tree().process_frame
	var movie_frame := await _render()
	var center := movie_frame.get_size() / 2
	var movie_center := movie_frame.get_pixelv(center)
	var varied := false
	for offset: Vector2i in [
		Vector2i(-16, -16), Vector2i(0, -16), Vector2i(-16, 0), Vector2i(16, 16),
	]:
		var color := movie_frame.get_pixelv(center + offset)
		if color.r > 0.02 or color.g > 0.02 or color.b > 0.02:
			varied = true
	assert_true(varied, "the real VideoStreamPlayer decoded a visible OGV frame")

	flash_rect.visible = true
	var flashed := await _render()
	var pixel := flashed.get_pixelv(center)
	assert_ne(pixel, movie_center)
	assert_almost_eq(pixel.r, 1.0, 1.5 / 255.0)
	assert_almost_eq(pixel.g, 0.0, 1.5 / 255.0)
	assert_almost_eq(pixel.b, 1.0, 1.5 / 255.0)
	assert_eq(_presenter.layer, PresentationLayerOrder.FULLSCREEN_MEDIA)
	assert_lt(_presenter.layer, _flash.layer)
