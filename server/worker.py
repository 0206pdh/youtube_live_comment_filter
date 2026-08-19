"""SQS consumer for isolated model training and verified ECS promotion."""

import json
import logging
import os
import shutil
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import boto3
import psycopg2
from transformers import AutoModelForSequenceClassification, AutoTokenizer

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(), format="[%(levelname)s] %(message)s")
LOGGER = logging.getLogger("ylcf_worker")

TRAINING_QUEUE_URL = os.environ["TRAINING_QUEUE_URL"]
TRAINING_DATA_BUCKET = os.environ["TRAINING_DATA_BUCKET"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "ylcf")
DB_USER = os.environ.get("DB_USER", "ylcf_admin")
DB_PASSWORD = os.environ["DB_PASSWORD"]
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/app/model"))
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-2")
ECS_CLUSTER = os.environ.get("ECS_CLUSTER", "")
ECS_API_SERVICE = os.environ.get("ECS_API_SERVICE", "")
ROLLOUT_WAIT_SECONDS = int(os.environ.get("ROLLOUT_WAIT_SECONDS", "1800"))
VISIBILITY_TIMEOUT_SECONDS = int(os.environ.get("VISIBILITY_TIMEOUT_SECONDS", "3600"))

sqs = boto3.client("sqs", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)
ecs = boto3.client("ecs", region_name=AWS_REGION)


def get_db():
    return psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
                            password=DB_PASSWORD, connect_timeout=10)


def ensure_schema(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("""CREATE TABLE IF NOT EXISTS training_runs (
            id SERIAL PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            status TEXT NOT NULL DEFAULT 'queued', sample_count INTEGER, triggered_by TEXT)""")
        for col, definition in [
            ("started_at", "TIMESTAMPTZ"), ("completed_at", "TIMESTAMPTZ"),
            ("model_version", "TEXT"), ("error_message", "TEXT"),
            ("created_at", "TIMESTAMPTZ DEFAULT NOW()"),
        ]:
            cur.execute(f"ALTER TABLE training_runs ADD COLUMN IF NOT EXISTS {col} {definition}")
    conn.commit()


def claim_run(conn, run_id: int) -> bool:
    with conn.cursor() as cur:
        cur.execute("UPDATE training_runs SET status='running', started_at=NOW(), "
                    "completed_at=NULL, error_message=NULL WHERE id=%s "
                    "AND status IN ('queued','failed') RETURNING id", (run_id,))
        claimed = cur.fetchone() is not None
    conn.commit()
    return claimed


def finish_run(conn, run_id: int, version: str | None, error: str | None) -> None:
    with conn.cursor() as cur:
        if version:
            cur.execute("UPDATE training_runs SET status='success', model_version=%s, "
                        "completed_at=NOW() WHERE id=%s", (version, run_id))
        else:
            cur.execute("UPDATE training_runs SET status='failed', error_message=%s, "
                        "completed_at=NOW() WHERE id=%s", (error or "unknown error", run_id))
    conn.commit()


def download_training_data(local_dir: Path) -> int:
    local_dir.mkdir(parents=True, exist_ok=True)
    count = 0
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=TRAINING_DATA_BUCKET, Prefix="training-data/"):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".jsonl"):
                s3.download_file(TRAINING_DATA_BUCKET, obj["Key"], str(local_dir / Path(obj["Key"]).name))
                count += 1
    return count


def get_active_pointer() -> dict | None:
    try:
        response = s3.get_object(Bucket=TRAINING_DATA_BUCKET, Key="models/latest.json")
        return json.loads(response["Body"].read().decode("utf-8"))
    except Exception as exc:
        if getattr(exc, "response", {}).get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
            return None
        raise


def download_model(version: str, local_dir: Path) -> int:
    prefix, count = f"models/{version}/", 0
    local_dir.mkdir(parents=True, exist_ok=True)
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=TRAINING_DATA_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            relative = obj["Key"][len(prefix):]
            if relative:
                destination = local_dir / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                s3.download_file(TRAINING_DATA_BUCKET, obj["Key"], str(destination))
                count += 1
    return count


def upload_model(local_dir: Path, version: str) -> None:
    files = [path for path in local_dir.rglob("*") if path.is_file()]
    if not files:
        raise RuntimeError("Training produced no model artifacts")
    for path in files:
        key = f"models/{version}/{path.relative_to(local_dir).as_posix()}"
        s3.upload_file(str(path), TRAINING_DATA_BUCKET, key)


def validate_model(model_dir: Path) -> None:
    tokenizer = AutoTokenizer.from_pretrained(str(model_dir), local_files_only=True)
    model = AutoModelForSequenceClassification.from_pretrained(str(model_dir), local_files_only=True)
    if model.config.num_labels != 3:
        raise RuntimeError(f"Model has {model.config.num_labels} labels; expected 3")
    del tokenizer, model


