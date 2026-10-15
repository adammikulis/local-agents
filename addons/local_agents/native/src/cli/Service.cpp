#include "Service.hpp"
#include "ServiceProtocol.hpp"
#include "field/FieldSession.hpp"
#include "field/ViewPublication.hpp"
#include <cmath>
#include <condition_variable>
#include <csignal>
#include <future>
#include <mutex>
#include <optional>
#include <thread>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

namespace lasim {
namespace {

struct PublicationCredit {
	bool available = true;
	uint64_t next_sequence = 1;
	uint64_t accepted_generation = 0;
	uint64_t accepted_revision = 0;
	std::vector<std::string> accepted_fields;
};

struct Outcome {
	wire::Packet reply;
	std::optional<ViewDraft> view;
	bool loaded = false;
	bool fatal = false;
	uint64_t ack_sequence = 0;
	bool accepted = false;
};

class Engine {
	la::Backend backend;
	int device_index;
	std::string blob;
	std::unique_ptr<la::Device> device;
	std::unique_ptr<FieldSession> field;
	uint64_t nonce = 0, generation = 0, revision = 0, last_request = 0;
	uint64_t prepared_bytes = 0;
	double imported_time_s = 0.0;
	std::vector<ReducedRow> audits;

	Outcome response(const wire::Packet &request) const {
		Outcome out;
		out.reply.operation = request.operation | wire::response_bit;
		out.reply.session = nonce;
		out.reply.request = request.request;
		out.reply.generation = generation;
		return out;
	}

	void metadata(wire::Packet &reply) const {
		wire::put_u32(reply.payload, field ? 1 : 0);
		if (!field) { return; }
		wire::put_u64(reply.payload, revision);
		wire::put_double(reply.payload, imported_time_s);
		wire::put_u64(reply.payload, field->identity().snapshot);
		wire::put_u64(reply.payload, field->identity().plan);
		wire::put_u64(reply.payload, field->identity().kernels);
		wire::put_u32(reply.payload, field->metadata().cells);
		wire::put_string(reply.payload, field->metadata().world_key);
	}

public:
	Engine(la::Backend b, int index, std::string path) : backend(b), device_index(index), blob(std::move(path)) {}

	Outcome error(const wire::Packet &request, const char *reason, const std::string &detail = "") const {
		Outcome out = response(request);
		out.reply.operation = wire::Error;
		if (!out.reply.session) { out.reply.session = request.session; }
		wire::put_string(out.reply.payload, reason);
		if (!detail.empty()) { std::fprintf(stderr, "lasim service: %s: %s\n", reason, detail.c_str()); }
		return out;
	}

