#pragma once

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

struct stb_vorbis;

namespace godot {

struct StellaMarkerBgmStreamData;

class StellaMarkerBgmPlayback final : public AudioStreamPlayback {
	GDCLASS(StellaMarkerBgmPlayback, AudioStreamPlayback)

public:
	static constexpr int MAX_STEMS = 32;
	static constexpr int COMMAND_CAPACITY = 8;
	static constexpr int EVENT_CAPACITY = COMMAND_CAPACITY * 3;

	StellaMarkerBgmPlayback();
	~StellaMarkerBgmPlayback() override;

	void set_stream_data(const std::shared_ptr<const StellaMarkerBgmStreamData> &p_data);

	void _start(double p_from_pos) override;
	void _stop() override;
	bool _is_playing() const override;
	int32_t _get_loop_count() const override;
	double _get_playback_position() const override;
	void _seek(double p_position) override;
	int32_t _mix(AudioFrame *p_dst_buffer, float p_rate_scale, int32_t p_frame_count) override;

	int32_t arm_marker_mix(
		const String &p_marker,
		const PackedFloat32Array &p_gains,
		int32_t p_fade_frames,
		int64_t p_operation_id);
	bool can_arm_marker_mix(
		const String &p_marker,
		const PackedFloat32Array &p_gains) const;
	int32_t start_immediate_mix(
		const PackedFloat32Array &p_gains,
		int32_t p_fade_frames,
		int64_t p_operation_id);
	Dictionary capture_marker_state() const;
	Array drain_marker_events();
	void invalidate_marker_arms();
	void release_startup_gate();
	int32_t cut_marker_mix(
			const PackedFloat32Array &p_gains,
			int64_t p_operation_id);
	Dictionary debug_get_marker_metrics() const;
	PackedFloat32Array debug_get_current_gains() const;
	bool debug_hold_all_free_event_credits();
	void debug_release_held_event_credits();
	void debug_set_callback_gate(bool p_closed);
	int64_t debug_get_gated_callback_count() const;
	void debug_set_hold_after_consume(bool p_hold);
	bool debug_is_callback_held() const;
	int32_t debug_get_capture_waiter_count() const;

protected:
	static void _bind_methods();

private:
	enum class EventType : int32_t {
		ARMED = 1,
		ARMED_REPLACED = 2,
		TRIGGERED = 3,
		COMPLETED = 4,
		FAILED_NO_MARKER = 5,
		FAILED_CONFLICT = 6,
		CUT_APPLIED = 7,
	};

	struct CommandPod {
		uint64_t sequence = 0;
		uint64_t control_epoch = 0;
		int32_t kind = 0;
		int64_t operation_id = 0;
		int64_t expected_active_arm_id = 0;
		int32_t marker_id = -1;
		bool exact_occurrence = false;
		int64_t expected_marker_frame = -1;
		int32_t expected_marker_ordinal = -1;
		int64_t expected_marker_loop_epoch = -1;
		int32_t fade_frames = 0;
		int32_t stem_count = 0;
		std::array<float, MAX_STEMS> gains{};
	};

	struct EventPod {
		EventType type = EventType::FAILED_CONFLICT;
		int64_t operation_id = 0;
		int64_t arm_id = 0;
		int64_t replaced_arm_id = 0;
		int64_t marker_frame = -1;
		int32_t marker_ordinal = -1;
		int64_t marker_loop_epoch = -1;
		int64_t horizon_frame = -1;
		int64_t horizon_loop_epoch = -1;
		bool wraps_loop = false;
	};

	struct DecoderState {
		std::vector<char> arena;
		std::vector<float> scratch;
		stb_vorbis *decoder = nullptr;
		int32_t decoded_frames = 0;
		int32_t read_frame = 0;
	};

	struct SnapshotAtomic {
		std::atomic<uint64_t> version{ 0 };
		std::atomic<int32_t> phase{ 0 };
		std::atomic<int64_t> active_operation_id{ 0 };
		std::atomic<int64_t> arm_id{ 0 };
		std::atomic<int32_t> marker_id{ -1 };
		std::atomic<int64_t> marker_frame{ -1 };
		std::atomic<int32_t> marker_ordinal{ -1 };
		std::atomic<int64_t> marker_loop_epoch{ -1 };
		std::atomic<int64_t> horizon_frame{ 0 };
		std::atomic<int64_t> horizon_loop_epoch{ 0 };
		std::array<std::atomic<float>, MAX_STEMS> target_gains{};
	};

	struct SnapshotPlain {
		int32_t phase = 0;
		int64_t active_operation_id = 0;
		int64_t arm_id = 0;
		int32_t marker_id = -1;
		int64_t marker_frame = -1;
		int32_t marker_ordinal = -1;
		int64_t marker_loop_epoch = -1;
		int64_t horizon_frame = 0;
		int64_t horizon_loop_epoch = 0;
		std::array<float, MAX_STEMS> target_gains{};
	};

