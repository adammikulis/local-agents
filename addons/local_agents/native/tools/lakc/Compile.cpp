#include "Compile.hpp"

#include <glslang/Public/ResourceLimits.h>
#include <glslang/Public/ShaderLang.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <sstream>

namespace lakc {
namespace {

// Set 0's argument buffer, and the push constant block, each take one Metal buffer slot.
constexpr uint32_t kArgBufferSlot = 0;
constexpr uint32_t kPushSlot = 1;

bool read_file(const std::string &path, std::string &out) {
	std::ifstream in(path, std::ios::binary);
	if (!in) { return false; }
	std::ostringstream ss;
	ss << in.rdbuf();
	out = ss.str();
	return true;
}

// Godot's importer eats a leading `#[compute]`; glslang does not. Blanked rather than removed, so every
// line number glslang reports is the line number in the file on disk.
std::string strip_import_marker(const std::string &src) {
	std::string out = src;
	size_t at = 0;
	while (at < out.size()) {
		size_t eol = out.find('\n', at);
		if (eol == std::string::npos) { eol = out.size(); }
		if (out.compare(at, 2, "#[") == 0) { out.replace(at, eol - at, eol - at, ' '); }
		at = eol + 1;
	}
	return out;
}

class DirIncluder : public glslang::TShader::Includer {
public:
	explicit DirIncluder(std::string dir) : dir_(std::move(dir)) {}

	IncludeResult *includeLocal(const char *header, const char *, size_t) override {
		return open(header);
	}
	IncludeResult *includeSystem(const char *header, const char *, size_t) override {
		return open(header);
	}
	void releaseInclude(IncludeResult *result) override {
		if (result == nullptr) { return; }
		delete[] static_cast<char *>(result->userData);
		delete result;
	}

private:
	IncludeResult *open(const char *header) {
		std::string text;
		const std::string path = dir_ + "/" + header;
		if (!read_file(path, text)) { return nullptr; }
		char *data = new char[text.size()];
		std::copy(text.begin(), text.end(), data);
		return new IncludeResult(path, data, text.size(), data);
	}

