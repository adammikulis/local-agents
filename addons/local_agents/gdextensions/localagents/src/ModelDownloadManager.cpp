#include "ModelDownloadManager.hpp"

#include "RuntimeStringUtils.hpp"

#include <godot_cpp/variant/utility_functions.hpp>

#include <llama.h>

#include <gguf.h>
#include <common/common.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>
#include <fstream>
#include <chrono>

#ifndef _WIN32
#include <sys/wait.h>
#endif

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#elif __has_include(<openssl/sha.h>)
#include <openssl/sha.h>
#endif

namespace godot {

using local_agents::runtime::from_utf8;
using local_agents::runtime::to_utf8;

namespace {
#ifdef _WIN32
constexpr const char *kExecutableExtension = ".exe";
#else
constexpr const char *kExecutableExtension = "";
#endif

constexpr size_t kPathBufferSize = 4096;

#ifdef _WIN32
std::optional<std::string> get_env_value(const std::string &key) {
    size_t len = 0;
    char *buffer = nullptr;
    if (_dupenv_s(&buffer, &len, key.c_str()) != 0) {
        return std::nullopt;
    }
    std::optional<std::string> result;
    if (buffer) {
        result = std::string(buffer, len > 0 ? len - 1 : 0);
        free(buffer);
    }
    return result;
}

bool set_env_value(const std::string &key, const std::string &value) {
    return _putenv_s(key.c_str(), value.c_str()) == 0;
}

bool unset_env_value(const std::string &key) {
    return _putenv_s(key.c_str(), "") == 0;
}
#else
std::optional<std::string> get_env_value(const std::string &key) {
    const char *value = std::getenv(key.c_str());
    if (!value) {
        return std::nullopt;
    }
    return std::string(value);
}

bool set_env_value(const std::string &key, const std::string &value) {
    return setenv(key.c_str(), value.c_str(), 1) == 0;
}

bool unset_env_value(const std::string &key) {
    return unsetenv(key.c_str()) == 0;
}
#endif

class EnvironmentOverride {
public:
    EnvironmentOverride(const std::string &key, const std::string &value) : key_(key) {
        previous_ = get_env_value(key);
        had_previous_ = previous_.has_value();
        valid_ = set_env_value(key, value);
    }

    EnvironmentOverride(const EnvironmentOverride &) = delete;
    EnvironmentOverride &operator=(const EnvironmentOverride &) = delete;

    EnvironmentOverride(EnvironmentOverride &&other) noexcept {
        *this = std::move(other);
    }

    EnvironmentOverride &operator=(EnvironmentOverride &&other) noexcept {
        if (this != &other) {
            restore();
            key_ = std::move(other.key_);
            previous_ = std::move(other.previous_);
            had_previous_ = other.had_previous_;
            valid_ = other.valid_;
            other.valid_ = false;
            other.had_previous_ = false;
        }
        return *this;
    }

    ~EnvironmentOverride() {
        restore();
    }

    bool valid() const { return valid_; }

private:
    void restore() {
        if (!valid_) {
            return;
        }
        if (had_previous_) {
            set_env_value(key_, previous_.value());
        } else {
            unset_env_value(key_);
        }
        valid_ = false;
    }

    std::string key_;
    std::optional<std::string> previous_;
    bool had_previous_ = false;
    bool valid_ = false;
};

int64_t file_size_bytes(const std::filesystem::path &path) {
    std::error_code ec;
    auto size = std::filesystem::file_size(path, ec);
    if (ec) {
        return 0;
    }
    return static_cast<int64_t>(size);
}

std::string json_escape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        switch (ch) {
            case '\"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out.push_back(ch); break;
        }
    }
    return out;
}

std::string sha256_file_hex(const std::filesystem::path &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in.good()) {
        return std::string();
    }
    constexpr size_t kBufferSize = 1 << 15;
    std::array<char, kBufferSize> buffer{};

