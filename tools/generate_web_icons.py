#!/usr/bin/env python3
"""
Generate web icons and favicon from assets/logo.png

Requirements:
    pip install Pillow

Usage:
    python3 tools/generate_web_icons.py
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("❌ Error: Pillow is not installed!")
    print("   Please install it with: pip3 install Pillow")
    sys.exit(1)


def generate_icons():
    print("🎨 CLM Schedule - Web Icon Generator")
    print("=" * 50)

    # Paths
    source_path = Path("assets/logo.png")
    web_dir = Path("web")
    icons_dir = Path("web/icons")

    # Validate source file
    if not source_path.exists():
        print("❌ Error: assets/logo.png not found!")
        print("   Please place your logo.png file in the assets/ directory.")
        sys.exit(1)

    # Ensure directories exist
    if not web_dir.exists():
        print("❌ Error: web/ directory not found!")
        sys.exit(1)

    if not icons_dir.exists():
        print("📁 Creating web/icons/ directory...")
        icons_dir.mkdir(parents=True, exist_ok=True)

    try:
        # Open source image
        print(f"📖 Reading logo from {source_path}...")
        img = Image.open(source_path)
        print(f"✅ Logo loaded successfully ({img.size[0]}x{img.size[1]})")
        print()

        # Convert to RGBA if necessary
        if img.mode != "RGBA":
            img = img.convert("RGBA")

        # Generate favicon (32x32)
        print("🖼️  Generating favicon.png (32x32)...")
        favicon = img.resize((32, 32), Image.Resampling.LANCZOS)
        favicon.save("web/favicon.png", "PNG")
        print("   ✅ web/favicon.png created")

        # Generate Icon-192.png
        print("🖼️  Generating Icon-192.png (192x192)...")
        icon_192 = img.resize((192, 192), Image.Resampling.LANCZOS)
        icon_192.save("web/icons/Icon-192.png", "PNG")
        print("   ✅ web/icons/Icon-192.png created")

        # Generate Icon-512.png
        print("🖼️  Generating Icon-512.png (512x512)...")
        icon_512 = img.resize((512, 512), Image.Resampling.LANCZOS)
        icon_512.save("web/icons/Icon-512.png", "PNG")
        print("   ✅ web/icons/Icon-512.png created")

        # Generate maskable icons (with 20% padding)
        print("🖼️  Generating Icon-maskable-192.png (192x192 with padding)...")
        maskable_192 = create_maskable_icon(img, 192)
        maskable_192.save("web/icons/Icon-maskable-192.png", "PNG")
        print("   ✅ web/icons/Icon-maskable-192.png created")

        print("🖼️  Generating Icon-maskable-512.png (512x512 with padding)...")
        maskable_512 = create_maskable_icon(img, 512)
        maskable_512.save("web/icons/Icon-maskable-512.png", "PNG")
        print("   ✅ web/icons/Icon-maskable-512.png created")

        print()
        print("=" * 50)
        print("✨ All icons generated successfully!")
        print()
        print("📝 Next steps:")
        print("   1. Check web/favicon.png and web/icons/*.png")
        print("   2. Run: flutter build web")
        print("   3. Deploy your web app!")

    except Exception as e:
        print(f"❌ Error generating icons: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


def create_maskable_icon(source_img, size):
    """Create a maskable icon with proper padding for safe zone"""
    # Create white background
    background = Image.new("RGBA", (size, size), (255, 255, 255, 255))

    # Calculate padded size (80% of canvas, 20% total padding)
    padded_size = int(size * 0.8)
    offset = (size - padded_size) // 2

    # Resize logo
    resized_logo = source_img.resize((padded_size, padded_size), Image.Resampling.LANCZOS)

    # Paste logo onto background
    background.paste(resized_logo, (offset, offset), resized_logo)

    return background


if __name__ == "__main__":
    generate_icons()
