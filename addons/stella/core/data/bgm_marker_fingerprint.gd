## Stable, cross-platform SHA-256 encodings for marker-capable BGM resources.
class_name BgmMarkerFingerprint extends RefCounted

const MARKER_SCHEMA_PREFIX := "stella.bgm.marker-table"
const TRACK_SCHEMA_PREFIX := "stella.bgm.track"


static func marker_table(markers: Array[BgmMarkerDefinition]) -> String:
	var encoded := MARKER_SCHEMA_PREFIX.to_utf8_buffer()
	_append_schema_version(encoded)
	_append_u32(encoded, markers.size())
	for marker: BgmMarkerDefinition in markers:
		if (
			marker == null
			or not BgmChannelState.is_valid_marker_label(marker.marker_name)
			or marker.sample_frame < 0
		):
			return ""
		var label_bytes := marker.marker_name.to_utf8_buffer()
		_append_u32(encoded, label_bytes.size())
		encoded.append_array(label_bytes)
		_append_u64(encoded, marker.sample_frame)
	return _sha256(encoded)


static func track(
	stem_names: Array[String],
	stem_ogg_bytes: Array[PackedByteArray],
	sample_rate: int,
	frame_count: int,
	loop: bool,
	loop_start_frame: int,
	loop_end_frame: int,
	marker_table_fingerprint: String,
) -> String:
	if (
		stem_names.size() < 2
		or stem_names.size() != stem_ogg_bytes.size()
		or sample_rate <= 0
		or frame_count <= 0
		or loop_start_frame < 0
		or loop_end_frame <= loop_start_frame
		or loop_end_frame > frame_count
		or not _is_sha256(marker_table_fingerprint)
	):
		return ""
	var encoded := TRACK_SCHEMA_PREFIX.to_utf8_buffer()
	_append_schema_version(encoded)
	_append_u32(encoded, stem_names.size())
	for index in range(stem_names.size()):
		var stem_name := stem_names[index]
		var bytes := stem_ogg_bytes[index]
		if not BgmChannelState.is_valid_stem_name(stem_name) or bytes.is_empty():
			return ""
		var name_bytes := stem_name.to_utf8_buffer()
		_append_u32(encoded, name_bytes.size())
		encoded.append_array(name_bytes)
		var content_digest := _sha256_bytes(bytes)
		if content_digest.size() != 32:
			return ""
		encoded.append_array(content_digest)
	_append_u32(encoded, sample_rate)
	_append_u64(encoded, frame_count)
	encoded.append(1 if loop else 0)
	_append_u64(encoded, loop_start_frame)
	_append_u64(encoded, loop_end_frame)
	encoded.append_array(marker_table_fingerprint.hex_decode())
	return _sha256(encoded)


static func _append_u32(target: PackedByteArray, value: int) -> void:
	for shift in [0, 8, 16, 24]:
		target.append((value >> shift) & 0xff)


static func _append_schema_version(target: PackedByteArray) -> void:
	target.append(0)
	target.append_array("v1".to_utf8_buffer())
	target.append(0)


static func _append_u64(target: PackedByteArray, value: int) -> void:
	for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
		target.append((value >> shift) & 0xff)


static func _sha256(bytes: PackedByteArray) -> String:
	return _sha256_bytes(bytes).hex_encode()


static func _sha256_bytes(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	if context.update(bytes) != OK:
		return PackedByteArray()
	return context.finish()


static func _is_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true
