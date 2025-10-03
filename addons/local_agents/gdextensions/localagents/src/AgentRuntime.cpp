#include "AgentRuntime.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <llama.h>

#include <cmath>
#include <cstring>
#include <filesystem>
#include <sstream>
#include <vector>
#include <chrono>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <limits>
#include <string_view>
#include <mutex>
#include <climits>

#include <gguf.h>

#ifdef LLAMA_USE_CURL
#include <curl/curl.h>
#endif

using namespace godot;

namespace {
std::string to_utf8(const String &value) {
    return std::string(value.utf8().get_data());
}

constexpr const char *kSplitCountKey = "split.count";
constexpr size_t kMaxUrlLength = 2084;
constexpr size_t kPathBufferSize = 4096;

#ifdef LLAMA_USE_CURL
void ensure_curl_initialized() {
    static std::once_flag once_flag;
    std::call_once(once_flag, []() {
        curl_global_init(CURL_GLOBAL_DEFAULT);
    });
}
#endif

llama_sampler *create_sampler(const Dictionary &options) {
    llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
    chain_params.no_perf = true;

    llama_sampler *chain = llama_sampler_chain_init(chain_params);
    if (!chain) {
        return nullptr;
    }

    auto append_sampler = [chain](llama_sampler *sampler) {
        if (sampler) {
            llama_sampler_chain_add(chain, sampler);
        }
    };

    bool use_distribution = false;

    if (options.has("top_k")) {
        int32_t top_k = (int32_t)options["top_k"];
        if (top_k > 0) {
            append_sampler(llama_sampler_init_top_k(top_k));
            use_distribution = true;
        }
    }

    if (options.has("top_p")) {
        float top_p = (float)options["top_p"];
        if (top_p > 0.0f) {
            append_sampler(llama_sampler_init_top_p(top_p, 1));
            use_distribution = true;
        }
    }

    if (options.has("min_p")) {
        float min_p = (float)options["min_p"];
        if (min_p > 0.0f) {
            append_sampler(llama_sampler_init_min_p(min_p, 1));
            use_distribution = true;
        }
    }

    float temperature = 1.0f;
    if (options.has("temperature")) {
        temperature = (float)options["temperature"];
    }

    if (temperature <= 0.0f) {
        use_distribution = false;
    } else if (temperature != 1.0f) {
        append_sampler(llama_sampler_init_temp(temperature));
        use_distribution = true;
    } else {
        use_distribution = true;
    }

    uint32_t seed = LLAMA_DEFAULT_SEED;
    if (options.has("seed")) {
        seed = static_cast<uint32_t>((int64_t)options["seed"]);
    }

    if (use_distribution) {
        append_sampler(llama_sampler_init_dist(seed));
    } else {
        append_sampler(llama_sampler_init_greedy());
    }

    if (llama_sampler_chain_n(chain) == 0) {
        append_sampler(llama_sampler_init_greedy());
    }

    return chain;
}

std::string format_bytes(uint64_t bytes) {
    static const char *kUnits[] = {"B", "KB", "MB", "GB", "TB", "PB"};
    double value = static_cast<double>(bytes);
    size_t unit = 0;
    const size_t unit_count = sizeof(kUnits) / sizeof(kUnits[0]);

    while (value >= 1024.0 && unit + 1 < unit_count) {
        value /= 1024.0;
        ++unit;
    }

    std::ostringstream oss;
    if (unit == 0) {
        oss << static_cast<uint64_t>(value + 0.5) << ' ' << kUnits[unit];
    } else {
        oss << std::fixed << std::setprecision(value >= 10.0 ? 1 : 2) << value << ' ' << kUnits[unit];
    }
    return oss.str();
}

PackedStringArray to_packed(const std::vector<String> &lines) {
    PackedStringArray array;
    array.resize(static_cast<int64_t>(lines.size()));
    for (int64_t i = 0; i < array.size(); ++i) {
        array[i] = lines[static_cast<size_t>(i)];
    }
    return array;
}

PackedStringArray to_packed(const std::vector<std::string> &lines) {
    PackedStringArray array;
    array.resize(static_cast<int64_t>(lines.size()));
    for (int64_t i = 0; i < array.size(); ++i) {
        array[i] = String::utf8(lines[static_cast<size_t>(i)].c_str());
    }
    return array;
}

} // namespace

AgentRuntime *AgentRuntime::singleton_ = nullptr;

