import atexit
import glob
import json
import logging
import os
import shutil
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

import torch
from fastapi import BackgroundTasks, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from transformers import AutoModelForSequenceClassification, AutoTokenizer


# Logging must be initialized before any startup logic runs. If model loading
# fails early, we still want structured logs rather than a NameError.
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="[%(levelname)s] %(message)s")
LOGGER = logging.getLogger("yt_live_chat_filter")


def get_base_path() -> Path:
    """Return the writable base path for the current execution mode."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parents[1]


def get_model_path() -> Path:
    """Return the bundled model path for local/script execution modes."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "model"
    return Path(__file__).resolve().parents[1] / "model"


def get_user_data_path() -> Path:
    """Create and return the writable data directory used by the service."""
    user_data_dir = get_base_path() / "user_data"
    user_data_dir.mkdir(exist_ok=True)
    return user_data_dir


def _get_env_bool(name: str, default: bool) -> bool:
    """Parse common boolean env var strings with a predictable fallback."""
    raw_value = os.environ.get(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def _get_env_csv(name: str, default: str = "") -> List[str]:
    """Split comma-separated env vars while ignoring empty entries."""
    raw_value = os.environ.get(name, default)
    return [item.strip() for item in raw_value.split(",") if item.strip()]


def _parse_allowed_origins() -> List[str]:
    """Return explicit CORS origins. Wildcards are intentionally avoided."""
    default_origins = ",".join(
        [
            "http://localhost",
            "http://127.0.0.1",
            "http://localhost:3000",
            "http://127.0.0.1:3000",
        ]
    )
    return _get_env_csv("ALLOWED_ORIGINS", default_origins)


def _parse_allowed_extension_ids() -> Set[str]:
    """
    Return extension ids that are allowed to call the API.

    Chrome extensions send origins like `chrome-extension://<extension-id>`.
    FastAPI CORS middleware cannot match `chrome-extension://*` safely, so we
    explicitly expand only the ids we trust.
    """
    return set(_get_env_csv("ALLOWED_EXTENSION_IDS"))


class Settings(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8000
    log_predictions: bool = True
    enable_traffic_metrics: bool = True
    metrics_log_interval_seconds: int = 60
    enable_rate_limit: bool = True
    rate_limit_window_seconds: int = 60
    predict_rate_limit: int = 120
    lookup_rate_limit: int = 180
    training_data_rate_limit: int = 30
    api_key: Optional[str] = None
    allowed_origins: List[str]
    allowed_extension_ids: Set[str]
    enforce_auth: bool = False


def load_settings() -> Settings:
    """
    Load runtime configuration from env vars.

    Phase 0 goal is to keep local development friction low while making cloud
    deployment possible without code changes. For that reason:
    - auth is optional by default
    - localhost origins are allowed by default
    - extension ids are opt-in
    """
    api_key = os.environ.get("API_KEY")
    allowed_extension_ids = _parse_allowed_extension_ids()

    return Settings(
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8000")),
        log_predictions=_get_env_bool("LOG_PREDICTIONS", True),
        enable_traffic_metrics=_get_env_bool("ENABLE_TRAFFIC_METRICS", True),
        metrics_log_interval_seconds=int(
            os.environ.get("METRICS_LOG_INTERVAL_SECONDS", "60")
        ),
        enable_rate_limit=_get_env_bool("ENABLE_RATE_LIMIT", True),
        rate_limit_window_seconds=int(
            os.environ.get("RATE_LIMIT_WINDOW_SECONDS", "60")
        ),
        predict_rate_limit=int(os.environ.get("PREDICT_RATE_LIMIT", "120")),
        lookup_rate_limit=int(os.environ.get("LOOKUP_RATE_LIMIT", "180")),
        training_data_rate_limit=int(
            os.environ.get("TRAINING_DATA_RATE_LIMIT", "30")
        ),
        api_key=api_key.strip() if api_key else None,
        allowed_origins=_parse_allowed_origins(),
        allowed_extension_ids=allowed_extension_ids,
        enforce_auth=_get_env_bool("ENFORCE_AUTH", bool(api_key)),
    )


SETTINGS = load_settings()


class PredictRequest(BaseModel):
    texts: List[str]


class PredictResponse(BaseModel):
    labels: List[int]
    probs: List[List[float]]
    label_names: Dict[int, str]


class TrainingDataRequest(BaseModel):
    text: str
    label: int
    user_id: str = "anonymous"


class TrainingDataResponse(BaseModel):
    success: bool
    message: str


class LookupRequest(BaseModel):
    texts: List[str]


def _load_model(model_dir: Path):
    """Load tokenizer/model once and place them on the best available device."""
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
    model = AutoModelForSequenceClassification.from_pretrained(str(model_dir))
    model.to(device)
    model.eval()
    return tokenizer, model, device


def _softmax(logits: torch.Tensor) -> torch.Tensor:
    return torch.nn.functional.softmax(logits, dim=-1)


USER_DATA_PATH = get_user_data_path()
UPDATED_MODEL_DIR = USER_DATA_PATH / "model"
DEFAULT_MODEL_DIR = get_model_path()
MODEL_DIR = (
    UPDATED_MODEL_DIR
    if UPDATED_MODEL_DIR.exists() and any(UPDATED_MODEL_DIR.iterdir())
    else DEFAULT_MODEL_DIR
)

TRAINING_DATA_DIR = USER_DATA_PATH / "training_data"
TRAINING_DATA_DIR.mkdir(exist_ok=True)

TEMP_TRAINING_DATA_DIR = USER_DATA_PATH / "training_temp"
TEMP_TRAINING_DATA_DIR.mkdir(exist_ok=True)

LABEL_NAMES = {0: "normal", 1: "borderline_abusive", 2: "abusive"}

# Readiness should reflect the real state of the serving process. These flags
# are updated during model load / reload so orchestration layers can use the
# endpoint for safe traffic shifting.
MODEL_READY = False
MODEL_LOAD_ERROR: Optional[str] = None

TRAINING_STATUS = {
    "is_training": False,
    "progress": 0,
    "message": "",
    "error": None,
}


class TrafficMetrics:
    """
    In-memory traffic collector for before/after operational comparisons.

    Phase 0 first used this collector to produce a baseline of real traffic
    characteristics. The same collector is now kept after rate limiting is
    enabled so before/after comparisons remain possible.

    What gets measured:
    - total HTTP requests and status code distribution
    - predict request volume
    - batch sizes (`texts` per request)
    - text volume (`characters` per request)
    - end-to-end latency
    - label distribution returned by the model
    - top callers by `(client_ip, origin)`
    - auth failures
    - request concurrency

    After rate limiting is added, the same counters will show:
    - how many requests would have hit the limit
    - whether p95 latency improved
    - whether one noisy caller was dominating traffic
    """

    def __init__(self, max_latency_samples: int = 500) -> None:
        self._lock = threading.Lock()
        self._max_latency_samples = max_latency_samples
        self._started_at = time.time()
        self._last_snapshot_at = self._started_at
        self._latency_samples_ms: List[float] = []
        self._counters = self._build_empty_counters()

    def _build_empty_counters(self) -> Dict[str, Any]:
        return {
            "http_requests_total": 0,
            "predict_requests_total": 0,
            "predict_texts_total": 0,
            "predict_characters_total": 0,
            "predict_batch_size_max": 0,
            "predict_latency_total_ms": 0.0,
            "predict_label_counts": {0: 0, 1: 0, 2: 0},
            "status_counts": {},
            "path_counts": {},
            "client_counts": {},
            "auth_failures_total": 0,
            "rate_limit_rejections_total": 0,
            "rate_limit_rejections_by_path": {},
            "inflight_requests": 0,
            "max_inflight_requests": 0,
        }

    def start_request(self) -> None:
        with self._lock:
            self._counters["inflight_requests"] += 1
            self._counters["max_inflight_requests"] = max(
                self._counters["max_inflight_requests"],
                self._counters["inflight_requests"],
            )

    def finish_http_request(
        self,
        *,
        path: str,
        status_code: int,
        client_key: str,
        latency_ms: float,
        auth_failed: bool = False,
    ) -> None:
        with self._lock:
            self._counters["http_requests_total"] += 1
            self._counters["inflight_requests"] = max(
                0, self._counters["inflight_requests"] - 1
            )
            self._counters["status_counts"][status_code] = (
                self._counters["status_counts"].get(status_code, 0) + 1
            )
            self._counters["path_counts"][path] = (
                self._counters["path_counts"].get(path, 0) + 1
            )
            self._counters["client_counts"][client_key] = (
                self._counters["client_counts"].get(client_key, 0) + 1
            )
            if auth_failed:
                self._counters["auth_failures_total"] += 1

    def record_rate_limit_rejection(self, path: str) -> None:
        with self._lock:
            self._counters["rate_limit_rejections_total"] += 1
            self._counters["rate_limit_rejections_by_path"][path] = (
                self._counters["rate_limit_rejections_by_path"].get(path, 0) + 1
            )

    def record_predict(
        self,
        *,
        client_key: str,
        batch_size: int,
        characters: int,
        latency_ms: float,
        labels: List[int],
    ) -> None:
        with self._lock:
            self._counters["predict_requests_total"] += 1
            self._counters["predict_texts_total"] += batch_size
            self._counters["predict_characters_total"] += characters
            self._counters["predict_latency_total_ms"] += latency_ms
            self._counters["predict_batch_size_max"] = max(
                self._counters["predict_batch_size_max"], batch_size
            )
            self._counters["client_counts"][client_key] = (
                self._counters["client_counts"].get(client_key, 0) + 1
            )
            for label in labels:
                if label in self._counters["predict_label_counts"]:
                    self._counters["predict_label_counts"][label] += 1

            self._latency_samples_ms.append(latency_ms)
            if len(self._latency_samples_ms) > self._max_latency_samples:
                self._latency_samples_ms = self._latency_samples_ms[
                    -self._max_latency_samples :
                ]

    def _percentile(self, values: List[float], percentile: float) -> float:
        if not values:
            return 0.0
        sorted_values = sorted(values)
        index = max(
            0,
            min(len(sorted_values) - 1, int(round((len(sorted_values) - 1) * percentile))),
        )
        return sorted_values[index]

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            counters = dict(self._counters)
            label_counts = dict(self._counters["predict_label_counts"])
            status_counts = dict(self._counters["status_counts"])
            path_counts = dict(self._counters["path_counts"])
            client_counts = dict(self._counters["client_counts"])
            latencies = list(self._latency_samples_ms)
            started_at = self._started_at
            last_snapshot_at = self._last_snapshot_at

        predict_requests = counters["predict_requests_total"]
        texts_total = counters["predict_texts_total"]
        elapsed_seconds = max(1.0, time.time() - started_at)
        snapshot_window_seconds = max(1.0, time.time() - last_snapshot_at)
        top_clients = sorted(
            client_counts.items(), key=lambda item: item[1], reverse=True
        )[:5]

        return {
            "uptime_seconds": round(elapsed_seconds, 1),
            "snapshot_window_seconds": round(snapshot_window_seconds, 1),
            "http_requests_total": counters["http_requests_total"],
            "predict_requests_total": predict_requests,
            "predict_requests_per_minute": round((predict_requests / elapsed_seconds) * 60, 2),
            "predict_texts_total": texts_total,
            "predict_texts_per_minute": round((texts_total / elapsed_seconds) * 60, 2),
            "predict_batch_size_avg": round(texts_total / predict_requests, 2)
            if predict_requests
            else 0.0,
            "predict_batch_size_max": counters["predict_batch_size_max"],
            "predict_characters_total": counters["predict_characters_total"],
            "predict_characters_avg_per_request": round(
                counters["predict_characters_total"] / predict_requests, 2
            )
            if predict_requests
            else 0.0,
            "predict_latency_avg_ms": round(
                counters["predict_latency_total_ms"] / predict_requests, 2
            )
            if predict_requests
            else 0.0,
            "predict_latency_p50_ms": round(self._percentile(latencies, 0.50), 2),
            "predict_latency_p95_ms": round(self._percentile(latencies, 0.95), 2),
            "predict_label_counts": label_counts,
            "status_counts": status_counts,
            "path_counts_top": sorted(
                path_counts.items(), key=lambda item: item[1], reverse=True
            )[:10],
            "top_clients": top_clients,
            "auth_failures_total": counters["auth_failures_total"],
            "rate_limit_rejections_total": counters["rate_limit_rejections_total"],
            "rate_limit_rejections_by_path": dict(
                counters["rate_limit_rejections_by_path"]
            ),
            "max_inflight_requests": counters["max_inflight_requests"],
            "current_inflight_requests": counters["inflight_requests"],
        }

    def mark_snapshot_logged(self) -> None:
        with self._lock:
            self._last_snapshot_at = time.time()


TRAFFIC_METRICS = TrafficMetrics()


class InMemoryRateLimiter:
    """
    Simple fixed-window rate limiter keyed by `(client, path)`.

    This is intentionally lightweight for Phase 0:
    - no extra dependency
    - works in local development and a single app instance
    - gives immediate protection before API Gateway/WAF exists

    Limitation:
    - counters are per-process memory only
    - once the service is replicated horizontally, the real source of truth
      should move to API Gateway/WAF and/or a shared store such as Redis
    """

    def __init__(self, window_seconds: int) -> None:
        self._window_seconds = max(1, window_seconds)
        self._lock = threading.Lock()
        self._windows: Dict[str, Dict[str, int]] = {}

    def _get_limit_for_path(self, path: str) -> int:
        if path == "/predict":
            return SETTINGS.predict_rate_limit
        if path == "/training-data/lookup":
            return SETTINGS.lookup_rate_limit
        if path == "/training-data":
            return SETTINGS.training_data_rate_limit
        return 0

    def check(self, client_key: str, path: str) -> Dict[str, int]:
        limit = self._get_limit_for_path(path)
        if not SETTINGS.enable_rate_limit or limit <= 0:
            return {"allowed": 1, "limit": limit, "remaining": limit, "retry_after": 0}

        now = int(time.time())
        window_started_at = now - (now % self._window_seconds)
        bucket_key = f"{client_key}|{path}"

        with self._lock:
            bucket = self._windows.get(bucket_key)
            if not bucket or bucket["window_started_at"] != window_started_at:
                bucket = {"window_started_at": window_started_at, "count": 0}
                self._windows[bucket_key] = bucket

            if bucket["count"] >= limit:
                retry_after = max(1, self._window_seconds - (now - window_started_at))
                return {
                    "allowed": 0,
                    "limit": limit,
                    "remaining": 0,
                    "retry_after": retry_after,
                }

            bucket["count"] += 1
            remaining = max(0, limit - bucket["count"])

        return {
            "allowed": 1,
            "limit": limit,
            "remaining": remaining,
            "retry_after": 0,
        }


RATE_LIMITER = InMemoryRateLimiter(window_seconds=SETTINGS.rate_limit_window_seconds)


def _cleanup_temp_dir() -> None:
    try:
        if TEMP_TRAINING_DATA_DIR.exists():
            shutil.rmtree(TEMP_TRAINING_DATA_DIR, ignore_errors=True)
    except Exception as exc:
        LOGGER.warning("Failed to cleanup temp dir: %s", exc)


atexit.register(_cleanup_temp_dir)


def _enforce_temp_limit(max_items: int = 30) -> None:
    """
    Keep the temp cache bounded.

    This cache exists only to avoid re-classifying recent comments repeatedly.
    A hard limit prevents unbounded disk growth in always-on environments.
    """
    try:
        files = sorted(
            TEMP_TRAINING_DATA_DIR.glob("training_data_*.jsonl"),
            key=lambda path: path.stat().st_mtime,
        )
        if not files:
            return

        total = 0
        file_lines: List[Dict[str, Any]] = []
        for file_path in files:
            try:
                with open(file_path, "r", encoding="utf-8") as file:
                    lines = file.readlines()
                valid_lines = [line for line in lines if line.strip()]
                file_lines.append({"path": file_path, "lines": valid_lines})
                total += len(valid_lines)
            except Exception:
                continue

        excess = max(0, total - max_items)
        index = 0
        while excess > 0 and index < len(file_lines):
            entry = file_lines[index]
            lines = entry["lines"]
            if not lines:
                try:
                    os.remove(entry["path"])
                except Exception:
                    pass
                index += 1
                continue

            remove_count = min(excess, len(lines))
            remaining_lines = lines[remove_count:]
            try:
                if remaining_lines:
                    with open(entry["path"], "w", encoding="utf-8") as file:
                        file.writelines(remaining_lines)
                else:
                    os.remove(entry["path"])
            except Exception:
                pass

            excess -= remove_count
            index += 1
    except Exception as exc:
        LOGGER.warning("Failed to enforce temp limit: %s", exc)


def save_training_data(
    text: str, label: int, user_id: str, use_temp: bool = False
) -> bool:
    """Append one labeled sample to daily JSONL training data files."""
    try:
        timestamp = datetime.now().isoformat()
        data = {
            "text": text,
            "label": label,
            "user_id": user_id,
            "timestamp": timestamp,
        }

        date_str = datetime.now().strftime("%Y-%m-%d")
        base_dir = TEMP_TRAINING_DATA_DIR if use_temp else TRAINING_DATA_DIR
        data_file = base_dir / f"training_data_{date_str}.jsonl"

        os.makedirs(base_dir, exist_ok=True)
        line = json.dumps(data, ensure_ascii=False) + "\n"
        with open(data_file, "a", encoding="utf-8") as file:
            file.write(line)
            file.flush()

        if use_temp:
            _enforce_temp_limit(30)

        LOGGER.info(
            'Training data saved: label=%s (%s) text="%s..."',
            label,
            LABEL_NAMES.get(label, "?"),
            text[:50],
        )
        return True
    except Exception as exc:
        LOGGER.error("Failed to save training data: %s", exc)
        return False


def _set_model_ready_state(is_ready: bool, error_message: Optional[str] = None) -> None:
    """Centralize readiness state updates used by health endpoints."""
    global MODEL_READY, MODEL_LOAD_ERROR
    MODEL_READY = is_ready
    MODEL_LOAD_ERROR = error_message


def _initialize_model() -> None:
    """
    Load the serving model once during startup.

    Readiness is intentionally flipped only after tokenizer/model/device are all
    available. This makes `/health/ready` meaningful for containers and load
    balancers.
    """
    global TOKENIZER, MODEL, DEVICE

    _set_model_ready_state(False, "model loading in progress")
    try:
        LOGGER.info("Loading model from %s", MODEL_DIR)
        TOKENIZER, MODEL, DEVICE = _load_model(MODEL_DIR)
        _set_model_ready_state(True)
        LOGGER.info("Model loaded successfully on device=%s", DEVICE)
    except Exception as exc:
        error_message = f"Model load failed: {exc}"
        _set_model_ready_state(False, error_message)
        LOGGER.exception(error_message)
        if getattr(sys, "frozen", False):
            input(
                "\n에러가 발생했습니다. 위 메시지를 확인하세요.\n"
                "계속하려면 Enter를 누르세요..."
            )
        raise


def run_training_background() -> None:
    """Run retraining without blocking the request/response cycle."""
    global TRAINING_STATUS, TOKENIZER, MODEL, DEVICE

    try:
        TRAINING_STATUS["is_training"] = True
        TRAINING_STATUS["progress"] = 10
        TRAINING_STATUS["message"] = "학습 데이터 확인 중..."
        TRAINING_STATUS["error"] = None

        total_samples = 0
        for data_file in TRAINING_DATA_DIR.glob("training_data_*.jsonl"):
            with open(data_file, "r", encoding="utf-8") as file:
                for line in file:
                    if line.strip():
                        total_samples += 1

        if total_samples < 1:
            TRAINING_STATUS["error"] = (
                f"학습 데이터가 부족합니다. 최소 1개 필요, 현재 {total_samples}개"
            )
            TRAINING_STATUS["is_training"] = False
            return

        TRAINING_STATUS["progress"] = 20
        TRAINING_STATUS["message"] = (
            f"학습 데이터 {total_samples}개 확인됨. 학습 시작..."
        )

        output_dir = USER_DATA_PATH / "model_new"

        TRAINING_STATUS["progress"] = 30
        TRAINING_STATUS["message"] = "모델 학습 중... (시간이 걸릴 수 있습니다)"

        result_returncode = 1
        result_stderr = ""

        try:
            from train import train_model

            success = train_model(
                model_dir=DEFAULT_MODEL_DIR,
                training_data_dir=TRAINING_DATA_DIR,
                output_dir=output_dir,
                num_epochs=3,
                batch_size=8,
                augment_factor=3000,
            )
            result_returncode = 0 if success else 1
            if not success:
                result_stderr = "학습 실패"
        except Exception as exc:
            LOGGER.error("Training module error: %s", exc)
            result_returncode = 1
            result_stderr = str(exc)

        if result_returncode == 0:
            TRAINING_STATUS["progress"] = 80
            TRAINING_STATUS["message"] = "학습 완료. 모델 교체 중..."

            backup_dir = USER_DATA_PATH / "model_backup"
            if backup_dir.exists():
                shutil.rmtree(backup_dir)

            if UPDATED_MODEL_DIR.exists() and any(UPDATED_MODEL_DIR.iterdir()):
                shutil.move(str(UPDATED_MODEL_DIR), str(backup_dir))

            shutil.move(str(output_dir), str(UPDATED_MODEL_DIR))

            TRAINING_STATUS["progress"] = 90
            TRAINING_STATUS["message"] = "모델 재로드 중..."

            # During reload we temporarily mark the service as not ready. This
            # becomes important once a load balancer starts checking readiness.
            _set_model_ready_state(False, "model reload in progress")
            TOKENIZER, MODEL, DEVICE = _load_model(UPDATED_MODEL_DIR)
            _set_model_ready_state(True)

            TRAINING_STATUS["progress"] = 100
            TRAINING_STATUS["message"] = "재학습 완료!"
            TRAINING_STATUS["is_training"] = False
            LOGGER.info("Model retraining completed successfully")
        else:
            TRAINING_STATUS["error"] = f"학습 실패: {result_stderr}"
            TRAINING_STATUS["is_training"] = False
            LOGGER.error("Training failed: %s", result_stderr)
    except Exception as exc:
        TRAINING_STATUS["error"] = f"학습 중 오류: {exc}"
        TRAINING_STATUS["is_training"] = False
        LOGGER.error("Training error: %s", exc)
        _set_model_ready_state(True if "MODEL" in globals() else False, str(exc))


app = FastAPI(title="YouTube Live Chat Moderation Model Server", version="1.1.0")


def _get_client_key(request: Request) -> str:
    """
    Build a stable caller key for traffic comparisons.

    In local mode this is typically `127.0.0.1|chrome-extension://...`.
    In cloud mode it becomes useful for spotting which IP/origin pair is
    producing most of the traffic before a rate limit policy is introduced.
    """
    forwarded_for = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
    client_host = forwarded_for or (request.client.host if request.client else "unknown")
    origin = request.headers.get("origin", "no-origin")
    return f"{client_host}|{origin}"


def _log_traffic_snapshot_if_due(force: bool = False) -> None:
    """
    Emit one aggregate traffic log line at a fixed cadence.

    The output is intentionally JSON so it can be diffed before/after enabling
    rate limit and also parsed later by CloudWatch Logs Insights.
    """
    if not SETTINGS.enable_traffic_metrics:
        return

    now = time.time()
    if not force and (
        now - TRAFFIC_METRICS._last_snapshot_at < SETTINGS.metrics_log_interval_seconds
    ):
        return

    snapshot = TRAFFIC_METRICS.snapshot()
    LOGGER.info("TRAFFIC_SNAPSHOT %s", json.dumps(snapshot, ensure_ascii=False))
    TRAFFIC_METRICS.mark_snapshot_logged()


def _build_rate_limit_headers(limit_result: Dict[str, int]) -> Dict[str, str]:
    """
    Return standard-ish headers to make client-side debugging easier.

    These headers are useful now for local validation and later when comparing
    app-level limiting with API Gateway/WAF behavior.
    """
    headers = {
        "X-RateLimit-Limit": str(limit_result["limit"]),
        "X-RateLimit-Remaining": str(limit_result["remaining"]),
    }
    if limit_result["retry_after"] > 0:
        headers["Retry-After"] = str(limit_result["retry_after"])
    return headers


def _build_cors_origin_list() -> List[str]:
    """Compose the final CORS whitelist from web origins and extension ids."""
    cors_origins = list(SETTINGS.allowed_origins)
    cors_origins.extend(
        f"chrome-extension://{extension_id}"
        for extension_id in SETTINGS.allowed_extension_ids
    )
    return cors_origins


app.add_middleware(
    CORSMiddleware,
    allow_origins=_build_cors_origin_list(),
    allow_credentials=False,
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-API-Key"],
)


AUTH_EXCLUDED_PATH_PREFIXES = {
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
}


@app.middleware("http")
async def api_key_middleware(request: Request, call_next):
    """
    Optionally enforce a shared API key.

    Phase 0 uses a simple shared secret because it is easy to roll out and does
    not require changing the rest of the architecture yet. Local development is
    unaffected unless `ENFORCE_AUTH=true` or `API_KEY` is set deliberately.
    """
    request_path = request.url.path
    client_key = _get_client_key(request)
    start_time = time.perf_counter()
    response = None
    auth_failed = False
    TRAFFIC_METRICS.start_request()

    try:
        if request.method == "OPTIONS":
            response = await call_next(request)
            return response

        if any(request_path.startswith(prefix) for prefix in AUTH_EXCLUDED_PATH_PREFIXES):
            response = await call_next(request)
            return response

        if SETTINGS.enforce_auth:
            provided_api_key = request.headers.get("x-api-key") or request.headers.get(
                "authorization", ""
            ).removeprefix("Bearer ").strip()
            if not (SETTINGS.api_key and provided_api_key == SETTINGS.api_key):
                auth_failed = True
                response = JSONResponse(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    content={"detail": "Unauthorized"},
                )
                return response

        # Apply app-level rate limiting before endpoint execution. This gives us
        # a local and single-instance protection layer until API Gateway/WAF is
        # introduced in the next phase.
        limit_result = RATE_LIMITER.check(client_key, request_path)
        if not limit_result["allowed"]:
            TRAFFIC_METRICS.record_rate_limit_rejection(request_path)
            response = JSONResponse(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                content={
                    "detail": "Rate limit exceeded",
                    "path": request_path,
                    "retry_after_seconds": limit_result["retry_after"],
                },
                headers=_build_rate_limit_headers(limit_result),
            )
            return response

        response = await call_next(request)
        if limit_result["limit"] > 0:
            for header_name, header_value in _build_rate_limit_headers(limit_result).items():
                response.headers[header_name] = header_value
        return response
    finally:
        # Middleware runs for every request, so this gives us a common traffic
        # baseline even before endpoint-specific instrumentation is inspected.
        latency_ms = round((time.perf_counter() - start_time) * 1000, 2)
        status_code = 500
        if response is not None:
            status_code = response.status_code

        TRAFFIC_METRICS.finish_http_request(
            path=request_path,
            status_code=status_code,
            client_key=client_key,
            latency_ms=latency_ms,
            auth_failed=auth_failed,
        )
        _log_traffic_snapshot_if_due()


@app.options("/predict")
def options_predict() -> Dict[str, Any]:
    """Keep explicit preflight handling for extension/browser compatibility."""
    return {"ok": True}


@app.get("/health")
def health() -> Dict[str, Any]:
    """
    Backward-compatible endpoint retained for existing local clients.

    New infrastructure should prefer `/health/live` and `/health/ready`.
    """
    return {
        "status": "ok" if MODEL_READY else "degraded",
        "ready": MODEL_READY,
        "device": str(DEVICE) if "DEVICE" in globals() else "unknown",
        "num_labels": MODEL.config.num_labels if "MODEL" in globals() else None,
        "version": app.version,
    }


@app.get("/health/live")
def health_live() -> Dict[str, str]:
    """Liveness checks only confirm the process is up and able to respond."""
    return {"status": "alive"}


@app.get("/health/ready")
def health_ready() -> JSONResponse:
    """
    Readiness checks confirm the model is actually loaded and ready to serve.

    Containers should use this endpoint for traffic admission decisions.
    """
    if not MODEL_READY:
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={
                "status": "not_ready",
                "reason": MODEL_LOAD_ERROR or "model not ready",
            },
        )

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content={
            "status": "ready",
            "device": str(DEVICE),
            "model_dir": str(MODEL_DIR),
        },
    )