	std::shared_ptr<const StellaMarkerBgmStreamData> data_;
	std::vector<DecoderState> decoders_;
	std::array<CommandPod, COMMAND_CAPACITY> commands_{};
	std::array<EventPod, EVENT_CAPACITY> events_{};
	std::atomic<uint64_t> published_sequence_{ 0 };
	std::atomic<uint64_t> consumed_sequence_{ 0 };
	std::atomic<uint64_t> event_write_sequence_{ 0 };
	std::atomic<uint64_t> event_read_sequence_{ 0 };
	std::atomic<int32_t> available_event_credits_{ EVENT_CAPACITY };
	std::atomic<int32_t> debug_held_event_credits_{ 0 };
	std::atomic<uint64_t> invalidate_epoch_{ 0 };
	uint64_t consumed_invalidate_epoch_ = 0;
	SnapshotAtomic snapshot_;

	bool playing_ = false;
	int64_t frame_cursor_ = 0;
	int64_t loop_count_ = 0;
	int64_t next_arm_id_ = 1;
	int64_t waiting_operation_id_ = 0;
	int64_t waiting_arm_id_ = 0;
	int32_t waiting_marker_id_ = -1;
	int64_t waiting_marker_frame_ = -1;
	int32_t waiting_marker_ordinal_ = -1;
	int64_t waiting_loop_epoch_ = 0;
	int64_t waiting_horizon_frame_ = 0;
	int64_t waiting_horizon_loop_epoch_ = 0;
	int32_t waiting_reserved_credits_ = 0;
	bool ramp_active_ = false;
	int64_t ramp_operation_id_ = 0;
	int64_t ramp_arm_id_ = 0;
	int32_t ramp_total_frames_ = 0;
	int32_t ramp_progress_frames_ = 0;
	int32_t ramp_reserved_credits_ = 0;
	std::array<float, MAX_STEMS> current_gains_{};
	std::array<float, MAX_STEMS> target_gains_{};
	std::array<float, MAX_STEMS> ramp_start_gains_{};
	std::array<AudioFrame, MAX_STEMS> current_source_samples_{};
	std::array<AudioFrame, MAX_STEMS> next_source_samples_{};
	bool current_source_frame_valid_ = false;
	bool next_source_frame_valid_ = false;
	int64_t current_source_frame_index_ = 0;
	int64_t next_source_frame_index_ = 0;
	int64_t current_source_loop_epoch_ = 0;
	int64_t next_source_loop_epoch_ = 0;
	uint64_t resample_phase_ = 0;
	std::atomic<int64_t> published_frame_cursor_{ 0 };
	std::atomic<int64_t> published_loop_count_{ 0 };
	std::atomic<bool> published_playing_{ false };
	std::atomic<int64_t> published_active_arm_id_{ 0 };
	std::atomic<bool> startup_gate_closed_{ false };
	std::atomic<uint64_t> callback_version_{ 0 };
	std::atomic<int64_t> rt_allocation_violations_{ 0 };
	std::atomic<int64_t> rt_lock_violations_{ 0 };
	std::atomic<int64_t> rt_event_overflow_violations_{ 0 };
	std::atomic<int64_t> rt_decoder_refill_calls_{ 0 };
	std::atomic<int64_t> debug_gated_callback_count_{ 0 };
	std::atomic<int64_t> debug_rate_hold_callback_count_{ 0 };
	std::atomic<bool> debug_hold_after_consume_{ false };
	std::atomic<bool> debug_callback_held_{ false };
	mutable std::atomic<int32_t> debug_capture_waiter_count_{ 0 };

	bool initialize_decoders();
	bool seek_decoders(int64_t p_frame);
	int32_t find_marker_id(const String &p_marker) const;
	bool reserve_event_credits(int32_t p_count);
	void release_event_credits(int32_t p_count);
	void consume_control_at_boundary();
	void consume_commands_at_boundary();
	bool select_occurrence(
		int32_t p_marker_id,
		int64_t &r_frame,
		int32_t &r_ordinal,
		int64_t &r_loop_epoch,
		int64_t &r_horizon_frame,
		int64_t &r_horizon_loop_epoch) const;
	void render_horizon(int64_t &r_frame, int64_t &r_loop_epoch) const;
	void consume_command(const CommandPod &p_command);
	void cancel_waiting_arm();
	void complete_ramp_cut();
	void trigger_waiting_arm();
	void finish_ramp();
	void emit_event(const EventPod &p_event);
	void publish_snapshot();
	SnapshotPlain read_audio_snapshot() const;
	bool decode_source_frame(
		std::array<AudioFrame, MAX_STEMS> &r_samples,
		int64_t &r_frame_index,
		int64_t &r_loop_epoch);
	bool refill_decoder(DecoderState &p_decoder);
	void activate_source_frame(int64_t p_frame_index, int64_t p_loop_epoch);
	AudioFrame mix_source_samples(
		const std::array<AudioFrame, MAX_STEMS> &p_samples) const;
	void apply_ramp_for_frame();
	void advance_ramp_after_source_frame();
	String event_type_name(EventType p_type) const;
};

class StellaMarkerBgmStream final : public AudioStream {
	GDCLASS(StellaMarkerBgmStream, AudioStream)

public:
	bool configure(const Dictionary &p_configuration);
	bool configure_startup_marker_mix(const Dictionary &p_configuration);
	int32_t get_source_sample_rate() const;
	int64_t get_source_frame_count() const;
	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override;
	double _get_length() const override;
	bool _is_monophonic() const override;
	bool _has_loop() const override;

protected:
	static void _bind_methods();

private:
	std::shared_ptr<StellaMarkerBgmStreamData> data_;
};

} // namespace godot