#if defined(__APPLE__)
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (in.good()) {
        in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        std::streamsize got = in.gcount();
        if (got > 0) {
            CC_SHA256_Update(&ctx, reinterpret_cast<const unsigned char *>(buffer.data()), static_cast<CC_LONG>(got));
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    constexpr size_t digest_len = CC_SHA256_DIGEST_LENGTH;
#elif defined(SHA256_DIGEST_LENGTH)
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    while (in.good()) {
        in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        std::streamsize got = in.gcount();
        if (got > 0) {
            SHA256_Update(&ctx, buffer.data(), static_cast<size_t>(got));
        }
    }
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256_Final(digest, &ctx);
    constexpr size_t digest_len = SHA256_DIGEST_LENGTH;
#else
    (void)buffer;
    return std::string();
#endif

    static const char *hex = "0123456789abcdef";
    std::string out;
    out.resize(digest_len * 2);
    for (size_t i = 0; i < digest_len; ++i) {
        out[2 * i] = hex[(digest[i] >> 4) & 0x0F];
        out[2 * i + 1] = hex[digest[i] & 0x0F];
    }
    return out;
}

bool write_download_manifest(
    const std::filesystem::path &file_path,
    const Dictionary &request,
    const std::string &sha256,
    int64_t bytes_total
) {
    std::filesystem::path manifest_path = file_path;
    manifest_path += ".manifest.json";
    std::ofstream out(manifest_path, std::ios::trunc);
    if (!out.good()) {
        return false;
    }

    String hf_repo = request.get("hf_repo", String());
    String hf_file = request.get("hf_file", String());
    String hf_tag = request.get("hf_tag", String());
    String url = request.get("url", String());
    String label = request.get("label", String());
    String expected_sha = request.get("sha256", String());

    auto now = std::chrono::system_clock::now();
    auto now_epoch = std::chrono::duration_cast<std::chrono::seconds>(now.time_since_epoch()).count();

    out << "{\n";
    out << "  \"path\": \"" << json_escape(file_path.string()) << "\",\n";
    out << "  \"label\": \"" << json_escape(to_utf8(label)) << "\",\n";
    out << "  \"bytes\": " << bytes_total << ",\n";
    out << "  \"sha256\": \"" << json_escape(sha256) << "\",\n";
    out << "  \"expected_sha256\": \"" << json_escape(to_utf8(expected_sha)) << "\",\n";
    out << "  \"hf_repo\": \"" << json_escape(to_utf8(hf_repo)) << "\",\n";
    out << "  \"hf_file\": \"" << json_escape(to_utf8(hf_file)) << "\",\n";
    out << "  \"hf_tag\": \"" << json_escape(to_utf8(hf_tag)) << "\",\n";
    out << "  \"url\": \"" << json_escape(to_utf8(url)) << "\",\n";
    out << "  \"generated_at_epoch\": " << now_epoch << "\n";
    out << "}\n";
    return out.good();
}

int read_split_count(const std::filesystem::path &primary_path) {
    struct gguf_init_params params = {true, nullptr};
    gguf_context *ctx = gguf_init_from_file(primary_path.string().c_str(), params);
    if (!ctx) {
        return 0;
    }
    int split = 0;
    int key_index = gguf_find_key(ctx, LLM_KV_SPLIT_COUNT);
    if (key_index >= 0) {
        split = static_cast<int>(gguf_get_val_u16(ctx, key_index));
    }
    gguf_free(ctx);
    return split;
}

std::vector<std::filesystem::path> build_split_paths(int split_count, const std::filesystem::path &primary_path) {
    std::vector<std::filesystem::path> paths;
    if (split_count <= 1) {
        return paths;
    }

    char path_prefix[kPathBufferSize] = {0};
    if (!llama_split_prefix(path_prefix, sizeof(path_prefix), primary_path.string().c_str(), 0, split_count)) {
        return std::vector<std::filesystem::path>();
    }
    for (int idx = 1; idx < split_count; ++idx) {
        char path_buffer[kPathBufferSize] = {0};
        if (!llama_split_path(path_buffer, sizeof(path_buffer), path_prefix, idx, split_count)) {
            return std::vector<std::filesystem::path>();
        }
        paths.emplace_back(std::filesystem::path(path_buffer));
    }
    return paths;
}

struct ProgressState {
    double last_fraction = -1.0;
};

void emit_progress_from_line(const std::string &line,
                             const ModelDownloadManager::Callbacks &callbacks,
                             const String &label,
                             const String &path,
                             ProgressState &state) {
    if (!callbacks.progress) {
        return;
    }

    static const std::regex kMbPattern(R"(([-+]?[0-9]*\.?[0-9]+)\s*MB\s*/\s*([-+]?[0-9]*\.?[0-9]+)\s*MB)");
    std::smatch match;
    if (!std::regex_search(line, match, kMbPattern)) {
        return;
    }

    std::string current_str = match[1].str();
    std::string total_str = match[2].str();
    char *current_end = nullptr;
    char *total_end = nullptr;
    double current_mb = std::strtod(current_str.c_str(), &current_end);
    double total_mb = std::strtod(total_str.c_str(), &total_end);
    if (current_end == current_str.c_str() || total_end == total_str.c_str()) {
        return;
    }
    if (total_mb <= 0.0) {
        return;
    }

    double fraction = current_mb / total_mb;
    if (fraction < 0.0) {
        fraction = 0.0;
    } else if (fraction > 1.0) {
        fraction = 1.0;
    }

    if (fraction > state.last_fraction + 0.0001) {
        state.last_fraction = fraction;
        int64_t received = static_cast<int64_t>(current_mb * 1024.0 * 1024.0);
        int64_t total = static_cast<int64_t>(total_mb * 1024.0 * 1024.0);
        callbacks.progress(label, fraction, received, total, path);
    }
}

#ifdef _WIN32
FILE *popen_command(const std::string &command) {
    return _popen(command.c_str(), "r");
}

int pclose_command(FILE *pipe) {
    return _pclose(pipe);
}
#else
FILE *popen_command(const std::string &command) {
    return popen(command.c_str(), "r");
}

int pclose_command(FILE *pipe) {
    return pclose(pipe);
}
#endif

int parse_exit_code(int status) {
#ifdef _WIN32
    return status;
#else
    if (status == -1) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
#endif
}

void ensure_directory(const std::filesystem::path &dir) {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
}

} // namespace

