from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
IMAGES = ROOT / "images"


def save_variant(source_name, output_stem, max_width=1200, jpeg_quality=82, webp_quality=78):
    source = IMAGES / source_name
    with Image.open(source) as image:
        image = image.convert("RGB")
        if image.width > max_width:
            ratio = max_width / image.width
            size = (max_width, round(image.height * ratio))
            image = image.resize(size, Image.Resampling.LANCZOS)

        jpg_path = IMAGES / f"{output_stem}.jpg"
        webp_path = IMAGES / f"{output_stem}.webp"
        image.save(jpg_path, "JPEG", quality=jpeg_quality, optimize=True, progressive=True)
        image.save(webp_path, "WEBP", quality=webp_quality, method=6)

        print(f"{source_name} -> {jpg_path.name} ({jpg_path.stat().st_size:,} bytes)")
        print(f"{source_name} -> {webp_path.name} ({webp_path.stat().st_size:,} bytes)")


save_variant("church-exterior.jpg", "church-exterior-1200", max_width=1200)
save_variant("sanctuary-service.png", "sanctuary-service-1200", max_width=1200)