@app.get("/config")
def config_summary() -> Dict[str, Any]:
    """Expose non-secret runtime configuration for debugging deployments."""
    return {
        "host": SETTINGS.host,
        "port": SETTINGS.port,
        "auth_enabled": SETTINGS.enforce_auth,
        "traffic_metrics_enabled": SETTINGS.enable_traffic_metrics,
        "metrics_log_interval_seconds": SETTINGS.metrics_log_interval_seconds,
        "rate_limit_enabled": SETTINGS.enable_rate_limit,
        "rate_limit_window_seconds": SETTINGS.rate_limit_window_seconds,
        "predict_rate_limit": SETTINGS.predict_rate_limit,
        "lookup_rate_limit": SETTINGS.lookup_rate_limit,
        "training_data_rate_limit": SETTINGS.training_data_rate_limit,
        "allowed_origins": SETTINGS.allowed_origins,
        "allowed_extension_ids": sorted(SETTINGS.allowed_extension_ids),
    }


@app.get("/metrics/live")
def live_metrics() -> Dict[str, Any]:
    """
    Return current in-memory traffic metrics.

    This endpoint exists so you can inspect the same numbers that are being
    logged without waiting for the next periodic `TRAFFIC_SNAPSHOT`.
    """
    return TRAFFIC_METRICS.snapshot()


