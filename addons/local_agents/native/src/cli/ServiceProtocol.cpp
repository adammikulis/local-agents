#include "ServiceProtocol.hpp"
#include <cstring>
#include <stdexcept>

namespace lasim::wire {
namespace {

constexpr uint32_t magic = 0x5350414c;
constexpr size_t header_size = 36;

void put(std::vector<uint8_t> &out, uint64_t value, size_t width) {
	for (size_t i = 0; i < width; ++i) { out.push_back(uint8_t(value >> (i * 8))); }
}

bool read_exact(std::FILE *stream, uint8_t *out, size_t count) {
	return count == 0 || std::fread(out, 1, count, stream) == count;
}

}

void put_u32(std::vector<uint8_t> &out, uint32_t value) { put(out, value, 4); }
void put_u64(std::vector<uint8_t> &out, uint64_t value) { put(out, value, 8); }

void put_double(std::vector<uint8_t> &out, double value) {
	uint64_t bits;
	static_assert(sizeof(bits) == sizeof(value));
	std::memcpy(&bits, &value, sizeof(bits));
	put_u64(out, bits);
}

void put_string(std::vector<uint8_t> &out, const std::string &value) {
	if (value.size() > max_payload || out.size() + 4 + value.size() > max_payload) {
		throw std::length_error("service message exceeds protocol limit");
	}
	put_u32(out, uint32_t(value.size()));
	out.insert(out.end(), value.begin(), value.end());
}

bool Cursor::take(size_t width, uint64_t &value) {
	if (width > bytes.size() - at) { return false; }
	value = 0;
	for (size_t i = 0; i < width; ++i) { value |= uint64_t(bytes[at++]) << (i * 8); }
	return true;
}

bool Cursor::u32(uint32_t &value) {
	uint64_t wide;
	if (!take(4, wide)) { return false; }
	value = uint32_t(wide);
	return true;
}

bool Cursor::u64(uint64_t &value) { return take(8, value); }

bool Cursor::number(double &value) {
	uint64_t bits;
	if (!u64(bits)) { return false; }
	std::memcpy(&value, &bits, sizeof(value));
	return true;
}

bool Cursor::string(std::string &value) {
	uint32_t count;
	if (!u32(count) || count > bytes.size() - at) { return false; }
	value.assign(reinterpret_cast<const char *>(bytes.data() + at), count);
	at += count;
	return value.find('\0') == std::string::npos;
}

bool read(std::FILE *stream, Packet &out, bool &eof, std::string &err) {
	eof = false;
	std::vector<uint8_t> header(header_size);
	const size_t got = std::fread(header.data(), 1, header.size(), stream);
	if (got == 0 && std::feof(stream)) { eof = true; return false; }
	if (got != header.size()) { err = "PROTOCOL_TRUNCATED_HEADER"; return false; }
	Cursor cursor(header);
	uint32_t tag, operation_version, length;
	if (!cursor.u32(tag) || !cursor.u32(operation_version) || !cursor.u32(length)
			|| !cursor.u64(out.session) || !cursor.u64(out.request) || !cursor.u64(out.generation)) {
		err = "PROTOCOL_HEADER";
		return false;
	}
	out.operation = uint16_t(operation_version >> 16);
	if (tag != magic || uint16_t(operation_version) != version) {
		err = "PROTOCOL_VERSION_OR_MAGIC";
		return false;
	}
	if (length > max_payload) { err = "PROTOCOL_PAYLOAD_LIMIT"; return false; }
	out.payload.resize(length);
	if (!read_exact(stream, out.payload.data(), length)) {
		err = "PROTOCOL_TRUNCATED_PAYLOAD";
		return false;
	}
	return true;
}

bool write(std::FILE *stream, const Packet &packet, std::string &err) {
	if (packet.payload.size() > max_payload) { err = "PROTOCOL_PAYLOAD_LIMIT"; return false; }
	std::vector<uint8_t> header;
	put_u32(header, magic);
	put_u32(header, uint32_t(version) | uint32_t(packet.operation) << 16);
	put_u32(header, uint32_t(packet.payload.size()));
	put_u64(header, packet.session);
	put_u64(header, packet.request);
	put_u64(header, packet.generation);
	if (std::fwrite(header.data(), 1, header.size(), stream) != header.size()
			|| (!packet.payload.empty() && std::fwrite(packet.payload.data(), 1, packet.payload.size(), stream)
					!= packet.payload.size()) || std::fflush(stream) != 0) {
		err = "PROTOCOL_WRITE_FAILED";
		return false;
	}
	return true;
}

}