AgentRuntime::AgentRuntime()
    : sampler_(nullptr, [](llama_sampler *sampler) {
          if (sampler) {
              llama_sampler_free(sampler);
          }
      }) {
    if (!singleton_) {
        singleton_ = this;
    }
    system_prompt_ = String("You are Local Agents, an offline assistant running inside a Godot game. Be concise and helpful.");
}

AgentRuntime::~AgentRuntime() {
    if (singleton_ == this) {
        singleton_ = nullptr;
    }
    unload_model();
}

AgentRuntime *AgentRuntime::get_singleton() {
    return singleton_;
}

void AgentRuntime::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "model_path", "options"), &AgentRuntime::load_model);
    ClassDB::bind_method(D_METHOD("unload_model"), &AgentRuntime::unload_model);
    ClassDB::bind_method(D_METHOD("is_model_loaded"), &AgentRuntime::is_model_loaded);
    ClassDB::bind_method(D_METHOD("generate", "request"), &AgentRuntime::generate);
    ClassDB::bind_method(D_METHOD("embed_text", "text", "options"), &AgentRuntime::embed_text, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("download_model", "request"), &AgentRuntime::download_model);

    ClassDB::bind_method(D_METHOD("set_default_model_path", "path"), &AgentRuntime::set_default_model_path);
    ClassDB::bind_method(D_METHOD("get_default_model_path"), &AgentRuntime::get_default_model_path);
    ClassDB::bind_method(D_METHOD("set_runtime_directory", "path"), &AgentRuntime::set_runtime_directory);
    ClassDB::bind_method(D_METHOD("get_runtime_directory"), &AgentRuntime::get_runtime_directory);
    ClassDB::bind_method(D_METHOD("set_system_prompt", "prompt"), &AgentRuntime::set_system_prompt);
    ClassDB::bind_method(D_METHOD("get_system_prompt"), &AgentRuntime::get_system_prompt);

    ADD_PROPERTY(PropertyInfo(Variant::STRING, "default_model_path"), "set_default_model_path", "get_default_model_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "runtime_directory"), "set_runtime_directory", "get_runtime_directory");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "system_prompt"), "set_system_prompt", "get_system_prompt");
}

void AgentRuntime::_notification(int what) {
    if (what == NOTIFICATION_PREDELETE) {
        if (singleton_ == this) {
            singleton_ = nullptr;
        }
    }
}

bool AgentRuntime::load_model(const String &model_path, const Dictionary &options) {
    std::scoped_lock lock(mutex_);
    String resolved = model_path.is_empty() ? default_model_path_ : model_path;
    if (resolved.is_empty()) {
        UtilityFunctions::push_error("AgentRuntime::load_model - model path empty");
        return false;
    }
    if (!model_path.is_empty()) {
        default_model_path_ = resolved;
    }
    return load_model_locked(resolved, options, true);
}

void AgentRuntime::unload_model() {
    std::scoped_lock lock(mutex_);
    unload_model_locked();
}

bool AgentRuntime::is_model_loaded() const {
    std::scoped_lock lock(mutex_);
    return model_ != nullptr && context_ != nullptr;
}

Dictionary AgentRuntime::generate(const Dictionary &request) {
    std::scoped_lock lock(mutex_);

    if (!model_ || !context_) {
        if (default_model_path_.is_empty()) {
            Dictionary error;
            error["ok"] = false;
            error["error"] = "model_not_loaded";
            return error;
        }
        if (!load_model_locked(default_model_path_, default_options_, false)) {
            Dictionary error;
            error["ok"] = false;
            error["error"] = "model_not_loaded";
            return error;
        }
    }

    return run_inference_locked(request);
}

