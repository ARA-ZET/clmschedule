#!/usr/bin/env python3
"""
Generate app icons and splash screens for Happy Sun flavor

Requirements:
    pip install Pillow

Usage:
    python3 tools/generate_happysun_assets.py
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("❌ Error: Pillow is not installed!")
    print("   Please install it with: pip3 install Pillow")
    sys.exit(1)


def generate_happysun_assets():
    print("☀️  Happy Sun - Asset Generator")
    print("=" * 50)

    # Paths
    source_path = Path("assets/logo.png")

    # Validate source file
    if not source_path.exists():
        print("❌ Error: assets/logo.png not found!")
        print("   Please place your logo.png file in the assets/ directory.")
        sys.exit(1)

    try:
        # Open source image
        print(f"📖 Reading logo from {source_path}...")
        logo = Image.open(source_path)
        print(f"✅ Logo loaded successfully ({logo.size[0]}x{logo.size[1]})")
        print()

        # Convert to RGBA if necessary
        if logo.mode != "RGBA":
            logo = logo.convert("RGBA")

        # Generate Android app icons for Happy Sun flavor
        generate_android_app_icons(logo)
        
        # Generate Android splash screens for Happy Sun flavor
        generate_android_splash_screens(logo)
        
        # Generate iOS assets for Happy Sun
        generate_ios_assets(logo)

        print()
        print("=" * 50)
        print("✨ All Happy Sun assets generated successfully!")
        print()
        print("📝 Assets created in:")
        print("   - android/app/src/happysun/res/ (app icons & splash)")
        print("   - ios/Runner/Assets.xcassets/ (already updated)")
        print()
        print("🚀 Next steps:")
        print("   1. Run: flutter clean")
        print("   2. Build Happy Sun flavor:")
        print("      flutter build apk --flavor happysun")
        print("      flutter build ios --flavor happysun")

    except Exception as e:
        print(f"❌ Error generating assets: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


def generate_android_app_icons(logo):
    """Generate Android app icons (ic_launcher) for Happy Sun flavor"""
    print("🤖 Generating Android app icons for Happy Sun...")
    
    # Android mipmap densities and icon sizes (standard launcher icons)
    densities = [
        ("mipmap-mdpi", 48),       # ~1x
        ("mipmap-hdpi", 72),       # ~1.5x
        ("mipmap-xhdpi", 96),      # ~2x
        ("mipmap-xxhdpi", 144),    # ~3x
        ("mipmap-xxxhdpi", 192),   # ~4x
    ]
    
    for density, size in densities:
        print(f"   Generating {density}/ic_launcher.png ({size}x{size})...")
        
        # Create directory if it doesn't exist
        icon_dir = Path(f"android/app/src/happysun/res/{density}")
        icon_dir.mkdir(parents=True, exist_ok=True)
        
        # Resize logo to app icon size
        icon = logo.resize((size, size), Image.Resampling.LANCZOS)
        
        # Save
        output_path = icon_dir / "ic_launcher.png"
        icon.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    print()


def generate_android_splash_screens(logo):
    """Generate Android splash screens for Happy Sun flavor"""
    print("🤖 Generating Android splash screens for Happy Sun...")
    
    # Android mipmap densities and logo sizes for splash
    densities = [
        ("mipmap-mdpi", 150),      # ~1x
        ("mipmap-hdpi", 225),      # ~1.5x
        ("mipmap-xhdpi", 300),     # ~2x
        ("mipmap-xxhdpi", 450),    # ~3x
        ("mipmap-xxxhdpi", 600),   # ~4x
    ]
    
    for density, logo_size in densities:
        print(f"   Generating {density}/launch_image.png (logo: {logo_size}x{logo_size})...")
        
        # Create directory if it doesn't exist
        splash_dir = Path(f"android/app/src/happysun/res/{density}")
        splash_dir.mkdir(parents=True, exist_ok=True)
        
        # Resize logo
        resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
        
        # Save
        output_path = splash_dir / "launch_image.png"
        resized_logo.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    # Create Happy Sun specific launch_background.xml
    create_happysun_launch_background()
    
    print()


def create_happysun_launch_background():
    """Create Happy Sun specific launch_background.xml with themed background"""
    print("   Creating Happy Sun launch_background.xml files...")
    
    # Happy Sun uses an orange/yellow theme
    launch_background_content = """<?xml version="1.0" encoding="utf-8"?>
<!-- Happy Sun flavor splash screen -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Orange gradient background for Happy Sun -->
    <item>
        <shape>
            <gradient
                android:angle="135"
                android:startColor="#FF9800"
                android:endColor="#FFB74D"
                android:type="linear" />
        </shape>
    </item>

    <!-- Centered logo -->
    <item>
        <bitmap
            android:gravity="center"
            android:src="@mipmap/launch_image" />
    </item>
</layer-list>
"""
    
    # Create both drawable and drawable-v21 for Happy Sun flavor
    for drawable_dir in ["drawable", "drawable-v21"]:
        xml_path = Path(f"android/app/src/happysun/res/{drawable_dir}/launch_background.xml")
        xml_path.parent.mkdir(parents=True, exist_ok=True)
        xml_path.write_text(launch_background_content)
        print(f"      ✅ {xml_path}")


def generate_ios_assets(logo):
    """iOS assets are already in the main bundle and shared across flavors"""
    print("📱 iOS assets already configured (shared across flavors)")
    print("   Note: iOS uses the same Assets.xcassets for all flavors")
    print()


if __name__ == "__main__":
    generate_happysun_assets()
