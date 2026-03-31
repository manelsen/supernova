# Benchmarks

Baseline performance metrics for Supernova v0.3.0.

Run benchmarks with: `gleam test`

## LLM Benchmarks (mock provider)

| Operation | Target | Status |
|-----------|--------|--------|
| Mock LLM latency (no tools) | <50ms | TBD |
| Mock LLM latency (with tools) | <50ms | TBD |
| Provider config creation | <1ms | TBD |
| Message list creation | <1ms | TBD |

## Session Benchmarks

| Operation | Target | Status |
|-----------|--------|--------|
| Session creation throughput | >10 sessions/s | TBD |
| Session lookup throughput | >500 ops/s | TBD |

## Tool Registry Benchmarks

| Operation | Target | Status |
|-----------|--------|--------|
| Actor start | <50ms | TBD |
| List tools | <5ms | TBD |
| Execute tool | <10ms | TBD |

## Notes

- All benchmarks use mock providers — no real API calls.
- Targets are conservative estimates for development hardware.
- Real-world performance depends on workload and hardware.
- Run on target deployment hardware for accurate baselines.

## Updating Baselines

After significant changes to core paths, run benchmarks and update this document with actual measured values.