Dictionary ModelDownloadManager::download(const Dictionary &request,
                                          const Callbacks &callbacks,
                                          const String &runtime_directory) const {
    Dictionary response;
    std::vector<String> log_entries;

    auto to_packed = [](const std::vector<String> &lines) {
        PackedStringArray array;
        array.resize(static_cast<int64_t>(lines.size()));
        for (int64_t i = 0; i < array.size(); ++i) {
            array[i] = lines[static_cast<size_t>(i)];
        }
        return array;
    };

    auto emit_log = [&](const std::string &line, const String &path) {
        String message = from_utf8(line);
        log_entries.push_back(message);
        if (callbacks.log) {
            callbacks.log(message, path);
        }
    };

    Dictionary hf_details;

    auto finalize = [&](bool ok, const std::string &error, const std::filesystem::path &path,
                        const std::vector<std::filesystem::path> &files, int64_t bytes) {
        response["ok"] = ok;
        response["bytes_downloaded"] = bytes;
        response["log"] = to_packed(log_entries);
        if (!error.empty()) {
            response["error"] = from_utf8(error);
        }
        if (!files.empty()) {
            PackedStringArray packed;
            packed.resize(static_cast<int64_t>(files.size()));
            for (int64_t i = 0; i < packed.size(); ++i) {
                packed[i] = from_utf8(files[static_cast<size_t>(i)].string());
            }
            response["files"] = packed;
            response["path"] = from_utf8(files.front().string());
        } else if (!path.empty()) {
            response["path"] = from_utf8(path.string());
        }
        response["log"] = to_packed(log_entries);
        if (!hf_details.is_empty()) {
            response["hf"] = hf_details;
        }
        return response;
    };

    String output_value = request.get("output_path", String());
    if (output_value.is_empty()) {
        emit_log("Missing output path", String());
        return finalize(false, "missing_output_path", {}, {}, 0);
    }

    std::filesystem::path output_path = std::filesystem::path(to_utf8(output_value)).lexically_normal();
    ensure_directory(output_path.parent_path());

    String output_path_string = from_utf8(output_path.string());

    String label_value = request.get("label", String());
    String label = label_value.is_empty() ? from_utf8(output_path.filename().string()) : label_value;

    if (callbacks.started) {
        callbacks.started(label, from_utf8(output_path.string()));
    }
    if (callbacks.progress) {
        callbacks.progress(label, 0.0, 0, 0, from_utf8(output_path.string()));
    }

    bool force = request.get("force", false);
    bool skip_existing = request.has("skip_existing") ? (bool)request["skip_existing"] : !force;
    bool offline = request.get("offline", false);
    String expected_sha256_value = String(request.get("sha256", String())).strip_edges().to_lower();

    auto build_existing_response = [&](const std::filesystem::path &path) {
        std::vector<std::filesystem::path> files;
        files.push_back(path);
        int64_t total_bytes = file_size_bytes(path);

        int split_count = read_split_count(path);
        if (split_count > 1) {
            auto split_paths = build_split_paths(split_count, path);
            if (static_cast<int>(split_paths.size()) != split_count - 1) {
                emit_log("Failed to resolve split files", output_path_string);
                return finalize(false, "split_resolution_failed", path, {}, 0);
            }
            for (const auto &split : split_paths) {
                files.push_back(split);
                total_bytes += file_size_bytes(split);
            }
        }

        std::string sha256 = sha256_file_hex(path);
        if (!expected_sha256_value.is_empty() && !sha256.empty() && sha256 != to_utf8(expected_sha256_value)) {
            emit_log("Cached file checksum mismatch for " + path.string(), output_path_string);
            if (callbacks.finished) {
                callbacks.finished(false, from_utf8("checksum_mismatch"), from_utf8(path.string()));
            }
            return finalize(false, "checksum_mismatch", path, {}, 0);
        }
        if (!sha256.empty()) {
            response["sha256"] = from_utf8(sha256);
        }
        response["checksum_verified"] = expected_sha256_value.is_empty() || (!sha256.empty() && sha256 == to_utf8(expected_sha256_value));
        write_download_manifest(path, request, sha256, total_bytes);

        if (callbacks.progress) {
            callbacks.progress(label, 1.0, total_bytes, total_bytes, from_utf8(path.string()));
        }
        if (callbacks.finished) {
            callbacks.finished(true, String(), from_utf8(path.string()));
        }
        emit_log("Using cached model " + path.string(), output_path_string);
        return finalize(true, std::string(), path, files, total_bytes);
    };

    if ((skip_existing || offline) && std::filesystem::exists(output_path)) {
        return build_existing_response(output_path);
    }

    if (offline) {
        emit_log("Offline mode: missing model file at " + output_path.string(), output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("offline_missing_file"), from_utf8(output_path.string()));
        }
        return finalize(false, "offline_missing_file", output_path, {}, 0);
    }

    String hf_repo_value = request.get("hf_repo", String());
    String hf_file_value = request.get("hf_file", String());
    if (hf_repo_value.is_empty() || hf_file_value.is_empty()) {
        emit_log("Missing Hugging Face repository or file information", output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("missing_hf_info"), from_utf8(output_path.string()));
        }
        return finalize(false, "missing_hf_info", output_path, {}, 0);
    }

    hf_details["repo"] = hf_repo_value;
    hf_details["file"] = hf_file_value;

    std::string repo_cli = to_utf8(hf_repo_value);
    String hf_tag_value = request.get("hf_tag", String());
    if (!hf_tag_value.is_empty()) {
        repo_cli += ":" + to_utf8(hf_tag_value);
        hf_details["tag"] = hf_tag_value;
    }

    std::filesystem::path runtime_path;
    if (!runtime_directory.is_empty()) {
        runtime_path = std::filesystem::path(to_utf8(runtime_directory));
    }

    std::vector<std::filesystem::path> cli_candidates;
    if (!runtime_path.empty()) {
        cli_candidates.push_back(runtime_path / "llama-cli");
        auto parent = runtime_path.parent_path();
        if (!parent.empty()) {
            cli_candidates.push_back(parent / "llama-cli");
            auto grand_parent = parent.parent_path();
            if (!grand_parent.empty()) {
                cli_candidates.push_back(grand_parent / "llama-cli");
            }
        }
    }
    cli_candidates.push_back(std::filesystem::path("llama-cli"));

    std::filesystem::path cli_path;
    for (auto candidate : cli_candidates) {
        candidate += kExecutableExtension;
        if (std::filesystem::exists(candidate)) {
            cli_path = candidate;
            break;
        }
    }

    if (cli_path.empty()) {
        emit_log("llama-cli executable not found in runtime directories", output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("llama_cli_missing"), from_utf8(output_path.string()));
        }
        return finalize(false, "llama_cli_missing", output_path, {}, 0);
    }

    std::vector<EnvironmentOverride> env_overrides;
    std::filesystem::path cache_dir = output_path.parent_path();
    env_overrides.emplace_back("LLAMA_CACHE", cache_dir.string());
    if (!env_overrides.back().valid()) {
        emit_log("Failed to set LLAMA_CACHE environment variable", output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("env_setup_failed"), from_utf8(output_path.string()));
        }
        return finalize(false, "env_setup_failed", output_path, {}, 0);
    }

    String hf_endpoint_override = request.get("hf_endpoint", String());
    if (!hf_endpoint_override.is_empty()) {
        env_overrides.emplace_back("MODEL_ENDPOINT", to_utf8(hf_endpoint_override));
        if (!env_overrides.back().valid()) {
            emit_log("Failed to set MODEL_ENDPOINT environment variable", output_path_string);
            if (callbacks.finished) {
                callbacks.finished(false, from_utf8("env_setup_failed"), from_utf8(output_path.string()));
            }
            return finalize(false, "env_setup_failed", output_path, {}, 0);
        }
        env_overrides.emplace_back("HF_ENDPOINT", to_utf8(hf_endpoint_override));
        if (!env_overrides.back().valid()) {
            emit_log("Failed to set HF_ENDPOINT environment variable", output_path_string);
            if (callbacks.finished) {
                callbacks.finished(false, from_utf8("env_setup_failed"), from_utf8(output_path.string()));
            }
            return finalize(false, "env_setup_failed", output_path, {}, 0);
        }
    }

    String bearer_token = request.get("bearer_token", String());
    if (!bearer_token.is_empty()) {
        env_overrides.emplace_back("HF_TOKEN", to_utf8(bearer_token));
        if (!env_overrides.back().valid()) {
            emit_log("Failed to set HF_TOKEN environment variable", output_path_string);
            if (callbacks.finished) {
                callbacks.finished(false, from_utf8("env_setup_failed"), from_utf8(output_path.string()));
            }
            return finalize(false, "env_setup_failed", output_path, {}, 0);
        }
    }

    std::ostringstream command;
    command << '"' << cli_path.string() << '"';
    command << " -m \"" << output_path.string() << "\"";
    command << " --hf-repo \"" << repo_cli << "\"";
    command << " --hf-file \"" << to_utf8(hf_file_value) << "\"";
    if (request.get("no_mmproj", false)) {
        command << " --no-mmproj";
    }
    command << " 2>&1";

    FILE *pipe = popen_command(command.str());
    if (!pipe) {
        emit_log("Failed to launch llama-cli", output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("llama_cli_launch_failed"), from_utf8(output_path.string()));
        }
        return finalize(false, "llama_cli_launch_failed", output_path, {}, 0);
    }

    std::string buffer;
    buffer.reserve(256);
    ProgressState progress_state;
    auto emit_progress_line = [&](const std::string &line_clean) {
        emit_progress_from_line(line_clean, callbacks, label, from_utf8(output_path.string()), progress_state);
    };

    std::array<char, 512> chunk{};
    while (fgets(chunk.data(), static_cast<int>(chunk.size()), pipe)) {
        buffer.append(chunk.data());
        size_t pos = 0;
        while (true) {
            size_t newline_pos = buffer.find_first_of("\r\n", pos);
            if (newline_pos == std::string::npos) {
                break;
            }
            std::string line = buffer.substr(pos, newline_pos - pos);
            if (!line.empty()) {
                emit_log(line, output_path_string);
                emit_progress_line(line);
            }
            pos = newline_pos + 1;
        }
        if (pos > 0) {
            buffer.erase(0, pos);
        }
    }

    if (!buffer.empty()) {
        emit_log(buffer, output_path_string);
        emit_progress_line(buffer);
    }

    int status = pclose_command(pipe);
    int exit_code = parse_exit_code(status);
    if (exit_code != 0) {
        emit_log("llama-cli exited with code " + std::to_string(exit_code), output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("llama_cli_failed"), from_utf8(output_path.string()));
        }
        return finalize(false, "llama_cli_failed", output_path, {}, 0);
    }

    if (!std::filesystem::exists(output_path)) {
        emit_log("Download completed but output file missing: " + output_path.string(), output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("download_missing_output"), from_utf8(output_path.string()));
        }
        return finalize(false, "download_missing_output", output_path, {}, 0);
    }

    std::vector<std::filesystem::path> files;
    files.push_back(output_path);
    int64_t total_bytes = file_size_bytes(output_path);

    int split_count = read_split_count(output_path);
    if (split_count > 1) {
        auto split_paths = build_split_paths(split_count, output_path);
        if (static_cast<int>(split_paths.size()) != split_count - 1) {
            emit_log("Unable to resolve GGUF split paths", output_path_string);
            if (callbacks.finished) {
                callbacks.finished(false, from_utf8("split_resolution_failed"), from_utf8(output_path.string()));
            }
            return finalize(false, "split_resolution_failed", output_path, {}, 0);
        }
        for (const auto &split : split_paths) {
            files.push_back(split);
            total_bytes += file_size_bytes(split);
        }
    }

    std::string sha256 = sha256_file_hex(output_path);
    if (!expected_sha256_value.is_empty() && !sha256.empty() && sha256 != to_utf8(expected_sha256_value)) {
        emit_log("Downloaded file checksum mismatch for " + output_path.string(), output_path_string);
        if (callbacks.finished) {
            callbacks.finished(false, from_utf8("checksum_mismatch"), from_utf8(output_path.string()));
        }
        return finalize(false, "checksum_mismatch", output_path, {}, 0);
    }
    if (!sha256.empty()) {
        response["sha256"] = from_utf8(sha256);
    }
    response["checksum_verified"] = expected_sha256_value.is_empty() || (!sha256.empty() && sha256 == to_utf8(expected_sha256_value));
    if (!write_download_manifest(output_path, request, sha256, total_bytes)) {
        emit_log("Warning: failed to write manifest for " + output_path.string(), output_path_string);
    }

    if (callbacks.progress) {
        callbacks.progress(label, 1.0, total_bytes, total_bytes, from_utf8(output_path.string()));
    }
    if (callbacks.finished) {
        callbacks.finished(true, String(), from_utf8(output_path.string()));
    }

    return finalize(true, std::string(), output_path, files, total_bytes);
}

} // namespace godot
