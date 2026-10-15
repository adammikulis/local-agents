#include "ViewPublication.hpp"
#include "cli/ServiceProtocol.hpp"
#include <cstdio>

namespace lasim {
bool ViewPublication::initialize(const std::string &root, uint64_t nonce, std::string &err) {
	std::error_code ec;
	std::filesystem::create_directories(root, ec);
	if (ec) { err = "PUBLICATION_DIRECTORY_FAILED"; return false; }
	const auto candidate = std::filesystem::path(root) / ("session-" + std::to_string(nonce));
	if (!std::filesystem::create_directory(candidate, ec) || ec) {
		err = "PUBLICATION_SESSION_EXISTS_OR_UNWRITABLE";
		return false;
	}
	directory = candidate;
	return true;
}

bool ViewPublication::publish(const ViewDraft &view, std::string &path, std::string &err) {
	if (directory.empty() || busy()) { err = "VIEW_BUSY_OR_UNINITIALIZED"; return false; }
	const auto final = directory / ("view-" + std::to_string(view.generation) + "-"
			+ std::to_string(view.sequence) + ".lavw");
	temporary = directory / "view.tmp";
	std::FILE *stream = std::fopen(temporary.string().c_str(), "wb");
	if (!stream) { err = "VIEW_WRITE_FAILED"; return false; }
	const bool wrote = std::fwrite(view.bytes.data(), 1, view.bytes.size(), stream) == view.bytes.size();
	const bool closed = std::fclose(stream) == 0;
	std::error_code ec;
	if (!wrote || !closed) {
		std::filesystem::remove(temporary, ec);
		err = "VIEW_WRITE_FAILED";
		return false;
	}
	std::filesystem::rename(temporary, final, ec);
	if (ec) {
		std::filesystem::remove(temporary, ec);
		err = "VIEW_RENAME_FAILED";
		return false;
	}
	pending = final;
	temporary.clear();
	sequence = view.sequence;
	path = final.string();
	return true;
}

bool ViewPublication::acknowledge(uint64_t view_sequence, std::string &err) {
	if (!busy() || view_sequence != sequence) { err = "VIEW_STALE_ACK"; return false; }
	return discard(err);
}

bool ViewPublication::discard(std::string &err) {
	std::error_code ec;
	if (busy()) {
		std::filesystem::remove(pending, ec);
		if (ec) { err = "VIEW_REMOVE_FAILED"; return false; }
		pending.clear();
	}
	return true;
}

ViewPublication::~ViewPublication() {
	std::error_code ec;
	if (!temporary.empty()) { std::filesystem::remove(temporary, ec); }
	if (!pending.empty()) { std::filesystem::remove(pending, ec); }
	if (!directory.empty()) { std::filesystem::remove(directory, ec); }
}

}