PackedFloat32Array AgentRuntime::embed_text(const String &text, const Dictionary &options) {
    std::scoped_lock lock(mutex_);

    PackedFloat32Array empty;
    if (text.is_empty()) {
        UtilityFunctions::push_warning("AgentRuntime::embed_text - empty text");
        return empty;
    }

    if (!model_ || !context_) {
        if (default_model_path_.is_empty()) {
            UtilityFunctions::push_error("AgentRuntime::embed_text - model not loaded");
            return empty;
        }
        Dictionary reload_options = default_options_.duplicate();
        reload_options["embedding"] = true;
        if (!load_model_locked(default_model_path_, reload_options, false)) {
            UtilityFunctions::push_error("AgentRuntime::embed_text - failed to reload model with embedding support");
            return empty;
        }
    }

    Dictionary resolved = default_options_.duplicate();
    if (!options.is_empty()) {
        Array keys = options.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            resolved[key] = options[key];
        }
    }

    bool add_bos = resolved.get("add_bos", true);
    bool normalize = resolved.get("normalize", true);

    std::string input = to_utf8(text);
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - vocab unavailable");
        return empty;
    }

    int token_capacity = llama_tokenize(vocab, input.c_str(), static_cast<int32_t>(input.length()), nullptr, 0, add_bos, false);
    if (token_capacity <= 0) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - tokenization failed");
        return empty;
    }

    std::vector<llama_token> tokens(static_cast<size_t>(token_capacity));
    llama_tokenize(vocab, input.c_str(), static_cast<int32_t>(input.length()), tokens.data(), token_capacity, add_bos, false);

    llama_memory_clear(llama_get_memory(context_), true);

    llama_batch batch = llama_batch_get_one(tokens.data(), token_capacity);

    if (llama_decode(context_, batch) != 0) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - llama_decode failed");
        return empty;
    }

    const float *embedding_ptr = nullptr;
    switch (llama_pooling_type(context_)) {
        case LLAMA_POOLING_TYPE_NONE:
            embedding_ptr = llama_get_embeddings(context_);
            if (!embedding_ptr) {
                embedding_ptr = llama_get_embeddings_ith(context_, token_capacity - 1);
            }
            break;
        default:
            embedding_ptr = llama_get_embeddings_seq(context_, 0);
            break;
    }

    if (!embedding_ptr) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - no embedding data");
        return empty;
    }

    int dim = llama_model_n_embd(model_);
    PackedFloat32Array embedding;
    embedding.resize(dim);
    float *out = embedding.ptrw();
    std::memcpy(out, embedding_ptr, dim * sizeof(float));

    if (normalize) {
        double norm = 0.0;
        for (int i = 0; i < dim; ++i) {
            norm += static_cast<double>(out[i]) * static_cast<double>(out[i]);
        }
        norm = std::sqrt(std::max(norm, 1e-12));
        if (norm > 0.0) {
            for (int i = 0; i < dim; ++i) {
                out[i] = static_cast<float>(out[i] / norm);
            }
        }
    }

    return embedding;
}

