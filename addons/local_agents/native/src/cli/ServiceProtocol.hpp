#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace lasim::wire {

constexpr uint16_t version = 1;
constexpr uint32_t max_payload = 65536;
constexpr uint16_t response_bit = 0x8000;
enum Capability : uint32_t { ResidentBuffers = 1, SelectedViews = 2, AcknowledgedViews = 4, AlgebraicOnly = 8 };
enum Operation : uint16_t { Hello = 1, Load = 2, Derive = 3, View = 4, Ack = 5,
	Advance = 6, Cancel = 7, Shutdown = 8, Status = 9, Error = 0xffff };

struct Packet {
	uint16_t operation = 0;
	uint64_t session = 0;
	uint64_t request = 0;
	uint64_t generation = 0;
	std::vector<uint8_t> payload;
};

void put_u32(std::vector<uint8_t> &out, uint32_t value);
void put_u64(std::vector<uint8_t> &out, uint64_t value);
void put_double(std::vector<uint8_t> &out, double value);
void put_string(std::vector<uint8_t> &out, const std::string &value);
bool read(std::FILE *stream, Packet &out, bool &eof, std::string &err);
bool write(std::FILE *stream, const Packet &packet, std::string &err);

class Cursor {
	const std::vector<uint8_t> &bytes;
	size_t at = 0;
	bool take(size_t width, uint64_t &value);

public:
	explicit Cursor(const std::vector<uint8_t> &input) : bytes(input) {}
	bool u32(uint32_t &value);
	bool u64(uint64_t &value);
	bool number(double &value);
	bool string(std::string &value);
	bool empty() const { return at == bytes.size(); }
};

}
