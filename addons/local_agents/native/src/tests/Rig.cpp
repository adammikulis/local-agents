#include "Rig.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <utility>

namespace lasim {

Rig::Rig(la::Device &dev, const char *kernel, uint32_t words, std::string &err) :
		dev_(dev), words_(words) {
	if (!dev_.has_kernel(kernel)) {
		err = std::string("the blob carries no kernel named ") + kernel;
		return;
	}
	kernel_ = dev_.kernel(kernel);
	if (!dev_.build(kernel_, err)) { return; }
	bindings_ = dev_.bindings_of(kernel_);
	const std::vector<float> zeros(words_, 0.0f);
	std::vector<std::pair<uint32_t, la::BufferId>> bound;
	for (uint32_t b : bindings_) {
		la::BufferId id = dev_.create_buffer(size_t(words_) * 4u, la::Usage::Storage, zeros.data());
		buffers_.push_back(id);
		bound.emplace_back(b, id);
	}
	set_ = dev_.make_set(kernel_, bound);
	ok_ = true;
}

Rig::~Rig() {
	if (!ok_) { return; }
	dev_.destroy_set(set_);
	for (la::BufferId b : buffers_) { dev_.destroy_buffer(b); }
}

bool Rig::declares(uint32_t binding) const {
	return std::find(bindings_.begin(), bindings_.end(), binding) != bindings_.end();
}

la::BufferId Rig::at(uint32_t binding) const {
	for (size_t i = 0; i < bindings_.size(); ++i) {
		if (bindings_[i] == binding) { return buffers_[i]; }
	}
	// A case that writes a slot the kernel never declared is a case written against another kernel.
	std::fprintf(stderr, "property-tests: binding %u is not declared by this kernel\n", binding);
	std::abort();
}

void Rig::put(uint32_t binding, const std::vector<float> &v) {
	const size_t n = std::min<size_t>(v.size(), words_);
	dev_.upload(at(binding), 0, v.data(), n * 4u);
}

void Rig::put(uint32_t binding, const std::vector<uint32_t> &v) {
	const size_t n = std::min<size_t>(v.size(), words_);
	dev_.upload(at(binding), 0, v.data(), n * 4u);
}

void Rig::put(uint32_t binding, const std::vector<int32_t> &v) {
	const size_t n = std::min<size_t>(v.size(), words_);
	dev_.upload(at(binding), 0, v.data(), n * 4u);
}

void Rig::fill(uint32_t binding, float v) {
	const std::vector<float> all(words_, v);
	put(binding, all);
}

void Rig::fill(uint32_t binding, uint32_t v) {
	const std::vector<uint32_t> all(words_, v);
	put(binding, all);
}

void Rig::zero(uint32_t binding) {
	dev_.clear(at(binding), 0, size_t(words_) * 4u);
}

std::vector<float> Rig::get(uint32_t binding, size_t n) {
	std::vector<float> out(std::min<size_t>(n, words_), 0.0f);
	dev_.download(at(binding), 0, out.data(), out.size() * 4u);
	return out;
}

std::vector<uint32_t> Rig::get_u(uint32_t binding, size_t n) {
	std::vector<uint32_t> out(std::min<size_t>(n, words_), 0u);
	dev_.download(at(binding), 0, out.data(), out.size() * 4u);
	return out;
}

uint32_t Rig::groups_for(uint32_t threads) const {
	const uint32_t local = std::max<uint32_t>(dev_.local_size_x(kernel_), 1u);
	return (threads + local - 1u) / local;
}

void Rig::run(const void *push, size_t push_bytes, uint32_t threads) {
	// A case whose push block is not the one the kernel declares is a case reading another kernel's
	// parameters off its own struct.
	if (push_bytes != size_t(dev_.push_size(kernel_))) {
		std::fprintf(stderr, "property-tests: %s declares a %u-byte push block; the case pushed %zu\n",
				dev_.kernel_name(kernel_), dev_.push_size(kernel_), push_bytes);
		std::abort();
	}
	la::List list = dev_.begin();
	dev_.bind(list, kernel_, set_);
	if (push_bytes > 0) { dev_.push(list, push, push_bytes); }
	dev_.dispatch(list, groups_for(threads));
	dev_.mark(list, dev_.kernel_name(kernel_));
	la::Fence f = dev_.submit(std::move(list));
	dev_.wait(f);
}

} // namespace lasim
