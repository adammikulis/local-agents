#include "cli/ServiceProtocol.hpp"
#include <cmath>
#include <limits>
#include <stdexcept>

using namespace lasim;

namespace {
std::vector<uint8_t> encode(const wire::Packet &packet) {
	std::FILE *stream = std::tmpfile();
	if (!stream) { throw std::runtime_error("tmpfile"); }
	std::string error;
	if (!wire::write(stream, packet, error)) { std::fclose(stream); throw std::runtime_error(error); }
	const long size = std::ftell(stream);
	std::rewind(stream);
	std::vector<uint8_t> bytes(static_cast<size_t>(size));
	const bool read = std::fread(bytes.data(), 1, bytes.size(), stream) == bytes.size();
	std::fclose(stream);
	if (!read) { throw std::runtime_error("read encoded packet"); }
	return bytes;
}

bool rejected(const std::vector<uint8_t> &bytes, const std::string &expected) {
	std::FILE *stream = std::tmpfile();
	if (!stream) { return false; }
	std::fwrite(bytes.data(), 1, bytes.size(), stream);
	std::rewind(stream);
	wire::Packet packet;
	bool eof = false;
	std::string error;
	const bool read = wire::read(stream, packet, eof, error);
	std::fclose(stream);
	return !read && !eof && error == expected;
}
}

int main() {
	wire::Packet source{wire::Load, 17, 23, 29, {}};
	wire::put_string(source.payload, "snapshot");
	wire::put_double(source.payload, 1.25);
	const auto bytes = encode(source);
	if (bytes.size() < 36 || bytes[0] != 'L' || bytes[1] != 'A' || bytes[2] != 'P'
			|| bytes[3] != 'S' || bytes[4] != 1 || bytes[5] != 0 || bytes[6] != 2 || bytes[7] != 0) { return 1; }
	std::FILE *stream = std::tmpfile();
	if (!stream) { return 1; }
	std::string error;
	bool eof = false;
	wire::write(stream, source, error);
	std::rewind(stream);
	wire::Packet result;
	if (!wire::read(stream, result, eof, error) || eof || result.operation != source.operation
			|| result.session != source.session || result.request != source.request
			|| result.generation != source.generation || result.payload != source.payload) { return 1; }
	wire::Packet end;
	if (wire::read(stream, end, eof, error) || !eof) { return 1; }
	std::fclose(stream);
	wire::Cursor payload(result.payload);
	std::string name;
	double time = 0.0;
	if (!payload.string(name) || name != "snapshot" || !payload.number(time) || time != 1.25 || !payload.empty()) { return 1; }
	for (size_t size = 1; size < 36; ++size) {
		if (!rejected({bytes.begin(), bytes.begin() + size}, "PROTOCOL_TRUNCATED_HEADER")) { return 1; }
	}
	auto mutant = bytes;
	mutant.pop_back();
	if (!rejected(mutant, "PROTOCOL_TRUNCATED_PAYLOAD")) { return 1; }
	mutant = bytes;
	mutant[4] = 0;
	if (!rejected(mutant, "PROTOCOL_VERSION_OR_MAGIC")) { return 1; }
	mutant = bytes;
	mutant[0] = 0;
	if (!rejected(mutant, "PROTOCOL_VERSION_OR_MAGIC")) { return 1; }
	mutant = bytes;
	const uint32_t oversized = wire::max_payload + 1;
	for (size_t i = 0; i < 4; ++i) { mutant[8 + i] = uint8_t(oversized >> (8 * i)); }
	if (!rejected(mutant, "PROTOCOL_PAYLOAD_LIMIT")) { return 1; }
	wire::Packet maximum{wire::View, 1, 1, 0, std::vector<uint8_t>(wire::max_payload, 7)};
	if (encode(maximum).size() != 36 + wire::max_payload) { return 1; }
	maximum.payload.push_back(7);
	stream = std::tmpfile();
	if (!stream) { return 1; }
	const bool bounded = !wire::write(stream, maximum, error) && std::ftell(stream) == 0;
	std::fclose(stream);
	if (!bounded) { return 1; }
	std::vector<uint8_t> invalid_string;
	wire::put_string(invalid_string, std::string("a\0b", 3));
	wire::Cursor invalid(invalid_string);
	if (invalid.string(name)) { return 1; }
	bool oversized_string_rejected = false;
	try { wire::put_string(invalid_string, std::string(wire::max_payload + 1, 'a')); }
	catch (const std::length_error &) { oversized_string_rejected = true; }
	return oversized_string_rejected ? 0 : 1;
}