Dictionary AgentRuntime::download_model(const Dictionary &request) {
    Dictionary response;
    std::vector<String> log_entries;
    auto log_line = [&log_entries](const std::string &line) {
        log_entries.push_back(String::utf8(line.c_str()));
    };

    String url_value = request.get("url", String());
    String output_value = request.get("output_path", String());
    if (url_value.is_empty()) {
        log_line("Missing download url");
        response["ok"] = false;
        response["error"] = String("missing_url");
        response["log"] = to_packed(log_entries);
        response["bytes_downloaded"] = static_cast<int64_t>(0);
        return response;
    }
    if (output_value.is_empty()) {
        log_line("Missing output path");
        response["ok"] = false;
        response["error"] = String("missing_output_path");
        response["log"] = to_packed(log_entries);
        response["bytes_downloaded"] = static_cast<int64_t>(0);
        return response;
    }

    String label_value = request.get("label", String());
    bool force = request.get("force", false);
    bool skip_existing = request.has("skip_existing") ? (bool)request["skip_existing"] : !force;
    bool offline = request.get("offline", false);
    PackedStringArray header_array;
    if (request.has("headers")) {
        header_array = request["headers"];
    }
    String bearer_token = request.get("bearer_token", String());
    double timeout_seconds = request.get("timeout_seconds", 0.0);

    std::filesystem::path output_path = std::filesystem::path(to_utf8(output_value)).lexically_normal();
    std::string label = label_value.is_empty() ? output_path.filename().string() : to_utf8(label_value);
    if (label.empty()) {
        label = to_utf8(url_value);
    }

    std::vector<std::string> file_paths;
    uint64_t total_bytes = 0;

    auto finalize = [&](bool ok, const std::string &error) {
        response["ok"] = ok;
        response["bytes_downloaded"] = static_cast<int64_t>(total_bytes);
        response["log"] = to_packed(log_entries);
        if (!file_paths.empty()) {
            response["files"] = to_packed(file_paths);
            response["path"] = String::utf8(file_paths.front().c_str());
        }
        if (!error.empty()) {
            response["error"] = String::utf8(error.c_str());
        }
        return response;
    };

    auto read_split_count = [](const std::filesystem::path &primary_path) -> int {
        struct gguf_init_params params = {true, nullptr};
        gguf_context *ctx = gguf_init_from_file(primary_path.string().c_str(), params);
        if (!ctx) {
            return 0;
        }
        int split = 0;
        int key_index = gguf_find_key(ctx, kSplitCountKey);
        if (key_index >= 0) {
            split = static_cast<int>(gguf_get_val_u16(ctx, key_index));
        }
        gguf_free(ctx);
        return split;
    };

    auto build_split_pairs = [&](int n_split, const std::filesystem::path &primary_path, const std::string &primary_url) {
        std::vector<std::pair<std::string, std::filesystem::path>> pairs;
        if (n_split <= 1) {
            return pairs;
        }
        char path_prefix[kPathBufferSize] = {0};
        if (!llama_split_prefix(path_prefix, kPathBufferSize, primary_path.string().c_str(), 0, n_split)) {
            log_line("Unable to resolve split path prefix");
            return std::vector<std::pair<std::string, std::filesystem::path>>();
        }
        char url_prefix[kMaxUrlLength] = {0};
        if (!llama_split_prefix(url_prefix, kMaxUrlLength, primary_url.c_str(), 0, n_split)) {
            log_line("Unable to resolve split URL prefix");
            return std::vector<std::pair<std::string, std::filesystem::path>>();
        }
        for (int idx = 1; idx < n_split; ++idx) {
            char path_buffer[kPathBufferSize] = {0};
            if (!llama_split_path(path_buffer, kPathBufferSize, path_prefix, idx, n_split)) {
                log_line("Unable to build split path for index " + std::to_string(idx));
                return std::vector<std::pair<std::string, std::filesystem::path>>();
            }
            char url_buffer[kMaxUrlLength] = {0};
            if (!llama_split_path(url_buffer, kMaxUrlLength, url_prefix, idx, n_split)) {
                log_line("Unable to build split URL for index " + std::to_string(idx));
                return std::vector<std::pair<std::string, std::filesystem::path>>();
            }
            pairs.emplace_back(std::string(url_buffer), std::filesystem::path(path_buffer));
        }
        return pairs;
    };

    auto build_split_paths_offline = [&](int n_split, const std::filesystem::path &primary_path) {
        std::vector<std::filesystem::path> paths;
        if (n_split <= 1) {
            return paths;
        }
        char path_prefix[kPathBufferSize] = {0};
        if (!llama_split_prefix(path_prefix, kPathBufferSize, primary_path.string().c_str(), 0, n_split)) {
            log_line("Unable to resolve split path prefix");
            return std::vector<std::filesystem::path>();
        }
        for (int idx = 1; idx < n_split; ++idx) {
            char path_buffer[kPathBufferSize] = {0};
            if (!llama_split_path(path_buffer, kPathBufferSize, path_prefix, idx, n_split)) {
                log_line("Unable to build split path for index " + std::to_string(idx));
                return std::vector<std::filesystem::path>();
            }
            paths.emplace_back(std::filesystem::path(path_buffer));
        }
        return paths;
    };

    if (offline) {
        if (!std::filesystem::exists(output_path)) {
            log_line("Offline mode: missing model file at " + output_path.string());
            return finalize(false, "offline_missing_file");
        }
        log_line("Offline mode: using cached model " + output_path.string());
        file_paths.push_back(output_path.string());

        int split_count = read_split_count(output_path);
        if (split_count > 1) {
            auto split_paths = build_split_paths_offline(split_count, output_path);
            if (static_cast<int>(split_paths.size()) != split_count - 1) {
                return finalize(false, "split_resolution_failed");
            }
            for (int idx = 0; idx < static_cast<int>(split_paths.size()); ++idx) {
                const auto &split_path = split_paths[static_cast<size_t>(idx)];
                if (!std::filesystem::exists(split_path)) {
                    log_line("Offline mode: missing split file " + split_path.string());
                    return finalize(false, "offline_missing_split");
                }
                file_paths.push_back(split_path.string());
            }
        }

        return finalize(true, "");
    }

#ifdef LLAMA_USE_CURL
    ensure_curl_initialized();

    std::error_code dir_error;
    std::filesystem::create_directories(output_path.parent_path(), dir_error);
    if (dir_error) {
        log_line("Failed to create directory: " + dir_error.message());
        return finalize(false, "mkdir_failed");
    }

    std::vector<std::string> header_lines;
    header_lines.reserve(header_array.size());
    for (int i = 0; i < header_array.size(); ++i) {
        header_lines.push_back(to_utf8(header_array[i]));
    }
    std::string bearer = to_utf8(bearer_token);
    std::string base_url = to_utf8(url_value);

    struct DownloadStatus {
        bool ok = false;
        bool skipped = false;
        uint64_t bytes = 0;
    };

    auto download_single = [&](const std::string &source_url, const std::filesystem::path &target_path, const std::string &friendly_name) {
        DownloadStatus status;
        std::error_code fs_error;

        bool exists = std::filesystem::exists(target_path, fs_error);
        fs_error.clear();
        if (exists && skip_existing && !force) {
            log_line("Using existing file " + target_path.string());
            status.ok = true;
            status.skipped = true;
            status.bytes = 0;
            return status;
        }

        if (exists && force) {
            std::filesystem::remove(target_path, fs_error);
            fs_error.clear();
        }

        std::filesystem::create_directories(target_path.parent_path(), fs_error);
        if (fs_error) {
            log_line("Failed to create directory: " + fs_error.message());
            return status;
        }

        std::filesystem::path temp_path = target_path;
        temp_path += ".download";
        if (std::filesystem::exists(temp_path, fs_error)) {
            std::filesystem::remove(temp_path, fs_error);
        }

        FILE *file = std::fopen(temp_path.string().c_str(), "wb");
        if (!file) {
            log_line("Unable to open temp file for writing: " + temp_path.string());
            return status;
        }

        CURL *curl = curl_easy_init();
        if (!curl) {
            std::fclose(file);
            log_line("curl_easy_init failed");
            return status;
        }

        struct curl_slist *header_list = nullptr;
        if (!bearer.empty()) {
            header_list = curl_slist_append(header_list, ("Authorization: Bearer " + bearer).c_str());
        }
        for (const auto &header : header_lines) {
            header_list = curl_slist_append(header_list, header.c_str());
        }

        struct ProgressData {
            std::vector<String> *entries = nullptr;
            std::string label;
            std::chrono::steady_clock::time_point last_emit;
        } progress{&log_entries, friendly_name, std::chrono::steady_clock::now() - std::chrono::seconds(1)};

        curl_easy_setopt(curl, CURLOPT_URL, source_url.c_str());
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, +[](char *ptr, size_t size, size_t nmemb, void *userdata) -> size_t {
            FILE *dest = static_cast<FILE *>(userdata);
            return std::fwrite(ptr, size, nmemb, dest);
        });
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, file);
        curl_easy_setopt(curl, CURLOPT_BUFFERSIZE, 1024 * 1024L);
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, +[](void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t, curl_off_t) -> int {
            auto *progress = static_cast<ProgressData *>(clientp);
            if (!progress || !progress->entries) {
                return 0;
            }
            if (dltotal <= 0) {
                return 0;
            }
            auto now = std::chrono::steady_clock::now();
            if ((now - progress->last_emit) < std::chrono::milliseconds(350) && dlnow < dltotal) {
                return 0;
            }
            progress->last_emit = now;
            double percent = static_cast<double>(dlnow) / static_cast<double>(dltotal) * 100.0;
            std::ostringstream oss;
            oss << progress->label << ": " << std::fixed << std::setprecision(1) << percent
                << "% (" << format_bytes(static_cast<uint64_t>(dlnow))
                << " / " << format_bytes(static_cast<uint64_t>(dltotal)) << ")";
            progress->entries->push_back(String::utf8(oss.str().c_str()));
            return 0;
        });
        curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progress);
        if (timeout_seconds > 0.0) {
            curl_easy_setopt(curl, CURLOPT_TIMEOUT, static_cast<long>(timeout_seconds));
        }
        if (header_list) {
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);
        }

        CURLcode code = curl_easy_perform(curl);
        long http_status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_status);

        if (header_list) {
            curl_slist_free_all(header_list);
        }
        curl_easy_cleanup(curl);
        std::fclose(file);

        if (code != CURLE_OK || http_status < 200 || http_status >= 400) {
            std::ostringstream error_stream;
            error_stream << "Download failed for " << friendly_name
                         << ": " << curl_easy_strerror(code)
                         << " (HTTP " << http_status << ")";
            log_line(error_stream.str());
            std::filesystem::remove(temp_path, fs_error);
            return status;
        }

        std::filesystem::remove(target_path, fs_error);
        fs_error.clear();
        std::filesystem::rename(temp_path, target_path, fs_error);
        if (fs_error) {
            log_line("Failed to finalize download: " + fs_error.message());
            std::filesystem::remove(temp_path, fs_error);
            return status;
        }

        status.ok = true;
        std::error_code size_error;
        status.bytes = static_cast<uint64_t>(std::filesystem::file_size(target_path, size_error));
        if (!size_error) {
            total_bytes += status.bytes;
            std::ostringstream done_line;
            done_line << friendly_name << " saved (" << format_bytes(status.bytes) << ")";
            log_line(done_line.str());
        } else {
            log_line(friendly_name + " saved");
        }

        return status;
    };

    auto primary_status = download_single(base_url, output_path, label);
    if (!primary_status.ok) {
        return finalize(false, "download_failed");
    }
    file_paths.push_back(output_path.string());

    int split_count = read_split_count(output_path);
    if (split_count > 1) {
        auto split_pairs = build_split_pairs(split_count, output_path, base_url);
        if (static_cast<int>(split_pairs.size()) != split_count - 1) {
            return finalize(false, "split_resolution_failed");
        }
        for (int idx = 0; idx < static_cast<int>(split_pairs.size()); ++idx) {
            const auto &pair = split_pairs[static_cast<size_t>(idx)];
            std::string part_label = label + " part " + std::to_string(idx + 2);
            auto status = download_single(pair.first, pair.second, part_label);
            if (!status.ok) {
                return finalize(false, "download_failed");
            }
            file_paths.push_back(pair.second.string());
        }
    }

    return finalize(true, "");
