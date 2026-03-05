# Web Icons Setup Guide

## Overview

This guide explains how to generate web app icons and favicon from your `assets/logo.png` file for the CLM Schedule web application.

## Quick Setup Options

### Option 1: Use Online Tools (Easiest)

1. **Go to [favicon.io/favicon-converter](https://favicon.io/favicon-converter/)** or **[realfavicongenerator.net](https://realfavicongenerator.net/)**

2. **Upload** your `assets/logo.png` file

3. **Download** the generated package

4. **Extract** and copy these files to your project:
   - `favicon.png` (32x32) → `web/favicon.png`
   - `icon-192.png` → `web/icons/Icon-192.png`
   - `icon-512.png` → `web/icons/Icon-512.png`

5. For maskable icons, use [maskable.app](https://maskable.app/editor) to add proper padding

### Option 2: Use ImageMagick (Command Line)

If you have ImageMagick installed:

```bash
# Install ImageMagick (if not already)
# macOS: brew install imagemagick
# Ubuntu: sudo apt-get install imagemagick

# Navigate to project root
cd /Users/Bunny/Tools/clmschedule

# Generate favicon (32x32)
convert assets/logo.png -resize 32x32 web/favicon.png

# Generate Icon-192
convert assets/logo.png -resize 192x192 web/icons/Icon-192.png

# Generate Icon-512
convert assets/logo.png -resize 512x512 web/icons/Icon-512.png

# Generate maskable icons (with 20% padding)
convert assets/logo.png -resize 154x154 -background white -gravity center -extent 192x192 web/icons/Icon-maskable-192.png
convert assets/logo.png -resize 410x410 -background white -gravity center -extent 512x512 web/icons/Icon-maskable-512.png
```

### Option 3: Use the Dart Script (Advanced)

If build hooks are working properly:

```bash
dart run tools/generate_web_icons.dart
```

**Note:** If this hangs due to build hooks, you'll need to use Option 1 or 2.

## Files That Need to Be Generated

From your `assets/logo.png`, you need to create:

1. **`web/favicon.png`** (32x32) - Browser tab icon
2. **`web/icons/Icon-192.png`** (192x192) - PWA manifest icon
3. **`web/icons/Icon-512.png`** (512x512) - PWA manifest icon
4. **`web/icons/Icon-maskable-192.png`** (192x192 with padding) - Android adaptive icon
5. **`web/icons/Icon-maskable-512.png`** (512x512 with padding) - Android adaptive icon

## What's Already Configured

✅ **pubspec.yaml** - Logo added to assets  
✅ **web/index.html** - Updated with:

- Proper favicon references
- Apple touch icon setup
- SEO meta tags
- App title: "CLM Schedule"

✅ **web/manifest.json** - Updated with:

- App name: "CLM Schedule"
- Proper description
- Icon references for all sizes
- Theme colors

## After Generating Icons

1. **Verify all files exist:**

   ```bash
   ls -la web/favicon.png
   ls -la web/icons/*.png
   ```

2. **Build your web app:**

   ```bash
   flutter build web
   ```

3. **Test locally:**

   ```bash
   cd build/web
   python3 -m http.server 8000
   # Open http://localhost:8000 in browser
   ```

4. **Check the favicon:** Look at the browser tab - your logo should appear

5. **Test PWA installation:** In Chrome, click the install icon in the address bar

## Troubleshooting

### Favicon not showing

- Clear browser cache (Ctrl+Shift+R or Cmd+Shift+R)
- Make sure `web/favicon.png` exists
- Check browser console for 404 errors

### Icons look stretched

- Make sure your source logo is square (same width and height)
- If not, add padding to make it square first

### Maskable icons show incorrectly on Android

- Ensure 20% padding on all sides (safe zone requirement)
- Test at [maskable.app](https://maskable.app/)

## Recommended Logo Specifications

For best results, your `assets/logo.png` should be:

- **Square** aspect ratio (e.g., 1024x1024)
- **PNG** format with transparency
- **High resolution** (at least 512x512, preferably 1024x1024 or higher)
- **Centered** content with some padding from edges

## Quick Command Reference

```bash
# Generate all icons using ImageMagick
convert assets/logo.png -resize 32x32 web/favicon.png
convert assets/logo.png -resize 192x192 web/icons/Icon-192.png
convert assets/logo.png -resize 512x512 web/icons/Icon-512.png
convert assets/logo.png -resize 154x154 -background white -gravity center -extent 192x192 web/icons/Icon-maskable-192.png
convert assets/logo.png -resize 410x410 -background white -gravity center -extent 512x512 web/icons/Icon-maskable-512.png

# Build web app
flutter build web

# Preview
cd build/web && python3 -m http.server 8000
```

---

**Need Help?** If you encounter issues, check:

1. File permissions on web/ directory
2. Logo file is valid PNG
3. ImageMagick is installed (for Option 2)
4. Browser cache is cleared after updating icons
