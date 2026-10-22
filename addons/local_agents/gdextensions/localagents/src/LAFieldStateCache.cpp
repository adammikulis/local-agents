#include "LAFieldStateCache.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <filesystem>
#include <system_error>
#include <vector>

using namespace godot;

namespace {

const char *MASK_DIR = "user://la_solid_cache";
const char *STATE_DIR = "user://la_field_cache";
const char *PURE_DIR = "user://la_pure_cache";
const char *BOUND_PATH = "res://docs/FIELD_CACHE_BYTES";
const char *CONSTANTS_GD = "res://addons/local_agents/sim/material/PhysicalConstants.gd";
std::atomic<int> g_pure_hits{ 0 };

String entry_path(const String &p_dir, const String &p_key) {
	return p_dir + String("/") + p_key + String(".bin");
}

void ensure_dir(const String &p_dir) {
	DirAccess::make_dir_recursive_absolute(ProjectSettings::get_singleton()->globalize_path(p_dir));
}

std::filesystem::path native_path(const String &p_path) {
	return std::filesystem::u8path(ProjectSettings::get_singleton()->globalize_path(p_path).utf8().get_data());
}

// Recency of use is the entry's mtime: a hit sets it to now.
void touch(const String &p_path) {
	std::error_code ec;
	std::filesystem::last_write_time(native_path(p_path), std::filesystem::file_time_type::clock::now(), ec);
}

// Entries of p_dir, least recently used first, removed until the directory holds at most p_max_bytes.
int evict(const String &p_dir, int64_t p_max_bytes, const String &p_keep_file) {
	namespace fs = std::filesystem;
	struct Entry {
		fs::file_time_type mtime;
		uintmax_t size;
		fs::path path;
	};
	std::vector<Entry> entries;
	uintmax_t total = 0;
	std::error_code ec;
	for (fs::directory_iterator it(native_path(p_dir), ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
		std::error_code stat_ec;
		if (!it->is_regular_file(stat_ec) || it->path().extension() != ".bin") {
			continue;
		}
		const Entry e{ it->last_write_time(stat_ec), it->file_size(stat_ec), it->path() };
		if (!stat_ec) {
			total += e.size;
			entries.push_back(e);
		}
	}
	std::sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) {
		return a.mtime != b.mtime ? a.mtime < b.mtime : a.path < b.path;
	});
	const fs::path keep = fs::u8path(p_keep_file.utf8().get_data());
	int removed = 0;
	for (const Entry &e : entries) {
		if (total <= uintmax_t(p_max_bytes)) {
			break;
		}
		if (e.path.filename() == keep) {
			continue;
		}
		std::error_code rm_ec;
		fs::remove(e.path, rm_ec);
		total -= e.size;
		removed++;
	}
	return removed;
}

// What every pure native function here is a function of besides its arguments. Empty where either file
// cannot be read, and an empty basis addresses nothing.
const String &pure_basis() {
	static const String basis = []() -> String {
		Ref<FileAccess> hf = FileAccess::open(
				"res://addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH", FileAccess::READ);
		Ref<FileAccess> pc = FileAccess::open(CONSTANTS_GD, FileAccess::READ);
		if (hf.is_null() || pc.is_null()) {
			return String();
		}
		return hf->get_as_text() + String("\n") + pc->get_as_text().sha256_text();
	}();
	return basis;
}

String pure_path(const String &p_name, const PackedFloat64Array &p_in) {
	const String &basis = pure_basis();
	if (basis.is_empty()) {
		return String();
	}
	PackedStringArray parts;
	parts.append(p_name);
	parts.append(basis);
	for (int i = 0; i < p_in.size(); i++) {
		const double v = p_in[i];
		uint64_t bits = 0;
		std::memcpy(&bits, &v, sizeof(bits));
		parts.append(String::num_uint64(bits, 16));
	}
	return entry_path(PURE_DIR, String("\n").join(parts).sha256_text());
}

bool same_bits(const PackedFloat64Array &p_a, const PackedFloat64Array &p_b) {
	return p_a.size() == p_b.size()
			&& (p_a.is_empty() || std::memcmp(p_a.ptr(), p_b.ptr(), size_t(p_a.size()) * sizeof(double)) == 0);
}

} // namespace

