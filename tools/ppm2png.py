"""PPM -> PNG。只用标准库，因为渲染器刻意不带第三方依赖。

游戏本体输出 PPM（写一个 P6 头 + 原始像素，十几行代码），
转 PNG 只是给人看图的便利工具，不属于游戏运行时。
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:2] != b"P6":
        raise SystemExit(f"{path} 不是 P6 PPM")
    idx, fields = 2, []
    while len(fields) < 3:
        while idx < len(data) and data[idx : idx + 1].isspace():
            idx += 1
        if data[idx : idx + 1] == b"#":
            while data[idx : idx + 1] != b"\n":
                idx += 1
            continue
        start = idx
        while not data[idx : idx + 1].isspace():
            idx += 1
        fields.append(int(data[start:idx]))
    idx += 1
    w, h, _maxv = fields
    return w, h, data[idx : idx + w * h * 3]


def write_png(path: Path, w: int, h: int, rgb: bytes) -> None:
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)  # filter = None
        raw += rgb[y * stride : (y + 1) * stride]

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: ppm2png.py 输入.ppm [输出.png]")
        return 1
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".png")
    w, h, rgb = read_ppm(src)
    write_png(dst, w, h, rgb)
    print(f"{src.name} {w}x{h} -> {dst}  ({dst.stat().st_size / 1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