@app.get("/labels")
def labels() -> Dict[int, str]:
    return LABEL_NAMES


@app.post("/training-data", response_model=TrainingDataResponse)
def add_training_data(
    req: TrainingDataRequest, temp: bool = False
) -> TrainingDataResponse:
    """Persist user-provided labels for later retraining."""
    if req.label not in LABEL_NAMES:
        return TrainingDataResponse(success=False, message="Invalid label")

    if not req.text.strip():
        return TrainingDataResponse(success=False, message="Empty text")

    success = save_training_data(req.text, req.label, req.user_id, use_temp=temp)
    if success:
        return TrainingDataResponse(
            success=True, message="Training data saved successfully"
        )
    return TrainingDataResponse(success=False, message="Failed to save training data")


@app.delete("/training-data/temp")
def delete_temp_training_data() -> Dict[str, Any]:
    """Delete the temporary cache used for quick local label lookups."""
    try:
        _cleanup_temp_dir()
        TEMP_TRAINING_DATA_DIR.mkdir(exist_ok=True)
        return {"message": "Temporary training data cleared"}
    except Exception as exc:
        raise HTTPException(
            status_code=500, detail=f"임시 데이터 삭제 실패: {exc}"
        ) from exc


@app.post("/training-data/lookup")
def lookup_cached_labels(req: LookupRequest) -> Dict[str, Any]:
    """Lookup recent labels from temporary JSONL cache files."""
    try:
        incoming = req.texts or []
        targets = [text.strip() for text in incoming if isinstance(text, str) and text.strip()]
        if not targets:
            return {"labels": [None] * len(incoming)}

        files = sorted(
            TEMP_TRAINING_DATA_DIR.glob("training_data_*.jsonl"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        cache: Dict[str, int] = {}
        for file_path in files:
            try:
                with open(file_path, "r", encoding="utf-8") as file:
                    for line in file:
                        if not line.strip():
                            continue
                        try:
                            item = json.loads(line)
                            text = str(item.get("text", "")).strip()
                            label = int(item.get("label", 0))
                            if text and text not in cache:
                                cache[text] = label
                        except Exception:
                            continue
            except Exception:
                continue

            if len(cache) >= 20000:
                break

        output = []
        for text in incoming:
            if isinstance(text, str):
                key = text.strip()
                output.append(cache.get(key, None) if key else None)
            else:
                output.append(None)
        return {"labels": output}
    except Exception as exc:
        LOGGER.error("lookup failed: %s", exc)
        return {"labels": [None] * len(getattr(req, "texts", []) or [])}


@app.get("/training-data/stats")
def get_training_data_stats() -> Dict[str, Any]:
    """Return aggregate stats for durable training data only."""
    try:
        total_count = 0
        label_counts = {0: 0, 1: 0, 2: 0}
        for data_file in TRAINING_DATA_DIR.glob("training_data_*.jsonl"):
            try:
                with open(data_file, "r", encoding="utf-8", errors="ignore") as file:
                    for line in file:
                        if line.strip():
                            try:
                                data = json.loads(line)
                                total_count += 1
                                label_counts[int(data.get("label", 0))] += 1
                            except (json.JSONDecodeError, ValueError):
                                continue
            except Exception as exc:
                LOGGER.warning("Failed to read file %s: %s", data_file, exc)
                continue
        return {
            "total_samples": total_count,
            "label_distribution": {LABEL_NAMES[key]: value for key, value in label_counts.items()},
            "data_files": len(list(TRAINING_DATA_DIR.glob("training_data_*.jsonl"))),
        }
    except Exception as exc:
        LOGGER.error("Failed to get training data stats: %s", exc)
        return {"error": str(exc)}


@app.get("/training-data/stats-temp")
def get_training_data_stats_temp() -> Dict[str, Any]:
    """Return aggregate stats for temporary click-labeled data."""
    try:
        total_count = 0
        label_counts = {0: 0, 1: 0, 2: 0}
        for data_file in TEMP_TRAINING_DATA_DIR.glob("training_data_*.jsonl"):
            try:
                with open(data_file, "r", encoding="utf-8", errors="ignore") as file:
                    for line in file:
                        if line.strip():
                            try:
                                data = json.loads(line)
                                total_count += 1
                                label_counts[int(data.get("label", 0))] += 1
                            except (json.JSONDecodeError, ValueError):
                                continue
            except Exception as exc:
                LOGGER.warning("Failed to read file %s: %s", data_file, exc)
                continue
        return {
            "total_samples": total_count,
            "label_distribution": {LABEL_NAMES[key]: value for key, value in label_counts.items()},
            "data_files": len(list(TEMP_TRAINING_DATA_DIR.glob("training_data_*.jsonl"))),
        }
    except Exception as exc:
        LOGGER.error("Failed to get temp training data stats: %s", exc)
        return {"error": str(exc)}


@app.get("/training-data/stats-all")
def get_training_data_stats_all() -> Dict[str, Any]:
    """Return aggregate stats across both durable and temporary stores."""
    try:
        def accumulate_from_dir(base: Path, total_label_counts: Dict[int, int]) -> int:
            total = 0
            for data_file in base.glob("training_data_*.jsonl"):
                try:
                    with open(data_file, "r", encoding="utf-8", errors="ignore") as file:
                        for line in file:
                            if line.strip():
                                try:
                                    data = json.loads(line)
                                    total += 1
                                    label = int(data.get("label", 0))
                                    if label in total_label_counts:
                                        total_label_counts[label] += 1
                                except (json.JSONDecodeError, ValueError):
                                    continue
                except Exception as exc:
                    LOGGER.warning("Failed to read file %s: %s", data_file, exc)
                    continue
            return total

        label_counts = {0: 0, 1: 0, 2: 0}
        total_count = 0
        total_count += accumulate_from_dir(TRAINING_DATA_DIR, label_counts)
        total_count += accumulate_from_dir(TEMP_TRAINING_DATA_DIR, label_counts)

        return {
            "total_samples": total_count,
            "label_distribution": {LABEL_NAMES[key]: value for key, value in label_counts.items()},
            "data_files": len(list(TRAINING_DATA_DIR.glob("training_data_*.jsonl")))
            + len(list(TEMP_TRAINING_DATA_DIR.glob("training_data_*.jsonl"))),
        }
    except Exception as exc:
        LOGGER.error("Failed to get training data stats(all): %s", exc)
        return {"error": str(exc)}


@app.post("/model/reload")
def reload_model() -> Dict[str, Any]:
    """Reload the latest model from disk without restarting the process."""
    global TOKENIZER, MODEL, DEVICE, MODEL_DIR

    try:
        LOGGER.info("Reloading model...")
        if UPDATED_MODEL_DIR.exists() and any(UPDATED_MODEL_DIR.iterdir()):
            MODEL_DIR = UPDATED_MODEL_DIR
        else:
            MODEL_DIR = DEFAULT_MODEL_DIR

        _set_model_ready_state(False, "model reload in progress")
        TOKENIZER, MODEL, DEVICE = _load_model(MODEL_DIR)
        _set_model_ready_state(True)
        LOGGER.info("Model reloaded successfully from %s", MODEL_DIR)
        return {"success": True, "message": "Model reloaded successfully"}
    except Exception as exc:
        _set_model_ready_state(False, f"model reload failed: {exc}")
        LOGGER.error("Failed to reload model: %s", exc)
        return {"success": False, "message": f"Failed to reload model: {exc}"}


@app.post("/model/retrain")
def start_retraining(background_tasks: BackgroundTasks) -> Dict[str, Any]:
    """Trigger retraining in the background if no job is currently running."""
    global TRAINING_STATUS

    if TRAINING_STATUS["is_training"]:
        return {"success": False, "message": "이미 학습이 진행 중입니다"}

    background_tasks.add_task(run_training_background)
    return {"success": True, "message": "재학습이 시작되었습니다"}


@app.get("/model/training-status")
def get_training_status() -> Dict[str, Any]:
    """Return retraining progress for the extension UI."""
    return TRAINING_STATUS


@app.get("/training-data/files-temp")
def get_training_data_files_temp() -> Dict[str, Any]:
    """List temporary training data files with simple size/count metadata."""
    try:
        files = []
        pattern = str(TEMP_TRAINING_DATA_DIR / "training_data_*.jsonl")
        for file_path in glob.glob(pattern):
            file_name = os.path.basename(file_path)
            file_size = os.path.getsize(file_path)
            file_date = datetime.fromtimestamp(os.path.getmtime(file_path))

            count = 0
            with open(file_path, "r", encoding="utf-8", errors="ignore") as file:
                for line in file:
                    if line.strip():
                        count += 1

            files.append(
                {
                    "filename": file_name,
                    "path": file_path,
                    "size": file_size,
                    "count": count,
                    "date": file_date.isoformat(),
                }
            )

        files.sort(key=lambda item: item["date"], reverse=True)
        return {"files": files}
    except Exception as exc:
        raise HTTPException(
            status_code=500, detail=f"파일 목록 조회 실패: {exc}"
        ) from exc


@app.get("/training-data/files")
def get_training_data_files() -> Dict[str, Any]:
    """List durable training data files with simple size/count metadata."""
    try:
        files = []
        pattern = str(TRAINING_DATA_DIR / "training_data_*.jsonl")
        for file_path in glob.glob(pattern):
            file_name = os.path.basename(file_path)
            file_size = os.path.getsize(file_path)
            file_date = datetime.fromtimestamp(os.path.getmtime(file_path))

            count = 0
            with open(file_path, "r", encoding="utf-8") as file:
                for line in file:
                    if line.strip():
                        count += 1

            files.append(
                {
                    "filename": file_name,
                    "path": file_path,
                    "size": file_size,
                    "count": count,
                    "date": file_date.isoformat(),
                }
            )

        files.sort(key=lambda item: item["date"], reverse=True)
        return {"files": files}
    except Exception as exc:
        raise HTTPException(
            status_code=500, detail=f"파일 목록 조회 실패: {exc}"
        ) from exc


@app.get("/training-data/files-temp/{filename}")
def get_training_data_file_temp(filename: str) -> Dict[str, Any]:
    """Read one temporary JSONL file and return parsed line items."""
    try:
        file_path = TEMP_TRAINING_DATA_DIR / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="파일을 찾을 수 없습니다")

        data = []
        with open(file_path, "r", encoding="utf-8", errors="ignore") as file:
            for line_number, line in enumerate(file, 1):
                if line.strip():
                    try:
                        item = json.loads(line.strip())
                        item["line_number"] = line_number
                        data.append(item)
                    except json.JSONDecodeError:
                        continue

        return {"filename": filename, "count": len(data), "data": data}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"파일 조회 실패: {exc}") from exc


