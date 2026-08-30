#include "stella_marker_bgm.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

#define STB_VORBIS_NO_STDIO
#include "stb_vorbis.c"

namespace godot {

namespace {

constexpr int32_t CONFIG_SCHEMA_VERSION = 1;
constexpr int32_t MAX_MARKERS = 4096;
constexpr int32_t MAX_MARKER_SCALARS = 64;
constexpr int32_t MAX_MARKER_UTF8_BYTES = 256;
constexpr int32_t SCRATCH_FRAME_FLOOR = 8192;
constexpr int32_t DECODER_ARENA_MARGIN = 65536;
constexpr uint32_t RESAMPLE_FP_BITS = 32;
constexpr uint64_t RESAMPLE_FP_ONE = uint64_t{ 1 } << RESAMPLE_FP_BITS;

static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<int64_t>::is_always_lock_free);
static_assert(std::atomic<int32_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);

struct MarkerEntry {
	int32_t label_id = -1;
	int64_t frame = -1;
	int32_t ordinal = -1;
};

struct StemEntry {
	String name;
	std::vector<uint8_t> ogg_bytes;
	int32_t decoder_arena_bytes = 0;
	int32_t max_frame_size = 0;
};

bool has_exact_keys(const Dictionary &p_dictionary, const std::vector<StringName> &p_keys) {
	if (p_dictionary.size() != static_cast<int64_t>(p_keys.size())) {
		return false;
	}
	for (const StringName &key : p_keys) {
		if (!p_dictionary.has(key)) {
			return false;
		}
	}
	return true;
}

bool is_valid_marker_label(const String &p_label) {
	if (p_label.is_empty() || p_label.length() > MAX_MARKER_SCALARS) {
		return false;
	}
	const CharString utf8 = p_label.utf8();
	if (utf8.length() > MAX_MARKER_UTF8_BYTES) {
		return false;
	}
	for (int64_t index = 0; index < p_label.length(); index++) {
		const char32_t code = p_label.unicode_at(index);
		if (code == 0 || (code < 32 && code != 9 && code != 10 && code != 13) ||
				(code >= 127 && code <= 159)) {
			return false;
		}
	}
	return true;
}

bool is_valid_stem_name(const String &p_name) {
	if (p_name.is_empty() || p_name.length() > 64) {
		return false;
	}
	for (int64_t index = 0; index < p_name.length(); index++) {
		const char32_t code = p_name.unicode_at(index);
		const bool ascii_letter = (code >= 'a' && code <= 'z') ||
				(code >= 'A' && code <= 'Z');
		const bool digit = code >= '0' && code <= '9';
		const bool valid = index == 0
				? ascii_letter || code == '_'
				: ascii_letter || digit || code == '_' || code == '-';
		if (!valid) {
			return false;
		}
	}
	return true;
}

template <typename Callback>
class ScopeExit final {
public:
	explicit ScopeExit(Callback p_callback) : callback_(std::move(p_callback)) {}
	ScopeExit(const ScopeExit &) = delete;
	ScopeExit &operator=(const ScopeExit &) = delete;
	~ScopeExit() {
		callback_();
	}

private:
	Callback callback_;
};

template <typename Callback>
ScopeExit<Callback> make_scope_exit(Callback p_callback) {
	return ScopeExit<Callback>(std::move(p_callback));
}

} // namespace

struct StellaMarkerBgmStreamData {
	std::vector<StemEntry> stems;
	std::vector<String> labels;
	std::vector<MarkerEntry> markers;
	std::array<float, StellaMarkerBgmPlayback::MAX_STEMS> initial_gains{};
	int32_t sample_rate = 0;
	int32_t output_mix_rate = 0;
	int32_t channels = 0;
	int64_t frame_count = 0;
	bool loop = false;
	int64_t loop_start_frame = 0;
	int64_t loop_end_frame = 0;
	int32_t scratch_frames = SCRATCH_FRAME_FLOOR;
	bool startup_arm_enabled = false;
	int64_t startup_operation_id = 0;
	int32_t startup_marker_id = -1;
	int32_t startup_fade_frames = 0;
	int64_t startup_horizon_frame = -1;
	int64_t startup_horizon_loop_epoch = -1;
	int64_t startup_marker_frame = -1;
	int32_t startup_marker_ordinal = -1;
	int64_t startup_marker_loop_epoch = -1;
	std::array<float, StellaMarkerBgmPlayback::MAX_STEMS> startup_gains{};
};

StellaMarkerBgmPlayback::StellaMarkerBgmPlayback() = default;

StellaMarkerBgmPlayback::~StellaMarkerBgmPlayback() {
	for (DecoderState &decoder : decoders_) {
		if (decoder.decoder != nullptr) {
			stb_vorbis_close(decoder.decoder);
			decoder.decoder = nullptr;
		}
	}
}

void StellaMarkerBgmPlayback::_bind_methods() {
	ClassDB::bind_method(D_METHOD("arm_marker_mix", "marker", "gains", "fade_frames", "operation_id"),
			&StellaMarkerBgmPlayback::arm_marker_mix);
	ClassDB::bind_method(D_METHOD("can_arm_marker_mix", "marker", "gains"),
			&StellaMarkerBgmPlayback::can_arm_marker_mix);
	ClassDB::bind_method(D_METHOD("start_immediate_mix", "gains", "fade_frames", "operation_id"),
			&StellaMarkerBgmPlayback::start_immediate_mix);
	ClassDB::bind_method(D_METHOD("capture_marker_state"),
			&StellaMarkerBgmPlayback::capture_marker_state);
	ClassDB::bind_method(D_METHOD("drain_marker_events"),
			&StellaMarkerBgmPlayback::drain_marker_events);
	ClassDB::bind_method(D_METHOD("invalidate_marker_arms"),
			&StellaMarkerBgmPlayback::invalidate_marker_arms);
	ClassDB::bind_method(D_METHOD("release_startup_gate"),
			&StellaMarkerBgmPlayback::release_startup_gate);
	ClassDB::bind_method(D_METHOD("cut_marker_mix", "gains", "operation_id"),
			&StellaMarkerBgmPlayback::cut_marker_mix);
#ifdef DEBUG_ENABLED
	ClassDB::bind_method(D_METHOD("debug_get_marker_metrics"),
			&StellaMarkerBgmPlayback::debug_get_marker_metrics);
	ClassDB::bind_method(D_METHOD("debug_get_current_gains"),
			&StellaMarkerBgmPlayback::debug_get_current_gains);
	ClassDB::bind_method(D_METHOD("debug_hold_all_free_event_credits"),
			&StellaMarkerBgmPlayback::debug_hold_all_free_event_credits);
	ClassDB::bind_method(D_METHOD("debug_release_held_event_credits"),
			&StellaMarkerBgmPlayback::debug_release_held_event_credits);
	ClassDB::bind_method(D_METHOD("debug_set_callback_gate", "closed"),
			&StellaMarkerBgmPlayback::debug_set_callback_gate);
	ClassDB::bind_method(D_METHOD("debug_get_gated_callback_count"),
			&StellaMarkerBgmPlayback::debug_get_gated_callback_count);
	ClassDB::bind_method(D_METHOD("debug_set_hold_after_consume", "hold"),
			&StellaMarkerBgmPlayback::debug_set_hold_after_consume);
	ClassDB::bind_method(D_METHOD("debug_is_callback_held"),
			&StellaMarkerBgmPlayback::debug_is_callback_held);
	ClassDB::bind_method(D_METHOD("debug_get_capture_waiter_count"),
			&StellaMarkerBgmPlayback::debug_get_capture_waiter_count);
#endif
}

void StellaMarkerBgmPlayback::set_stream_data(
		const std::shared_ptr<const StellaMarkerBgmStreamData> &p_data) {
	data_ = p_data;
	startup_gate_closed_.store(
			data_ && data_->startup_arm_enabled, std::memory_order_release);
	initialize_decoders();
	if (data_) {
		for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
			current_gains_[index] = data_->initial_gains[index];
			target_gains_[index] = data_->initial_gains[index];
		}
	}
	publish_snapshot();
}

