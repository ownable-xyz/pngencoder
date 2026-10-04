// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./InflateLib.sol";

/// Test-only PNG reader for the output of this encoder. It accepts truecolor or
/// indexed images, all filters, stored, fixed or dynamic DEFLATE, and any
/// number of IDAT chunks. It goes through the chunks, inflates the joined IDAT
/// stream, reverses the row filters and returns the RGBA pixels.
library PngDecode {
    uint256 private constant T_IHDR = 0x49484452;
    uint256 private constant T_PLTE = 0x504C5445;
    uint256 private constant T_TRNS = 0x74524E53;
    uint256 private constant T_IDAT = 0x49444154;
    uint256 private constant T_IEND = 0x49454E44;

    function decode(bytes memory png) internal pure returns (uint256 w, uint256 h, uint8 colorType, bytes memory rgba) {
        uint256 o = 8; // skip signature
        bytes memory plte;
        bytes memory trns;
        bytes memory idat = new bytes(0);
        while (o + 8 <= png.length) {
            uint256 len = _u32(png, o);
            uint256 typ = _u32(png, o + 4);
            uint256 d = o + 8;
            if (typ == T_IHDR) {
                w = _u32(png, d);
                h = _u32(png, d + 4);
                colorType = uint8(png[d + 9]);
            } else if (typ == T_PLTE) {
                plte = _slice(png, d, len);
            } else if (typ == T_TRNS) {
                trns = _slice(png, d, len);
            } else if (typ == T_IDAT) {
                idat = bytes.concat(idat, _slice(png, d, len));
            }
            o = d + len + 4; // skip CRC
            if (typ == T_IEND) break;
        }

        uint256 bpp = colorType == 6 ? 4 : 1;
        bytes memory recon = _unfilter(InflateLib.inflateZlib(idat), w, h, bpp);
        rgba = colorType == 6 ? _extractTruecolor(recon, w, h) : _extractIndexed(recon, plte, trns, w, h);
    }

    function _extractTruecolor(bytes memory recon, uint256 w, uint256 h) private pure returns (bytes memory rgba) {
        rgba = new bytes(w * h * 4);
        uint256 rb = w * 4;
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint256 so = y * rb + x * 4;
                uint256 ro = (y * w + x) * 4;
                rgba[ro] = recon[so];
                rgba[ro + 1] = recon[so + 1];
                rgba[ro + 2] = recon[so + 2];
                rgba[ro + 3] = recon[so + 3];
            }
        }
    }

    function _extractIndexed(bytes memory recon, bytes memory plte, bytes memory trns, uint256 w, uint256 h)
        private
        pure
        returns (bytes memory rgba)
    {
        rgba = new bytes(w * h * 4);
        for (uint256 y = 0; y < h; y++) {
            for (uint256 x = 0; x < w; x++) {
                uint8 idx = uint8(recon[y * w + x]);
                uint256 po = uint256(idx) * 3;
                uint256 ro = (y * w + x) * 4;
                rgba[ro] = plte[po];
                rgba[ro + 1] = plte[po + 1];
                rgba[ro + 2] = plte[po + 2];
                rgba[ro + 3] = idx < trns.length ? trns[idx] : bytes1(uint8(255));
            }
        }
    }

    function _unfilter(bytes memory scan, uint256 w, uint256 h, uint256 bpp) private pure returns (bytes memory recon) {
        uint256 rowBytes = w * bpp;
        uint256 stride = 1 + rowBytes;
        recon = new bytes(h * rowBytes);
        for (uint256 y = 0; y < h; y++) {
            uint8 ft = uint8(scan[y * stride]);
            for (uint256 i = 0; i < rowBytes; i++) {
                uint8 f = uint8(scan[y * stride + 1 + i]);
                uint8 a = i >= bpp ? uint8(recon[y * rowBytes + i - bpp]) : 0;
                uint8 b = y > 0 ? uint8(recon[(y - 1) * rowBytes + i]) : 0;
                uint8 x;
                unchecked {
                    if (ft == 0) {
                        x = f;
                    } else if (ft == 1) {
                        x = f + a;
                    } else if (ft == 2) {
                        x = f + b;
                    } else {
                        uint8 c = (i >= bpp && y > 0) ? uint8(recon[(y - 1) * rowBytes + i - bpp]) : 0;
                        x = f + _paeth(a, b, c);
                    }
                }
                recon[y * rowBytes + i] = bytes1(x);
            }
        }
    }

    function _paeth(uint8 a, uint8 b, uint8 c) private pure returns (uint8) {
        int256 p = int256(uint256(a)) + int256(uint256(b)) - int256(uint256(c));
        int256 pa = p >= int256(uint256(a)) ? p - int256(uint256(a)) : int256(uint256(a)) - p;
        int256 pb = p >= int256(uint256(b)) ? p - int256(uint256(b)) : int256(uint256(b)) - p;
        int256 pc = p >= int256(uint256(c)) ? p - int256(uint256(c)) : int256(uint256(c)) - p;
        if (pa <= pb && pa <= pc) return a;
        if (pb <= pc) return b;
        return c;
    }

    function _u32(bytes memory b, uint256 o) private pure returns (uint256) {
        return (uint256(uint8(b[o])) << 24) | (uint256(uint8(b[o + 1])) << 16) | (uint256(uint8(b[o + 2])) << 8)
            | uint256(uint8(b[o + 3]));
    }

    function _slice(bytes memory b, uint256 off, uint256 len) private pure returns (bytes memory r) {
        r = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            r[i] = b[off + i];
        }
    }
}
