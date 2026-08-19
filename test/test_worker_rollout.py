import importlib.util
import os
from pathlib import Path
from unittest.mock import MagicMock


def load_worker(monkeypatch):
    env = {
        "TRAINING_QUEUE_URL": "https://sqs.invalid/queue",
        "TRAINING_DATA_BUCKET": "bucket",
        "DB_HOST": "db.invalid",
        "DB_PASSWORD": "secret",
        "ECS_CLUSTER": "cluster",
        "ECS_API_SERVICE": "api",
        "AWS_ACCESS_KEY_ID": "test",
        "AWS_SECRET_ACCESS_KEY": "test",
    }
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    clients = {name: MagicMock(name=name) for name in ("sqs", "s3", "ecs")}
    monkeypatch.setattr("boto3.client", lambda name, **kwargs: clients[name])
    spec = importlib.util.spec_from_file_location(
        "worker_under_test", Path(__file__).parents[1] / "server" / "worker.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_promote_waits_for_stable_service(monkeypatch):
    worker = load_worker(monkeypatch)
    worker.get_active_pointer = MagicMock(return_value={"version": "old"})
    worker.put_pointer = MagicMock()
    worker.wait_for_rollout = MagicMock()

    worker.promote_model("new")

    worker.put_pointer.assert_called_once()
    worker.ecs.update_service.assert_called_once()
    worker.wait_for_rollout.assert_called_once()


def test_failed_rollout_restores_previous_pointer(monkeypatch):
    worker = load_worker(monkeypatch)
    previous = {"version": "old"}
    worker.get_active_pointer = MagicMock(return_value=previous)
    worker.put_pointer = MagicMock()
    worker.wait_for_rollout = MagicMock(side_effect=[RuntimeError("failed"), None])

    try:
        worker.promote_model("bad")
        assert False, "promotion must fail"
    except RuntimeError:
        pass

    assert worker.put_pointer.call_args_list[-1].args == (previous,)
    assert worker.ecs.update_service.call_count == 2


def test_duplicate_message_is_deleted_without_training(monkeypatch):
    worker = load_worker(monkeypatch)
    worker.claim_run = MagicMock(return_value=False)
    message = {"ReceiptHandle": "receipt", "Body": '{"run_id": 42}'}

    worker.process(message, MagicMock())

    worker.sqs.delete_message.assert_called_once_with(
        QueueUrl=worker.TRAINING_QUEUE_URL, ReceiptHandle="receipt"
    )
