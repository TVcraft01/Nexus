#!/usr/bin/env python3
"""Generate a simple Nexus desktop icon."""

from __future__ import annotations

import os
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover - build helper, not part of tests
    raise SystemExit(
        "Pillow is required to generate the icon.\n"
        "Run: source venv/bin/activate && pip install -r requirements.txt"
    ) from exc


def generate_icon(size: int = 256) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    bg_color = (30, 30, 35, 255)
    outline_color = (70, 130, 255, 255)
    accent_color = (70, 130, 255, 255)
    corner_radius = size // 8

    # Dark rounded-square background
    draw.rounded_rectangle(
        (4, 4, size - 4, size - 4),
        radius=corner_radius,
        fill=bg_color,
        outline=outline_color,
        width=max(3, size // 64),
    )

    # Draw a stylised "N" in the centre.
    thickness = max(8, size // 16)
    margin = size // 6
    x1 = margin
    x2 = size - margin
    y1 = margin
    y2 = size - margin

    def draw_line(points: list[tuple[int, int]]) -> None:
        for i in range(len(points) - 1):
            draw.line([points[i], points[i + 1]], fill=accent_color, width=thickness)

    # Left vertical, diagonal, right vertical.
    draw_line([(x1, y1), (x1, y2)])
    draw_line([(x1, y1), (x2, y2)])
    draw_line([(x2, y1), (x2, y2)])

    return image


def main() -> None:
    project_root = Path(__file__).resolve().parent
    assets_dir = project_root / "assets"
    assets_dir.mkdir(exist_ok=True)
    icon_path = assets_dir / "nexus-icon.png"

    icon = generate_icon(256)
    icon.save(icon_path, "PNG")
    print(f"Icon saved to {icon_path}")


if __name__ == "__main__":
    main()
