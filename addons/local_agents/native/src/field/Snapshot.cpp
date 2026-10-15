#include "Snapshot.hpp"
#include "la/ContentHash.hpp"

#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace la {
namespace {

const uint32_t kMagic = 0x5346414CU; // 'LAFS'

bool take_u32(const std::vector<uint8_t> &in, size_t &at, uint32_t &v) {
	if (at + 4 > in.size()) { return false; }
	std::memcpy(&v, in.data() + at, 4);
	at += 4;
	return true;
}

bool take_string(const std::vector<uint8_t> &in, size_t &at, std::string &s) {
	uint32_t len = 0;
	if (!take_u32(in, at, len)) { return false; }
	if (at + len > in.size()) { return false; }
	s.assign(reinterpret_cast<const char *>(in.data() + at), len);
	at += len;
	return true;
}

bool slurp(const std::string &path, std::vector<uint8_t> &out, std::string &err) {
	std::FILE *f = std::fopen(path.c_str(), "rb");
	if (f == nullptr) {
		err = "cannot open " + path;
		return false;
	}
	std::fseek(f, 0, SEEK_END);
	const long n = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	if (n < 0) {
		std::fclose(f);
		err = "cannot size " + path;
		return false;
	}
	out.resize(size_t(n));
	const size_t got = n > 0 ? std::fread(out.data(), 1, size_t(n), f) : 0;
	std::fclose(f);
	if (got != out.size()) {
		err = "short read of " + path;
		return false;
	}
	return true;
}

} // namespace

bool Snapshot::read(const std::string &path, Snapshot &out, std::string &err) {
	std::vector<uint8_t> bytes;
	if (!slurp(path, bytes, err)) { return false; }
	size_t at = 0;
	uint32_t magic = 0;
	uint32_t count = 0;
	if (!take_u32(bytes, at, magic) || magic != kMagic) {
		err = path + " is not a field snapshot";
		return false;
	}
	if (!take_u32(bytes, at, out.version) || out.version != 1u) {
		err = path + " carries layout version " + std::to_string(out.version) + ", not 1";
		return false;
	}
	if (!take_u32(bytes, at, out.cells) || !take_u32(bytes, at, count) ||
			!take_string(bytes, at, out.world_key)) {
		err = path + " has a truncated header";
		return false;
	}
	for (uint32_t i = 0; i < count; ++i) {
		std::string name;
		if (!take_string(bytes, at, name)) {
			err = path + " has truncated channel names";
			return false;
		}
		out.names.push_back(name);
	}
	const size_t want = size_t(out.cells) * size_t(count) * 4u;
	if (bytes.size() - at != want) {
		err = path + " holds " + std::to_string(bytes.size() - at) + " cell bytes against " +
				std::to_string(want);
		return false;
	}
	out.data.resize(size_t(out.cells) * size_t(count));
	if (want > 0) { std::memcpy(out.data.data(), bytes.data() + at, want); }
	out.content_hash = la::content_hash(bytes.data(), bytes.size());
	return true;
}

bool Snapshot::write(const std::string &path, const Snapshot &in, std::string &err) {
	std::FILE *f = std::fopen(path.c_str(), "wb");
	if (f == nullptr) {
		err = "cannot write " + path;
		return false;
	}
	auto put_u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
	auto put_string = [&](const std::string &s) {
		put_u32(uint32_t(s.size()));
		if (!s.empty()) { std::fwrite(s.data(), 1, s.size(), f); }
	};
	put_u32(kMagic);
	put_u32(1u);
	put_u32(in.cells);
	put_u32(uint32_t(in.names.size()));
	put_string(in.world_key);
	for (const std::string &n : in.names) { put_string(n); }
	if (!in.data.empty()) { std::fwrite(in.data.data(), 4, in.data.size(), f); }
	const bool ok = std::ferror(f) == 0;
	std::fclose(f);
	if (!ok) { err = "short write of " + path; }
	return ok;
}

int Snapshot::at(const std::string &name) const {
	for (size_t i = 0; i < names.size(); ++i) {
		if (names[i] == name) { return int(i); }
	}
	return -1;
}

const float *Snapshot::channel(const std::string &name) const {
	const int i = at(name);
	return i < 0 ? nullptr : data.data() + size_t(i) * size_t(cells);
}

bool WorldKey::parse(const std::string &key, WorldKey &out, std::string &err) {
	// nx,ny,nz,cell_size,ox/oy/oz,cell_count,max_level
	std::vector<std::string> parts;
	std::string cur;
	for (char c : key) {
		if (c == ',' || c == '/') {
			parts.push_back(cur);
			cur.clear();
		} else {
			cur.push_back(c);
		}
	}
	parts.push_back(cur);
	if (parts.size() != 9) {
		err = "the snapshot's world key has " + std::to_string(parts.size()) + " fields, not 9: " + key;
		return false;
	}
	out.nx = std::strtoll(parts[0].c_str(), nullptr, 10);
	out.ny = std::strtoll(parts[1].c_str(), nullptr, 10);
	out.nz = std::strtoll(parts[2].c_str(), nullptr, 10);
	out.cell_size = std::strtod(parts[3].c_str(), nullptr);
	out.ox = std::strtod(parts[4].c_str(), nullptr);
	out.oy = std::strtod(parts[5].c_str(), nullptr);
	out.oz = std::strtod(parts[6].c_str(), nullptr);
	out.cell_count = std::strtoll(parts[7].c_str(), nullptr, 10);
	out.max_level = std::strtoll(parts[8].c_str(), nullptr, 10);
	return true;
}

} // namespace la
