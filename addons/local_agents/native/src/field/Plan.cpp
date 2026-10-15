#include "Plan.hpp"
#include "la/ContentHash.hpp"

#include <cstdio>
#include <cstring>

namespace la {
namespace {

const uint32_t kMagic = 0x4C50414CU; // 'LAPL'

struct Cursor {
	const std::vector<uint8_t> &in;
	size_t at = 0;
	bool ok = true;

	uint32_t u32() {
		uint32_t v = 0;
		if (!ok || at + 4 > in.size()) {
			ok = false;
			return 0;
		}
		std::memcpy(&v, in.data() + at, 4);
		at += 4;
		return v;
	}
	std::string str() {
		const uint32_t n = u32();
		if (!ok || at + n > in.size()) {
			ok = false;
			return std::string();
		}
		std::string s(reinterpret_cast<const char *>(in.data() + at), n);
		at += n;
		return s;
	}
	std::vector<uint8_t> blob(size_t n) {
		std::vector<uint8_t> out;
		if (!ok || at + n > in.size()) {
			ok = false;
			return out;
		}
		out.assign(in.begin() + long(at), in.begin() + long(at + n));
		at += n;
		return out;
	}
};

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

bool Plan::read(const std::string &path, Plan &out, std::string &err) {
	std::vector<uint8_t> bytes;
	if (!slurp(path, bytes, err)) { return false; }
	Cursor c{ bytes };
	if (c.u32() != kMagic) {
		err = path + " is not a recorded plan";
		return false;
	}
	out.version = c.u32();
	if (out.version != 1u) {
		err = path + " carries plan version " + std::to_string(out.version) + ", not 1";
		return false;
	}
	out.cells = c.u32();
	out.reduce_groups = c.u32();
	const uint32_t nbuf = c.u32();
	for (uint32_t i = 0; i < nbuf && c.ok; ++i) {
		PlanBuffer b;
		b.name = c.str();
		b.elems = c.u32();
		b.kind = c.u32();
		b.bytes = c.blob(size_t(b.elems) * 4u);
		out.buffers.push_back(std::move(b));
	}
	const uint32_t nsets = c.u32();
	for (uint32_t s = 0; s < nsets && c.ok; ++s) {
		PlanSet set;
		set.kernel = c.str();
		const uint32_t ne = c.u32();
		for (uint32_t e = 0; e < ne && c.ok; ++e) {
			PlanBind bind;
			bind.binding = c.u32();
			bind.buffer = c.u32();
			set.binds.push_back(bind);
		}
		out.sets.push_back(std::move(set));
	}
	const uint32_t nsteps = c.u32();
	for (uint32_t s = 0; s < nsteps && c.ok; ++s) {
		std::vector<PlanDispatch> step;
		const uint32_t nd = c.u32();
		for (uint32_t d = 0; d < nd && c.ok; ++d) {
			PlanDispatch p;
			p.kernel = c.str();
			p.set = c.u32();
			p.groups = c.u32();
			p.push = c.blob(c.u32());
			step.push_back(std::move(p));
		}
		out.steps.push_back(std::move(step));
	}
	const uint32_t nrows = c.u32();
	for (uint32_t r = 0; r < nrows && c.ok; ++r) {
		PlanRow row;
		row.key = c.str();
		row.fold = c.u32();
		out.rows.push_back(std::move(row));
	}
	if (!c.ok) {
		err = path + " is truncated";
		return false;
	}
	if (c.at != bytes.size()) {
		err = path + " carries " + std::to_string(bytes.size() - c.at) + " bytes past its own end";
		return false;
	}
	out.content_hash = la::content_hash(bytes.data(), bytes.size());
	return true;
}

int Plan::at(const std::string &name) const {
	for (size_t i = 0; i < buffers.size(); ++i) {
		if (buffers[i].name == name) { return int(i); }
	}
	return -1;
}

} // namespace la
