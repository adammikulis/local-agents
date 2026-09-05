#include "LAFieldSnapshot.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

namespace {

const uint32_t MAGIC = 0x5346414CU; // 'LAFS' little-endian

void put_u32(PackedByteArray &p_out, uint32_t p_v) {
	const int at = p_out.size();
	p_out.resize(at + 4);
	uint8_t *w = p_out.ptrw() + at;
	w[0] = uint8_t(p_v & 0xFF);
	w[1] = uint8_t((p_v >> 8) & 0xFF);
	w[2] = uint8_t((p_v >> 16) & 0xFF);
	w[3] = uint8_t((p_v >> 24) & 0xFF);
}

bool take_u32(const PackedByteArray &p_in, int &p_at, uint32_t &p_v) {
	if (p_at < 0 || p_at + 4 > p_in.size()) {
		return false;
	}
	const uint8_t *r = p_in.ptr() + p_at;
	p_v = uint32_t(r[0]) | (uint32_t(r[1]) << 8) | (uint32_t(r[2]) << 16) | (uint32_t(r[3]) << 24);
	p_at += 4;
	return true;
}

void put_string(PackedByteArray &p_out, const String &p_s) {
	const PackedByteArray b = p_s.to_utf8_buffer();
	put_u32(p_out, uint32_t(b.size()));
	p_out.append_array(b);
}

bool take_string(const PackedByteArray &p_in, int &p_at, String &p_s) {
	uint32_t len = 0;
	if (!take_u32(p_in, p_at, len)) {
		return false;
	}
	if (p_at + int(len) > p_in.size()) {
		return false;
	}
	p_s = p_in.slice(p_at, p_at + int(len)).get_string_from_utf8();
	p_at += int(len);
	return true;
}

// The field's CPU copy of a channel: `_` and the channel's own name, the two energy channels under the
// shorter names the field holds them by.
String mirror_of(const String &p_name) {
	if (p_name == "e_j_m3") {
		return "_e";
	}
	if (p_name == "e_lith_j_m3") {
		return "_e_lith";
	}
	return "_" + p_name;
}

} // namespace

void LAFieldSnapshot::bind(RenderingDevice *p_rd, const Dictionary &p_bufs, const PackedStringArray &p_names,
		int p_cell_count, Object *p_grid) {
	_rd = p_rd;
	_cc = p_cell_count;
	_world_key = world_key_of(p_grid);
	_names = PackedStringArray();
	_rids.clear();
	for (int i = 0; i < p_names.size(); i++) {
		const String name = p_names[i];
		if (!p_bufs.has(name)) {
			continue;
		}
		const RID rid = p_bufs[name];
		if (!rid.is_valid()) {
			continue;
		}
		_names.append(name);
		_rids.push_back(rid);
	}
}

String LAFieldSnapshot::world_key_of(Object *p_grid) {
	if (p_grid == nullptr) {
		return String();
	}
	const Vector3 origin = p_grid->get("origin");
	PackedStringArray parts;
	parts.append(itos(int64_t(p_grid->get("nx"))));
	parts.append(itos(int64_t(p_grid->get("ny"))));
	parts.append(itos(int64_t(p_grid->get("nz"))));
	parts.append(String::num(double(p_grid->get("cell_size")), 6));
	parts.append(String::num(origin.x, 4) + "/" + String::num(origin.y, 4) + "/" + String::num(origin.z, 4));
	parts.append(itos(int64_t(p_grid->get("cell_count"))));
	parts.append(itos(int64_t(p_grid->get("max_level"))));
	return String(",").join(parts);
}

int LAFieldSnapshot::capture() {
	if (_rd == nullptr || _cc <= 0 || _rids.empty()) {
		return -1;
	}
	Snap s;
	s.cc = _cc;
	s.world_key = _world_key;
	s.names = _names;
	const int stride = _cc * 4;
	s.data.resize(int64_t(stride) * int64_t(_rids.size()));
	uint8_t *w = s.data.ptrw();
	for (size_t i = 0; i < _rids.size(); i++) {
		const PackedByteArray block = _rd->buffer_get_data(_rids[i], 0, uint32_t(stride));
		if (block.size() != stride) {
			UtilityFunctions::push_error("LAFieldSnapshot: channel '" + String(_names[int(i)]) +
					"' read back " + itos(block.size()) + " bytes against " + itos(stride) + ".");
			return -1;
		}
		memcpy(w + int64_t(stride) * int64_t(i), block.ptr(), size_t(stride));
	}
	return store(std::move(s));
}

int LAFieldSnapshot::blank() {
	if (_cc <= 0 || _rids.empty()) {
		return -1;
	}
	Snap s;
	s.cc = _cc;
	s.world_key = _world_key;
	s.names = _names;
	const int64_t bytes = int64_t(_cc) * 4 * int64_t(_rids.size());
	s.data.resize(bytes);
	memset(s.data.ptrw(), 0, size_t(bytes));
	return store(std::move(s));
}

