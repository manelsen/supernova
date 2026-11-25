#!/usr/bin/env python3
"""Compose the frames of an animated sticker and keep a few for the reader.

Usage: sticker_frames.py <input.webp|gif> <out_dir> <max_frames>

WhatsApp animated stickers are animated WebP files that store only what
changes between frames; Gemini sees only the first frame of such a file
(measured on 2026-11-25). Pillow composes each frame whole; this keeps up to
<max_frames> of them, evenly spaced, as PNG (at most 512 px a side), and
prints JSON: {"frames": [...], "count": N, "duration_ms": D}.
(PRD-A, A-10; the same approach as Amélie's.)
"""

import json
import os
import sys

try:
    from PIL import Image, ImageSequence
except ImportError:
    print(json.dumps({"error": "Pillow is not installed"}))
    sys.exit(2)


def main():
    source, out_dir, wanted = sys.argv[1], sys.argv[2], int(sys.argv[3])
    os.makedirs(out_dir, exist_ok=True)
    with Image.open(source) as image:
        frames, duration = [], 0
        for frame in ImageSequence.Iterator(image):
            duration += frame.info.get("duration", 0) or 0
            frames.append(frame.convert("RGBA").copy())
    count = len(frames)
    if count == 0:
        print(json.dumps({"error": "no frames"}))
        sys.exit(1)
    if count <= wanted:
        chosen = list(range(count))
    else:
        chosen = [round(i * (count - 1) / (wanted - 1)) for i in range(wanted)]
    paths = []
    for n, index in enumerate(chosen):
        frame = frames[index]
        frame.thumbnail((512, 512))
        background = Image.new("RGBA", frame.size, (255, 255, 255, 255))
        background.alpha_composite(frame)
        path = os.path.join(out_dir, f"frame_{n:02d}.png")
        background.convert("RGB").save(path, "PNG")
        paths.append(path)
    print(json.dumps({"frames": paths, "count": count, "duration_ms": duration}))


if __name__ == "__main__":
    main()
