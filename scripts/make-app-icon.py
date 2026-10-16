#!/usr/bin/env python3
"""Regenerate Pict's macOS app icon sizes from the checked-in artwork.

    python3 scripts/make-app-icon.py

The ivory Pictish beast on violet was created with OpenAI's image generator.
The master and generation prompts live in artwork/. Keep the master outside the
app's synchronized source group so it is not bundled alongside the icon catalog.

Requires macOS's built-in sips tool, with no third-party dependencies. The asset
catalog defines the sizes; its metadata and the app's accent color stay intact.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    source = root / "artwork" / "pict-icon.png"
    iconset = root / "App" / "Pict" / "Assets.xcassets" / "AppIcon.appiconset"
    sips = shutil.which("sips")
    if sips is None:
        raise SystemExit("Regenerating app icons requires macOS's sips tool.")
    if not source.is_file():
        raise SystemExit(f"Missing app icon artwork: {source}")

    catalog = json.loads((iconset / "Contents.json").read_text())
    # Resize each distinct pixel size once so equivalent 1x/2x slots are exact
    # copies. Preserve the generated alpha, including the transparent corners.
    with tempfile.TemporaryDirectory(prefix="pict-app-icon-") as temporary:
        resized = {}
        for entry in catalog["images"]:
            nominal = int(entry["size"].split("x")[0])
            scale = int(entry["scale"].removesuffix("x"))
            pixels = nominal * scale
            if pixels not in resized:
                output = Path(temporary) / f"{pixels}.png"
                subprocess.run(
                    [sips, "--resampleHeightWidth", str(pixels), str(pixels),
                     str(source), "--out", str(output)],
                    check=True, stdout=subprocess.DEVNULL,
                )
                resized[pixels] = output
            shutil.copyfile(resized[pixels], iconset / entry["filename"])
            print(f"  {entry['filename']} ({pixels}px)")


if __name__ == "__main__":
    main()
