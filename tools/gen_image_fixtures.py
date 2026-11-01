#!/usr/bin/env python3
"""Generate image-decoder fixtures in src/image/testdata.

Each fixture `<name>.<ext>` is paired with `<name>.rgba`: the reference decode as
straight-alpha RGBA8 rows (from Pillow, or from the source pixels for hand-built PNGs).
PNGs are assembled by hand to cover every colour type, bit depth, filter type and
Adam7 interlacing, which Pillow cannot all write.
"""
import io
import random
import struct
import zlib
from pathlib import Path

from PIL import Image

out = Path(__file__).resolve().parents[1] / "src/image/testdata"
out.mkdir(parents=True, exist_ok=True)
W, H = 23, 17
random.seed(7)


def base_rgba():
    px = []
    for y in range(H):
        for x in range(W):
            r = (x * 11 + y * 3) & 255
            g = (y * 15) & 255
            b = ((x ^ y) * 9) & 255
            a = 255 if (x + y) % 5 else (x * 10) & 255
            px.append((r, g, b, a))
    return px


def save_rgba(name, pixels):
    (out / f"{name}.rgba").write_bytes(bytes(c for p in pixels for c in p))


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def filter_rows(rows, bpp):
    """Apply a random PNG filter to each scanline (exercises all five)."""
    result = b""
    prev = bytes(len(rows[0])) if rows else b""
    for row in rows:
        f = random.randrange(5)
        out_row = bytearray()
        for i, v in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) // 2, paeth(a, b, c)][f]
            out_row.append((v - pred) & 255)
        result += bytes([f]) + bytes(out_row)
        prev = row
    return result


