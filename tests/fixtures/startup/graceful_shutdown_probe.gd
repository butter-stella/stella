extends Node
## Real-startup probe for StellaRuntime's public graceful shutdown boundary.

const MAX_TITLE_START_PROCESS_FRAMES := 120


func _ready() -> void:
	_verify_active_title_bgm_and_quit.call_deferred()


func _verify_active_title_bgm_and_quit() -> void:
	for _frame_index: int in range(MAX_TITLE_START_PROCESS_FRAMES):
		var audio := StellaRuntime.get_node_or_null("AudioPresenter") as AudioPresenter
		var channel: Dictionary = audio._bgm_channel if audio != null else {}
		var current: Dictionary = channel.get("current", {})
		var player: AudioStreamPlayer = current.get("player")
		if (
			StellaRuntime.config.title_bgm == "synthetic_bgm"
			and String(current.get("asset", "")) == "synthetic_bgm"
			and player != null
			and player.playing
			and player.stream != null
		):
			# Exercise the real OS-close route, then race it with an explicit host
			# request. The Runtime latch must schedule only one graceful completion.
			StellaRuntime._notification(NOTIFICATION_WM_CLOSE_REQUEST)
			StellaRuntime.request_quit()
			return
		await get_tree().process_frame
	push_error(
		"GracefulShutdownProbe: active synthetic title BGM was not projected")
	StellaRuntime.request_quit(1)