#else
    log_line("llama.cpp built without curl support; downloader unavailable");
    return finalize(false, "curl_not_available");
#endif
}

Dictionary AgentRuntime::run_inference_locked(const Dictionary &request) {
    Dictionary response;
    if (!model_ || !context_) {
        response["ok"] = false;
        response["error"] = "model_not_loaded";
        return response;
    }

    TypedArray<Dictionary> history = request.get("history", TypedArray<Dictionary>());
    String prompt = request.get("prompt", String());
    Dictionary options = default_options_.duplicate();
    if (request.has("options")) {
        Dictionary overrides = request["options"];
        Array keys = overrides.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            options[key] = overrides[key];
        }
    }

    sampler_.reset();
    if (!ensure_sampler_locked(options)) {
        response["ok"] = false;
        response["error"] = "sampler_init_failed";
        return response;
    }

    if (sampler_) {
        llama_sampler_reset(sampler_.get());
    }

    std::string prompt_text = build_prompt(history, prompt);

    const bool add_bos = true;
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        response["ok"] = false;
        response["error"] = "vocab_unavailable";
        return response;
    }

    int token_capacity = llama_tokenize(vocab, prompt_text.c_str(), (int32_t)prompt_text.length(), nullptr, 0, add_bos, false);
    if (token_capacity <= 0) {
        response["ok"] = false;
        response["error"] = "tokenization_failed";
        return response;
    }

    std::vector<llama_token> tokens_prompt(token_capacity);
    llama_tokenize(vocab, prompt_text.c_str(), (int32_t)prompt_text.length(), tokens_prompt.data(), token_capacity, add_bos, false);

    llama_batch batch = llama_batch_get_one(tokens_prompt.data(), token_capacity);

    if (llama_decode(context_, batch)) {
        response["ok"] = false;
        response["error"] = "llama_decode_failed";
        return response;
    }

    int max_tokens = options.get("max_tokens", 256);

    std::ostringstream generated;
    for (int i = 0; i < max_tokens; ++i) {
        llama_token token = llama_sampler_sample(sampler_.get(), context_, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }
        generated << token_to_string(token);

        llama_batch cont = llama_batch_get_one(&token, 1);
        if (llama_decode(context_, cont)) {
            UtilityFunctions::push_warning("llama_decode failed during continuation");
            break;
        }
    }

    String text = String::utf8(generated.str().c_str()).strip_edges();
    response["ok"] = true;
    response["text"] = text;
    return response;
}

