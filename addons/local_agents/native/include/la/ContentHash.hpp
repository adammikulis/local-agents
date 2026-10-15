#pragma once

#include <cstddef>
#include <cstdint>

namespace la {

inline uint64_t content_hash(const uint8_t *data, size_t size) {
	uint64_t result = 1469598103934665603ULL;
	for (size_t i = 0; i < size; ++i) {
		result ^= data[i];
		result *= 1099511628211ULL;
	}
	return result;
}

}
