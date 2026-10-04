# benchmarks

This directory holds the buffer micro-benchmark for
[`../docs/BENCHMARK.md`](../docs/BENCHMARK.md). The benchmark compares the
on-chain strategies for a dynamic buffer in three append regimes:

- ethier / `scripty.sol`
- Solady `DynamicBufferLib`
- the rope of no_side
- the `MCOPY` static buffer of this repository

This is a **separate small project**. It is not part of the encoder build, so
`forge test` at the repository root tests only the encoder. It uses the
`forge-std` of the parent repository at `../lib`.

```bash
# full table including the MCOPY rows (needs a Cancun-capable Foundry >= 1.0)
forge test --root benchmarks --evm-version cancun -vv

# the word-loop-only rows also reproduce on Shanghai (identical numbers):
forge test --root benchmarks --evm-version shanghai --match-contract BenchShanghai -vv
```

Each implementation has its own test function (its own message call). Thus the
EVM charges the memory-expansion gas equally to each implementation. See the
method section of `../docs/BENCHMARK.md`.

Contents:

- `src/Libs.sol`: safe for Shanghai. It contains `Ethier`, `Hoisted`, Solady
  `DynamicBufferLib` (trimmed, exact copy) and `RopeWL` (a word-loop rope).
- `src/LibsMcopy.sol`: for Cancun only. It contains `Mcopy` (a static buffer
  with `mcopy`) and `RopeMcopy` (the deployed `LibDynamicBuffer` of no_side).
- `test/Bench.t.sol`: regimes S1, S2 and S3 for the Shanghai-safe libraries.
- `test/BenchMcopy.t.sol`: the same regimes for the `MCOPY` variants.