	Outcome handle(const wire::Packet &request, const PublicationCredit &credit) {
		wire::Cursor payload(request.payload);
		if (nonce == 0) {
			if (request.operation != wire::Hello || !request.session || !request.request
					|| request.generation != 0 || !payload.empty()) {
				return error(request, "HANDSHAKE_REQUIRED");
			}
			nonce = request.session;
			last_request = request.request;
			std::string err;
			device = la::Device::create(backend, device_index, err);
			if (!device || !device->load_kernels(blob, err)) {
				auto out = error(request, "GPU_REQUIRED", err);
				out.fatal = true;
				return out;
			}
			auto out = response(request);
			wire::put_u32(out.reply.payload, wire::ResidentBuffers | wire::SelectedViews
					| wire::AcknowledgedViews | wire::AlgebraicOnly);
			wire::put_string(out.reply.payload, device->name());
			wire::put_string(out.reply.payload, device->backend() == la::Backend::Metal ? "metal" : "vulkan");
			return out;
		}
		if (request.session != nonce) { return error(request, "STALE_SESSION"); }
		if (request.request <= last_request) { return error(request, "STALE_REQUEST"); }
		last_request = request.request;
		if (request.generation != generation) { return error(request, "STALE_GENERATION"); }
		if (request.operation == wire::Load) {
			RunArgs args;
			double time_s;
			if (!payload.string(args.snapshot) || !payload.string(args.plan) || !payload.string(args.passes)
					|| !payload.number(time_s) || !std::isfinite(time_s) || time_s < 0 || !payload.empty()) {
				return error(request, "INVALID_LOAD");
			}
			args.blob = blob;
			std::string err;
			auto candidate = FieldSession::open(*device, args, err);
			if (!candidate) { return error(request, "LOAD_FAILED", err); }
			field = std::move(candidate);
			generation++;
			revision = 1;
			imported_time_s = time_s;
			audits.clear();
			auto out = response(request);
			metadata(out.reply);
			out.loaded = true;
			return out;
		}
		if (request.operation == wire::Status && payload.empty()) {
			auto out = response(request);
			metadata(out.reply);
			wire::put_u64(out.reply.payload, prepared_bytes);
			wire::put_u32(out.reply.payload, uint32_t(audits.size()));
			for (const ReducedRow &row : audits) {
				wire::put_string(out.reply.payload, row.key);
				wire::put_double(out.reply.payload, row.value);
				wire::put_u32(out.reply.payload, row.present ? 1 : 0);
			}
			return out;
		}
		if (request.operation == wire::Shutdown && payload.empty()) {
			auto out = response(request);
			metadata(out.reply);
			return out;
		}
		if (!field) { return error(request, "WORLD_NOT_LOADED"); }
		if (request.operation == wire::Derive) {
			uint32_t step;
			if (!payload.u32(step) || !payload.empty() || step >= field->plan().steps.size()) {
				return error(request, "INVALID_DERIVE");
			}
			std::string err;
			if (!field->execute(step, err) || !field->reductions(audits, err)) {
				auto out = error(request, "DERIVE_FAILED", err);
				out.fatal = true;
				return out;
			}
			revision++;
			auto out = response(request);
			metadata(out.reply);
			return out;
		}
		if (request.operation == wire::View) {
			uint64_t seen;
			uint32_t count;
			if (!payload.u64(seen) || !payload.u32(count) || count > wire::max_payload / 4) {
				return error(request, "INVALID_VIEW");
			}
			std::vector<std::string> fields;
			for (uint32_t i = 0; i < count; ++i) {
				std::string name;
				if (!payload.string(name)) { return error(request, "INVALID_VIEW"); }
				fields.push_back(std::move(name));
			}
			if (!payload.empty() || fields.empty()) { return error(request, "INVALID_VIEW"); }
			if (!credit.available) { return error(request, "VIEW_BUSY"); }
			auto out = response(request);
			metadata(out.reply);
			if (seen == revision && credit.accepted_revision == revision
					&& credit.accepted_generation == generation && fields == credit.accepted_fields) {
				wire::put_u32(out.reply.payload, 0);
				return out;
			}
			ViewDraft view;
			std::string err;
			if (!prepare_view(*field, nonce, generation, credit.next_sequence, revision,
					imported_time_s, fields, view, err)) { return error(request, "VIEW_FAILED", err); }
			prepared_bytes += view.bytes.size();
			wire::put_u32(out.reply.payload, 1);
			wire::put_u64(out.reply.payload, view.sequence);
			out.view = std::move(view);
			return out;
		}
		if (request.operation == wire::Ack) {
			uint64_t sequence;
			uint32_t accepted;
			if (!payload.u64(sequence) || !payload.u32(accepted) || accepted > 1 || !payload.empty()) {
				return error(request, "INVALID_ACK");
			}
			auto out = response(request);
			metadata(out.reply);
			out.ack_sequence = sequence;
			out.accepted = accepted != 0;
			return out;
		}
		if (request.operation == wire::Cancel && payload.empty()) {
			auto out = response(request);
			metadata(out.reply);
			return out;
		}
		if (request.operation == wire::Advance) { return error(request, "INTEGRATION_NOT_AVAILABLE"); }
		return error(request, "UNSUPPORTED_OPERATION");
	}
};

class EngineWorker {
	struct Task {
		wire::Packet packet;
		PublicationCredit credit;
		std::promise<Outcome> result;
	};
	std::mutex mutex;
	std::condition_variable changed;
	bool stopping = false;
	std::optional<Task> pending;
	std::thread thread;

public:
	EngineWorker(la::Backend backend, int index, const std::string &blob) {
		thread = std::thread([this, backend, index, blob]() {
#ifdef __APPLE__
			@autoreleasepool {
#endif
			Engine engine(backend, index, blob);
			while (true) {
				std::optional<Task> task;
				{
					std::unique_lock lock(mutex);
					changed.wait(lock, [&] { return stopping || pending.has_value(); });
					if (stopping && !pending) { break; }
					task = std::move(pending);
					pending.reset();
				}
#ifdef __APPLE__
				@autoreleasepool {
#endif
				try { task->result.set_value(engine.handle(task->packet, task->credit)); }
				catch (const std::exception &err) {
					auto out = engine.error(task->packet, "SERVICE_FAILED", err.what());
					out.fatal = true;
					task->result.set_value(std::move(out));
				}
#ifdef __APPLE__
				}
#endif
			}
#ifdef __APPLE__
			}
#endif
		});
	}