PackedFloat64Array LAFieldStateCache::pure_load(const String &p_name, const PackedFloat64Array &p_in) {
	const String path = pure_path(p_name, p_in);
	if (path.is_empty()) {
		return PackedFloat64Array();
	}
	Ref<FileAccess> f = FileAccess::open(path, FileAccess::READ);
	if (f.is_null()) {
		return PackedFloat64Array();
	}
	const Variant raw = f->get_var();
	if (raw.get_type() != Variant::DICTIONARY) {
		return PackedFloat64Array();
	}
	const Dictionary data = raw;
	// The file names its own arguments, so a file that is not this call's is not served as one.
	if (!same_bits(data.get("in", PackedFloat64Array()), p_in)) {
		return PackedFloat64Array();
	}
	const PackedFloat64Array out = data.get("out", PackedFloat64Array());
	if (!out.is_empty()) {
		g_pure_hits.fetch_add(1);
	}
	return out;
}

void LAFieldStateCache::pure_store(const String &p_name, const PackedFloat64Array &p_in,
		const PackedFloat64Array &p_out) {
	const String path = pure_path(p_name, p_in);
	if (path.is_empty() || p_out.is_empty()) {
		return;
	}
	ensure_dir(PURE_DIR);
	// Written whole under another name and renamed, so a reader in another process never sees half a file.
	const String staging = path + String(".") + itos(OS::get_singleton()->get_process_id()) + String(".tmp");
	Ref<FileAccess> f = FileAccess::open(staging, FileAccess::WRITE);
	if (f.is_null()) {
		return;
	}
	Dictionary data;
	data["in"] = p_in;
	data["out"] = p_out;
	f->store_var(data);
	f->close();
	DirAccess::rename_absolute(ProjectSettings::get_singleton()->globalize_path(staging),
			ProjectSettings::get_singleton()->globalize_path(path));
}

int LAFieldStateCache::pure_hits() {
	return g_pure_hits.load();
}

void LAFieldStateCache::pure_clear() {
	Ref<DirAccess> dir = DirAccess::open(PURE_DIR);
	if (dir.is_null()) {
		return;
	}
	for (const String &name : dir->get_files()) {
		dir->remove(name);
	}
}

String LAFieldStateCache::mask_key(const Dictionary &p_opts, int p_nx, int p_ny, int p_nz, double p_cell,
		const Vector3 &p_origin, const PackedStringArray &p_sources) {
	PackedStringArray parts;
	Array names = p_opts.keys();
	names.sort();
	for (int i = 0; i < names.size(); i++) {
		const String k = names[i];
		// view_distance changes how much terrain is streamed, never what the SDF says at a point.
		if (k == "view_distance") {
			continue;
		}
		parts.append(k + String("=") + String(p_opts[names[i]]));
	}
	parts.append(String("dims=") + itos(p_nx) + "," + itos(p_ny) + "," + itos(p_nz));
	parts.append(String("cell=") + String::num(p_cell, 6));
	parts.append(String("origin=") + String::num(p_origin.x, 4) + "," + String::num(p_origin.y, 4) + "," +
			String::num(p_origin.z, 4));
	for (int i = 0; i < p_sources.size(); i++) {
		Ref<FileAccess> src = FileAccess::open(p_sources[i], FileAccess::READ);
		if (src.is_null()) {
			return String();
		}
		parts.append(p_sources[i] + String("=") + src->get_as_text().sha256_text());
	}
	// The walks this key stands for are NATIVE, so a rebuilt extension is a different walk.
	Ref<FileAccess> hf = FileAccess::open(
			"res://addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH", FileAccess::READ);
	if (hf.is_null()) {
		return String();
	}
	parts.append(String("ext=") + hf->get_as_text());
	return String("\n").join(parts).sha256_text();
}

String LAFieldStateCache::state_key(const String &p_tree_key, int p_nx, int p_ny, int p_nz, double p_cell,
		const Vector3 &p_origin) {
	if (p_tree_key.is_empty()) {
		return String();
	}
	PackedStringArray parts;
	parts.append(p_tree_key);
	parts.append(String("dims=") + itos(p_nx) + "," + itos(p_ny) + "," + itos(p_nz));
	parts.append(String("cell=") + String::num(p_cell, 6));
	parts.append(String("origin=") + String::num(p_origin.x, 4) + "," + String::num(p_origin.y, 4) + "," +
			String::num(p_origin.z, 4));
	return String("\n").join(parts).sha256_text();
}