def put_pointer(pointer: dict) -> None:
    s3.put_object(Bucket=TRAINING_DATA_BUCKET, Key="models/latest.json",
                  Body=json.dumps(pointer).encode("utf-8"), ContentType="application/json")


def wait_for_rollout() -> None:
    attempts = max(1, ROLLOUT_WAIT_SECONDS // 15)
    ecs.get_waiter("services_stable").wait(
        cluster=ECS_CLUSTER, services=[ECS_API_SERVICE],
        WaiterConfig={"Delay": 15, "MaxAttempts": attempts})
    service = ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_API_SERVICE])["services"][0]
    if service["deployments"][0].get("rolloutState") == "FAILED":
        raise RuntimeError(service["deployments"][0].get("rolloutStateReason", "ECS rollout failed"))


def promote_model(version: str) -> None:
    if not ECS_CLUSTER or not ECS_API_SERVICE:
        raise RuntimeError("ECS_CLUSTER and ECS_API_SERVICE are required for promotion")
    previous = get_active_pointer()
    put_pointer({"version": version, "promoted_at": datetime.now(timezone.utc).isoformat()})
    try:
        ecs.update_service(cluster=ECS_CLUSTER, service=ECS_API_SERVICE, forceNewDeployment=True)
        wait_for_rollout()
    except Exception:
        LOGGER.exception("Rollout failed; restoring the previous model pointer")
        if previous is None:
            s3.delete_object(Bucket=TRAINING_DATA_BUCKET, Key="models/latest.json")
        else:
            put_pointer(previous)
        ecs.update_service(cluster=ECS_CLUSTER, service=ECS_API_SERVICE, forceNewDeployment=True)
        wait_for_rollout()
        raise


@contextmanager
def visibility_heartbeat(receipt_handle: str):
    stopped = threading.Event()

    def extend() -> None:
        while not stopped.wait(max(30, VISIBILITY_TIMEOUT_SECONDS // 3)):
            try:
                sqs.change_message_visibility(QueueUrl=TRAINING_QUEUE_URL,
                    ReceiptHandle=receipt_handle, VisibilityTimeout=VISIBILITY_TIMEOUT_SECONDS)
            except Exception:
                LOGGER.exception("Failed to extend SQS message visibility")

    thread = threading.Thread(target=extend, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stopped.set()
        thread.join(timeout=2)


def process(message: dict, conn) -> None:
    receipt = message["ReceiptHandle"]
    body = json.loads(message["Body"])
    run_id = int(body["run_id"])
    if not claim_run(conn, run_id):
        LOGGER.warning("Ignoring duplicate or unknown run_id=%s", run_id)
        sqs.delete_message(QueueUrl=TRAINING_QUEUE_URL, ReceiptHandle=receipt)
        return

    job_dir = Path("/tmp/ylcf-jobs") / str(run_id)
    shutil.rmtree(job_dir, ignore_errors=True)
    data_dir, output_dir, active_dir = job_dir / "data", job_dir / "output", job_dir / "active"
    try:
        with visibility_heartbeat(receipt):
            if download_training_data(data_dir) == 0:
                raise RuntimeError("No training data found in S3")
            pointer = get_active_pointer()
            base_model = MODEL_DIR
            if pointer:
                if download_model(str(pointer["version"]), active_dir) == 0:
                    raise RuntimeError("Active model pointer has no artifacts")
                validate_model(active_dir)
                base_model = active_dir

            sys.path.insert(0, str(Path(__file__).parent))
            from train import train_model
            output_dir.mkdir(parents=True, exist_ok=True)
            if not train_model(model_dir=base_model, training_data_dir=data_dir, output_dir=output_dir):
                raise RuntimeError("train_model() returned False")
            validate_model(output_dir)
            version = f"{datetime.now(timezone.utc):%Y%m%d-%H%M%S}-{run_id}"
            upload_model(output_dir, version)
            promote_model(version)
            finish_run(conn, run_id, version, None)
            sqs.delete_message(QueueUrl=TRAINING_QUEUE_URL, ReceiptHandle=receipt)
            LOGGER.info("Job complete: run_id=%s model_version=%s", run_id, version)
    except Exception as exc:
        LOGGER.exception("Job failed: run_id=%s", run_id)
        finish_run(conn, run_id, None, str(exc))
    finally:
        shutil.rmtree(job_dir, ignore_errors=True)


def run() -> None:
    conn = get_db()
    ensure_schema(conn)
    while True:
        try:
            response = sqs.receive_message(QueueUrl=TRAINING_QUEUE_URL,
                                           MaxNumberOfMessages=1, WaitTimeSeconds=20)
            for message in response.get("Messages", []):
                process(message, conn)
        except psycopg2.Error:
            LOGGER.exception("Database connection failed; reconnecting")
            try:
                conn.close()
            except Exception:
                pass
            time.sleep(5)
            conn = get_db()
            ensure_schema(conn)
        except Exception:
            LOGGER.exception("Worker loop error")
            time.sleep(5)


if __name__ == "__main__":
    run()
