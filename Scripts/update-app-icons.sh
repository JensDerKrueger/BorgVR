#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v magick >/dev/null || { echo "ImageMagick (magick) is required." >&2; exit 1; }

# Approved square crop of the macOS welcome artwork; no generated replacement.
magick macOSApp/mandelbulb-background.jpg -crop 960x960+320+20 +repage \
  -filter Lanczos -resize 1024x1024 -colorspace sRGB -alpha off -depth 8 -strip PNG24:borgvr.png

for size in 16 32 64 128 256 512 1024; do
  magick borgvr.png -filter Lanczos -resize "${size}x${size}" -strip \
    "PNG24:macOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon-${size}.png"
  magick borgvr.png -filter Lanczos -resize "${size}x${size}" -strip \
    "PNG24:macOSServer/Assets.xcassets/AppIcon.appiconset/${size}.png"
done

for size in 40 58 60 80 87 120 152 167 180 1024; do
  magick borgvr.png -filter Lanczos -resize "${size}x${size}" -strip \
    "PNG24:iOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon-${size}.png"
done

cp borgvr.png macOSApp/Assets.xcassets/borgvr.imageset/borgvr.png
cp borgvr.png iOSApp/borgvr.png
cp borgvr.png html/borgvr.png
magick borgvr.png -quality 92 html/borgvr-hero.webp
magick borgvr.png -quality 92 web/assets/borgvr.jpg
for app in VisionApp macOSServer; do
  for size in 200 400 600; do
    magick borgvr.png -filter Lanczos -resize "${size}x${size}" -strip \
      "PNG24:${app}/Assets.xcassets/borgvr.imageset/borgvr${size}.png"
  done
done

# Background removal/inpainting produced these two source images. Keep them
# separate for visionOS parallax, with space around the foreground for its mask.
STACK=VisionApp/Assets.xcassets/AppIcon.solidimagestack
cp Scripts/IconSources/mandelbulb-background.png "$STACK/Back.solidimagestacklayer/Content.imageset/borgvr.png"
magick Scripts/IconSources/mandelbulb-foreground.png -filter Lanczos -resize 860x860 \
  -background none -gravity center -extent 1024x1024 -depth 8 -strip \
  "PNG32:$STACK/Front.solidimagestacklayer/Content.imageset/borgvr.png"
echo "Updated app icons, in-app logos, and website branding."