bool StellaMarkerBgmPlayback::initialize_decoders() {
	if (!data_) {
		return false;
	}
	decoders_.clear();
	decoders_.resize(data_->stems.size());
	for (size_t index = 0; index < data_->stems.size(); index++) {
		const StemEntry &stem = data_->stems[index];
		DecoderState &decoder = decoders_[index];
		decoder.arena.resize(static_cast<size_t>(stem.decoder_arena_bytes));
		decoder.scratch.resize(static_cast<size_t>(data_->scratch_frames * data_->channels));
		stb_vorbis_alloc allocation{};
		allocation.alloc_buffer = decoder.arena.data();
		allocation.alloc_buffer_length_in_bytes = static_cast<int>(decoder.arena.size());
		int error = VORBIS__no_error;
		decoder.decoder = stb_vorbis_open_memory(
				stem.ogg_bytes.data(), static_cast<int>(stem.ogg_bytes.size()),
				&error, &allocation);
		if (decoder.decoder == nullptr) {
			UtilityFunctions::push_error(
					"StellaMarkerBgmPlayback: preallocated OGG decoder initialization failed");
			return false;
		}
		decoder.decoded_frames = 0;
		decoder.read_frame = 0;
	}
	return true;
}

void StellaMarkerBgmPlayback::_start(double p_from_pos) {
	if (!data_ || decoders_.size() != data_->stems.size()) {
		playing_ = false;
		published_playing_.store(false, std::memory_order_release);
		return;
	}
	const double safe_position = std::isfinite(p_from_pos) ? std::max(0.0, p_from_pos) : 0.0;
	int64_t requested = static_cast<int64_t>(std::llround(
			safe_position * static_cast<double>(data_->sample_rate)));
	if (data_->startup_arm_enabled) {
		if (requested != data_->startup_horizon_frame) {
			playing_ = false;
			published_playing_.store(false, std::memory_order_release);
			return;
		}
		requested = data_->startup_horizon_frame;
	}
	frame_cursor_ = std::clamp<int64_t>(requested, 0, data_->frame_count);
	loop_count_ = data_->startup_arm_enabled ? data_->startup_horizon_loop_epoch : 0;
	playing_ = seek_decoders(frame_cursor_) && frame_cursor_ < data_->frame_count;
	current_source_frame_valid_ = false;
	next_source_frame_valid_ = false;
	resample_phase_ = 0;
	if (playing_ && data_->startup_arm_enabled) {
		if (!reserve_event_credits(3)) {
			playing_ = false;
		} else {
			const uint64_t published = published_sequence_.load(std::memory_order_relaxed);
			const uint64_t consumed = consumed_sequence_.load(std::memory_order_acquire);
			if (published - consumed >= COMMAND_CAPACITY) {
				release_event_credits(3);
				playing_ = false;
			} else {
				const uint64_t sequence = published + 1;
				CommandPod &command = commands_[(sequence - 1) % COMMAND_CAPACITY];
				command = CommandPod{};
				command.sequence = sequence;
				command.control_epoch = invalidate_epoch_.load(std::memory_order_acquire);
				command.kind = 1;
				command.operation_id = data_->startup_operation_id;
				command.expected_active_arm_id = 0;
				command.marker_id = data_->startup_marker_id;
				command.exact_occurrence = true;
				command.expected_marker_frame = data_->startup_marker_frame;
				command.expected_marker_ordinal = data_->startup_marker_ordinal;
				command.expected_marker_loop_epoch = data_->startup_marker_loop_epoch;
				command.fade_frames = data_->startup_fade_frames;
				command.stem_count = static_cast<int32_t>(data_->stems.size());
				for (int32_t index = 0; index < command.stem_count; index++) {
					command.gains[index] = data_->startup_gains[index];
				}
				published_sequence_.store(sequence, std::memory_order_release);
			}
		}
	}
	published_frame_cursor_.store(frame_cursor_, std::memory_order_release);
	published_loop_count_.store(loop_count_, std::memory_order_release);
	published_playing_.store(playing_, std::memory_order_release);
	publish_snapshot();
}

void StellaMarkerBgmPlayback::_stop() {
	playing_ = false;
	cancel_waiting_arm();
	complete_ramp_cut();
	published_playing_.store(false, std::memory_order_release);
	publish_snapshot();
}

bool StellaMarkerBgmPlayback::_is_playing() const {
	return published_playing_.load(std::memory_order_acquire);
}

int32_t StellaMarkerBgmPlayback::_get_loop_count() const {
	return static_cast<int32_t>(std::min<int64_t>(
			published_loop_count_.load(std::memory_order_acquire),
			std::numeric_limits<int32_t>::max()));
}

double StellaMarkerBgmPlayback::_get_playback_position() const {
	if (!data_ || data_->sample_rate <= 0) {
		return 0.0;
	}
	return static_cast<double>(published_frame_cursor_.load(std::memory_order_acquire)) /
			static_cast<double>(data_->sample_rate);
}

void StellaMarkerBgmPlayback::_seek(double p_position) {
	if (!data_ || !std::isfinite(p_position)) {
		return;
	}
	const int64_t requested = static_cast<int64_t>(std::llround(
			std::max(0.0, p_position) * static_cast<double>(data_->sample_rate)));
	frame_cursor_ = std::clamp<int64_t>(requested, 0, data_->frame_count);
	seek_decoders(frame_cursor_);
	current_source_frame_valid_ = false;
	next_source_frame_valid_ = false;
	resample_phase_ = 0;
	published_frame_cursor_.store(frame_cursor_, std::memory_order_release);
	publish_snapshot();
}

bool StellaMarkerBgmPlayback::seek_decoders(int64_t p_frame) {
	for (DecoderState &decoder : decoders_) {
		if (decoder.decoder == nullptr ||
				stb_vorbis_seek(decoder.decoder, static_cast<unsigned int>(p_frame)) == 0) {
			return false;
		}
		decoder.decoded_frames = 0;
		decoder.read_frame = 0;
	}
	return true;
}

int32_t StellaMarkerBgmPlayback::find_marker_id(const String &p_marker) const {
	if (!data_) {
		return -1;
	}
	for (int32_t index = 0; index < static_cast<int32_t>(data_->labels.size()); index++) {
		if (data_->labels[index] == p_marker) {
			return index;
		}
	}
	return -1;
}

bool StellaMarkerBgmPlayback::reserve_event_credits(int32_t p_count) {
	int32_t available = available_event_credits_.load(std::memory_order_acquire);
	while (available >= p_count) {
		if (available_event_credits_.compare_exchange_weak(
					available, available - p_count,
					std::memory_order_acq_rel, std::memory_order_acquire)) {
			return true;
		}
	}
	return false;
}

void StellaMarkerBgmPlayback::release_event_credits(int32_t p_count) {
	if (p_count > 0) {
		available_event_credits_.fetch_add(p_count, std::memory_order_acq_rel);
	}
}

bool StellaMarkerBgmPlayback::can_arm_marker_mix(
		const String &p_marker,
		const PackedFloat32Array &p_gains) const {
	if (!data_ || !is_valid_marker_label(p_marker) ||
			p_gains.size() != static_cast<int64_t>(data_->stems.size())) {
		return false;
	}
	bool audible = false;
	for (int64_t index = 0; index < p_gains.size(); index++) {
		const float gain = p_gains[index];
		if (!std::isfinite(gain) || gain < 0.0f || gain > 1.0f) {
			return false;
		}
		audible = audible || gain > 0.0f;
	}
	const uint64_t published = published_sequence_.load(std::memory_order_acquire);
	const uint64_t consumed = consumed_sequence_.load(std::memory_order_acquire);
	return audible && published - consumed < COMMAND_CAPACITY &&
			available_event_credits_.load(std::memory_order_acquire) >= 3;
}

int32_t StellaMarkerBgmPlayback::arm_marker_mix(
		const String &p_marker,
		const PackedFloat32Array &p_gains,
		int32_t p_fade_frames,
		int64_t p_operation_id) {
	if (!data_ || !is_valid_marker_label(p_marker) || p_operation_id <= 0 ||
			p_fade_frames < 0 || p_gains.size() != static_cast<int64_t>(data_->stems.size())) {
		return -1;
	}
	bool audible = false;
	for (int64_t index = 0; index < p_gains.size(); index++) {
		const float gain = p_gains[index];
		if (!std::isfinite(gain) || gain < 0.0f || gain > 1.0f) {
			return -1;
		}
		audible = audible || gain > 0.0f;
	}
	if (!audible || !reserve_event_credits(3)) {
		return -2;
	}
	const uint64_t published = published_sequence_.load(std::memory_order_acquire);
	const uint64_t consumed = consumed_sequence_.load(std::memory_order_acquire);
	if (published - consumed >= COMMAND_CAPACITY) {
		release_event_credits(3);
		return -3;
	}
	const uint64_t sequence = published + 1;
	CommandPod &command = commands_[(sequence - 1) % COMMAND_CAPACITY];
	command = CommandPod{};
	command.sequence = sequence;
	command.control_epoch = invalidate_epoch_.load(std::memory_order_acquire);
	command.kind = 1;
	command.operation_id = p_operation_id;
	command.expected_active_arm_id = published_active_arm_id_.load(std::memory_order_acquire);
	command.marker_id = find_marker_id(p_marker);
	command.fade_frames = p_fade_frames;
	command.stem_count = static_cast<int32_t>(p_gains.size());
	for (int32_t index = 0; index < command.stem_count; index++) {
		command.gains[index] = p_gains[index];
	}
	published_sequence_.store(sequence, std::memory_order_release);
	return 0;
}