@app.get("/training-data/files/{filename}")
def get_training_data_file(filename: str) -> Dict[str, Any]:
    """Read one durable JSONL file and return parsed line items."""
    try:
        file_path = TRAINING_DATA_DIR / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="파일을 찾을 수 없습니다")

        data = []
        with open(file_path, "r", encoding="utf-8") as file:
            for line_number, line in enumerate(file, 1):
                if line.strip():
                    try:
                        item = json.loads(line.strip())
                        item["line_number"] = line_number
                        data.append(item)
                    except json.JSONDecodeError:
                        continue

        return {"filename": filename, "count": len(data), "data": data}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"파일 조회 실패: {exc}") from exc


@app.delete("/training-data/files/{filename}")
def delete_training_data_file(filename: str) -> Dict[str, Any]:
    """Delete one durable training data file."""
    try:
        file_path = TRAINING_DATA_DIR / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="파일을 찾을 수 없습니다")

        os.remove(file_path)
        return {"message": f"파일 '{filename}'이 삭제되었습니다"}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"파일 삭제 실패: {exc}") from exc


@app.delete("/training-data/files/{filename}/lines/{line_number}")
def delete_training_data_line(filename: str, line_number: int) -> Dict[str, Any]:
    """Delete a single line from one durable JSONL file."""
    try:
        file_path = TRAINING_DATA_DIR / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="파일을 찾을 수 없습니다")

        with open(file_path, "r", encoding="utf-8") as file:
            lines = file.readlines()

        if line_number < 1 or line_number > len(lines):
            raise HTTPException(status_code=400, detail="유효하지 않은 라인 번호입니다")

        del lines[line_number - 1]

        with open(file_path, "w", encoding="utf-8") as file:
            file.writelines(lines)

        return {"message": f"라인 {line_number}이 삭제되었습니다"}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"라인 삭제 실패: {exc}") from exc


