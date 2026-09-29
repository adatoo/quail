"""Small SVG charts for the report: lines (throughput by concurrency) and horizontal bars with optional intervals
(accuracies, memory). Hand-written, so the report needs nothing installed; each chart follows the reader's light or
dark appearance through a media query inside it."""

from __future__ import annotations

from html import escape

PALETTE = ["#d9730d", "#2f6fdb", "#2f9e6e", "#9b51e0", "#c93c3c", "#6b7280", "#b8860b"]
# Quail is always the first colour, so it reads the same in every chart.

STYLE = """<style>
  text { font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #1f2328; }
  .muted { fill: #57606a; } .grid { stroke: #d0d7de; stroke-width: 1; } .axis { stroke: #8c959f; }
  .bg { fill: #ffffff; }
  @media (prefers-color-scheme: dark) {
    text { fill: #e6edf3; } .muted { fill: #8d96a0; } .grid { stroke: #30363d; } .axis { stroke: #6e7681; }
    .bg { fill: #0d1117; }
  }
</style>"""


def _nice_max(value: float) -> float:
    if value <= 0:
        return 1.0
    magnitude = 10 ** len(str(int(value))) / 10
    for step in (1, 2, 2.5, 5, 10):
        if value <= step * magnitude:
            return step * magnitude
    return value


def lines(title: str, x_values: list, series: dict[str, list[float | None]], y_label: str,
          width: int = 640, height: int = 320) -> str:
    """One line per series over the shared `x_values` (shown evenly spaced, as categories)."""
    left, right, top, bottom = 56, 150, 36, 44
    plot_w, plot_h = width - left - right, height - top - bottom
    top_value = _nice_max(max((v for s in series.values() for v in s if v is not None), default=1))

    def x(i: int) -> float:
        return left + (plot_w * i / max(1, len(x_values) - 1))

    def y(v: float) -> float:
        return top + plot_h * (1 - v / top_value)

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">', STYLE,
           f'<rect class="bg" width="{width}" height="{height}"/>',
           f'<text x="{left}" y="20" font-weight="600">{escape(title)}</text>']
    for i in range(5):
        value = top_value * i / 4
        out.append(f'<line class="grid" x1="{left}" x2="{left + plot_w}" y1="{y(value):.1f}" y2="{y(value):.1f}"/>')
        out.append(f'<text class="muted" x="{left - 6}" y="{y(value) + 4:.1f}" text-anchor="end">{value:g}</text>')
    for i, label in enumerate(x_values):
        out.append(f'<text class="muted" x="{x(i):.1f}" y="{top + plot_h + 18}" text-anchor="middle">'
                   f'{escape(str(label))}</text>')
    out.append(f'<text class="muted" x="{left}" y="{height - 6}">{escape(y_label)}</text>')
    for index, (name, values) in enumerate(series.items()):
        colour = PALETTE[index % len(PALETTE)]
        points = [(x(i), y(v)) for i, v in enumerate(values) if v is not None]
        if len(points) > 1:
            path = " ".join(f"{'M' if j == 0 else 'L'}{px:.1f},{py:.1f}" for j, (px, py) in enumerate(points))
            out.append(f'<path d="{path}" fill="none" stroke="{colour}" stroke-width="2.5"/>')
        for px, py in points:
            out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="3.5" fill="{colour}"/>')
        legend_y = top + 8 + index * 20
        out.append(f'<rect x="{left + plot_w + 16}" y="{legend_y - 9}" width="12" height="12" rx="2" fill="{colour}"/>')
        out.append(f'<text x="{left + plot_w + 34}" y="{legend_y + 1}">{escape(name)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def bars(title: str, rows: list[tuple[str, float, float | None, float | None]], unit: str, maximum: float | None = None,
         width: int = 640) -> str:
    """Horizontal bars: (label, value, low, high); low/high draw an interval when given."""
    left, right, top, row_h = 150, 70, 36, 26
    height = top + row_h * len(rows) + 28
    plot_w = width - left - right
    top_value = maximum or _nice_max(max((max(v, h or 0) for _, v, _, h in rows), default=1))

    def x(v: float) -> float:
        return left + plot_w * v / top_value

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">', STYLE,
           f'<rect class="bg" width="{width}" height="{height}"/>',
           f'<text x="12" y="20" font-weight="600">{escape(title)}</text>']
    for i in range(5):
        value = top_value * i / 4
        out.append(f'<line class="grid" x1="{x(value):.1f}" x2="{x(value):.1f}" y1="{top - 4}" '
                   f'y2="{top + row_h * len(rows)}"/>')
        out.append(f'<text class="muted" x="{x(value):.1f}" y="{height - 8}" text-anchor="middle">{value:g}</text>')
    for index, (label, value, low, high) in enumerate(rows):
        colour = PALETTE[index % len(PALETTE)]
        mid = top + row_h * index + row_h / 2
        out.append(f'<text x="{left - 8}" y="{mid + 4:.1f}" text-anchor="end">{escape(label)}</text>')
        out.append(f'<rect x="{left}" y="{mid - 8:.1f}" width="{max(0.0, x(value) - left):.1f}" height="16" rx="2" '
                   f'fill="{colour}" opacity="0.85"/>')
        if low is not None and high is not None:
            out.append(f'<line class="axis" x1="{x(low):.1f}" x2="{x(high):.1f}" y1="{mid:.1f}" y2="{mid:.1f}" '
                       f'stroke-width="2"/>')
        out.append(f'<text class="muted" x="{x(max(value, high or 0)) + 6:.1f}" y="{mid + 4:.1f}">'
                   f'{value:.3g}{escape(unit)}</text>')
    out.append("</svg>")
    return "\n".join(out)