int32_t StellaMarkerBgmPlayback::start_immediate_mix(
		const PackedFloat32Array &p_gains,
		int32_t p_fade_frames,
		int64_t p_operation_id) {
	if (!data_ || p_operation_id <= 0 || p_fade_frames < 0 ||
			p_gains.size() != static_cast<int64_t>(data_->stems.size())) {
		return -1;
	}
	bool audible = false;
	for (int32_t index = 0; index < static_cast<int32_t>(p_gains.size()); index++) {
		const float gain = p_gains[index];
		if (!std::isfinite(gain) || gain < 0.0f || gain > 1.0f) {
			return -1;
		}
		audible = audible || gain > 0.0f;
	}
	if (!audible || !reserve_event_credits(2)) {
		return -2;
	}
	const uint64_t published = published_sequence_.load(std::memory_order_acquire);
	const uint64_t consumed = consumed_sequence_.load(std::memory_order_acquire);
	if (published - consumed >= COMMAND_CAPACITY) {
		release_event_credits(2);
		return -3;
	}
	const uint64_t sequence = published + 1;
	CommandPod &command = commands_[(sequence - 1) % COMMAND_CAPACITY];
	command = CommandPod{};
	command.sequence = sequence;
	command.control_epoch = invalidate_epoch_.load(std::memory_order_acquire);
	command.kind = 3;
	command.operation_id = p_operation_id;
	command.fade_frames = p_fade_frames;
	command.stem_count = static_cast<int32_t>(p_gains.size());
	for (int32_t index = 0; index < command.stem_count; index++) {
		command.gains[index] = p_gains[index];
	}
	published_sequence_.store(sequence, std::memory_order_release);
	return 0;
}

void StellaMarkerBgmPlayback::invalidate_marker_arms() {
	invalidate_epoch_.fetch_add(1, std::memory_order_acq_rel);
}

void StellaMarkerBgmPlayback::release_startup_gate() {
	startup_gate_closed_.store(false, std::memory_order_release);
}

int32_t StellaMarkerBgmPlayback::cut_marker_mix(
		const PackedFloat32Array &p_gains,
		int64_t p_operation_id) {
	if (!data_ || p_operation_id <= 0 ||
			p_gains.size() != static_cast<int64_t>(data_->stems.size())) {
		return -1;
	}
	bool audible = false;
	for (int32_t index = 0; index < static_cast<int32_t>(p_gains.size()); index++) {
		const float gain = p_gains[index];
		if (!std::isfinite(gain) || gain < 0.0f || gain > 1.0f) {
			return -1;
		}
		audible = audible || gain > 0.0f;
	}
	if (!audible) {
		return -1;
	}
	if (!reserve_event_credits(1)) {
		return -2;
	}
	const uint64_t published = published_sequence_.load(std::memory_order_acquire);
	const uint64_t consumed = consumed_sequence_.load(std::memory_order_acquire);
	if (published - consumed >= COMMAND_CAPACITY) {
		release_event_credits(1);
		return -3;
	}
	const uint64_t sequence = published + 1;
	CommandPod &command = commands_[(sequence - 1) % COMMAND_CAPACITY];
	command = CommandPod{};
	command.sequence = sequence;
	command.control_epoch = invalidate_epoch_.load(std::memory_order_acquire);
	command.kind = 2;
	command.operation_id = p_operation_id;
	command.stem_count = static_cast<int32_t>(p_gains.size());
	for (int32_t index = 0; index < command.stem_count; index++) {
		command.gains[index] = p_gains[index];
	}
	published_sequence_.store(sequence, std::memory_order_release);
	return 0;
}

void StellaMarkerBgmPlayback::consume_control_at_boundary() {
	const uint64_t invalidate = invalidate_epoch_.load(std::memory_order_acquire);
	if (invalidate != consumed_invalidate_epoch_) {
		consumed_invalidate_epoch_ = invalidate;
		cancel_waiting_arm();
		complete_ramp_cut();
		const uint64_t published = published_sequence_.load(std::memory_order_acquire);
		uint64_t consumed = consumed_sequence_.load(std::memory_order_relaxed);
		while (consumed < published) {
			const CommandPod &command = commands_[consumed % COMMAND_CAPACITY];
			if (command.control_epoch >= invalidate) {
				break;
			}
			release_event_credits(
					command.kind == 1 ? 3 : (command.kind == 3 ? 2 : 1));
			consumed++;
		}
		consumed_sequence_.store(consumed, std::memory_order_release);
	}
}

void StellaMarkerBgmPlayback::consume_commands_at_boundary() {
	const uint64_t published = published_sequence_.load(std::memory_order_acquire);
	uint64_t consumed = consumed_sequence_.load(std::memory_order_relaxed);
	while (consumed < published) {
		const CommandPod &command = commands_[consumed % COMMAND_CAPACITY];
		consume_command(command);
		consumed++;
		consumed_sequence_.store(consumed, std::memory_order_release);
	}
}

bool StellaMarkerBgmPlayback::select_occurrence(
		int32_t p_marker_id,
		int64_t &r_frame,
		int32_t &r_ordinal,
		int64_t &r_loop_epoch,
		int64_t &r_horizon_frame,
		int64_t &r_horizon_loop_epoch) const {
	if (!data_ || p_marker_id < 0) {
		return false;
	}
	render_horizon(r_horizon_frame, r_horizon_loop_epoch);
	const int64_t current_end = data_->loop ? data_->loop_end_frame : data_->frame_count;
	for (const MarkerEntry &marker : data_->markers) {
		if (marker.label_id == p_marker_id && marker.frame >= r_horizon_frame &&
				marker.frame < current_end) {
			r_frame = marker.frame;
			r_ordinal = marker.ordinal;
			r_loop_epoch = r_horizon_loop_epoch;
			return true;
		}
	}
	if (!data_->loop) {
		return false;
	}
	for (const MarkerEntry &marker : data_->markers) {
		if (marker.label_id == p_marker_id && marker.frame >= data_->loop_start_frame &&
				marker.frame < data_->loop_end_frame) {
			r_frame = marker.frame;
			r_ordinal = marker.ordinal;
			r_loop_epoch = r_horizon_loop_epoch + 1;
			return true;
		}
	}
	return false;
}

void StellaMarkerBgmPlayback::render_horizon(
		int64_t &r_frame,
		int64_t &r_loop_epoch) const {
	if (!data_) {
		r_frame = frame_cursor_;
		r_loop_epoch = loop_count_;
		return;
	}
	// Selection runs before this callback advances the resampler. A decoded
	// interpolation lookahead is still not activated; with rate > 1 every
	// intermediate frame is likewise activated by the while loop below. The
	// exact boundary is therefore the first raw source frame not yet passed to
	// activate_source_frame(), never a phase-projected playback position.
	if (next_source_frame_valid_) {
		r_frame = next_source_frame_index_;
		r_loop_epoch = next_source_loop_epoch_;
		return;
	}
	r_frame = frame_cursor_;
	r_loop_epoch = loop_count_;
	if (data_->loop && r_frame >= data_->loop_end_frame) {
		const int64_t loop_length = data_->loop_end_frame - data_->loop_start_frame;
		const int64_t beyond_end = r_frame - data_->loop_end_frame;
		r_loop_epoch += 1 + (beyond_end / loop_length);
		r_frame = data_->loop_start_frame + (beyond_end % loop_length);
	} else if (!data_->loop) {
		r_frame = std::min(r_frame, data_->frame_count);
	}
}

