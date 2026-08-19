# Grafana performance dashboard

The dashboard visualizes measurements already recorded by the repository's k6 runs.

| Dashboard value | Recorded source |
|---|---|
| Baseline p50 59 ms, p95 97 ms, 9.37 RPS | `load_tests/results/2026-03-26/2026-03-26_all_stages.md` |
| Soak p50 190 ms, p95 431 ms, 31.04 RPS | `load_tests/results/2026-03-26/2026-03-26_all_stages.md` |
| Retraining p50 61 ms, p95 107 ms, error 0%, 18,408 requests | `load_tests/results/2026-03-26/phase3_retrain_concurrent_raw.txt` |
| Before isolation p95 866 ms, error 49.93% | `load_tests/results/2026-03-26/retrain_concurrent_comparison.md` |

The dashboard JSON and datasource are provisioned from this directory. No generated
time series or projected GPU figures are included.

## Presentation dashboards

- `toxicfree-performance.json`: executive performance and retraining summary
- `stage-evolution.json`: Stage 1 → Stage 2 → ECS → 4-vCPU ECS comparison
- `scenario-slo.json`: baseline, spike, soak, retraining and SLO compliance
- `mlops-capacity.json`: model promotion state machine and current ECS controls

The final k6 summary files recorded p50/p90/p95/max but did not emit p99 for every
scenario. The dashboards therefore do not substitute max or an older run's p99 for
a missing final-run percentile.
