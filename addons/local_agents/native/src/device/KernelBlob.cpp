#include "la/KernelBlob.hpp"
#include "la/ContentHash.hpp"

#include <cstdio>
#include <cstring>

namespace la {
namespace {

constexpr char kMagic[8] = {'L', 'A', 'K', 'B', 'L', 'O', 'B', '\0'};
constexpr uint32_t kVersion = 1;


void put_u32(std::vector<uint8_t> &out, uint32_t v) {
	out.insert(out.end(), reinterpret_cast<uint8_t *>(&v), reinterpret_cast<uint8_t *>(&v) + 4);
}

void put_str(std::vector<uint8_t> &out, const std::string &s) {
	put_u32(out, static_cast<uint32_t>(s.size()));
	out.insert(out.end(), s.begin(), s.end());
}

class Cursor {
public:
	Cursor(const uint8_t *p, size_t n) : p_(p), n_(n) {}
	bool u32(uint32_t &v) {
		if (at_ + 4 > n_) { return false; }
		std::memcpy(&v, p_ + at_, 4);
		at_ += 4;
		return true;
	}
	bool str(std::string &s) {
		uint32_t len = 0;
		if (!u32(len) || at_ + len > n_) { return false; }
		s.assign(reinterpret_cast<const char *>(p_ + at_), len);
		at_ += len;
		return true;
	}
	bool words(std::vector<uint32_t> &w) {
		uint32_t count = 0;
		if (!u32(count) || at_ + size_t(count) * 4 > n_) { return false; }
		w.resize(count);
		if (count > 0) { std::memcpy(w.data(), p_ + at_, size_t(count) * 4); }
		at_ += size_t(count) * 4;
		return true;
	}
	bool done() const { return at_ == n_; }

private:
	const uint8_t *p_;
	size_t n_;
	size_t at_ = 0;
};

} // namespace

bool KernelBlob::write(const std::string &path, const KernelBlob &blob, std::string &err) {
	std::vector<uint8_t> body;
	put_u32(body, static_cast<uint32_t>(blob.kernels.size()));
	for (const BlobKernel &k : blob.kernels) {
		put_str(body, k.name);
		put_str(body, k.entry);
		put_str(body, k.msl);
		put_u32(body, k.local[0]);
		put_u32(body, k.local[1]);
		put_u32(body, k.local[2]);
		put_u32(body, k.push_size);
		put_u32(body, k.push_slot);
		put_u32(body, k.arg_slot);
		put_u32(body, static_cast<uint32_t>(k.spirv.size()));
		const uint8_t *sp = reinterpret_cast<const uint8_t *>(k.spirv.data());
		body.insert(body.end(), sp, sp + k.spirv.size() * 4);
		put_u32(body, static_cast<uint32_t>(k.bindings.size()));
		for (const BlobBinding &b : k.bindings) {
			put_u32(body, b.set);
			put_u32(body, b.binding);
			put_u32(body, b.slot);
			put_str(body, b.name);
		}
	}

	const uint64_t hash = la::content_hash(body.data(), body.size());
	FILE *fh = std::fopen(path.c_str(), "wb");
	if (fh == nullptr) {
		err = "cannot open " + path + " for writing";
		return false;
	}
	bool ok = std::fwrite(kMagic, 1, sizeof(kMagic), fh) == sizeof(kMagic);
	ok = ok && std::fwrite(&kVersion, 1, 4, fh) == 4;
	ok = ok && std::fwrite(&hash, 1, 8, fh) == 8;
	ok = ok && std::fwrite(body.data(), 1, body.size(), fh) == body.size();
	std::fclose(fh);
	if (!ok) {
		err = "short write to " + path;
		return false;
	}
	return true;
}

bool KernelBlob::read(const std::string &path, KernelBlob &blob, std::string &err) {
	FILE *fh = std::fopen(path.c_str(), "rb");
	if (fh == nullptr) {
		err = "no kernel blob at " + path + "; build it with lakc";
		return false;
	}
	std::vector<uint8_t> raw;
	uint8_t chunk[65536];
	size_t got = 0;
	while ((got = std::fread(chunk, 1, sizeof(chunk), fh)) > 0) {
		raw.insert(raw.end(), chunk, chunk + got);
	}
	std::fclose(fh);

	if (raw.size() < sizeof(kMagic) + 12 || std::memcmp(raw.data(), kMagic, sizeof(kMagic)) != 0) {
		err = path + " is not a kernel blob";
		return false;
	}
	uint32_t version = 0;
	uint64_t stored = 0;
	std::memcpy(&version, raw.data() + sizeof(kMagic), 4);
	std::memcpy(&stored, raw.data() + sizeof(kMagic) + 4, 8);
	if (version != kVersion) {
		err = path + " carries blob version " + std::to_string(version) + ", not "
				+ std::to_string(kVersion);
		return false;
	}
	const uint8_t *body = raw.data() + sizeof(kMagic) + 12;
	const size_t body_size = raw.size() - sizeof(kMagic) - 12;
	if (la::content_hash(body, body_size) != stored) {
		err = path + " does not hash to what it was written with; it is corrupt or truncated";
		return false;
	}

	Cursor cur(body, body_size);
	uint32_t count = 0;
	if (!cur.u32(count)) {
		err = path + " carries no kernel count";
		return false;
	}
	blob.kernels.clear();
	blob.kernels.resize(count);
	for (BlobKernel &k : blob.kernels) {
		uint32_t nbind = 0;
		bool ok = cur.str(k.name) && cur.str(k.entry) && cur.str(k.msl);
		ok = ok && cur.u32(k.local[0]) && cur.u32(k.local[1]) && cur.u32(k.local[2]);
		ok = ok && cur.u32(k.push_size) && cur.u32(k.push_slot) && cur.u32(k.arg_slot);
		ok = ok && cur.words(k.spirv) && cur.u32(nbind);
		if (!ok) {
			err = path + " ends inside a kernel record";
			return false;
		}
		k.bindings.resize(nbind);
		for (BlobBinding &b : k.bindings) {
			if (!(cur.u32(b.set) && cur.u32(b.binding) && cur.u32(b.slot) && cur.str(b.name))) {
				err = path + " ends inside a binding record";
				return false;
			}
		}
	}
	if (!cur.done()) {
		err = path + " carries bytes past its last kernel";
		return false;
	}
	blob.content_hash = la::content_hash(raw.data(), raw.size());
	return true;
}

} // namespace la
