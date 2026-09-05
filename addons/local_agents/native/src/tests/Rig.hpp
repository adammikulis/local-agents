#pragma once

#include "la/Device.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace lasim {

// ONE BUFFER PER DECLARED BINDING, from the blob's own reflection: nothing here restates which slots a
// kernel wants. Every buffer is the same length in words and starts zeroed, so a kernel that reads a
// slot the case never wrote reads zero rather than whatever the device last held.
class Rig {
public:
	Rig(la::Device &dev, const char *kernel, uint32_t words, std::string &err);
	~Rig();

	bool ok() const { return ok_; }
	uint32_t words() const { return words_; }
	bool declares(uint32_t binding) const;

	void put(uint32_t binding, const std::vector<float> &v);
	void put(uint32_t binding, const std::vector<uint32_t> &v);
	void put(uint32_t binding, const std::vector<int32_t> &v);
	void fill(uint32_t binding, float v);
	void fill(uint32_t binding, uint32_t v);
	void zero(uint32_t binding);

	std::vector<float> get(uint32_t binding, size_t n);
	std::vector<uint32_t> get_u(uint32_t binding, size_t n);

	// One dispatch over `threads` invocations, rounded up to the kernel's own local size.
	void run(const void *push, size_t push_bytes, uint32_t threads);
	uint32_t groups_for(uint32_t threads) const;

private:
	la::BufferId at(uint32_t binding) const;

	la::Device &dev_;
	la::KernelId kernel_{};
	uint32_t words_ = 0;
	bool ok_ = false;
	std::vector<uint32_t> bindings_;
	std::vector<la::BufferId> buffers_;
	la::SetId set_{};
};

} // namespace lasim