void StellaMarkerBgmPlayback::consume_command(const CommandPod &p_command) {
	if (p_command.kind == 2) {
		cancel_waiting_arm();
		if (ramp_active_) {
			ramp_active_ = false;
			release_event_credits(ramp_reserved_credits_);
			ramp_reserved_credits_ = 0;
			ramp_operation_id_ = 0;
			ramp_arm_id_ = 0;
		}
		for (int32_t index = 0; index < p_command.stem_count; index++) {
			current_gains_[index] = p_command.gains[index];
			target_gains_[index] = p_command.gains[index];
		}
		EventPod applied{};
		applied.type = EventType::CUT_APPLIED;
		applied.operation_id = p_command.operation_id;
		emit_event(applied);
		publish_snapshot();
		return;
	}
	if (p_command.kind == 3) {
		cancel_waiting_arm();
		if (ramp_active_) {
			complete_ramp_cut();
		}
		for (int32_t index = 0; index < p_command.stem_count; index++) {
			ramp_start_gains_[index] = current_gains_[index];
			target_gains_[index] = p_command.gains[index];
		}
		ramp_operation_id_ = p_command.operation_id;
		ramp_arm_id_ = 0;
		ramp_total_frames_ = p_command.fade_frames;
		ramp_progress_frames_ = 0;
		ramp_reserved_credits_ = 2;
		ramp_active_ = true;
		EventPod triggered{};
		triggered.type = EventType::TRIGGERED;
		triggered.operation_id = ramp_operation_id_;
		emit_event(triggered);
		ramp_reserved_credits_--;
		if (ramp_total_frames_ <= 0) {
			for (int32_t index = 0; index < p_command.stem_count; index++) {
				current_gains_[index] = target_gains_[index];
			}
			finish_ramp();
		}
		publish_snapshot();
		return;
	}
	int64_t marker_frame = -1;
	int32_t marker_ordinal = -1;
	int64_t marker_loop_epoch = -1;
	int64_t horizon_frame = -1;
	int64_t horizon_loop_epoch = -1;
	const bool active_matches = p_command.expected_active_arm_id == waiting_arm_id_;
	const bool occurrence_found = active_matches && select_occurrence(
			p_command.marker_id, marker_frame, marker_ordinal, marker_loop_epoch,
			horizon_frame, horizon_loop_epoch);
	const bool exact_matches = !p_command.exact_occurrence || (
			marker_frame == p_command.expected_marker_frame &&
			marker_ordinal == p_command.expected_marker_ordinal &&
			marker_loop_epoch == p_command.expected_marker_loop_epoch);
	if (!occurrence_found || !exact_matches) {
		EventPod failed{};
		failed.type = active_matches && occurrence_found
				? EventType::FAILED_CONFLICT
				: (active_matches ? EventType::FAILED_NO_MARKER : EventType::FAILED_CONFLICT);
		failed.operation_id = p_command.operation_id;
		emit_event(failed);
		release_event_credits(2);
		return;
	}
	if (ramp_active_) {
		complete_ramp_cut();
	}
	const int64_t replaced_arm_id = waiting_arm_id_;
	if (waiting_arm_id_ != 0) {
		cancel_waiting_arm();
	}
	waiting_operation_id_ = p_command.operation_id;
	waiting_arm_id_ = next_arm_id_++;
	waiting_marker_id_ = p_command.marker_id;
	waiting_marker_frame_ = marker_frame;
	waiting_marker_ordinal_ = marker_ordinal;
	waiting_loop_epoch_ = marker_loop_epoch;
	waiting_horizon_frame_ = horizon_frame;
	waiting_horizon_loop_epoch_ = horizon_loop_epoch;
	waiting_reserved_credits_ = 2;
	for (int32_t index = 0; index < p_command.stem_count; index++) {
		target_gains_[index] = p_command.gains[index];
	}
	ramp_total_frames_ = p_command.fade_frames;
	published_active_arm_id_.store(waiting_arm_id_, std::memory_order_release);
	EventPod armed{};
	armed.type = replaced_arm_id == 0 ? EventType::ARMED : EventType::ARMED_REPLACED;
	armed.operation_id = waiting_operation_id_;
	armed.arm_id = waiting_arm_id_;
	armed.replaced_arm_id = replaced_arm_id;
	armed.marker_frame = waiting_marker_frame_;
	armed.marker_ordinal = waiting_marker_ordinal_;
	armed.marker_loop_epoch = waiting_loop_epoch_;
	armed.horizon_frame = waiting_horizon_frame_;
	armed.horizon_loop_epoch = waiting_horizon_loop_epoch_;
	armed.wraps_loop = waiting_loop_epoch_ > waiting_horizon_loop_epoch_;
	emit_event(armed);
	publish_snapshot();
}

void StellaMarkerBgmPlayback::cancel_waiting_arm() {
	if (waiting_arm_id_ == 0) {
		return;
	}
	release_event_credits(waiting_reserved_credits_);
	waiting_reserved_credits_ = 0;
	waiting_operation_id_ = 0;
	waiting_arm_id_ = 0;
	waiting_marker_id_ = -1;
	waiting_marker_frame_ = -1;
	waiting_marker_ordinal_ = -1;
	waiting_loop_epoch_ = 0;
	waiting_horizon_frame_ = 0;
	waiting_horizon_loop_epoch_ = 0;
	published_active_arm_id_.store(0, std::memory_order_release);
}

void StellaMarkerBgmPlayback::complete_ramp_cut() {
	if (!ramp_active_) {
		return;
	}
	for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
		current_gains_[index] = target_gains_[index];
	}
	finish_ramp();
}

void StellaMarkerBgmPlayback::trigger_waiting_arm() {
	EventPod triggered{};
	triggered.type = EventType::TRIGGERED;
	triggered.operation_id = waiting_operation_id_;
	triggered.arm_id = waiting_arm_id_;
	triggered.marker_frame = waiting_marker_frame_;
	triggered.marker_ordinal = waiting_marker_ordinal_;
	triggered.marker_loop_epoch = waiting_loop_epoch_;
	triggered.horizon_frame = waiting_horizon_frame_;
	triggered.horizon_loop_epoch = waiting_horizon_loop_epoch_;
	triggered.wraps_loop = waiting_loop_epoch_ > waiting_horizon_loop_epoch_;
	emit_event(triggered);
	waiting_reserved_credits_--;
	ramp_operation_id_ = waiting_operation_id_;
	ramp_arm_id_ = waiting_arm_id_;
	ramp_reserved_credits_ = waiting_reserved_credits_;
	ramp_progress_frames_ = 0;
	for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
		ramp_start_gains_[index] = current_gains_[index];
	}
	waiting_reserved_credits_ = 0;
	waiting_operation_id_ = 0;
	waiting_arm_id_ = 0;
	waiting_marker_id_ = -1;
	waiting_marker_frame_ = -1;
	waiting_marker_ordinal_ = -1;
	waiting_loop_epoch_ = 0;
	waiting_horizon_frame_ = 0;
	waiting_horizon_loop_epoch_ = 0;
	published_active_arm_id_.store(0, std::memory_order_release);
	if (ramp_total_frames_ <= 0) {
		for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
			current_gains_[index] = target_gains_[index];
		}
		ramp_active_ = true;
		finish_ramp();
	} else {
		ramp_active_ = true;
	}
	publish_snapshot();
}

void StellaMarkerBgmPlayback::finish_ramp() {
	if (!ramp_active_) {
		return;
	}
	EventPod completed{};
	completed.type = EventType::COMPLETED;
	completed.operation_id = ramp_operation_id_;
	completed.arm_id = ramp_arm_id_;
	emit_event(completed);
	ramp_reserved_credits_--;
	release_event_credits(ramp_reserved_credits_);
	ramp_reserved_credits_ = 0;
	ramp_active_ = false;
	ramp_operation_id_ = 0;
	ramp_arm_id_ = 0;
	ramp_progress_frames_ = 0;
}

void StellaMarkerBgmPlayback::emit_event(const EventPod &p_event) {
	const uint64_t write = event_write_sequence_.load(std::memory_order_relaxed);
	const uint64_t read = event_read_sequence_.load(std::memory_order_acquire);
	if (write - read >= EVENT_CAPACITY) {
		rt_event_overflow_violations_.fetch_add(1, std::memory_order_relaxed);
		return;
	}
	events_[write % EVENT_CAPACITY] = p_event;
	event_write_sequence_.store(write + 1, std::memory_order_release);
}

void StellaMarkerBgmPlayback::publish_snapshot() {
	const uint64_t before = snapshot_.version.load(std::memory_order_relaxed);
	snapshot_.version.store(before + 1, std::memory_order_release);
	const int32_t phase = waiting_arm_id_ != 0 ? 1 : (ramp_active_ ? 2 : 0);
	snapshot_.phase.store(phase, std::memory_order_relaxed);
	snapshot_.active_operation_id.store(
			waiting_arm_id_ != 0 ? waiting_operation_id_ : ramp_operation_id_,
			std::memory_order_relaxed);
	snapshot_.arm_id.store(
			waiting_arm_id_ != 0 ? waiting_arm_id_ : ramp_arm_id_,
			std::memory_order_relaxed);
	snapshot_.marker_id.store(waiting_marker_id_, std::memory_order_relaxed);
	snapshot_.marker_frame.store(waiting_marker_frame_, std::memory_order_relaxed);
	snapshot_.marker_ordinal.store(waiting_marker_ordinal_, std::memory_order_relaxed);
	snapshot_.marker_loop_epoch.store(
			waiting_arm_id_ != 0 ? waiting_loop_epoch_ : -1,
			std::memory_order_relaxed);
	int64_t horizon_frame = frame_cursor_;
	int64_t horizon_loop_epoch = loop_count_;
	render_horizon(horizon_frame, horizon_loop_epoch);
	snapshot_.horizon_frame.store(horizon_frame, std::memory_order_relaxed);
	snapshot_.horizon_loop_epoch.store(
			horizon_loop_epoch, std::memory_order_relaxed);
	for (int32_t index = 0; index < MAX_STEMS; index++) {
		snapshot_.target_gains[index].store(target_gains_[index], std::memory_order_relaxed);
	}
	snapshot_.version.store(before + 2, std::memory_order_release);
}

