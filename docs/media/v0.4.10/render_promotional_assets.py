from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[3]
MEDIA_DIR = Path(__file__).resolve().parent
BACKGROUND_DIR = MEDIA_DIR / "generated"

OVERVIEW_SCREENSHOT = ROOT / "docs/images/macscope-overview-0.4.10.png"
LANDSCAPE_BACKGROUND = BACKGROUND_DIR / "background-landscape.png"
PORTRAIT_BACKGROUND = BACKGROUND_DIR / "background-portrait.png"

SF_FONT = "/System/Library/Fonts/SFNS.ttf"
PINGFANG_CANDIDATES = list(
    Path("/System/Library/AssetsV2/com_apple_MobileAsset_Font8").glob(
        "*/AssetData/PingFang.ttc"
    )
)
PINGFANG_FONT = str(
    PINGFANG_CANDIDATES[0]
    if PINGFANG_CANDIDATES
    else Path("/System/Library/Fonts/Hiragino Sans GB.ttc")
)

INK = (29, 29, 31, 255)
SECONDARY = (110, 110, 115, 255)


def sf_font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(SF_FONT, size)
    font.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    return font


def pingfang_font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    index = {"regular": 3, "medium": 7, "semibold": 11}[weight]
    return ImageFont.truetype(PINGFANG_FONT, size, index=index)


def cover(image: Image.Image, size: tuple[int, int], vertical_bias: float = 0.5) -> Image.Image:
    target_width, target_height = size
    scale = max(target_width / image.width, target_height / image.height)
    resized = image.resize(
        (round(image.width * scale), round(image.height * scale)),
        Image.Resampling.LANCZOS,
    )
    left = max(0, (resized.width - target_width) // 2)
    available_y = max(0, resized.height - target_height)
    top = round(available_y * vertical_bias)
    return resized.crop((left, top, left + target_width, top + target_height))


def rounded_image(image: Image.Image, radius: int) -> Image.Image:
    layer = image.convert("RGBA")
    mask = Image.new("L", layer.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, layer.width - 1, layer.height - 1),
        radius=radius,
        fill=255,
    )
    layer.putalpha(mask)
    return layer


def paste_with_shadow(
    canvas: Image.Image,
    layer: Image.Image,
    position: tuple[int, int],
    blur: int,
    offset_y: int,
    opacity: int,
) -> None:
    padding = blur * 2
    mask = layer.getchannel("A")
    shadow_mask = Image.new("L", (layer.width + padding * 2, layer.height + padding * 2), 0)
    shadow_mask.paste(mask, (padding, padding))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(blur))
    shadow_mask = shadow_mask.point(lambda value: value * opacity // 255)
    shadow = Image.new("RGBA", shadow_mask.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_mask)
    x, y = position
    canvas.paste(shadow, (x - padding, y - padding + offset_y), shadow)
    canvas.paste(layer, position, layer)


def fit_width(image: Image.Image, width: int) -> Image.Image:
    height = round(image.height * width / image.width)
    return image.resize((width, height), Image.Resampling.LANCZOS)


def draw_landscape() -> Path:
    size = (1920, 1080)
    background = cover(Image.open(LANDSCAPE_BACKGROUND).convert("RGB"), size, 0.05)
    canvas = background.convert("RGBA")
    canvas = Image.blend(canvas, Image.new("RGBA", size, (248, 248, 250, 255)), 0.18)
    draw = ImageDraw.Draw(canvas)

    draw.text((100, 66), "MacScope 0.4.10", font=sf_font(30, 600), fill=INK)
    draw.text((100, 120), "看清你的 Mac。", font=pingfang_font(82, "semibold"), fill=INK)
    draw.text(
        (100, 254),
        "实时监控、硬件状态与系统维护，集中在一个原生应用里。",
        font=pingfang_font(32, "medium"),
        fill=SECONDARY,
    )

    screenshot = Image.open(OVERVIEW_SCREENSHOT).convert("RGBA")
    screenshot = rounded_image(fit_width(screenshot, 1720), 34)
    paste_with_shadow(canvas, screenshot, (100, 390), blur=34, offset_y=18, opacity=82)

    output = MEDIA_DIR / "macscope-0.4.10-landscape-1920x1080.png"
    canvas.convert("RGB").save(output, quality=95, optimize=True)
    return output


def draw_portrait() -> Path:
    size = (1242, 1660)
    background = cover(Image.open(PORTRAIT_BACKGROUND).convert("RGB"), size, 0.18)
    canvas = background.convert("RGBA")
    canvas = Image.blend(canvas, Image.new("RGBA", size, (248, 248, 250, 255)), 0.14)
    draw = ImageDraw.Draw(canvas)

    draw.text((70, 70), "MacScope 0.4.10", font=sf_font(28, 600), fill=INK)
    draw.text((70, 126), "看清你的 Mac。", font=pingfang_font(70, "semibold"), fill=INK)
    draw.multiline_text(
        (70, 242),
        "实时监控、硬件状态与系统维护，\n集中在一个原生应用里。",
        font=pingfang_font(30, "medium"),
        fill=SECONDARY,
        spacing=12,
    )

    screenshot = Image.open(OVERVIEW_SCREENSHOT).convert("RGBA")
    screenshot = rounded_image(fit_width(screenshot, 1102), 28)
    paste_with_shadow(canvas, screenshot, (70, 430), blur=28, offset_y=16, opacity=76)

    feature_y = 1270
    feature_width = 338
    feature_gap = 44
    features = [
        ("实时监控", "CPU、内存与进程"),
        ("硬件状态", "芯片、电池与端口"),
        ("安全维护", "下载、清理与卸载"),
    ]
    for index, (title, detail) in enumerate(features):
        x = 70 + index * (feature_width + feature_gap)
        draw.text((x, feature_y), title, font=pingfang_font(27, "semibold"), fill=INK)
        draw.text(
            (x, feature_y + 48),
            detail,
            font=pingfang_font(21, "regular"),
            fill=SECONDARY,
        )

    draw.text(
        (70, 1575),
        "原生 SwiftUI  ·  macOS 13+",
        font=pingfang_font(20, "medium"),
        fill=(134, 134, 139, 255),
    )

    output = MEDIA_DIR / "macscope-0.4.10-portrait-1242x1660.png"
    canvas.convert("RGB").save(output, quality=95, optimize=True)
    return output


if __name__ == "__main__":
    for path in (draw_landscape(), draw_portrait()):
        print(path)
