"""Training Worker — SQS consumer for async model retraining.

Polls the training queue, downloads labelled data from S3, runs train.py,
uploads the versioned model artifact back to S3, and updates the RDS
training_runs table with the outcome.

Environment variables (all required unless noted):
  TRAINING_QUEUE_URL       SQS queue URL
  TRAINING_DATA_BUCKET     S3 bucket holding training-data/ and models/
  DB_HOST                  RDS host
  DB_PASSWORD              RDS master password
  DB_PORT                  (optional, default 5432)
  DB_NAME                  (optional, default ylcf)
  DB_USER                  (optional, default ylcf_admin)
  MODEL_DIR                (optional, default /app/model)
  AWS_DEFAULT_REGION       (optional, default ap-northeast-2)
  LOG_LEVEL                (optional, default INFO)

Architecture note
-----------------
The API server (app.py) only *publishes* a job to SQS when /model/retrain is
called. This worker is the sole consumer. Separating the two processes means
BERT fine-tuning never competes with inference for CPU, which is the main
latency improvement in Phase 3.
"""

import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
import psycopg2

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="[%(levelname)s] %(message)s")
LOGGER = logging.getLogger("ylcf_worker")

# ---------------------------------------------------------------------------
# Configuration (fail fast on missing required env vars)
# ---------------------------------------------------------------------------
TRAINING_QUEUE_URL = os.environ["TRAINING_QUEUE_URL"]
TRAINING_DATA_BUCKET = os.environ["TRAINING_DATA_BUCKET"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "ylcf")
DB_USER = os.environ.get("DB_USER", "ylcf_admin")
DB_PASSWORD = os.environ["DB_PASSWORD"]
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/app/model"))
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-2")

sqs = boto3.client("sqs", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=10,
    )


def ensure_schema(conn) -> None:
    """Ensure training_runs table has all columns the worker needs.

    app.py creates the base table; this function adds columns introduced in
    Phase 3 without touching existing rows.
    """
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS training_runs (
                id          SERIAL PRIMARY KEY,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                status      TEXT        NOT NULL DEFAULT 'queued',
                sample_count INTEGER,
                triggered_by TEXT
            )
        """)
        for col, defn in [
            ("started_at",    "TIMESTAMPTZ"),
            ("completed_at",  "TIMESTAMPTZ"),
            ("model_version", "TEXT"),
            ("error_message", "TEXT"),
            ("created_at",    "TIMESTAMPTZ DEFAULT NOW()"),
        ]:
            cur.execute(
                f"ALTER TABLE training_runs ADD COLUMN IF NOT EXISTS {col} {defn}"
            )
    conn.commit()


def claim_run(conn) -> int | None:
    """Mark the most-recent queued run as running and return its id."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id FROM training_runs WHERE status = 'queued'"
            " ORDER BY created_at DESC LIMIT 1"
        )
        row = cur.fetchone()
        if not row:
            return None
        run_id = row[0]
        cur.execute(
            "UPDATE training_runs SET status = 'running', started_at = NOW()"
            " WHERE id = %s",
            (run_id,),
        )
    conn.commit()
    return run_id


def finish_run(
    conn,
    run_id: int | None,
    version: str | None,
    error: str | None,
) -> None:
    if run_id is None:
        return
    with conn.cursor() as cur:
        if version:
            cur.execute(
                "UPDATE training_runs"
                " SET status = 'success', model_version = %s, completed_at = NOW()"
                " WHERE id = %s",
                (version, run_id),
            )
        else:
            cur.execute(
                "UPDATE training_runs"
                " SET status = 'failed', error_message = %s, completed_at = NOW()"
                " WHERE id = %s",
                (error or "unknown error", run_id),
            )
    conn.commit()


# ---------------------------------------------------------------------------
# S3 helpers
# ---------------------------------------------------------------------------