StellaMarkerBgmPlayback::SnapshotPlain StellaMarkerBgmPlayback::read_audio_snapshot() const {
	SnapshotPlain result{};
	for (;;) {
		const uint64_t first = snapshot_.version.load(std::memory_order_acquire);
		if ((first & 1U) != 0U) {
			continue;
		}
		result.phase = snapshot_.phase.load(std::memory_order_relaxed);
		result.active_operation_id = snapshot_.active_operation_id.load(std::memory_order_relaxed);
		result.arm_id = snapshot_.arm_id.load(std::memory_order_relaxed);
		result.marker_id = snapshot_.marker_id.load(std::memory_order_relaxed);
		result.marker_frame = snapshot_.marker_frame.load(std::memory_order_relaxed);
		result.marker_ordinal = snapshot_.marker_ordinal.load(std::memory_order_relaxed);
		result.marker_loop_epoch = snapshot_.marker_loop_epoch.load(std::memory_order_relaxed);
		result.horizon_frame = snapshot_.horizon_frame.load(std::memory_order_relaxed);
		result.horizon_loop_epoch = snapshot_.horizon_loop_epoch.load(std::memory_order_relaxed);
		for (int32_t index = 0; index < MAX_STEMS; index++) {
			result.target_gains[index] =
					snapshot_.target_gains[index].load(std::memory_order_relaxed);
		}
		const uint64_t second = snapshot_.version.load(std::memory_order_acquire);
		if (first == second) {
			return result;
		}
	}
}

Dictionary StellaMarkerBgmPlayback::capture_marker_state() const {
	Dictionary result;
	if (!data_) {
		return result;
	}
#ifdef DEBUG_ENABLED
	bool registered_debug_waiter = false;
#endif
	for (;;) {
		const uint64_t callback_first = callback_version_.load(std::memory_order_acquire);
		if ((callback_first & 1U) != 0U) {
#ifdef DEBUG_ENABLED
			if (!registered_debug_waiter) {
				debug_capture_waiter_count_.fetch_add(1, std::memory_order_acq_rel);
				registered_debug_waiter = true;
			}
#endif
			continue;
		}
		const uint64_t published_first = published_sequence_.load(std::memory_order_acquire);
		const uint64_t consumed_first = consumed_sequence_.load(std::memory_order_acquire);
		const SnapshotPlain snapshot = read_audio_snapshot();
		const uint64_t consumed_second = consumed_sequence_.load(std::memory_order_acquire);
		const uint64_t published_second = published_sequence_.load(std::memory_order_acquire);
		const uint64_t callback_second = callback_version_.load(std::memory_order_acquire);
		if (callback_first != callback_second || (callback_second & 1U) != 0U ||
				published_first != published_second || consumed_first != consumed_second) {
			continue;
		}
		result["published_sequence"] = static_cast<int64_t>(published_first);
		result["consumed_sequence"] = static_cast<int64_t>(consumed_first);
		result["frame_cursor"] = snapshot.horizon_frame;
		result["horizon_frame"] = snapshot.horizon_frame;
		result["horizon_loop_epoch"] = snapshot.horizon_loop_epoch;
		result["startup_gate_closed"] =
				startup_gate_closed_.load(std::memory_order_acquire);
		result["playback_frame_cursor"] =
				published_frame_cursor_.load(std::memory_order_acquire);
		result["active_operation_id"] = snapshot.active_operation_id;
		result["arm_id"] = snapshot.arm_id;
		result["expected_active_arm_id"] = snapshot.arm_id;
		int32_t marker_id = snapshot.marker_id;
		PackedFloat32Array gains;
		gains.resize(static_cast<int64_t>(data_->stems.size()));
		if (published_first > consumed_first) {
			const CommandPod &queued = commands_[(published_first - 1) % COMMAND_CAPACITY];
			result["phase"] = "queued";
			result["queued_operation_id"] = queued.operation_id;
			result["expected_active_arm_id"] = queued.expected_active_arm_id;
			marker_id = queued.marker_id;
			result["marker_frame"] = -1;
			result["marker_ordinal"] = -1;
			result["marker_loop_epoch"] = -1;
			result["wraps_loop"] = false;
			for (int32_t index = 0; index < queued.stem_count; index++) {
				gains.set(index, queued.gains[index]);
			}
		} else {
			result["phase"] = snapshot.phase == 1
					? "armed"
					: (snapshot.phase == 2 ? "triggered" : "none");
			result["queued_operation_id"] = 0;
			result["marker_frame"] = snapshot.marker_frame;
			result["marker_ordinal"] = snapshot.marker_ordinal;
			result["marker_loop_epoch"] = snapshot.marker_loop_epoch;
			result["wraps_loop"] =
					snapshot.marker_loop_epoch > snapshot.horizon_loop_epoch;
			for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
				gains.set(index, snapshot.target_gains[index]);
			}
		}
		result["marker"] = marker_id >= 0 && marker_id < static_cast<int32_t>(data_->labels.size())
				? data_->labels[marker_id]
				: String();
		result["target_gains"] = gains;
#ifdef DEBUG_ENABLED
		if (registered_debug_waiter) {
			debug_capture_waiter_count_.fetch_sub(1, std::memory_order_acq_rel);
		}
#endif
		return result;
	}
}

String StellaMarkerBgmPlayback::event_type_name(EventType p_type) const {
	switch (p_type) {
		case EventType::ARMED:
			return "armed";
		case EventType::ARMED_REPLACED:
			return "armed_replaced";
		case EventType::TRIGGERED:
			return "triggered";
		case EventType::COMPLETED:
			return "completed";
		case EventType::FAILED_NO_MARKER:
			return "failed_no_marker";
		case EventType::FAILED_CONFLICT:
			return "failed_conflict";
		case EventType::CUT_APPLIED:
			return "cut_applied";
	}
	return "failed_conflict";
}

Array StellaMarkerBgmPlayback::drain_marker_events() {
	Array result;
	uint64_t read = event_read_sequence_.load(std::memory_order_relaxed);
	const uint64_t write = event_write_sequence_.load(std::memory_order_acquire);
	while (read < write) {
		const EventPod &event = events_[read % EVENT_CAPACITY];
		Dictionary encoded;
		encoded["type"] = event_type_name(event.type);
		encoded["operation_id"] = event.operation_id;
		encoded["arm_id"] = event.arm_id;
		encoded["replaced_arm_id"] = event.replaced_arm_id;
		encoded["marker_frame"] = event.marker_frame;
		encoded["marker_ordinal"] = event.marker_ordinal;
		encoded["marker_loop_epoch"] = event.marker_loop_epoch;
		encoded["horizon_frame"] = event.horizon_frame;
		encoded["horizon_loop_epoch"] = event.horizon_loop_epoch;
		encoded["wraps_loop"] = event.wraps_loop;
		result.append(encoded);
		read++;
		event_read_sequence_.store(read, std::memory_order_release);
		release_event_credits(1);
	}
	return result;
}

Dictionary StellaMarkerBgmPlayback::debug_get_marker_metrics() const {
	Dictionary metrics;
	metrics["command_capacity"] = COMMAND_CAPACITY;
	metrics["event_capacity"] = EVENT_CAPACITY;
	metrics["available_event_credits"] = available_event_credits_.load(std::memory_order_acquire);
	metrics["rt_allocation_violations"] = rt_allocation_violations_.load(std::memory_order_acquire);
	metrics["rt_lock_violations"] = rt_lock_violations_.load(std::memory_order_acquire);
	metrics["rt_event_overflow_violations"] =
			rt_event_overflow_violations_.load(std::memory_order_acquire);
	metrics["rt_decoder_refill_calls"] =
			rt_decoder_refill_calls_.load(std::memory_order_acquire);
	metrics["rate_hold_callback_count"] =
			debug_rate_hold_callback_count_.load(std::memory_order_acquire);
	return metrics;
}