bool LAFieldSnapshot::restore(int p_handle) {
	const Snap *s = find(p_handle);
	if (s == nullptr || _rd == nullptr) {
		return false;
	}
	if (s->cc != _cc || s->world_key != _world_key) {
		UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"another world\", held:\"" + s->world_key +
				"\", cells_held:" + itos(s->cc) + ", live:\"" + _world_key + "\", cells_live:" + itos(_cc) + "}");
		return false;
	}
	const int stride = _cc * 4;
	for (int i = 0; i < s->names.size(); i++) {
		const String name = s->names[i];
		int at = -1;
		for (int j = 0; j < _names.size(); j++) {
			if (String(_names[j]) == name) {
				at = j;
				break;
			}
		}
		if (at < 0) {
			UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"channel absent\", channel:\"" + name + "\"}");
			return false;
		}
		const PackedByteArray block = s->data.slice(int64_t(stride) * int64_t(i), int64_t(stride) * int64_t(i + 1));
		_rd->buffer_update(_rids[size_t(at)], 0, uint32_t(stride), block);
	}
	return true;
}

int LAFieldSnapshot::apply_mirrors(int p_handle, Object *p_field) {
	const Snap *s = find(p_handle);
	if (s == nullptr || p_field == nullptr) {
		return 0;
	}
	const int stride = s->cc * 4;
	int applied = 0;
	for (int i = 0; i < s->names.size(); i++) {
		const StringName key = StringName(mirror_of(s->names[i]));
		const Variant held = p_field->get(key);
		if (held.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			continue;
		}
		if (PackedFloat32Array(held).size() != s->cc) {
			continue;
		}
		PackedFloat32Array out;
		out.resize(s->cc);
		memcpy((uint8_t *)out.ptrw(), s->data.ptr() + int64_t(stride) * int64_t(i), size_t(stride));
		p_field->set(key, out);
		applied++;
	}
	return applied;
}

void LAFieldSnapshot::ring(int p_cap) {
	_cap = p_cap < 0 ? 0 : p_cap;
	while (_cap > 0 && int(_order.size()) > _cap) {
		_snaps.erase(_order.front());
		_order.erase(_order.begin());
	}
}

void LAFieldSnapshot::drop(int p_handle) {
	if (_snaps.erase(p_handle) == 0) {
		return;
	}
	for (size_t i = 0; i < _order.size(); i++) {
		if (_order[i] == p_handle) {
			_order.erase(_order.begin() + int(i));
			break;
		}
	}
}

bool LAFieldSnapshot::has(int p_handle) const {
	return find(p_handle) != nullptr;
}

int LAFieldSnapshot::size() const {
	return int(_order.size());
}

int64_t LAFieldSnapshot::snapshot_bytes() const {
	return int64_t(_cc) * 4 * int64_t(_names.size());
}

int LAFieldSnapshot::cell_count(int p_handle) const {
	const Snap *s = find(p_handle);
	return s == nullptr ? -1 : s->cc;
}

PackedStringArray LAFieldSnapshot::channels(int p_handle) const {
	const Snap *s = find(p_handle);
	return s == nullptr ? PackedStringArray() : s->names;
}

String LAFieldSnapshot::world_key(int p_handle) const {
	const Snap *s = find(p_handle);
	return s == nullptr ? String() : s->world_key;
}

Dictionary LAFieldSnapshot::totals(int p_handle) const {
	Dictionary out;
	const Snap *s = find(p_handle);
	if (s == nullptr) {
		return out;
	}
	for (int i = 0; i < s->names.size(); i++) {
		const uint8_t *r = s->data.ptr() + int64_t(s->cc) * 4 * int64_t(i);
		double sum = 0.0;
		for (int c = 0; c < s->cc; c++) {
			float v = 0.0f;
			memcpy(&v, r + int64_t(c) * 4, 4);
			sum += double(v);
		}
		out[s->names[i]] = sum;
	}
	return out;
}

Dictionary LAFieldSnapshot::compare(int p_a, int p_b) const {
	Dictionary out;
	const Snap *a = find(p_a);
	const Snap *b = find(p_b);
	PackedStringArray differ;
	if (a == nullptr || b == nullptr) {
		out["cells"] = -1;
		out["channels"] = differ;
		return out;
	}
	int64_t cells = 0;
	for (int i = 0; i < a->names.size(); i++) {
		const String name = a->names[i];
		const int at = offset_of(*b, name);
		if (at < 0 || a->cc != b->cc) {
			differ.append(name);
			cells += a->cc;
			continue;
		}
		const uint8_t *ra = a->data.ptr() + int64_t(a->cc) * 4 * int64_t(i);
		const uint8_t *rb = b->data.ptr() + int64_t(b->cc) * 4 * int64_t(at);
		int64_t here = 0;
		for (int c = 0; c < a->cc; c++) {
			if (memcmp(ra + int64_t(c) * 4, rb + int64_t(c) * 4, 4) != 0) {
				here++;
			}
		}
		if (here > 0) {
			differ.append(name);
			cells += here;
		}
	}
	for (int i = 0; i < b->names.size(); i++) {
		if (offset_of(*a, b->names[i]) < 0) {
			differ.append(b->names[i]);
			cells += b->cc;
		}
	}
	out["cells"] = cells;
	out["channels"] = differ;
	return out;
}