def pack_bits(values, depth):
    if depth == 8:
        return bytes(values)
    if depth == 16:
        return b"".join(struct.pack(">H", v) for v in values)
    per = 8 // depth
    data = bytearray()
    for i in range(0, len(values), per):
        byte = 0
        for j in range(per):
            v = values[i + j] if i + j < len(values) else 0
            byte |= v << (8 - depth * (j + 1))
        data.append(byte)
    return bytes(data)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def make_png(name, color_type, depth, samples, interlace=False, plte=None, trns=None):
    """samples(x, y) -> tuple of channel values for that pixel at `depth`."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    bpp = max(1, channels * depth // 8)

    def scanlines(xs, ys):
        rows = []
        for y in ys:
            vals = []
            for x in xs:
                vals.extend(samples(x, y))
            rows.append(pack_bits(vals, depth))
        return rows

    raw = b""
    if interlace:
        for x0, y0, dx, dy in ADAM7:
            xs = list(range(x0, W, dx))
            ys = list(range(y0, H, dy))
            if xs and ys:
                raw += filter_rows(scanlines(xs, ys), bpp)
    else:
        raw = filter_rows(scanlines(range(W), range(H)), bpp)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, depth, color_type, 0, 0, 1 if interlace else 0))
    if plte:
        png += chunk(b"PLTE", plte)
    if trns:
        png += chunk(b"tRNS", trns)
    comp = zlib.compress(raw, 9)
    png += chunk(b"IDAT", comp[: len(comp) // 2]) + chunk(b"IDAT", comp[len(comp) // 2 :])  # split IDAT
    png += chunk(b"IEND", b"")
    (out / f"{name}.png").write_bytes(png)


base = base_rgba()
at = lambda x, y: base[y * W + x]

# RGBA8, interlaced RGBA8, RGB8, RGBA16, gray8, gray16, gray+alpha8, gray 1/2/4-bit, palette 1/2/4/8-bit + tRNS
make_png("png_rgba8", 6, 8, lambda x, y: at(x, y))
save_rgba("png_rgba8", base)
make_png("png_rgba8_adam7", 6, 8, lambda x, y: at(x, y), interlace=True)
save_rgba("png_rgba8_adam7", base)
make_png("png_rgb8", 2, 8, lambda x, y: at(x, y)[:3])
save_rgba("png_rgb8", [(r, g, b, 255) for r, g, b, _ in base])
make_png("png_rgba16", 6, 16, lambda x, y: tuple(c * 256 + ((x * 7 + i) & 255) for i, c in enumerate(at(x, y))))
save_rgba("png_rgba16", base)
gray = lambda x, y: (at(x, y)[0] * 3 + at(x, y)[1] * 5) // 8
make_png("png_gray8", 0, 8, lambda x, y: (gray(x, y),))
save_rgba("png_gray8", [(gray(x, y),) * 3 + (255,) for y in range(H) for x in range(W)])
make_png("png_gray16_adam7", 0, 16, lambda x, y: (gray(x, y) * 256 + ((x * 3) & 255),), interlace=True)
save_rgba("png_gray16_adam7", [(gray(x, y),) * 3 + (255,) for y in range(H) for x in range(W)])
make_png("png_graya8", 4, 8, lambda x, y: (gray(x, y), at(x, y)[3]))
save_rgba("png_graya8", [(gray(x, y),) * 3 + (at(x, y)[3],) for y in range(H) for x in range(W)])
for depth in (1, 2, 4):
    levels = (1 << depth) - 1
    g = lambda x, y, d=depth, lv=levels: ((x + 2 * y) % (lv + 1))
    make_png(f"png_gray{depth}", 0, depth, lambda x, y, g=g: (g(x, y),))
    save_rgba(f"png_gray{depth}", [((g(x, y) * 255) // levels,) * 3 + (255,) for y in range(H) for x in range(W)])
    entries = 1 << depth
    pal = [((i * 53) & 255, (i * 97) & 255, (i * 31 + 40) & 255) for i in range(entries)]
    trns = bytes([(i * 70) & 255 for i in range(entries - 1)])  # last entry stays opaque
    idx = lambda x, y, e=entries: (x * 3 + y) % e
    make_png(f"png_pal{depth}", 3, depth, lambda x, y, idx=idx: (idx(x, y),), plte=b"".join(bytes(p) for p in pal), trns=trns)
    save_rgba(f"png_pal{depth}", [pal[idx(x, y)] + ((trns[idx(x, y)] if idx(x, y) < len(trns) else 255),) for y in range(H) for x in range(W)])
pal8 = [((i * 13) & 255, (i * 7) & 255, 255 - i) for i in range(256)]
make_png("png_pal8_adam7", 3, 8, lambda x, y: ((x * 5 + y * 9) & 255,), interlace=True, plte=b"".join(bytes(p) for p in pal8))
save_rgba("png_pal8_adam7", [pal8[(x * 5 + y * 9) & 255] + (255,) for y in range(H) for x in range(W)])
# tRNS colour key on RGB8
key = at(4, 4)[:3]
make_png("png_rgb8_trns", 2, 8, lambda x, y: at(x, y)[:3], trns=struct.pack(">HHH", *key))
save_rgba("png_rgb8_trns", [(r, g, b, 0 if (r, g, b) == key else 255) for r, g, b, _ in base])

# JPEG via Pillow: smooth content so encoders agree; reference is Pillow's decode.
photo = Image.new("RGB", (W * 3, H * 3))
photo.putdata([((x * 4) & 255, (y * 5) & 255, ((x + y) * 3) & 255) for y in range(H * 3) for x in range(W * 3)])
for name, kwargs, mode in [
    ("jpeg_420", dict(quality=92, subsampling=2), "RGB"),
    ("jpeg_444", dict(quality=92, subsampling=0), "RGB"),
    ("jpeg_422", dict(quality=92, subsampling=1), "RGB"),
    ("jpeg_gray", dict(quality=92), "L"),
    ("jpeg_progressive", dict(quality=90, subsampling=2, progressive=True), "RGB"),
    ("jpeg_restart", dict(quality=90, subsampling=2, restart_marker_blocks=3), "RGB"),
    ("jpeg_progressive_gray", dict(quality=90, progressive=True), "L"),
]:
    img = photo.convert(mode)
    buf = io.BytesIO()
    img.save(buf, "JPEG", **kwargs)
    (out / f"{name}.jpg").write_bytes(buf.getvalue())
    decoded = Image.open(io.BytesIO(buf.getvalue())).convert("RGBA")
    (out / f"{name}.rgba").write_bytes(decoded.tobytes())

# GIF (palette, transparency, interlaced) and BMP (24/32/8-bit).
pimg = Image.new("RGBA", (W, H))
pimg.putdata(base)
pal_img = pimg.convert("RGB").quantize(colors=64)
for name, kwargs in [("gif_basic", {}), ("gif_interlaced", dict(interlace=True))]:
    img = pal_img.copy()
    img.info["transparency"] = 5
    buf = io.BytesIO()
    img.save(buf, "GIF", transparency=5, **kwargs)
    (out / f"{name}.gif").write_bytes(buf.getvalue())
    (out / f"{name}.rgba").write_bytes(Image.open(io.BytesIO(buf.getvalue())).convert("RGBA").tobytes())
for name, img in [("bmp_24", pimg.convert("RGB")), ("bmp_32", pimg), ("bmp_8", pal_img)]:
    buf = io.BytesIO()
    img.save(buf, "BMP")
    (out / f"{name}.bmp").write_bytes(buf.getvalue())
    (out / f"{name}.rgba").write_bytes(Image.open(io.BytesIO(buf.getvalue())).convert("RGBA").tobytes())
print("fixtures in", out)
