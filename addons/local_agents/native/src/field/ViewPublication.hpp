#pragma once

#include "FieldSession.hpp"
#include <filesystem>

namespace lasim {

struct ViewDraft {
	uint64_t generation = 0;
	uint64_t sequence = 0;
	uint64_t revision = 0;
	double time_s = 0.0;
	std::vector<std::string> fields;
	std::vector<uint8_t> bytes;
};

bool prepare_view(FieldSession &session, uint64_t nonce, uint64_t generation, uint64_t sequence,
		uint64_t revision, double time_s, const std::vector<std::string> &fields,
		ViewDraft &out, std::string &err);

class ViewPublication {
	std::filesystem::path directory;
	std::filesystem::path pending;
	std::filesystem::path temporary;
	uint64_t sequence = 0;

public:
	~ViewPublication();
	bool initialize(const std::string &root, uint64_t nonce, std::string &err);
	bool publish(const ViewDraft &view, std::string &path, std::string &err);
	bool acknowledge(uint64_t view_sequence, std::string &err);
	bool discard(std::string &err);
	bool busy() const { return !pending.empty(); }
};

}
