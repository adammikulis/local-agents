from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

try:
    from huggingface_hub import hf_hub_download  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - handled at runtime
    hf_hub_download = None

try:
    from llama_cpp import Llama  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - handled at runtime
    Llama = None

REPO_ID = "Qwen/Qwen3-0.6B-Instruct-GGUF"
FILENAME = "Qwen3-0.6B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_DIR = Path(os.environ.get("LOCAL_AGENTS_MODEL_DIR", ".models"))
LLAMA_CPP_MODELS_INDEX_URL = "https://raw.githubusercontent.com/ggerganov/llama.cpp/master/models/models.json"
PACKAGED_MODELS_INDEX = Path(__file__).resolve().parent / "data" / "llama_cpp_models.json"


@dataclass(frozen=True)
class ModelArtifact:
    """Represents a single downloadable artifact for a model variant."""

    filename: str
    quantization: Optional[str]
    format: Optional[str]
    repo_id: Optional[str]
    url: Optional[str]
    size_bytes: Optional[int]


@dataclass(frozen=True)
class ModelVariant:
    """Metadata for an individual model variant."""

    family_id: str
    family_name: str
    variant_id: str
    display_name: str
    parameters: Optional[str]
    context_length: Optional[int]
    description: Optional[str]
    license: Optional[str]
    repo_id: Optional[str]
    artifacts: tuple[ModelArtifact, ...]


def _load_packaged_models_index() -> Dict[str, Any]:
    """Load the bundled llama.cpp models catalog."""

    if not PACKAGED_MODELS_INDEX.exists():
        raise FileNotFoundError(f"Packaged llama.cpp catalog missing: {PACKAGED_MODELS_INDEX}")
    with PACKAGED_MODELS_INDEX.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _download_remote_models_index(timeout: float = 10.0) -> Dict[str, Any]:
    """Download the upstream llama.cpp models catalog from GitHub."""

    with urlopen(LLAMA_CPP_MODELS_INDEX_URL, timeout=timeout) as response:  # nosec: B310 - trusted source
        status = getattr(response, "status", response.getcode())
        if status != 200:
            raise HTTPError(LLAMA_CPP_MODELS_INDEX_URL, status, "unexpected status code", hdrs=None, fp=None)
        payload = response.read()
    return json.loads(payload.decode("utf-8"))