	std::string dir_;
};

// The MSL SPIRV-Cross emitted, read back for what it actually did: the [[id]] of every argument-buffer
// member, and every Metal buffer slot the entry point takes. The bake asserts these rather than assuming.
struct MslLayout {
	std::vector<uint32_t> ids;
	std::vector<uint32_t> entry_slots;
};

uint32_t read_uint(const std::string &text, size_t at) {
	uint32_t v = 0;
	while (at < text.size() && text[at] >= '0' && text[at] <= '9') {
		v = v * 10 + static_cast<uint32_t>(text[at] - '0');
		++at;
	}
	return v;
}

std::vector<uint32_t> ids_in(const std::string &text, size_t from, size_t to, const char *token) {
	std::vector<uint32_t> out;
	const size_t len = std::string(token).size();
	for (size_t at = from; at < to;) {
		const size_t hit = text.find(token, at);
		if (hit == std::string::npos || hit >= to) { break; }
		out.push_back(read_uint(text, hit + len));
		at = hit + len;
	}
	return out;
}

MslLayout read_msl_layout(const std::string &msl, const std::string &entry) {
	MslLayout out;
	const size_t sb = msl.find("struct spvDescriptorSetBuffer0");
	if (sb != std::string::npos) {
		out.ids = ids_in(msl, sb, msl.find("};", sb), "[[id(");
	}
	const size_t ep = msl.find("kernel void " + entry + "(");
	if (ep == std::string::npos) { return out; }
	size_t at = msl.find('(', ep);
	int depth = 0;
	for (; at < msl.size(); ++at) {
		if (msl[at] == '(') { ++depth; }
		if (msl[at] == ')' && --depth == 0) { break; }
	}
	out.entry_slots = ids_in(msl, ep, at, "[[buffer(");
	return out;
}

} // namespace

void init() { glslang::InitializeProcess(); }
void finalize() { glslang::FinalizeProcess(); }

bool compile_kernel(const std::string &dir, const std::string &file, la::BlobKernel &out,
		std::string &err) {
	std::string src;
	if (!read_file(dir + "/" + file, src)) {
		err = dir + "/" + file + ": cannot read";
		return false;
	}
	src = strip_import_marker(src);

	glslang::TShader shader(EShLangCompute);
	const char *strings[1] = {src.c_str()};
	const int lengths[1] = {static_cast<int>(src.size())};
	const char *names[1] = {file.c_str()};
	shader.setStringsWithLengthsAndNames(strings, lengths, names, 1);
	// glslang refuses #include unless the directive is enabled; the kernels do not carry the pragma
	// because Godot's importer never needed it.
	shader.setPreamble("#extension GL_GOOGLE_include_directive : require\n");
	shader.setEnvInput(glslang::EShSourceGlsl, EShLangCompute, glslang::EShClientVulkan, 100);
	shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_1);
	shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_3);

	DirIncluder includer(dir);
	const EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);
	if (!shader.parse(GetDefaultResources(), 450, false, messages, includer)) {
		err = std::string(shader.getInfoLog());
		return false;
	}
	glslang::TProgram program;
	program.addShader(&shader);
	if (!program.link(messages)) {
		err = std::string(program.getInfoLog());
		return false;
	}
	glslang::TIntermediate *inter = program.getIntermediate(EShLangCompute);
	if (inter == nullptr) {
		err = file + ": linked to no compute stage";
		return false;
	}
	std::vector<uint32_t> spirv;
	glslang::GlslangToSpv(*inter, spirv);
	if (spirv.empty()) {
		err = file + ": glslang emitted no SPIR-V";
		return false;
	}

	spirv_cross::CompilerMSL msl(spirv);
	spirv_cross::ShaderResources res = msl.get_shader_resources();

	std::vector<std::pair<uint32_t, const spirv_cross::Resource *>> ssbo;
	for (const spirv_cross::Resource &r : res.storage_buffers) {
		const uint32_t set = msl.get_decoration(r.id, spv::DecorationDescriptorSet);
		if (set != 0) {
			err = file + ": buffer '" + r.name + "' is in descriptor set " + std::to_string(set)
					+ "; the device binds set 0 only";
			return false;
		}
		ssbo.emplace_back(msl.get_decoration(r.id, spv::DecorationBinding), &r);
	}
	std::sort(ssbo.begin(), ssbo.end(),
			[](const auto &a, const auto &b) { return a.first < b.first; });

	spirv_cross::CompilerMSL::Options opts = msl.get_msl_options();
	opts.platform = spirv_cross::CompilerMSL::Options::macOS;
	opts.set_msl_version(3, 0);
	opts.argument_buffers = true;
	opts.argument_buffers_tier = spirv_cross::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
	// Without this SPIRV-Cross drops a declared-but-unused buffer, and the blob's reflection would then
	// disagree with the GLSL the pass binds against.
	opts.force_active_argument_buffer_resources = true;
	msl.set_msl_options(opts);

	spirv_cross::MSLResourceBinding arg{};
	arg.stage = spv::ExecutionModelGLCompute;
	arg.desc_set = 0;
	arg.binding = spirv_cross::kArgumentBufferBinding;
	arg.msl_buffer = kArgBufferSlot;
	msl.add_msl_resource_binding(arg);

	for (uint32_t slot = 0; slot < ssbo.size(); ++slot) {
		spirv_cross::MSLResourceBinding b{};
		b.stage = spv::ExecutionModelGLCompute;
		b.desc_set = 0;
		b.binding = ssbo[slot].first;
		b.count = 1;
		b.msl_buffer = slot;
		msl.add_msl_resource_binding(b);
		out.bindings.push_back({0, ssbo[slot].first, slot, ssbo[slot].second->name});
	}

	uint32_t push_size = 0;
	if (!res.push_constant_buffers.empty()) {
		const spirv_cross::Resource &pc = res.push_constant_buffers.front();
		push_size = static_cast<uint32_t>(msl.get_declared_struct_size(msl.get_type(pc.base_type_id)));
		spirv_cross::MSLResourceBinding b{};
		b.stage = spv::ExecutionModelGLCompute;
		b.desc_set = spirv_cross::kPushConstDescSet;
		b.binding = spirv_cross::kPushConstBinding;
		b.msl_buffer = kPushSlot;
		msl.add_msl_resource_binding(b);
	}

	try {
		out.msl = msl.compile();
	} catch (const std::exception &e) {
		err = file + ": SPIRV-Cross could not translate to MSL: " + e.what();
		return false;
	}
	out.entry = msl.get_cleansed_entry_point_name("main", spv::ExecutionModelGLCompute);
	out.name = file.substr(0, file.find_last_of('.'));
	out.spirv = std::move(spirv);
	out.local[0] = msl.get_execution_mode_argument(spv::ExecutionModeLocalSize, 0);
	out.local[1] = msl.get_execution_mode_argument(spv::ExecutionModeLocalSize, 1);
	out.local[2] = msl.get_execution_mode_argument(spv::ExecutionModeLocalSize, 2);
	if (out.local[0] == 0) {
		err = file + ": declares no local size, so a dispatch has no threadgroup to launch";
		return false;
	}
	out.push_size = push_size;
	out.push_slot = kPushSlot;
	out.arg_slot = kArgBufferSlot;

	// Metal gives a compute function 31 buffer slots and the flux kernel declares ~90 buffers, so the
	// entry point may take the argument buffer and the push constant block and nothing else.
	const MslLayout layout = read_msl_layout(out.msl, out.entry);
	std::vector<uint32_t> want{kArgBufferSlot};
	if (push_size > 0) { want.push_back(kPushSlot); }
	if (layout.entry_slots != want) {
		err = file + ": the entry point takes " + std::to_string(layout.entry_slots.size())
				+ " Metal buffer slots, not the argument buffer and the push block";
		return false;
	}
	if (layout.ids.size() != out.bindings.size()) {
		err = file + ": the argument buffer carries " + std::to_string(layout.ids.size())
				+ " members for " + std::to_string(out.bindings.size()) + " declared buffers";
		return false;
	}
	// Dense and ascending: a set is then eight bytes per member and the device writes a GPU address at
	// slot * 8 without consulting Metal's struct padding rules.
	for (uint32_t i = 0; i < layout.ids.size(); ++i) {
		if (layout.ids[i] != i) {
			err = file + ": argument-buffer member " + std::to_string(i) + " carries id "
					+ std::to_string(layout.ids[i]);
			return false;
		}
	}
	return true;
}

} // namespace lakc
