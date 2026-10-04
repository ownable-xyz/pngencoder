# demo

Render the sample animation:

```bash
forge script script/Demo.s.sol
```

This command writes two files. Git ignores the two files.

- `demo/kintsugi.png`: an **animated PNG** (APNG). A gold seam moves across a
  dark lacquer panel, in the style of kintsugi. The seam grows in each frame and
  has a bright tip. Then the animation loops.
- `demo/kintsugi.uri.txt`: the same image as a `data:image/png;base64,…` URI.

The animation has 16 frames of 128×128 pixels. The simulated EVM calculates and
encodes all of it. The demo uses no off-chain image library.

The palette has a small, fixed set of colours. Thus `AutoDeflate` encodes the
animation as an indexed APNG with filtering and LZ77 + Huffman compression. The
size is **~13 KB**, compared with ~1 MB for truecolor without compression
(≈81×). To see the animation, open the `.png` file in a browser or viewer that
supports APNG.