@app.delete("/training-data/all")
def delete_all_training_data() -> Dict[str, Any]:
    """Delete all durable training data files."""
    try:
        deleted_files = []
        for file_path in glob.glob(str(TRAINING_DATA_DIR / "training_data_*.jsonl")):
            file_name = os.path.basename(file_path)
            os.remove(file_path)
            deleted_files.append(file_name)
        return {
            "message": f"영구 데이터 {len(deleted_files)}개 삭제",
            "deleted_files": deleted_files,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"전체 삭제 실패: {exc}") from exc


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest, request: Request) -> PredictResponse:
    """
    Batch inference endpoint used by the browser extension.

    Batching remains important in cloud mode because it reduces request
    overhead and increases throughput for the model container.
    """
    started_at = time.perf_counter()
    texts = [text if isinstance(text, str) else str(text) for text in req.texts]
    if len(texts) == 0:
        return PredictResponse(labels=[], probs=[], label_names=LABEL_NAMES)

    encoded = TOKENIZER(
        texts,
        padding=True,
        truncation=True,
        max_length=256,
        return_tensors="pt",
    )
    encoded = {key: value.to(DEVICE) for key, value in encoded.items()}

    with torch.no_grad():
        outputs = MODEL(**encoded)
        logits = outputs.logits
        probabilities = _softmax(logits).cpu()
        predictions = torch.argmax(probabilities, dim=-1).tolist()

    probs = probabilities.tolist()
    latency_ms = round((time.perf_counter() - started_at) * 1000, 2)
    total_characters = sum(len(text) for text in texts)
    client_key = _get_client_key(request)

    if SETTINGS.enable_traffic_metrics:
        TRAFFIC_METRICS.record_predict(
            client_key=client_key,
            batch_size=len(texts),
            characters=total_characters,
            latency_ms=latency_ms,
            labels=predictions,
        )

        # This per-request log is the raw material for before/after analysis.
        # Typical things to compare once a rate limit is added:
        # - batch size distribution
        # - latency spikes under burst traffic
        # - whether one caller dominates request volume
        # - label mix under peak traffic
        predict_log = {
            "client": client_key,
            "batch_size": len(texts),
            "characters": total_characters,
            "latency_ms": latency_ms,
            "labels": {
                "normal": predictions.count(0),
                "borderline_abusive": predictions.count(1),
                "abusive": predictions.count(2),
            },
        }
        LOGGER.info("PREDICT_METRIC %s", json.dumps(predict_log, ensure_ascii=False))

    if SETTINGS.log_predictions:
        for index, (text, label, prob) in enumerate(zip(texts, predictions, probs)):
            preview = (text or "").replace("\n", " ")
            if len(preview) > 200:
                preview = preview[:200] + "..."
            LOGGER.info(
                'PRED[%s] label=%s (%s) probs=%s text="%s"',
                index,
                label,
                LABEL_NAMES.get(label, "?"),
                [round(score, 4) for score in prob],
                preview,
            )

    return PredictResponse(labels=predictions, probs=probs, label_names=LABEL_NAMES)


_initialize_model()


if __name__ == "__main__":
    import uvicorn

    try:
        LOGGER.info("Starting server on %s:%s", SETTINGS.host, SETTINGS.port)
        uvicorn.run(app, host=SETTINGS.host, port=SETTINGS.port, reload=False)
    except Exception as exc:
        LOGGER.exception("Server start failed: %s", exc)
        if getattr(sys, "frozen", False):
            input(
                "\n에러가 발생했습니다. 위 메시지를 확인하세요.\n"
                "계속하려면 Enter를 누르세요..."
            )
        raise