PackedFloat32Array StellaMarkerBgmPlayback::debug_get_current_gains() const {
	PackedFloat32Array gains;
#ifdef DEBUG_ENABLED
	if (!data_) {
		return gains;
	}
	gains.resize(static_cast<int64_t>(data_->stems.size()));
	for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
		gains.set(index, current_gains_[index]);
	}
#endif
	return gains;
}

bool StellaMarkerBgmPlayback::debug_hold_all_free_event_credits() {
#ifdef DEBUG_ENABLED
	if (debug_held_event_credits_.load(std::memory_order_acquire) != 0) {
		return false;
	}
	const int32_t held = available_event_credits_.exchange(0, std::memory_order_acq_rel);
	debug_held_event_credits_.store(held, std::memory_order_release);
	return held > 0;
#else
	return false;
#endif
}

void StellaMarkerBgmPlayback::debug_release_held_event_credits() {
#ifdef DEBUG_ENABLED
	const int32_t held = debug_held_event_credits_.exchange(0, std::memory_order_acq_rel);
	release_event_credits(held);
#endif
}

void StellaMarkerBgmPlayback::debug_set_callback_gate(bool p_closed) {
#ifdef DEBUG_ENABLED
	startup_gate_closed_.store(p_closed, std::memory_order_release);
#else
	(void)p_closed;
#endif
}

int64_t StellaMarkerBgmPlayback::debug_get_gated_callback_count() const {
#ifdef DEBUG_ENABLED
	return debug_gated_callback_count_.load(std::memory_order_acquire);
#else
	return 0;
#endif
}

void StellaMarkerBgmPlayback::debug_set_hold_after_consume(bool p_hold) {
#ifdef DEBUG_ENABLED
	debug_hold_after_consume_.store(p_hold, std::memory_order_release);
#else
	(void)p_hold;
#endif
}

bool StellaMarkerBgmPlayback::debug_is_callback_held() const {
#ifdef DEBUG_ENABLED
	return debug_callback_held_.load(std::memory_order_acquire);
#else
	return false;
#endif
}

int32_t StellaMarkerBgmPlayback::debug_get_capture_waiter_count() const {
#ifdef DEBUG_ENABLED
	return debug_capture_waiter_count_.load(std::memory_order_acquire);
#else
	return 0;
#endif
}

void StellaMarkerBgmPlayback::apply_ramp_for_frame() {
	if (!ramp_active_ || ramp_total_frames_ <= 0) {
		return;
	}
	const float progress = static_cast<float>(ramp_progress_frames_) /
			static_cast<float>(ramp_total_frames_);
	for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
		current_gains_[index] = ramp_start_gains_[index] +
				(target_gains_[index] - ramp_start_gains_[index]) * progress;
	}
}

bool StellaMarkerBgmPlayback::decode_source_frame(
		std::array<AudioFrame, MAX_STEMS> &r_samples,
		int64_t &r_frame_index,
		int64_t &r_loop_epoch) {
	if (!playing_ || !data_) {
		return false;
	}
	const int64_t playback_end = data_->loop ? data_->loop_end_frame : data_->frame_count;
	if (frame_cursor_ >= playback_end) {
		if (!data_->loop || !seek_decoders(data_->loop_start_frame)) {
			playing_ = false;
			return false;
		}
		frame_cursor_ = data_->loop_start_frame;
		loop_count_++;
	}
	r_frame_index = frame_cursor_;
	r_loop_epoch = loop_count_;
	for (size_t stem_index = 0; stem_index < decoders_.size(); stem_index++) {
		DecoderState &decoder = decoders_[stem_index];
		if (decoder.read_frame >= decoder.decoded_frames && !refill_decoder(decoder)) {
			playing_ = false;
			return false;
		}
		const int64_t offset = static_cast<int64_t>(decoder.read_frame) * data_->channels;
		if (data_->channels == 1) {
			r_samples[stem_index].left = decoder.scratch[offset];
			r_samples[stem_index].right = decoder.scratch[offset];
		} else {
			r_samples[stem_index].left = decoder.scratch[offset];
			r_samples[stem_index].right = decoder.scratch[offset + 1];
		}
		decoder.read_frame++;
	}
	frame_cursor_++;
	return true;
}

bool StellaMarkerBgmPlayback::refill_decoder(DecoderState &p_decoder) {
	if (p_decoder.decoder == nullptr || !data_ || p_decoder.scratch.empty()) {
		return false;
	}
	const int32_t decoded = stb_vorbis_get_samples_float_interleaved(
			p_decoder.decoder,
			data_->channels,
			p_decoder.scratch.data(),
			static_cast<int>(p_decoder.scratch.size()));
	rt_decoder_refill_calls_.fetch_add(1, std::memory_order_relaxed);
	p_decoder.decoded_frames = decoded;
	p_decoder.read_frame = 0;
	return decoded > 0;
}

void StellaMarkerBgmPlayback::activate_source_frame(
		int64_t p_frame_index,
		int64_t p_loop_epoch) {
	if (waiting_arm_id_ != 0 && p_loop_epoch == waiting_loop_epoch_ &&
			p_frame_index == waiting_marker_frame_) {
		trigger_waiting_arm();
	}
	apply_ramp_for_frame();
	advance_ramp_after_source_frame();
}

AudioFrame StellaMarkerBgmPlayback::mix_source_samples(
		const std::array<AudioFrame, MAX_STEMS> &p_samples) const {
	AudioFrame mixed{};
	for (size_t stem_index = 0; stem_index < decoders_.size(); stem_index++) {
		mixed.left += p_samples[stem_index].left * current_gains_[stem_index];
		mixed.right += p_samples[stem_index].right * current_gains_[stem_index];
	}
	return mixed;
}

void StellaMarkerBgmPlayback::advance_ramp_after_source_frame() {
	if (!ramp_active_) {
		return;
	}
	ramp_progress_frames_++;
	if (ramp_total_frames_ <= 0 || ramp_progress_frames_ < ramp_total_frames_) {
		return;
	}
	for (int32_t index = 0; index < static_cast<int32_t>(data_->stems.size()); index++) {
		current_gains_[index] = target_gains_[index];
	}
	finish_ramp();
}

