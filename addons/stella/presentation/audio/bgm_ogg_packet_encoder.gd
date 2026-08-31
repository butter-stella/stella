## Deterministically rebuilds an Ogg container from Godot's export-safe
## OggPacketSequence representation. This runs only during main-thread BGM
## preflight; the audio callback receives immutable bytes and never allocates.
class_name BgmOggPacketEncoder extends RefCounted

const MAX_CONTAINER_BYTES := 512 * 1024 * 1024
const MAX_PAGE_SEGMENTS := 255


static func encode(
	packet_pages: Array,
	granule_positions: PackedInt64Array,
	stream_serial: int,
) -> PackedByteArray:
	if (
		packet_pages.is_empty()
		or packet_pages.size() != granule_positions.size()
		or stream_serial <= 0
	):
		return PackedByteArray()
	var packets: Array[Dictionary] = []
	var total_payload_bytes := 0
	for page_index in range(packet_pages.size()):
		var page_value: Variant = packet_pages[page_index]
		if not page_value is Array:
			return PackedByteArray()
		var page: Array = page_value
		for packet_index in range(page.size()):
			var packet_value: Variant = page[packet_index]
			if not packet_value is PackedByteArray:
				return PackedByteArray()
			var packet: PackedByteArray = packet_value
			if packet.is_empty():
				return PackedByteArray()
			total_payload_bytes += packet.size()
			if total_payload_bytes > MAX_CONTAINER_BYTES:
				return PackedByteArray()
			packets.append({
				"bytes": packet,
				"granule": (
					granule_positions[page_index]
					if packet_index == page.size() - 1
					else -1
				),
			})
	if packets.size() < 3:
		return PackedByteArray()

	var result := PackedByteArray()
	var sequence := 0
	for packet_index in range(packets.size()):
		var packet: PackedByteArray = packets[packet_index]["bytes"]
		var packet_offset := 0
		var first_packet_page := true
		while packet_offset < packet.size() or (
			packet_offset == packet.size() and packet.size() % 255 == 0
		):
			var lacing := PackedByteArray()
			var payload_size := 0
			while lacing.size() < MAX_PAGE_SEGMENTS and packet_offset + payload_size < packet.size():
				var segment_size := mini(255, packet.size() - packet_offset - payload_size)
				lacing.append(segment_size)
				payload_size += segment_size
				if segment_size < 255:
					break
			# A packet ending exactly at a full 255-segment page needs an
			# explicit zero-length terminator on its following continuation page.
			if lacing.is_empty() and packet_offset == packet.size():
				lacing.append(0)
			if (
				packet_offset + payload_size == packet.size()
				and not lacing.is_empty()
				and lacing[-1] == 255
				and lacing.size() < MAX_PAGE_SEGMENTS
			):
				lacing.append(0)
			var packet_finished := (
				packet_offset + payload_size == packet.size()
				and not lacing.is_empty()
				and lacing[-1] < 255
			)
			var header_type := 0
			if not first_packet_page:
				header_type |= 0x01
			if packet_index == 0 and first_packet_page:
				header_type |= 0x02
			if packet_index == packets.size() - 1 and packet_finished:
				header_type |= 0x04
			var granule := int(packets[packet_index]["granule"]) \
				if packet_finished else -1
			var page_bytes := _encode_page(
				header_type,
				granule,
				stream_serial,
				sequence,
				lacing,
				packet.slice(packet_offset, packet_offset + payload_size),
			)
			if page_bytes.is_empty() or result.size() + page_bytes.size() > MAX_CONTAINER_BYTES:
				return PackedByteArray()
			result.append_array(page_bytes)
			sequence += 1
			packet_offset += payload_size
			first_packet_page = false
			if packet_finished:
				break
	return result


static func _encode_page(
	header_type: int,
	granule: int,
	stream_serial: int,
	sequence: int,
	lacing: PackedByteArray,
	payload: PackedByteArray,
) -> PackedByteArray:
	if lacing.is_empty() or lacing.size() > MAX_PAGE_SEGMENTS:
		return PackedByteArray()
	var page := "OggS".to_ascii_buffer()
	page.append(0)
	page.append(header_type & 0xff)
	_append_u64(page, granule)
	_append_u32(page, stream_serial)
	_append_u32(page, sequence)
	_append_u32(page, 0)
	page.append(lacing.size())
	page.append_array(lacing)
	page.append_array(payload)
	var checksum := _ogg_crc(page)
	for index in range(4):
		page[22 + index] = (checksum >> (index * 8)) & 0xff
	return page


static func _ogg_crc(bytes: PackedByteArray) -> int:
	var checksum := 0
	for byte in bytes:
		var table_index := ((checksum >> 24) & 0xff) ^ byte
		var remainder := table_index << 24
		for _bit in range(8):
			remainder = (
				((remainder << 1) ^ 0x04c11db7)
				if remainder & 0x80000000
				else remainder << 1
			) & 0xffffffff
		checksum = ((checksum << 8) ^ remainder) & 0xffffffff
	return checksum


static func _append_u32(target: PackedByteArray, value: int) -> void:
	for shift in [0, 8, 16, 24]:
		target.append((value >> shift) & 0xff)


static func _append_u64(target: PackedByteArray, value: int) -> void:
	for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
		target.append((value >> shift) & 0xff)
