#!/usr/bin/env python3
"""
Generate splash screen images from assets/logo.png for Android and iOS

Requirements:
    pip install Pillow

Usage:
    python3 tools/generate_splash_screens.py
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


def generate_splash_screens():
    print("🎨 CLM Schedule - Splash Screen Generator")
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

        # Generate iOS splash screens
        generate_ios_splash_screens(logo)
        
        # Generate Android splash screens
        generate_android_splash_screens(logo)

        print()
        print("=" * 50)
        print("✨ All splash screens generated successfully!")
        print()
        print("📝 Configuration files have been updated:")
        print("   - Android: drawable/launch_background.xml")
        print("   - iOS: LaunchImage.imageset (1x, 2x, 3x)")
        print()
        print("🚀 Next steps:")
        print("   1. Run: flutter clean")
        print("   2. Run: flutter pub get")
        print("   3. Build and test your app!")

    except Exception as e:
        print(f"❌ Error generating splash screens: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


def generate_ios_splash_screens(logo):
    """Generate iOS LaunchImages at different scales"""
    print("📱 Generating iOS splash screens...")
    
    ios_dir = Path("ios/Runner/Assets.xcassets/LaunchImage.imageset")
    ios_dir.mkdir(parents=True, exist_ok=True)
    
    # iOS LaunchImage sizes (centered logo on white background)
    # Using reasonable logo sizes that look good on splash screens
    sizes = [
        ("LaunchImage.png", 200),      # 1x
        ("LaunchImage@2x.png", 400),   # 2x
        ("LaunchImage@3x.png", 600),   # 3x
    ]
    
    for filename, logo_size in sizes:
        print(f"   Generating {filename} (logo size: {logo_size}x{logo_size})...")
        
        # Create white background (we'll use a reasonable canvas size)
        # iOS will scale this appropriately
        canvas_size = logo_size + 100  # Add some padding
        splash = Image.new("RGB", (canvas_size, canvas_size), (255, 255, 255))
        
        # Resize and center logo
        resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
        
        # Calculate position to center the logo
        offset = ((canvas_size - logo_size) // 2, (canvas_size - logo_size) // 2)
        
        # Paste logo onto splash (handle transparency)
        splash.paste(resized_logo, offset, resized_logo if logo.mode == "RGBA" else None)
        
        # Save
        output_path = ios_dir / filename
        splash.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    print()


def generate_android_splash_screens(logo):
    """Generate Android launch images for different densities"""
    print("🤖 Generating Android splash screens...")
    
    # Android mipmap densities and logo sizes
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
        density_dir = Path(f"android/app/src/main/res/{density}")
        density_dir.mkdir(parents=True, exist_ok=True)
        
        # Resize logo
        resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
        
        # Save
        output_path = density_dir / "launch_image.png"
        resized_logo.save(output_path, "PNG")
        print(f"      ✅ {output_path}")
    
    # Update launch_background.xml files
    update_android_launch_background()
    
    print()


def update_android_launch_background():
    """Update Android launch_background.xml to use the splash image"""
    print("   Updating launch_background.xml files...")
    
    launch_background_content = """<?xml version="1.0" encoding="utf-8"?>
<!-- Modify this file to customize your launch splash screen -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- White background -->
    <item android:drawable="@android:color/white" />

    <!-- Centered logo -->
    <item>
        <bitmap
            android:gravity="center"
            android:src="@mipmap/launch_image" />
    </item>
</layer-list>
"""
    
    # Update both drawable and drawable-v21
    for drawable_dir in ["drawable", "drawable-v21"]:
        xml_path = Path(f"android/app/src/main/res/{drawable_dir}/launch_background.xml")
        xml_path.parent.mkdir(parents=True, exist_ok=True)
        xml_path.write_text(launch_background_content)
        print(f"      ✅ {xml_path}")


if __name__ == "__main__":
    generate_splash_screens()