int32_t StellaMarkerBgmPlayback::_mix(
		AudioFrame *p_dst_buffer, float p_rate_scale, int32_t p_frame_count) {
	callback_version_.fetch_add(1, std::memory_order_acq_rel);
	const auto callback_guard = make_scope_exit([this]() {
		publish_snapshot();
		callback_version_.fetch_add(1, std::memory_order_release);
	});
	if (!playing_ || !data_ || p_frame_count <= 0) {
		return 0;
	}
	if (startup_gate_closed_.load(std::memory_order_acquire)) {
		// AudioServer retires a playback that returns fewer frames than requested.
		// Publish a complete silent buffer while preserving the exact startup
		// horizon; no command, decoder, resampler, or cursor state advances.
		std::fill_n(p_dst_buffer, p_frame_count, AudioFrame{});
#ifdef DEBUG_ENABLED
		debug_gated_callback_count_.fetch_add(1, std::memory_order_relaxed);
#endif
		return p_frame_count;
	}
	// Validate the entire source-step projection before the callback consumes
	// control or command state. Extreme but positive AudioServer speed scales
	// are recoverable: retain the playback with a complete silent buffer and
	// leave the queued operation untouched until a supported rate returns.
	if (!std::isfinite(p_rate_scale) || p_rate_scale <= 0.0f) {
		std::fill_n(p_dst_buffer, p_frame_count, AudioFrame{});
#ifdef DEBUG_ENABLED
		debug_rate_hold_callback_count_.fetch_add(1, std::memory_order_relaxed);
#endif
		return p_frame_count;
	}
	const double output_rate = static_cast<double>(data_->output_mix_rate);
	AudioServer *audio_server = AudioServer::get_singleton();
	const double playback_speed = audio_server != nullptr
			? audio_server->get_playback_speed_scale()
			: 0.0;
	const double source_step = static_cast<double>(p_rate_scale) * playback_speed *
			static_cast<double>(data_->sample_rate) / output_rate;
	if (!std::isfinite(source_step) || source_step <= 0.0 || source_step > 1024.0) {
		std::fill_n(p_dst_buffer, p_frame_count, AudioFrame{});
#ifdef DEBUG_ENABLED
		debug_rate_hold_callback_count_.fetch_add(1, std::memory_order_relaxed);
#endif
		return p_frame_count;
	}
	const uint64_t source_increment = static_cast<uint64_t>(
			source_step * static_cast<double>(RESAMPLE_FP_ONE));
	if (source_increment == 0) {
		std::fill_n(p_dst_buffer, p_frame_count, AudioFrame{});
#ifdef DEBUG_ENABLED
		debug_rate_hold_callback_count_.fetch_add(1, std::memory_order_relaxed);
#endif
		return p_frame_count;
	}
	consume_control_at_boundary();
	consume_commands_at_boundary();
#ifdef DEBUG_ENABLED
	if (debug_hold_after_consume_.load(std::memory_order_acquire)) {
		debug_callback_held_.store(true, std::memory_order_release);
		while (debug_hold_after_consume_.load(std::memory_order_acquire)) {
		}
		debug_callback_held_.store(false, std::memory_order_release);
	}
#endif
	int32_t written = 0;
	while (written < p_frame_count && playing_) {
		if (!current_source_frame_valid_) {
			if (!decode_source_frame(
					current_source_samples_, current_source_frame_index_,
					current_source_loop_epoch_)) {
				break;
			}
			current_source_frame_valid_ = true;
			activate_source_frame(
					current_source_frame_index_, current_source_loop_epoch_);
		}
		while (resample_phase_ >= RESAMPLE_FP_ONE && playing_) {
			resample_phase_ -= RESAMPLE_FP_ONE;
			if (next_source_frame_valid_) {
				current_source_samples_ = next_source_samples_;
				current_source_frame_index_ = next_source_frame_index_;
				current_source_loop_epoch_ = next_source_loop_epoch_;
				next_source_frame_valid_ = false;
			} else if (!decode_source_frame(
					current_source_samples_, current_source_frame_index_,
					current_source_loop_epoch_)) {
				break;
			}
			activate_source_frame(
					current_source_frame_index_, current_source_loop_epoch_);
		}
		if (!playing_) {
			break;
		}
		const uint64_t fractional_phase = resample_phase_ & (RESAMPLE_FP_ONE - 1);
		if (fractional_phase != 0 && !next_source_frame_valid_) {
			if (!decode_source_frame(
					next_source_samples_, next_source_frame_index_,
					next_source_loop_epoch_)) {
				break;
			}
			next_source_frame_valid_ = true;
		}
		const AudioFrame current_mixed = mix_source_samples(current_source_samples_);
		if (fractional_phase == 0) {
			p_dst_buffer[written] = current_mixed;
		} else {
			const AudioFrame next_mixed = mix_source_samples(next_source_samples_);
			const float fraction = static_cast<float>(
					static_cast<double>(fractional_phase) /
					static_cast<double>(RESAMPLE_FP_ONE));
			p_dst_buffer[written].left = current_mixed.left +
					(next_mixed.left - current_mixed.left) * fraction;
			p_dst_buffer[written].right = current_mixed.right +
					(next_mixed.right - current_mixed.right) * fraction;
		}
		written++;
		resample_phase_ += source_increment;
	}
	if (!playing_) {
		// A true decoder/EOF terminal is allowed to return a short buffer, but it
		// must not strand an operation whose event credits were already reserved.
		if (waiting_arm_id_ != 0) {
			EventPod failed{};
			failed.type = EventType::FAILED_CONFLICT;
			failed.operation_id = waiting_operation_id_;
			failed.arm_id = waiting_arm_id_;
			failed.marker_frame = waiting_marker_frame_;
			failed.marker_ordinal = waiting_marker_ordinal_;
			failed.marker_loop_epoch = waiting_loop_epoch_;
			emit_event(failed);
			waiting_reserved_credits_--;
			cancel_waiting_arm();
		}
		if (ramp_active_) {
			complete_ramp_cut();
		}
	}
	int64_t playback_frame = frame_cursor_;
	int64_t playback_loop_count = loop_count_;
	if (current_source_frame_valid_) {
		const int64_t whole_advance = static_cast<int64_t>(
				resample_phase_ >> RESAMPLE_FP_BITS);
		playback_frame = current_source_frame_index_ + whole_advance;
		playback_loop_count = current_source_loop_epoch_;
		if (data_->loop && playback_frame >= data_->loop_end_frame) {
			const int64_t loop_length = data_->loop_end_frame - data_->loop_start_frame;
			const int64_t beyond_end = playback_frame - data_->loop_end_frame;
			playback_loop_count += 1 + (beyond_end / loop_length);
			playback_frame = data_->loop_start_frame + (beyond_end % loop_length);
		} else if (!data_->loop) {
			playback_frame = std::min(playback_frame, data_->frame_count);
		}
	}
	published_frame_cursor_.store(playback_frame, std::memory_order_release);
	published_loop_count_.store(playback_loop_count, std::memory_order_release);
	published_playing_.store(playing_, std::memory_order_release);
	return written;
}

void StellaMarkerBgmStream::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "configuration"),
			&StellaMarkerBgmStream::configure);
	ClassDB::bind_method(D_METHOD("configure_startup_marker_mix", "configuration"),
			&StellaMarkerBgmStream::configure_startup_marker_mix);
	ClassDB::bind_method(D_METHOD("get_source_sample_rate"),
			&StellaMarkerBgmStream::get_source_sample_rate);
	ClassDB::bind_method(D_METHOD("get_source_frame_count"),
			&StellaMarkerBgmStream::get_source_frame_count);
}

bool StellaMarkerBgmStream::configure(const Dictionary &p_configuration) {
	static const std::vector<StringName> CONFIG_KEYS = {
		"initial_gains", "loop", "loop_end_frame", "loop_start_frame", "markers",
		"schema_version", "stem_names", "stem_ogg_bytes"
	};
	if (!has_exact_keys(p_configuration, CONFIG_KEYS) ||
			p_configuration["schema_version"].get_type() != Variant::INT ||
			p_configuration["loop_start_frame"].get_type() != Variant::INT ||
			p_configuration["loop_end_frame"].get_type() != Variant::INT ||
			p_configuration["loop"].get_type() != Variant::BOOL ||
			p_configuration["stem_names"].get_type() != Variant::PACKED_STRING_ARRAY ||
			p_configuration["initial_gains"].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
			p_configuration["stem_ogg_bytes"].get_type() != Variant::ARRAY ||
			p_configuration["markers"].get_type() != Variant::ARRAY) {
		return false;
	}
	const int64_t schema_version = p_configuration["schema_version"];
	if (schema_version != CONFIG_SCHEMA_VERSION) {
		return false;
	}
	const PackedStringArray stem_names = p_configuration["stem_names"];
	const PackedFloat32Array initial_gains = p_configuration["initial_gains"];
	const Array stem_bytes = p_configuration["stem_ogg_bytes"];
	if (stem_names.size() < 2 || stem_names.size() > StellaMarkerBgmPlayback::MAX_STEMS ||
			initial_gains.size() != stem_names.size() || stem_bytes.size() != stem_names.size()) {
		return false;
	}
	auto candidate = std::make_shared<StellaMarkerBgmStreamData>();
	const AudioServer *audio_server = AudioServer::get_singleton();
	if (audio_server == nullptr || audio_server->get_mix_rate() <= 0) {
		return false;
	}
	candidate->output_mix_rate = audio_server->get_mix_rate();
	bool audible = false;
	for (int64_t index = 0; index < stem_names.size(); index++) {
		const String name = stem_names[index];
		const float gain = initial_gains[index];
		if (!is_valid_stem_name(name) || !std::isfinite(gain) || gain < 0.0f || gain > 1.0f ||
				stem_bytes[index].get_type() != Variant::PACKED_BYTE_ARRAY) {
			return false;
		}
		for (int64_t other = 0; other < index; other++) {
			if (stem_names[other] == name) {
				return false;
			}
		}
		audible = audible || gain > 0.0f;
		const PackedByteArray bytes = stem_bytes[index];
		if (bytes.is_empty() || bytes.size() > std::numeric_limits<int>::max()) {
			return false;
		}
		StemEntry stem;
		stem.name = name;
		stem.ogg_bytes.resize(static_cast<size_t>(bytes.size()));
		std::memcpy(stem.ogg_bytes.data(), bytes.ptr(), static_cast<size_t>(bytes.size()));
		int error = VORBIS__no_error;
		stb_vorbis *probe = stb_vorbis_open_memory(
				stem.ogg_bytes.data(), static_cast<int>(stem.ogg_bytes.size()), &error, nullptr);
		if (probe == nullptr) {
			return false;
		}
		const stb_vorbis_info info = stb_vorbis_get_info(probe);
		const int64_t frames = static_cast<int64_t>(stb_vorbis_stream_length_in_samples(probe));
		stb_vorbis_close(probe);
		if (info.sample_rate == 0 || (info.channels != 1 && info.channels != 2) || frames <= 0) {
			return false;
		}
		if (index == 0) {
			candidate->sample_rate = static_cast<int32_t>(info.sample_rate);
			candidate->channels = info.channels;
			candidate->frame_count = frames;
		} else if (candidate->sample_rate != static_cast<int32_t>(info.sample_rate) ||
				candidate->channels != info.channels || candidate->frame_count != frames) {
			return false;
		}
		stem.decoder_arena_bytes = static_cast<int32_t>(
				info.setup_memory_required + info.setup_temp_memory_required +
				info.temp_memory_required + DECODER_ARENA_MARGIN);
		stem.max_frame_size = info.max_frame_size;
		candidate->scratch_frames = std::max(candidate->scratch_frames, info.max_frame_size);
		candidate->stems.push_back(std::move(stem));
		candidate->initial_gains[index] = gain;
	}
	if (!audible) {
		return false;
	}
	const int64_t loop_start = static_cast<int64_t>(p_configuration["loop_start_frame"]);
	const int64_t loop_end = static_cast<int64_t>(p_configuration["loop_end_frame"]);
	candidate->loop = static_cast<bool>(p_configuration["loop"]);
	candidate->loop_start_frame = loop_start;
	candidate->loop_end_frame = loop_end;
	if (loop_start < 0 || loop_end <= loop_start || loop_end > candidate->frame_count) {
		return false;
	}
	const Array markers = p_configuration["markers"];
	if (markers.size() > MAX_MARKERS) {
		return false;
	}
	int64_t previous_frame = -1;
	for (int64_t index = 0; index < markers.size(); index++) {
		if (markers[index].get_type() != Variant::DICTIONARY) {
			return false;
		}
		const Dictionary encoded = markers[index];
		if (!has_exact_keys(encoded, { "frame", "name" }) ||
				encoded["frame"].get_type() != Variant::INT ||
				encoded["name"].get_type() != Variant::STRING) {
			return false;
		}
		const String name = encoded["name"];
		const int64_t frame = static_cast<int64_t>(encoded["frame"]);
		if (!is_valid_marker_label(name) || frame < 0 || frame >= candidate->frame_count ||
				frame < previous_frame) {
			return false;
		}
		int32_t label_id = -1;
		for (int32_t label_index = 0; label_index < static_cast<int32_t>(candidate->labels.size()); label_index++) {
			if (candidate->labels[label_index] == name) {
				label_id = label_index;
				break;
			}
		}
		if (label_id < 0) {
			label_id = static_cast<int32_t>(candidate->labels.size());
			candidate->labels.push_back(name);
		}
		for (auto previous = candidate->markers.rbegin();
				previous != candidate->markers.rend() && previous->frame == frame;
				previous++) {
			if (previous->label_id == label_id) {
				return false;
			}
		}
		candidate->markers.push_back({ label_id, frame, static_cast<int32_t>(index) });
		previous_frame = frame;
	}
	data_ = std::move(candidate);
	return true;
}