bool AgentRuntime::ensure_sampler_locked(const Dictionary &options) {
    llama_sampler *sampler = create_sampler(options);
    if (!sampler) {
        UtilityFunctions::push_error("AgentRuntime::ensure_sampler - failed to create sampler");
        return false;
    }
    sampler_.reset(sampler);
    llama_sampler_reset(sampler_.get());
    return true;
}

std::string AgentRuntime::build_prompt(const TypedArray<Dictionary> &history, const String &user_prompt) const {
    std::ostringstream oss;
    oss << to_utf8(system_prompt_) << "\n";
    for (int i = 0; i < history.size(); ++i) {
        Dictionary entry = history[i];
        String role = entry.get("role", String());
        String content = entry.get("content", String());
        oss << role.utf8().get_data() << ": " << content.utf8().get_data() << "\n";
    }
    if (!user_prompt.is_empty()) {
        oss << "user: " << user_prompt.utf8().get_data() << "\n";
    }
    oss << "assistant:";
    return oss.str();
}

std::string AgentRuntime::token_to_string(llama_token token) const {
    std::string buffer;
    buffer.resize(4096);
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        return std::string();
    }
    int written = llama_token_to_piece(vocab, token, buffer.data(), buffer.size(), 0, false);
    if (written < 0) {
        return std::string();
    }
    buffer.resize(written);
    return buffer;
}