namespace {

Dictionary read_entry(const String &p_path) {
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::READ);
	if (f.is_null()) {
		return Dictionary();
	}
	const Variant raw = f->get_var();
	return raw.get_type() == Variant::DICTIONARY ? Dictionary(raw) : Dictionary();
}

} // namespace

Dictionary LAFieldStateCache::load_state(const String &p_key, int p_cell_count) {
	if (p_key.is_empty()) {
		return Dictionary();
	}
	const String path = entry_path(STATE_DIR, p_key);
	const Dictionary data = read_entry(path);
	const PackedByteArray snapshot = data.get("snapshot", PackedByteArray());
	if (int(data.get("cell_count", -1)) != p_cell_count || snapshot.is_empty()) {
		return Dictionary();
	}
	touch(path);
	return data;
}

Dictionary LAFieldStateCache::load_from(const String &p_dir, const String &p_key) {
	if (p_key.is_empty()) {
		return Dictionary();
	}
	const String path = entry_path(p_dir, p_key);
	const Dictionary data = read_entry(path);
	if (!data.is_empty()) {
		touch(path);
	}
	return data;
}

Dictionary LAFieldStateCache::load_blob(const String &p_key) {
	return load_from(STATE_DIR, p_key);
}

void LAFieldStateCache::save_blob(const String &p_key, const Dictionary &p_data) {
	save_state(p_key, p_data);
}

int64_t LAFieldStateCache::declared_bound() {
	Ref<FileAccess> f = FileAccess::open(BOUND_PATH, FileAccess::READ);
	if (f.is_null()) {
		return -1;
	}
	while (!f->eof_reached()) {
		const String line = f->get_line().strip_edges();
		if (line.is_valid_int()) {
			return line.to_int();
		}
	}
	return -1;
}

int LAFieldStateCache::save_into(const String &p_dir, const String &p_key, const Dictionary &p_data,
		int64_t p_max_bytes) {
	if (p_key.is_empty() || p_data.is_empty()) {
		return 0;
	}
	ensure_dir(p_dir);
	{
		Ref<FileAccess> f = FileAccess::open(entry_path(p_dir, p_key), FileAccess::WRITE);
		if (f.is_null()) {
			return 0;
		}
		f->store_var(p_data);
	}
	return evict(p_dir, p_max_bytes, p_key + String(".bin"));
}

// A store with no declared bound grows without one, so it writes nothing and names the absence.
void LAFieldStateCache::save_state(const String &p_key, const Dictionary &p_data) {
	const int64_t bound = declared_bound();
	if (bound < 0) {
		ERR_PRINT("FIELD_CACHE_BOUND_ABSENT: docs/FIELD_CACHE_BYTES declares no bound, so nothing is stored.");
		return;
	}
	save_into(STATE_DIR, p_key, p_data, bound);
}

void LAFieldStateCache::_bind_methods() {
	ClassDB::bind_static_method("LAFieldStateCache",
			D_METHOD("mask_key", "opts", "nx", "ny", "nz", "cell", "origin", "sources"),
			&LAFieldStateCache::mask_key);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("load_blob", "key"), &LAFieldStateCache::load_blob);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("save_blob", "key", "data"), &LAFieldStateCache::save_blob);
	ClassDB::bind_static_method("LAFieldStateCache",
			D_METHOD("state_key", "tree_key", "nx", "ny", "nz", "cell", "origin"),
			&LAFieldStateCache::state_key);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("load_state", "key", "cell_count"),
			&LAFieldStateCache::load_state);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("save_state", "key", "data"),
			&LAFieldStateCache::save_state);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("save_into", "dir", "key", "data", "max_bytes"),
			&LAFieldStateCache::save_into);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("load_from", "dir", "key"),
			&LAFieldStateCache::load_from);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("declared_bound"), &LAFieldStateCache::declared_bound);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("pure_hits"), &LAFieldStateCache::pure_hits);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("pure_clear"), &LAFieldStateCache::pure_clear);
}
