#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace la {

// LAFieldSnapshot's save layout, version 1: 'LAFS', u32 version, u32 cell_count, u32 channel_count,
// length-prefixed world key, length-prefixed channel names, channel-major f32 cells.
struct Snapshot {
	uint64_t content_hash = 0;
	uint32_t version = 0;
	uint32_t cells = 0;
	std::string world_key;
	std::vector<std::string> names;
	std::vector<float> data; // names.size() * cells, channel-major

	static bool read(const std::string &path, Snapshot &out, std::string &err);
	static bool write(const std::string &path, const Snapshot &in, std::string &err);

	// Index of a channel, or -1.
	int at(const std::string &name) const;
	const float *channel(const std::string &name) const;
};

// The world key's fields, in the order LAFieldSnapshot::world_key_of joins them.
struct WorldKey {
	int64_t nx = 0;
	int64_t ny = 0;
	int64_t nz = 0;
	double cell_size = 0.0;
	double ox = 0.0;
	double oy = 0.0;
	double oz = 0.0;
	int64_t cell_count = 0;
	int64_t max_level = 0;

	static bool parse(const std::string &key, WorldKey &out, std::string &err);
};

} // namespace la