def download_training_data(local_dir: Path) -> int:
    """Download all training-data/*.jsonl objects from S3 into local_dir."""
    local_dir.mkdir(parents=True, exist_ok=True)
    paginator = s3.get_paginator("list_objects_v2")
    count = 0
    for page in paginator.paginate(Bucket=TRAINING_DATA_BUCKET, Prefix="training-data/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".jsonl"):
                continue
            dest = local_dir / Path(key).name
            LOGGER.info("s3://%s/%s → %s", TRAINING_DATA_BUCKET, key, dest)
            s3.download_file(TRAINING_DATA_BUCKET, key, str(dest))
            count += 1
    return count


def upload_model(local_dir: Path, version: str) -> None:
    """Upload all files in local_dir to s3://bucket/models/{version}/."""
    for f in local_dir.iterdir():
        if not f.is_file():
            continue
        key = f"models/{version}/{f.name}"
        LOGGER.info("%s → s3://%s/%s", f.name, TRAINING_DATA_BUCKET, key)
        s3.upload_file(str(f), TRAINING_DATA_BUCKET, key)


# ---------------------------------------------------------------------------
# Core message handler
# ---------------------------------------------------------------------------

def process(message: dict, conn) -> None:
    receipt = message["ReceiptHandle"]
    body = json.loads(message["Body"])
    LOGGER.info("Job received: %s", body)

    run_id = claim_run(conn)

    try:
        # 1. Download training data
        data_dir = Path("/tmp/training_data")
        n_files = download_training_data(data_dir)
        LOGGER.info("Downloaded %d training file(s)", n_files)
        if n_files == 0:
            raise RuntimeError("No training data found in S3 (training-data/*.jsonl)")

        # 2. Run training
        output_dir = Path("/tmp/model_output")
        output_dir.mkdir(parents=True, exist_ok=True)

        # train.py lives next to worker.py in the same image
        sys.path.insert(0, str(Path(__file__).parent))
        from train import train_model  # noqa: PLC0415

        LOGGER.info("Training started — base model: %s", MODEL_DIR)
        success = train_model(
            model_dir=MODEL_DIR,
            training_data_dir=data_dir,
            output_dir=output_dir,
        )
        if not success:
            raise RuntimeError("train_model() returned False")

        # 3. Upload versioned artifact to S3
        version = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        upload_model(output_dir, version)
        LOGGER.info("Model version %s uploaded to s3://%s/models/%s/",
                    version, TRAINING_DATA_BUCKET, version)

        # 4. Update RDS
        finish_run(conn, run_id, version=version, error=None)

        # 5. Delete SQS message (job is done)
        sqs.delete_message(QueueUrl=TRAINING_QUEUE_URL, ReceiptHandle=receipt)
        LOGGER.info("Job complete. model_version=%s", version)

    except Exception as exc:
        LOGGER.error("Job failed: %s", exc, exc_info=True)
        finish_run(conn, run_id, version=None, error=str(exc))
        # Intentionally do NOT delete the message so it re-appears after
        # visibility timeout and eventually lands in the DLQ for inspection.


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run() -> None:
    LOGGER.info("Training worker starting")
    LOGGER.info("Queue  : %s", TRAINING_QUEUE_URL)
    LOGGER.info("Bucket : %s", TRAINING_DATA_BUCKET)
    LOGGER.info("DB     : %s:%s/%s", DB_HOST, DB_PORT, DB_NAME)

    conn = get_db()
    ensure_schema(conn)
    LOGGER.info("Schema ready")

    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=TRAINING_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,  # long-polling
            )
            for msg in resp.get("Messages", []):
                process(msg, conn)

        except psycopg2.Error:
            LOGGER.warning("DB error — reconnecting", exc_info=True)
            try:
                conn.close()
            except Exception:
                pass
            try:
                conn = get_db()
                ensure_schema(conn)
            except Exception:
                LOGGER.error("DB reconnect failed — retrying in 10s")
                time.sleep(10)

        except Exception:
            LOGGER.error("Worker loop error", exc_info=True)
            time.sleep(5)


if __name__ == "__main__":
    run()
