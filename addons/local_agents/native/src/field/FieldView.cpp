#include "ViewPublication.hpp"
#include "cli/ServiceProtocol.hpp"
#include <set>

namespace lasim {
namespace {

void put_text(std::vector<uint8_t> &out, const std::string &text) {
	wire::put_u32(out, uint32_t(text.size()));
	out.insert(out.end(), text.begin(), text.end());
}

}

bool prepare_view(FieldSession &session, uint64_t nonce, uint64_t generation, uint64_t sequence,
		uint64_t revision, double time_s, const std::vector<std::string> &fields,
		ViewDraft &out, std::string &err) {
	if (fields.empty()) { err = "VIEW_FIELDS_REQUIRED"; return false; }
	std::set<std::string> seen;
	for (const std::string &field : fields) {
		const int at = session.plan().at(field);
		if (at < 0 || !seen.insert(field).second || session.plan().buffers[size_t(at)].kind > 1) {
			err = "VIEW_INVALID_FIELD";
			return false;
		}
	}
	out = ViewDraft{generation, sequence, revision, time_s, fields, {}};
	auto &bytes = out.bytes;
	wire::put_u32(bytes, 0x5756414c); // LAVW
	wire::put_u32(bytes, 1);
	wire::put_u64(bytes, nonce);
	wire::put_u64(bytes, generation);
	wire::put_u64(bytes, sequence);
	wire::put_u64(bytes, revision);
	wire::put_double(bytes, time_s);
	wire::put_u32(bytes, session.metadata().cells);
	put_text(bytes, session.metadata().world_key);
	wire::put_u32(bytes, uint32_t(fields.size()));
	for (const std::string &field : fields) {
		const la::PlanBuffer &buffer = session.plan().buffers[size_t(session.plan().at(field))];
		put_text(bytes, field);
		wire::put_u32(bytes, buffer.kind);
		wire::put_u32(bytes, buffer.elems);
		const size_t offset = bytes.size();
		bytes.resize(offset + size_t(buffer.elems) * 4);
		if (!session.read_buffer(field, std::span<uint8_t>(bytes.data() + offset,
				size_t(buffer.elems) * 4), err)) { return false; }
	}
	return true;
}


}
