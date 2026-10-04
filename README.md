# pngencoder

`pngencoder` is an on-chain **PNG and APNG encoder** for the EVM, written in
Solidity. Give the encoder a raw RGBA framebuffer. The encoder gives back a
`data:image/png;base64,…` URI or the raw PNG bytes. All of the work occurs in
one `view` call. The encoder does not use IPFS or an off-chain renderer.

```
raw RGBA ──► upscale + filter ──► zlib( DEFLATE ) ──► PNG chunks (+CRC/adler) ──► base64 URI
```

The encoder supports still images and **animated PNGs** (APNG). One frame makes
a PNG. More than one frame makes an APNG with `acTL`, `fcTL` and `fdAT` chunks.

## Deployed contracts

Each link opens the contract on Etherscan.

| Contract | Mainnet | Sepolia |
|---|---|---|
| `PNGEncoder` | [`0xAF8f886Df2285a4Ca847AAA1a3223d420d79e886`](https://etherscan.io/address/0xAF8f886Df2285a4Ca847AAA1a3223d420d79e886#code) | [`0xbF91c1168034ca77A41DBc904552a3F7625bB923`](https://sepolia.etherscan.io/address/0xbF91c1168034ca77A41DBc904552a3F7625bB923#code) |
| `Deflate` (linked library) | [`0xFe7C75c11b6a28F4E36c2a0b3af8EA6dfFa0Ed9f`](https://etherscan.io/address/0xFe7C75c11b6a28F4E36c2a0b3af8EA6dfFa0Ed9f#code) | [`0xFe7C75c11b6a28F4E36c2a0b3af8EA6dfFa0Ed9f`](https://sepolia.etherscan.io/address/0xFe7C75c11b6a28F4E36c2a0b3af8EA6dfFa0Ed9f#code) |

## Speed

An on-chain image encoder uses almost all of its gas to **copy bytes**. It
copies the pixel stream, the chunks and the base64 input. This encoder requires
the Cancun EVM. It copies bytes with the
[`MCOPY`](https://eips.ethereum.org/EIPS/eip-5656) opcode, which is one
instruction. Older buffer libraries copy 32 bytes at a time in a loop.

On typical buffers, `MCOPY` makes the copy path **approximately 45% to 69%
cheaper**. [`docs/BENCHMARK.md`](docs/BENCHMARK.md) compares the buffer of this
encoder with other on-chain buffer libraries.

A render is a `view` call. Low gas keeps the call in the `eth_call` gas budget
of a node. Low gas also helps other contracts that call the encoder on-chain.
For these reasons, this project optimizes the copy path.

## Usage

```solidity
import {PNGEncoder} from "pngencoder/src/PNGEncoder.sol";
import {Animation} from "pngencoder/src/Animation.sol";

PNGEncoder enc = new PNGEncoder();

Animation memory a;
a.frameCount = 1;
a.width = 64;
a.height = 64;
a.frames = new bytes[](1);
a.frames[0] = rgba;                          // width*height*4 bytes, row-major RGBA

bytes memory uri = enc.getDataUri(a, 1);     // data:image/png;base64,...
bytes memory png = enc.getImageBuffer(a, 1); // raw PNG bytes
```

For a still image, the struct is optional. The convenience overloads take the
pixels directly:

```solidity
bytes memory uri = enc.getDataUri(rgba, 64, 64, 1);  // same output, no struct
```

`scaleFactor` increases the image size on-chain with nearest-neighbour scaling.
A 64×64 frame with `scaleFactor = 4` gives a 256×256 image.

Malformed input does not make a corrupt PNG. The encoder reverts with a typed
error:

- `InvalidDimensions`: a dimension or the scale is zero.
- `ImageTooLarge`: a scaled dimension is more than 65,535.
- `LayerSizeMismatch`: the byte length of a frame does not agree with its
  dimensions.
- `InvalidFrame`: the geometry of an APNG frame goes out of the canvas, or the
  first frame does not cover the canvas.

`frameCount` sets the number of frames, not `frames.length`. The encoder reads
exactly `frameCount` frames. Each per-frame array must have a minimum of
`frameCount` items. Make sure that the count agrees with the arrays.

## Encodings

The three-argument overloads select an encoding. An encoding sets two
properties: the colour representation and the compression.

```solidity
enum Encoding { TrueColor, Indexed, Auto, TrueColorDeflate, IndexedDeflate, AutoDeflate, IndexedRLE, AutoRLE }

enc.getDataUri(a, 1, Encoding.AutoDeflate);     // smallest, automatically
enc.getImageBuffer(a, 1, Encoding.Indexed);
```

**Colour**

- *TrueColor* stores RGBA. It accepts all images and uses four bytes for each
  pixel.
- *Indexed* stores a palette and one byte for each pixel (PNG colour type 3).
  The image must have a maximum of 256 different colours. If the image has
  more, the encoder reverts with `NotIndexable`.
- *Auto*, *AutoDeflate* and *AutoRLE* use Indexed when the image is indexable.
  If the image is not indexable, they use TrueColor. `resolveEncoding(a)` gives
  the colour choice.

**Compression**

- The plain variants store the pixels without compression. They use the least
  gas to encode.
- The `*Deflate` variants apply an adaptive PNG filter to each row (None, Sub or
  Up). Then they apply DEFLATE with **LZ77 matching** and **Huffman codes** for
  each block. The output is much smaller, but this path uses much more gas than
  the other paths. Use it when a small output is more important than the gas to
  encode.
- The `*RLE` variants are between the two. They apply DEFLATE with run-length
  matches only, in one O(n) pass. They use a small fraction of the gas of the
  full compressor. On palette art with long runs, the output is almost as small.
  RLE is available for indexed images only. `AutoRLE` uses stored TrueColor when
  the image is not indexable.

The `*Deflate` variants have these properties:

- The LZ77 back-references can go back as far as the 32 KB window.
- For each block, the encoder makes optimal length-limited Huffman codes from
  the symbol counts of that block.
- The encoder uses these codes when they give a smaller block than the fixed
  codes of the RFC. If they do not, it uses the fixed codes.

The combined effect is large. This table shows a 128×128 canvas with 32
colours:

| encoding | bytes |
|---|--:|
| TrueColor | 65,737 |
| Indexed | 16,688 |
| **IndexedDeflate** | **604** |

The two-argument calls use plain TrueColor. Select the path for each output:

- Use the stored variants when the gas to encode is most important.
- Use the `*Deflate` variants when the output size is most important. The output
  size sets the cost of on-chain storage and of embedding.

### Pre-indexed input

If you know the palette (this is usual for generative art), give the indices
directly to the encoder. The encoder then does not extract the colours.

```solidity
// a.frames[i] = one palette index per pixel (not RGBA)
enc.getDataUriIndexed(a, 1, palette, true /* deflate */);
```

`palette` holds a maximum of 256 packed-RGBA colours. Each index must be
`< palette.length`. This is the cheapest indexed encode, because there is no
extraction pass for each pixel.

### Windowed encoding (a sequence of eth_calls)

You can make a large image with many `eth_call`s. Each call stays in the gas
budget of a node. The client joins the results and does not encode again.

One zlib stream contains the full image. The header opens the stream. Each band
(a group of source rows) adds one IDAT chunk. Each call gives the Adler-32 value
to the next call:

```solidity
bytes memory png = enc.pngStreamHeader(w, h, scale, palette); // empty palette = truecolor
uint32 adler = 1;
for (/* each band of source rows, top to bottom */) {
    (bytes memory idat, adler) = enc.pngStreamBand(bandPixels, w, scale, isIndexed, adler);
    png = bytes.concat(png, idat);
}
png = bytes.concat(png, enc.pngStreamTrailer(adler));
```

Select a band height that lets each call stay in the budget. Then continue the
loop until the bands include all rows. You can use this with tiled
rasterization: a renderer contract renders a band, then encodes it. Thus you can
make an image of any size, one call at a time.

Two band encoders use the same header and trailer:

- **`pngStreamBand`**: stored (not compressed). It uses the least gas for each
  call.
- **`pngStreamBandDeflate`**: compressed (LZ77 + Huffman). Each band is an
  independent DEFLATE fragment. The match window stays in the band, and a sync
  flush ends the band on a byte boundary. Thus the bands still join into one
  stream.

The output of `pngStreamBandDeflate` is much smaller. For example, a 32×48
canvas with four colours in 8-row bands uses **275 B**, compared with
**1,790 B** stored. But the compression is local to each band: matches do not
go across bands. This is the cost of independent calls.

The output of each band encoder decodes to the same pixels as the one-shot
encode, byte for byte ([`test/Stream.t.sol`](test/Stream.t.sol)).

To put ancillary chunks (`tEXt`, `gAMA`, `pHYs`, …) into a windowed stream:

1. Make each chunk with `pngChunk(tag, data)`.
2. Put the chunks between the preamble and the stream opener.

`pngStreamHeader` is the preamble and the stream opener joined.

```solidity
bytes memory png = bytes.concat(
    enc.pngStreamPreamble(w, h, scale, palette),
    enc.pngChunk("tEXt", bytes("Software\x00pngencoder")),
    enc.pngStreamOpen()
);
```

### APNG playback control

By default, the animation loops forever and uses `DISPOSE_OP_NONE` and
`BLEND_OP_OVER`. The input struct has no playback fields. To change the
playback, patch the finished bytes:

- `withLoopCount(png, n)` writes the play count of `acTL` again (0 = forever).
- `withFrameControl(png, frame, disposeOp, blendOp)` writes the `fcTL` of one
  frame again.

Each function calculates the CRC of the chunk again and changes nothing else.
Thus you can use these functions with all encoding paths.

## Discovery and self-description

The deployed encoder supports ERC-165. It registers
`type(IPNGEncoder).interfaceId` and the narrower `IAnimationEncoder`.

When a call uses an unknown selector, the encoder reverts with
`Self.Describe(bytes)`. The revert data contains one line of prose, then the
full interface. The interface is a list of canonical ABI signatures, one on each
line. The hash of each signature gives its selector. Thus you can integrate the
contract without external documentation
([wattsyart/self](https://github.com/wattsyart/self)).

Each `getDataUri*` function has a `getDataUri*String` twin that returns `string`
and not `bytes`. An ERC-721 or ERC-1155 `tokenURI` can return this value
directly, without a `string(...)` cast. Each twin only reinterprets the `bytes`
form: the output and the gas are the same.

## Not in scope

The encoder does not have these three capabilities. Each omission is
intentional.

**Windowed APNG**

- The band path (`pngStream*`) makes one still image. Animation is one-shot
  only.
- A windowed APNG would have to pass much state from call to call: the
  `fcTL`/`fdAT` sequence numbers, the region of each frame and the shared
  palette.
- The one-shot APNG path can encode typical animations (tens of frames) in one
  `view` call. Thus the added complexity gives little benefit.

**Sub-8-bit indexed depth**

- Indexed output always uses 8 bits (one byte) for each pixel.
- An image with a maximum of 16 colours could use 4 bits (or 2 bits or 1 bit)
  for each pixel. This would make the *stored* payload approximately half the
  size.
- When the output size is important, use `*Deflate` or `*RLE`. These variants
  compress the unused high bits much more than bit packing can.
- The stored variants are for a cheap encode, where the size is not important.
  Thus bit packing would help only where the size is not important.

**Compositing**

- Each frame has one pixel buffer. The encoder does not blend layers.
- Generative pipelines composite their framebuffer before they encode.
- On-chain alpha blending for each pixel costs gas. Callers do not usually want
  to pay that gas two times.

## Correctness

A test suite checks the encoder:

- [`test/PNGEncoder.t.sol`](test/PNGEncoder.t.sol) checks the PNG signature, the
  IHDR dimensions and format, and the data-URI prefix. It also pins the exact
  `keccak` hash of a fixed fixture, so a change in the output bytes causes a
  failure.
- [`test/Indexed.t.sol`](test/Indexed.t.sol) **decodes** the output of the
  indexed and DEFLATE paths back to pixels. It makes sure that the pixels are
  the same as the source.
- [`test/Deflate.t.sol`](test/Deflate.t.sol) sends the output of the DEFLATE
  compressor through an independent inflater. The inputs include runs, literals
  and the full byte range.
- [`test/Huffman.t.sol`](test/Huffman.t.sol) uses differential fuzzing to
  compare the optimized Huffman tree builder with an exact copy of the merge
  that is not optimized.
- [`test/Adler.t.sol`](test/Adler.t.sol) uses differential fuzzing to compare
  the lane-arithmetic Adler-32 with the recurrence that processes one byte at a
  time.
- [`test/Validate.t.sol`](test/Validate.t.sol) makes sure that malformed input
  reverts with typed errors.

## Requirements

- **Cancun EVM or later**: the encoder uses `MCOPY`. Ethereum mainnet and most
  L2 chains support Cancun. The encoder does not run on a chain that does not
  support Cancun.
- **Foundry ≥ 1.0** and **solc ≥ 0.8.24** for the build. `foundry.toml` sets the
  solc version.

## Build, test and demo

```bash
forge build
forge test -vv                     # validity, golden, and gas
forge script script/Demo.s.sol     # writes demo/kintsugi.png (an animated PNG)
```

The demo renders a gold seam that moves across a dark lacquer panel, in the
style of kintsugi. The simulated EVM calculates and encodes all of the image.

## License

MIT. See [`LICENSE`](LICENSE).
