#!/usr/bin/env python3
"""
Generate app icons and splash screens for CLM flavor

Requirements:
    pip install Pillow

Usage:
    python3 tools/generate_clm_assets.py
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


def generate_clm_assets():
    print("📅 CLM Schedule - Asset Generator")
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

        # Generate Android app icons for CLM flavor
        generate_android_app_icons(logo)
        
        # Generate Android splash screens for CLM flavor
        generate_android_splash_screens(logo)

        print()
        print("=" * 50)
        print("✨ All CLM assets generated successfully!")
        print()
        print("📝 Assets created in:")
        print("   - android/app/src/clm/res/ (app icons & splash)")
        print()
        print("🚀 Next steps:")
        print("   1. Run: flutter clean")
        print("   2. Build CLM flavor:")
        print("      flutter build apk --flavor clm")

    except Exception as e:
        print(f"❌ Error generating assets: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


def generate_android_app_icons(logo):
    """Generate Android app icons (ic_launcher) for CLM flavor"""
    print("🤖 Generating Android app icons for CLM...")
    
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
        icon_dir = Path(f"android/app/src/clm/res/{density}")
        icon_dir.mkdir(parents=True, exist_ok=True)
        
        # Resize logo to app icon size
        icon = logo.resize((size, size), Image.Resampling.LANCZOS)
        
        # Save
        output_path = icon_dir / "ic_launcher.png"
        icon.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    print()


def generate_android_splash_screens(logo):
    """Generate Android splash screens for CLM flavor"""
    print("🤖 Generating Android splash screens for CLM...")
    
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
        splash_dir = Path(f"android/app/src/clm/res/{density}")
        splash_dir.mkdir(parents=True, exist_ok=True)
        
        # Resize logo
        resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
        
        # Save
        output_path = splash_dir / "launch_image.png"
        resized_logo.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    # Create CLM specific launch_background.xml
    create_clm_launch_background()
    
    print()


def create_clm_launch_background():
    """Create CLM specific launch_background.xml with themed background"""
    print("   Creating CLM launch_background.xml files...")
    
    # CLM uses a blue theme
    launch_background_content = """<?xml version="1.0" encoding="utf-8"?>
<!-- CLM Schedule flavor splash screen -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Blue gradient background for CLM -->
    <item>
        <shape>
            <gradient
                android:angle="135"
                android:startColor="#0175C2"
                android:endColor="#0a9fdb"
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
    
    # Create both drawable and drawable-v21 for CLM flavor
    for drawable_dir in ["drawable", "drawable-v21"]:
        xml_path = Path(f"android/app/src/clm/res/{drawable_dir}/launch_background.xml")
        xml_path.parent.mkdir(parents=True, exist_ok=True)
        xml_path.write_text(launch_background_content)
        print(f"      ✅ {xml_path}")


if __name__ == "__main__":
    generate_clm_assets()
