# Buffer benchmark: MCOPY and the word-loop libraries

One operation controls the gas of this encoder: the copy of bytes into an output
buffer. This document measures the effect of the copy strategy on gas. It also
explains why this repository requires Cancun and uses `MCOPY`.

## Contenders

| name | origin | strategy | needs Cancun? |
|---|---|---|---|
| `ethier` | divergencetech/ethier (= `scripty.sol` core) | static allocate + 32B word-loop append | no |
| `solady` | Solady `DynamicBufferLib` | dynamic doubling, in-place-contiguous fast path, single-cursor word loop | no |
| `ropeWL` | no_side's *design*, word-loop flatten | O(1) linked-list push + one flatten pass | no |
| **`mcopy`** | this repo's `Buffer` | static allocate + `MCOPY` append | **yes** |
| `ropeMcopy` | no_side's *deployed* `LibDynamicBuffer` | O(1) push + `MCOPY` flatten | **yes** |

## Method

**Each implementation has its own message call** (its own test function).

- It is incorrect to measure more than one implementation in one call.
- In the EVM, the gas for memory expansion only increases in a call frame. Thus
  the first implementation pays for all the expansion, and the others look free.
- Each dispatcher makes its source chunk in the same way before it starts the
  gas measurement. Thus each implementation allocates its buffer from the same
  memory level.

The benchmark has three regimes:

- **S1**: one append of ~300 KB (like IDAT).
- **S2**: 256 appends of 1 KB, with a known total (assembly of frames or tiles).
- **S3**: 2000 appends of 40 B, with a size that is *not known* before the
  appends. This is the SVG-string regime, and dynamic buffers are made for it.

In S3, the static implementations get the exact size. In practice, they cannot
know this size. Thus their result is a lower limit, marked `*`.

The compiler is solc 0.8.26 with optimizer 200. The word-loop numbers are
**the same** for Shanghai (forge 0.2.0) and for Cancun (forge 1.5.1). This
agreement is a check of the harness. Only the `MCOPY` rows require Cancun.

## Results (gas)

### Shanghai: no MCOPY available

| regime | ethier | hoisted | solady(nores) | solady(reserve) | ropeWL |
|---|--:|--:|--:|--:|--:|
| S1  1×300 KB, known    | 1,171,949 | 1,256,347 | **1,041,296** | 1,672,974 | 1,172,680 |
| S2  256×1 KB, known    | 749,750 | 821,971 | 812,452 | **689,042** | 820,271 |
| S3  2000×40 B, unknown | 630,021* | 654,050* | **889,539** | n/a | 1,116,771 |

Conclusions:

- The single-cursor copy loop of Solady is cheaper than the word loop of ethier
  and scripty.
- With `reserve()`, Solady is the cheapest in the regime with many appends.
- A word-loop rope is more expensive. It has bookkeeping for each node and a
  second pass.
- The `hoisted` variant moves the length load out of the ethier loop by hand.
  This does *not* help: it adds a stack variable, and the optimizer gives
  slightly worse code.
- On Shanghai, manual changes to the assembly do not make a buffer cheaper than
  Solady.

### Cancun: MCOPY

| regime | ethier | solady | **mcopy** | ropeMcopy (no_side) |
|---|--:|--:|--:|--:|
| M1  1×300 KB, known    | 1,171,949 | 1,041,267 | **571,965** | 572,621 |
| M2  256×1 KB, known    | 749,750 | 812,423 | **214,768** | 285,979 |
| M3  2000×40 B, unknown | 630,021* | 889,510 | 290,067* | **782,723** |

Conclusions:

- `MCOPY` causes almost all of the difference.
- The `mcopy` column is the buffer that this repository ships: a simple static
  allocation with an `mcopy` append.
- On one large copy, `mcopy` is **~45%** cheaper than the best word-loop
  library. On many appends, it is **~69%** cheaper.
- `mcopy` is cheaper than the rope of no_side when the size is known. For a PNG
  encoder the size is always known, because the encoder calculates the output
  size before it writes.
- The `MCOPY` rope of no_side is the cheapest only when the size is not known
  (M3). This encoder does not have that condition.

## End-to-end encoder gas (this repo, Cancun)

`getDataUri`, single frame, `scaleFactor = 1`:

| canvas | data URI | gas |
|---|--:|--:|
| 64×64   | 22,046 B | 3,228,938 |
| 256×256 | 350,006 B | 56,238,028 |
| 512×512 | 1,399,006 B | 324,348,501 |

These are the costs of a `view` call. They are important for large canvases,
where the call must stay below the `eth_call` gas limit of a node. They are also
important for on-chain composition.

## How to reproduce

The harness for the buffer micro-benchmark is in [`../benchmarks`](../benchmarks).
The end-to-end encoder numbers come from `forge test -vv` (the
`test_Gas_getDataUri` test). The two require a Foundry version that supports Cancun (`>= 1.0`).
