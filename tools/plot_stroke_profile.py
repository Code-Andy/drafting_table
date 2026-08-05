"""Cross-section of a long straight stroke vs the brush hardness setting.

Models the actual renderer: dabs at kSpacing = 0.18 * radius along the path,
the same per-dab radial profile as kDabFS in renderer.cpp. Brush alpha is
fixed at 1.0 so the curves isolate the effect of `hard`.

Plots both modes:
  - "stacking" — OVER blend per dab (1 - prod(1 - contrib_i)). The default.
  - "uniform"  — MAX of dab contributions (no buildup within a stroke).

The X axis is position across the stroke in dab-radius units, picked at a
pixel directly under a dab center (so the cross-section is at its widest).
"""
import numpy as np
import matplotlib.pyplot as plt


def dab_profile(r, hardness):
    """Matches kDabFS in renderer.cpp.
    r: distance from dab center, in dab-radius units (0 = center, 1 = edge).
    hardness: in [0, 1].
    """
    a = np.zeros_like(r)
    inside = r < 1.0
    if hardness >= 1.0:
        a[inside] = 1.0
        return a
    core = inside & (r <= hardness)
    rim  = inside & (r > hardness)
    a[core] = 1.0
    t = (1.0 - r[rim]) / (1.0 - hardness)
    a[rim] = t**4
    return a


def stroke_cross_section(y_vals, hardness, mode="stacking",
                         brush_alpha=1.0, spacing=0.18, n_dabs=40):
    """Cross-section of a horizontal stroke at perpendicular position y.

    Pixel at (px=0, y), dabs at x_i = i*spacing for i in [-n_dabs, n_dabs].
    Per-dab contribution = brush_alpha * dab_profile(sqrt(x_i^2 + y^2)).
    Mode determines how contributions combine:
      stacking: 1 - prod(1 - contrib_i)  (OVER blend, the default)
      uniform:  max(contrib_i)           (MAX blend, no buildup)
    """
    if mode == "stacking":
        log_one_minus = np.zeros_like(y_vals)
        for i in range(-n_dabs, n_dabs + 1):
            x_off = i * spacing
            r = np.sqrt(x_off**2 + y_vals**2)
            contrib = brush_alpha * dab_profile(r, hardness)
            log_one_minus += np.log(1.0 - contrib + 1e-12)
        return 1.0 - np.exp(log_one_minus)
    elif mode == "uniform":
        best = np.zeros_like(y_vals)
        for i in range(-n_dabs, n_dabs + 1):
            x_off = i * spacing
            r = np.sqrt(x_off**2 + y_vals**2)
            best = np.maximum(best, brush_alpha * dab_profile(r, hardness))
        return best
    else:
        raise ValueError(f"unknown mode: {mode}")


def plot_one(mode, out_path):
    y = np.linspace(-1.5, 1.5, 600)
    hardness_values = [0.0, 0.25, 0.5, 0.75, 1.0]

    fig, ax = plt.subplots(figsize=(9, 5.5))
    colors = plt.cm.viridis(np.linspace(0.15, 0.85, len(hardness_values)))
    for h, c in zip(hardness_values, colors):
        profile = stroke_cross_section(y, hardness=h, mode=mode)
        ax.plot(y, profile, label=f"hard = {h:.2f}", color=c, linewidth=2)

    ax.set_xlabel("Position across stroke (dab-radius units)")
    ax.set_ylabel("Stroke alpha")
    title_suffix = "uniform α, brush α = 1.0" if mode == "uniform" \
                   else "brush α = 1.0"
    ax.set_title(f"Stroke cross-section vs hardness ({title_suffix})")
    ax.set_xlim(-1.5, 1.5)
    ax.set_ylim(-0.02, 1.05)
    ax.grid(True, alpha=0.3)
    ax.axvline(-1.0, color="0.7", linewidth=0.8, linestyle="--")
    ax.axvline( 1.0, color="0.7", linewidth=0.8, linestyle="--")
    ax.legend(loc="upper right", framealpha=0.95)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"wrote {out_path}")


def main():
    plot_one("stacking", "tools/stroke_profile_stacking.png")
    plot_one("uniform",  "tools/stroke_profile_uniform.png")


if __name__ == "__main__":
    main()
