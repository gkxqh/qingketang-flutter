from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parents[1]
MASTER_SIZE = 1024
SCALE = 3


def _s(value: float) -> int:
    return round(value * SCALE)


def _rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_color.lstrip("#")
    return (
        int(value[0:2], 16),
        int(value[2:4], 16),
        int(value[4:6], 16),
        alpha,
    )


def render_master() -> Image.Image:
    canvas_size = MASTER_SIZE * SCALE
    image = Image.new("RGBA", (canvas_size, canvas_size), _rgba("#071A1C"))
    draw = ImageDraw.Draw(image, "RGBA")

    # A soft dawn glow behind the central mark.
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow, "RGBA")
    glow_draw.ellipse(
        (
            _s(145),
            _s(76),
            _s(879),
            _s(810),
        ),
        fill=_rgba("#1D5755", 210),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(_s(95)))
    image.alpha_composite(glow)

    # Faint rain in the upper-left, fading toward the sunrise.
    for offset, alpha in ((0, 74), (82, 56), (164, 38)):
        draw.line(
            (
                _s(138 + offset),
                _s(318),
                _s(250 + offset),
                _s(132),
            ),
            fill=_rgba("#8ED9CF", alpha),
            width=_s(17),
        )

    # Sunrise disk.
    draw.ellipse(
        (_s(414), _s(374), _s(610), _s(570)),
        fill=_rgba("#F3C65B"),
    )
    draw.ellipse(
        (_s(447), _s(405), _s(577), _s(535)),
        fill=_rgba("#FFDA78"),
    )

    cream = _rgba("#F7F3E8")
    shadow = _rgba("#031012", 80)

    # A small offset shadow keeps the monogram legible on busy launchers.
    draw.line(
        [(_s(286), _s(762)), (_s(512), _s(276)), (_s(738), _s(762))],
        fill=shadow,
        width=_s(118),
        joint="curve",
    )
    draw.line(
        [(_s(276), _s(750)), (_s(512), _s(262)), (_s(748), _s(750))],
        fill=cream,
        width=_s(108),
        joint="curve",
    )
    draw.ellipse(
        (_s(452), _s(236), _s(572), _s(356)),
        fill=cream,
    )
    draw.ellipse(
        (_s(222), _s(696), _s(330), _s(804)),
        fill=cream,
    )
    draw.ellipse(
        (_s(694), _s(696), _s(802), _s(804)),
        fill=cream,
    )

    # Crossbar doubles as a horizon line.
    draw.line(
        [(_s(388), _s(596)), (_s(636), _s(596))],
        fill=cream,
        width=_s(86),
    )
    draw.ellipse(
        (_s(345), _s(553), _s(431), _s(639)),
        fill=cream,
    )
    draw.ellipse(
        (_s(593), _s(553), _s(679), _s(639)),
        fill=cream,
    )

    # A small turquoise drop balances the rain-to-sun transition.
    draw.ellipse(
        (_s(731), _s(238), _s(801), _s(308)),
        fill=_rgba("#78CEC4"),
    )
    draw.polygon(
        [
            (_s(766), _s(177)),
            (_s(731), _s(267)),
            (_s(801), _s(267)),
        ],
        fill=_rgba("#78CEC4"),
    )

    return image.resize(
        (MASTER_SIZE, MASTER_SIZE),
        Image.Resampling.LANCZOS,
    )


def save_rgb(source: Image.Image, destination: Path, size: int) -> None:
    resized = source.resize((size, size), Image.Resampling.LANCZOS)
    destination.parent.mkdir(parents=True, exist_ok=True)
    resized.convert("RGB").save(destination, "PNG", optimize=True)


def main() -> None:
    master = render_master()
    branding = ROOT / "assets" / "branding"
    branding.mkdir(parents=True, exist_ok=True)
    master_rgb = master.convert("RGB")
    master_rgb.save(
        branding / "afterrain-icon-1024.png",
        "PNG",
        optimize=True,
    )

    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for directory, size in android_sizes.items():
        save_rgb(
            master,
            ROOT / "android" / "app" / "src" / "main" / "res" / directory
            / "ic_launcher.png",
            size,
        )

    ios_directory = (
        ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for filename, size in ios_sizes.items():
        save_rgb(master, ios_directory / filename, size)


if __name__ == "__main__":
    main()