bool StellaMarkerBgmStream::configure_startup_marker_mix(
		const Dictionary &p_configuration) {
	static const std::vector<StringName> STARTUP_KEYS = {
		"fade_frames", "gains", "horizon_frame", "horizon_loop_epoch",
		"marker", "marker_frame", "marker_loop_epoch", "marker_ordinal",
		"operation_id", "schema_version"
	};
	if (!data_ || data_.use_count() != 1 ||
			!has_exact_keys(p_configuration, STARTUP_KEYS) ||
			p_configuration["schema_version"].get_type() != Variant::INT ||
			p_configuration["fade_frames"].get_type() != Variant::INT ||
			p_configuration["gains"].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
			p_configuration["horizon_frame"].get_type() != Variant::INT ||
			p_configuration["horizon_loop_epoch"].get_type() != Variant::INT ||
			p_configuration["marker"].get_type() != Variant::STRING ||
			p_configuration["marker_frame"].get_type() != Variant::INT ||
			p_configuration["marker_loop_epoch"].get_type() != Variant::INT ||
			p_configuration["marker_ordinal"].get_type() != Variant::INT ||
			p_configuration["operation_id"].get_type() != Variant::INT) {
		return false;
	}
	const int64_t schema_version = p_configuration["schema_version"];
	const int64_t fade_frames_value = p_configuration["fade_frames"];
	const PackedFloat32Array gains = p_configuration["gains"];
	const int64_t horizon_frame = p_configuration["horizon_frame"];
	const int64_t horizon_loop_epoch = p_configuration["horizon_loop_epoch"];
	const String marker_name = p_configuration["marker"];
	const int64_t expected_frame = p_configuration["marker_frame"];
	const int64_t expected_loop_epoch = p_configuration["marker_loop_epoch"];
	const int64_t expected_ordinal_value = p_configuration["marker_ordinal"];
	const int64_t operation_id = p_configuration["operation_id"];
	if (schema_version != 1 || fade_frames_value < 0 ||
			fade_frames_value > std::numeric_limits<int32_t>::max() ||
			operation_id <= 0 || horizon_frame < 0 || horizon_loop_epoch < 0 ||
			expected_frame < 0 || expected_loop_epoch < 0 ||
			expected_ordinal_value < 0 ||
			expected_ordinal_value > std::numeric_limits<int32_t>::max() ||
			gains.size() != static_cast<int64_t>(data_->stems.size()) ||
			!is_valid_marker_label(marker_name)) {
		return false;
	}
	const int64_t playback_end = data_->loop ? data_->loop_end_frame : data_->frame_count;
	if (horizon_frame >= playback_end ||
			(!data_->loop && horizon_loop_epoch != 0) ||
			(data_->loop && horizon_loop_epoch > 0 && horizon_frame < data_->loop_start_frame)) {
		return false;
	}
	int32_t marker_id = -1;
	for (int32_t index = 0; index < static_cast<int32_t>(data_->labels.size()); index++) {
		if (data_->labels[index] == marker_name) {
			marker_id = index;
			break;
		}
	}
	if (marker_id < 0) {
		return false;
	}
	int64_t selected_frame = -1;
	int32_t selected_ordinal = -1;
	int64_t selected_loop_epoch = -1;
	for (const MarkerEntry &marker : data_->markers) {
		if (marker.label_id == marker_id && marker.frame >= horizon_frame &&
				marker.frame < playback_end) {
			selected_frame = marker.frame;
			selected_ordinal = marker.ordinal;
			selected_loop_epoch = horizon_loop_epoch;
			break;
		}
	}
	if (selected_frame < 0 && data_->loop) {
		for (const MarkerEntry &marker : data_->markers) {
			if (marker.label_id == marker_id && marker.frame >= data_->loop_start_frame &&
					marker.frame < data_->loop_end_frame) {
				selected_frame = marker.frame;
				selected_ordinal = marker.ordinal;
				selected_loop_epoch = horizon_loop_epoch + 1;
				break;
			}
		}
	}
	if (selected_frame != expected_frame || selected_ordinal != expected_ordinal_value ||
			selected_loop_epoch != expected_loop_epoch) {
		return false;
	}
	bool audible = false;
	for (int32_t index = 0; index < static_cast<int32_t>(gains.size()); index++) {
		const float gain = gains[index];
		if (!std::isfinite(gain) || gain < 0.0f || gain > 1.0f) {
			return false;
		}
		audible = audible || gain > 0.0f;
		data_->startup_gains[index] = gain;
	}
	if (!audible) {
		return false;
	}
	data_->startup_arm_enabled = true;
	data_->startup_operation_id = operation_id;
	data_->startup_marker_id = marker_id;
	data_->startup_fade_frames = static_cast<int32_t>(fade_frames_value);
	data_->startup_horizon_frame = horizon_frame;
	data_->startup_horizon_loop_epoch = horizon_loop_epoch;
	data_->startup_marker_frame = expected_frame;
	data_->startup_marker_ordinal = static_cast<int32_t>(expected_ordinal_value);
	data_->startup_marker_loop_epoch = expected_loop_epoch;
	return true;
}

int32_t StellaMarkerBgmStream::get_source_sample_rate() const {
	return data_ ? data_->sample_rate : 0;
}

int64_t StellaMarkerBgmStream::get_source_frame_count() const {
	return data_ ? data_->frame_count : 0;
}

Ref<AudioStreamPlayback> StellaMarkerBgmStream::_instantiate_playback() const {
	Ref<StellaMarkerBgmPlayback> playback;
	playback.instantiate();
	playback->set_stream_data(data_);
	return playback;
}

String StellaMarkerBgmStream::_get_stream_name() const {
	return "Stella marker BGM";
}

double StellaMarkerBgmStream::_get_length() const {
	if (!data_ || data_->sample_rate <= 0) {
		return 0.0;
	}
	return static_cast<double>(data_->frame_count) / static_cast<double>(data_->sample_rate);
}

bool StellaMarkerBgmStream::_is_monophonic() const {
	return false;
}

bool StellaMarkerBgmStream::_has_loop() const {
	return data_ && data_->loop;
}

} // namespace godot