PackedByteArray LAFieldSnapshot::serialize(int p_handle) const {
	PackedByteArray out;
	const Snap *s = find(p_handle);
	if (s == nullptr) {
		return out;
	}
	put_u32(out, MAGIC);
	put_u32(out, uint32_t(LAYOUT_VERSION));
	put_u32(out, uint32_t(s->cc));
	put_u32(out, uint32_t(s->names.size()));
	put_string(out, s->world_key);
	for (int i = 0; i < s->names.size(); i++) {
		put_string(out, s->names[i]);
	}
	out.append_array(s->data);
	return out;
}

int LAFieldSnapshot::deserialize(const PackedByteArray &p_bytes) {
	int at = 0;
	uint32_t magic = 0;
	uint32_t version = 0;
	uint32_t cc = 0;
	uint32_t count = 0;
	if (!take_u32(p_bytes, at, magic) || magic != MAGIC) {
		UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"not a field snapshot\"}");
		return -1;
	}
	if (!take_u32(p_bytes, at, version) || int(version) != LAYOUT_VERSION) {
		UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"layout\", held:" + itos(int(version)) +
				", reads:" + itos(LAYOUT_VERSION) + "}");
		return -1;
	}
	Snap s;
	if (!take_u32(p_bytes, at, cc) || !take_u32(p_bytes, at, count) || !take_string(p_bytes, at, s.world_key)) {
		UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"truncated header\"}");
		return -1;
	}
	s.cc = int(cc);
	for (uint32_t i = 0; i < count; i++) {
		String name;
		if (!take_string(p_bytes, at, name)) {
			UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"truncated channel names\"}");
			return -1;
		}
		s.names.append(name);
	}
	const int64_t want = int64_t(s.cc) * 4 * int64_t(count);
	if (int64_t(p_bytes.size()) - int64_t(at) != want) {
		UtilityFunctions::print("SNAPSHOT_REFUSED={reason:\"truncated cells\", holds:" +
				itos(p_bytes.size() - at) + ", wants:" + itos(want) + "}");
		return -1;
	}
	s.data = p_bytes.slice(at);
	return store(std::move(s));
}

const LAFieldSnapshot::Snap *LAFieldSnapshot::find(int p_handle) const {
	const auto it = _snaps.find(p_handle);
	return it == _snaps.end() ? nullptr : &it->second;
}

int LAFieldSnapshot::store(Snap &&p_snap) {
	const int handle = _next++;
	_snaps.emplace(handle, std::move(p_snap));
	_order.push_back(handle);
	while (_cap > 0 && int(_order.size()) > _cap) {
		_snaps.erase(_order.front());
		_order.erase(_order.begin());
	}
	return handle;
}

int LAFieldSnapshot::offset_of(const Snap &p_snap, const String &p_name) const {
	for (int i = 0; i < p_snap.names.size(); i++) {
		if (String(p_snap.names[i]) == p_name) {
			return i;
		}
	}
	return -1;
}

void LAFieldSnapshot::_bind_methods() {
	ClassDB::bind_method(D_METHOD("bind", "rd", "bufs", "names", "cell_count", "grid"), &LAFieldSnapshot::bind);
	ClassDB::bind_method(D_METHOD("capture"), &LAFieldSnapshot::capture);
	ClassDB::bind_method(D_METHOD("blank"), &LAFieldSnapshot::blank);
	ClassDB::bind_method(D_METHOD("restore", "handle"), &LAFieldSnapshot::restore);
	ClassDB::bind_method(D_METHOD("apply_mirrors", "handle", "field"), &LAFieldSnapshot::apply_mirrors);
	ClassDB::bind_method(D_METHOD("ring", "cap"), &LAFieldSnapshot::ring);
	ClassDB::bind_method(D_METHOD("drop", "handle"), &LAFieldSnapshot::drop);
	ClassDB::bind_method(D_METHOD("has", "handle"), &LAFieldSnapshot::has);
	ClassDB::bind_method(D_METHOD("size"), &LAFieldSnapshot::size);
	ClassDB::bind_method(D_METHOD("snapshot_bytes"), &LAFieldSnapshot::snapshot_bytes);
	ClassDB::bind_method(D_METHOD("cell_count", "handle"), &LAFieldSnapshot::cell_count);
	ClassDB::bind_method(D_METHOD("channels", "handle"), &LAFieldSnapshot::channels);
	ClassDB::bind_method(D_METHOD("world_key", "handle"), &LAFieldSnapshot::world_key);
	ClassDB::bind_method(D_METHOD("totals", "handle"), &LAFieldSnapshot::totals);
	ClassDB::bind_method(D_METHOD("compare", "a", "b"), &LAFieldSnapshot::compare);
	ClassDB::bind_method(D_METHOD("serialize", "handle"), &LAFieldSnapshot::serialize);
	ClassDB::bind_method(D_METHOD("deserialize", "bytes"), &LAFieldSnapshot::deserialize);
	ClassDB::bind_integer_constant("LAFieldSnapshot", StringName(), "LAYOUT_VERSION", LAYOUT_VERSION);
}