def load_llama_cpp_model_catalog(*, prefer_remote: bool = True, timeout: float = 10.0) -> Dict[str, Any]:
    """Load the llama.cpp model catalog, optionally attempting a remote refresh first."""

    errors: list[Exception] = []
    if prefer_remote:
        try:
            return _download_remote_models_index(timeout=timeout)
        except (URLError, HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            errors.append(exc)

    try:
        return _load_packaged_models_index()
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(exc)

    details = "; ".join(str(error) for error in errors) or "unknown error"
    raise RuntimeError(f"Unable to load llama.cpp model catalog: {details}")


def _coerce_optional_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return None
        try:
            return int(float(stripped.replace(",", "")))
        except ValueError:
            return None
    return None


def _coerce_optional_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    return str(value)


def _iter_variants_from_catalog(raw_catalog: Dict[str, Any]) -> Iterable[ModelVariant]:
    families: Iterable[Any]
    if isinstance(raw_catalog.get("families"), list):
        families = raw_catalog["families"]
    elif isinstance(raw_catalog.get("families"), dict):
        families = raw_catalog["families"].values()
    elif isinstance(raw_catalog, dict):
        # Some historical catalogs expose the family list at the top-level under "models"
        families = raw_catalog.get("models", [])
    else:
        families = []

    for family_index, family_entry in enumerate(families):
        if not isinstance(family_entry, dict):
            continue
        family_id = _coerce_optional_str(
            family_entry.get("id")
            or family_entry.get("slug")
            or family_entry.get("family")
            or family_entry.get("name")
        ) or f"family-{family_index}"
        family_name = _coerce_optional_str(
            family_entry.get("display_name")
            or family_entry.get("name")
            or family_entry.get("title")
            or family_id
        ) or family_id

        variant_entries: Iterable[Any]
        if isinstance(family_entry.get("variants"), list):
            variant_entries = family_entry["variants"]
        elif isinstance(family_entry.get("models"), list):
            variant_entries = family_entry["models"]
        else:
            variant_entries = []

        for variant_index, variant_entry in enumerate(variant_entries):
            if not isinstance(variant_entry, dict):
                continue
            variant_id = _coerce_optional_str(
                variant_entry.get("id")
                or variant_entry.get("slug")
                or variant_entry.get("name")
                or variant_entry.get("model")
            ) or f"{family_id}-variant-{variant_index}"
            display_name = _coerce_optional_str(
                variant_entry.get("display_name")
                or variant_entry.get("name")
                or variant_entry.get("title")
                or variant_id
            ) or variant_id
            repo_id = _coerce_optional_str(variant_entry.get("repo_id"))
            description = _coerce_optional_str(variant_entry.get("description"))
            license_name = _coerce_optional_str(variant_entry.get("license"))
            parameters = _coerce_optional_str(variant_entry.get("parameters"))
            context_length = _coerce_optional_int(variant_entry.get("context_length"))

            file_entries: Iterable[Any]
            if isinstance(variant_entry.get("files"), list):
                file_entries = variant_entry["files"]
            elif isinstance(variant_entry.get("artifacts"), list):
                file_entries = variant_entry["artifacts"]
            else:
                file_entries = []

            artifacts: List[ModelArtifact] = []
            for file_entry in file_entries:
                if not isinstance(file_entry, dict):
                    continue
                filename = _coerce_optional_str(
                    file_entry.get("filename")
                    or file_entry.get("name")
                    or file_entry.get("path")
                )
                if not filename:
                    continue
                artifact_repo = _coerce_optional_str(file_entry.get("repo_id")) or repo_id
                quantization = _coerce_optional_str(
                    file_entry.get("quantization")
                    or file_entry.get("variant")
                    or file_entry.get("dtype")
                )
                file_format = _coerce_optional_str(file_entry.get("format"))
                size_bytes = _coerce_optional_int(
                    file_entry.get("size_bytes")
                    or file_entry.get("size")
                    or file_entry.get("file_size")
                )
                url = _coerce_optional_str(file_entry.get("url"))
                artifacts.append(
                    ModelArtifact(
                        filename=filename,
                        quantization=quantization,
                        format=file_format,
                        repo_id=artifact_repo,
                        url=url,
                        size_bytes=size_bytes,
                    )
                )

            yield ModelVariant(
                family_id=family_id,
                family_name=family_name,
                variant_id=variant_id,
                display_name=display_name,
                parameters=parameters,
                context_length=context_length,
                description=description,
                license=license_name,
                repo_id=repo_id,
                artifacts=tuple(artifacts),
            )


def _build_catalog_index(catalog: Dict[str, Any]) -> Dict[str, List[ModelVariant]]:
    index: Dict[str, List[ModelVariant]] = {}
    for variant in _iter_variants_from_catalog(catalog):
        index.setdefault(variant.family_id, []).append(variant)
    return index


def list_llama_cpp_model_families(
    catalog: Optional[Dict[str, Any]] = None,
    *,
    prefer_remote: bool = True,
    timeout: float = 10.0,
) -> List[str]:
    """Return the available model family identifiers."""

    if catalog is None:
        catalog = load_llama_cpp_model_catalog(prefer_remote=prefer_remote, timeout=timeout)
    return sorted(_build_catalog_index(catalog).keys())


def get_llama_cpp_model_variants(
    family_id: str,
    catalog: Optional[Dict[str, Any]] = None,
    *,
    prefer_remote: bool = True,
    timeout: float = 10.0,
) -> List[ModelVariant]:
    """Return the variants for a given model family."""

    if catalog is None:
        catalog = load_llama_cpp_model_catalog(prefer_remote=prefer_remote, timeout=timeout)
    index = _build_catalog_index(catalog)
    return index.get(family_id, [])


def _select_variant(
    family_id: str,
    variant_id: Optional[str],
    *,
    catalog: Optional[Dict[str, Any]] = None,
    prefer_remote: bool = True,
    timeout: float = 10.0,
) -> ModelVariant:
    variants = get_llama_cpp_model_variants(
        family_id,
        catalog=catalog,
        prefer_remote=prefer_remote,
        timeout=timeout,
    )
    if not variants:
        raise KeyError(f"Unknown model family: {family_id}")
    if variant_id is None:
        if len(variants) == 1:
            return variants[0]
        raise ValueError(f"Multiple variants available for family '{family_id}'; specify variant_id explicitly.")
    for variant in variants:
        if variant.variant_id == variant_id:
            return variant
    raise KeyError(f"Variant '{variant_id}' not found for family '{family_id}'")


def _select_artifact(variant: ModelVariant, quantization: Optional[str]) -> ModelArtifact:
    if not variant.artifacts:
        raise RuntimeError(f"Variant '{variant.variant_id}' does not include any downloadable artifacts.")
    if quantization is None:
        if len(variant.artifacts) == 1:
            return variant.artifacts[0]
        raise ValueError(
            "Multiple artifacts available; specify the desired quantization via the 'quantization' argument."
        )
    for artifact in variant.artifacts:
        if artifact.quantization and artifact.quantization.lower() == quantization.lower():
            return artifact
    raise KeyError(
        f"Quantization '{quantization}' not available for variant '{variant.variant_id}'."
    )


def _download_via_http(url: str, destination: Path, *, chunk_size: int = 1024 * 1024) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(url) as response:  # nosec: B310 - trusted sources only
        status = getattr(response, "status", response.getcode())
        if status != 200:
            raise HTTPError(url, status, "unexpected status code", hdrs=None, fp=None)
        with tempfile.NamedTemporaryFile(delete=False, dir=str(destination.parent)) as tmp_file:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                tmp_file.write(chunk)
            tmp_path = Path(tmp_file.name)
    tmp_path.replace(destination)
    return destination


def download_llama_cpp_model(
    family_id: str,
    *,
    variant_id: Optional[str] = None,
    quantization: Optional[str] = None,
    cache_dir: Optional[Path] = None,
    catalog: Optional[Dict[str, Any]] = None,
    prefer_remote: bool = True,
    timeout: float = 10.0,
) -> Path:
    """Download a model from the llama.cpp catalog.

    When `quantization` is omitted and the variant exposes a single artifact, the
    downloader selects it automatically. Hugging Face downloads are preferred
    when the entry includes a `repo_id`.
    """

    variant = _select_variant(
        family_id,
        variant_id,
        catalog=catalog,
        prefer_remote=prefer_remote,
        timeout=timeout,
    )
    artifact = _select_artifact(variant, quantization)

    target_dir = cache_dir or DEFAULT_MODEL_DIR
    target_dir.mkdir(parents=True, exist_ok=True)

    if hf_hub_download is not None and artifact.repo_id:
        return Path(
            hf_hub_download(
                repo_id=artifact.repo_id,
                filename=artifact.filename,
                repo_type="model",
                local_dir=target_dir,
                local_dir_use_symlinks=False,
            )
        )

    if artifact.url:
        destination = target_dir / artifact.filename
        return _download_via_http(artifact.url, destination)

    raise RuntimeError(
        "No download location is available for the requested model artifact."
    )


def ensure_qwen3_model(cache_dir: Optional[Path] = None) -> Path:
    """Download the Qwen3-0.6B-Instruct model if it is not already cached."""

    if hf_hub_download is None:
        raise RuntimeError("huggingface_hub is required to download models. Install it before running inference.")

    target_dir = cache_dir or DEFAULT_MODEL_DIR
    target_dir.mkdir(parents=True, exist_ok=True)
    model_path = hf_hub_download(
        repo_id=REPO_ID,
        filename=FILENAME,
        repo_type="model",
        local_dir=target_dir,
        local_dir_use_symlinks=False,
    )
    return Path(model_path)


def _format_chat_prompt(system_prompt: str, user_prompt: str) -> str:
    return (
        "<|im_start|>system\n"
        f"{system_prompt}\n"
        "<|im_end|>\n"
        "<|im_start|>user\n"
        f"{user_prompt}\n"
        "<|im_end|>\n"
        "<|im_start|>assistant\n"
    )


def run_chat_completion(
    model_path: Path,
    prompt: str,
    *,
    system_prompt: str = "You are a helpful assistant.",
    max_tokens: int = 128,
    temperature: float = 0.7,
    n_threads: Optional[int] = None,
    n_ctx: int = 2048,
) -> str:
    """Run a chat-style completion using llama.cpp via the python bindings."""

    if n_threads is None:
        cpu_count = os.cpu_count() or 1
        n_threads = max(1, min(8, cpu_count))

    if Llama is None:
        raise RuntimeError("llama_cpp is required for inference. Install llama-cpp-python before running inference.")

    llm = Llama(
        model_path=str(model_path),
        n_ctx=n_ctx,
        n_threads=n_threads,
        n_gpu_layers=0,
        logits_all=False,
    )

    raw_prompt = _format_chat_prompt(system_prompt, prompt)
    result = llm.create_completion(
        raw_prompt,
        temperature=temperature,
        max_tokens=max_tokens,
        top_p=0.95,
        stop=["<|im_end|>", "<|im_start|>"],
    )
    text = result["choices"][0]["text"].strip()
    return text