bool AgentRuntime::load_model_locked(const String &path, const Dictionary &options, bool store_defaults) {
    unload_model_locked();

    llama_backend_init();

    llama_model_params model_params = llama_model_default_params();
    if (options.has("n_gpu_layers")) {
        model_params.n_gpu_layers = (int32_t)options["n_gpu_layers"];
    }
    if (options.has("use_mmap")) {
        model_params.use_mmap = (bool)options["use_mmap"];
    }
    if (options.has("use_mlock")) {
        model_params.use_mlock = (bool)options["use_mlock"];
    }

    model_ = llama_model_load_from_file(path.utf8().get_data(), model_params);
    if (!model_) {
        UtilityFunctions::push_error("AgentRuntime::load_model - failed to load: " + path);
        return false;
    }

    llama_context_params ctx_params = llama_context_default_params();
    if (options.has("context_size")) {
        ctx_params.n_ctx = (int32_t)options["context_size"];
    }
    if (options.has("pooling")) {
        ctx_params.pooling_type = static_cast<enum llama_pooling_type>((int)options["pooling"]);
    }

    if (options.has("embedding")) {
        ctx_params.embeddings = (bool)options["embedding"];
    } else if (options.has("embeddings")) {
        ctx_params.embeddings = (bool)options["embeddings"];
    } else {
        ctx_params.embeddings = true;
    }

    context_ = llama_init_from_model(model_, ctx_params);
    if (!context_) {
        UtilityFunctions::push_error("AgentRuntime::load_model - failed to create context");
        unload_model_locked();
        return false;
    }

    if (store_defaults) {
        default_options_.clear();
        Array keys = options.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            default_options_[key] = options[key];
        }
        if (!default_options_.has("embedding")) {
            default_options_["embedding"] = ctx_params.embeddings;
        }
    }

    Dictionary sampler_opts = store_defaults ? default_options_ : options;
    sampler_.reset();
    ensure_sampler_locked(sampler_opts);
    return true;
}

void AgentRuntime::unload_model_locked() {
    if (context_) {
        llama_free(context_);
        context_ = nullptr;
    }
    if (model_) {
        llama_model_free(model_);
        model_ = nullptr;
    }
    sampler_.reset();
    llama_backend_free();
}

void AgentRuntime::set_default_model_path(const String &path) {
    std::scoped_lock lock(mutex_);
    default_model_path_ = path;
}

String AgentRuntime::get_default_model_path() const {
    std::scoped_lock lock(mutex_);
    return default_model_path_;
}

void AgentRuntime::set_runtime_directory(const String &path) {
    std::scoped_lock lock(mutex_);
    runtime_directory_ = path;
}

String AgentRuntime::get_runtime_directory() const {
    std::scoped_lock lock(mutex_);
    return runtime_directory_;
}

void AgentRuntime::set_system_prompt(const String &prompt) {
    std::scoped_lock lock(mutex_);
    system_prompt_ = prompt;
}

String AgentRuntime::get_system_prompt() const {
    std::scoped_lock lock(mutex_);
    return system_prompt_;
}