	Outcome call(wire::Packet packet, const PublicationCredit &credit) {
		Task task{std::move(packet), credit, {}};
		auto result = task.result.get_future();
		{
			std::lock_guard lock(mutex);
			pending = std::move(task);
		}
		changed.notify_one();
		return result.get();
	}

	~EngineWorker() {
		{
			std::lock_guard lock(mutex);
			stopping = true;
		}
		changed.notify_one();
		thread.join();
	}
};

}

int serve(la::Backend backend, int device_index, const std::string &blob, const std::string &root) {
#ifdef SIGPIPE
	std::signal(SIGPIPE, SIG_IGN);
#endif
#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
#endif
	EngineWorker worker(backend, device_index, blob);
	ViewPublication publication;
	PublicationCredit credit;
	std::optional<ViewDraft> pending;
	bool ready = false;
	while (true) {
		wire::Packet request;
		bool eof;
		std::string err;
		if (!wire::read(stdin, request, eof, err)) {
			if (eof) { return 0; }
			wire::Packet reply{wire::Error, request.session, request.request, request.generation, {}};
			wire::put_string(reply.payload, err);
			wire::write(stdout, reply, err);
			return 2;
		}
		credit.available = !publication.busy();
		Outcome out = worker.call(request, credit);
		auto io_error = [&](const std::string &reason) {
			out.reply.operation = wire::Error;
			out.reply.payload.clear();
			wire::put_string(out.reply.payload, reason);
		};
		if (out.reply.operation != wire::Error) {
			if (request.operation == wire::Hello) {
				if (!publication.initialize(root, request.session, err)) { io_error(err); out.fatal = true; }
				else { ready = true; }
			} else if (out.loaded) {
				if (!publication.discard(err)) { io_error(err); out.fatal = true; }
				pending.reset();
				credit.accepted_fields.clear();
				credit.accepted_revision = 0;
				credit.accepted_generation = 0;
			} else if (out.view) {
				std::string path;
				if (!publication.publish(*out.view, path, err)) { io_error(err); }
				else {
					wire::put_string(out.reply.payload, path);
					credit.next_sequence++;
					pending = std::move(out.view);
					pending->bytes.clear();
					pending->bytes.shrink_to_fit();
				}
			} else if (request.operation == wire::Ack) {
				if (!pending || !publication.acknowledge(out.ack_sequence, err)) {
					io_error("VIEW_STALE_ACK");
				} else {
					if (out.accepted) {
						credit.accepted_fields = pending->fields;
						credit.accepted_revision = pending->revision;
						credit.accepted_generation = pending->generation;
					}
					pending.reset();
				}
			} else if (request.operation == wire::Cancel) {
				const bool existed = publication.busy();
				if (!publication.discard(err)) { io_error(err); }
				else { pending.reset(); wire::put_u32(out.reply.payload, existed ? 1 : 0); }
			}
		}
		if (!wire::write(stdout, out.reply, err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 2; }
		if (out.fatal) { return 2; }
		if (ready && request.operation == wire::Shutdown && out.reply.operation != wire::Error) { return 0; }
	}
}

}
