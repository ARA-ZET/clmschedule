# Shareable Maps - Quick Start Guide

## How to Access

1. **Launch the app** (CLM or HappySun flavor)
2. **Look for the map icon (📍)** in the main app bar at the top
3. **Tap the icon** - a new ShareableMap is created automatically
4. **Start drawing!**

## Quick Actions

### Drawing on the Map

1. **Open the drawing toolbar** (right side of screen)
2. **Select a mode**:
   - 🔷 **Polygon** - Tap to add corners, finish to close the shape
   - 📏 **Polyline** - Tap to add points for a line or path
   - 📍 **Point** - Single tap to place a marker
3. **Finish drawing** - Click the checkmark button
4. **Cancel drawing** - Click the X button

### Managing Layers

1. **Open the layers sidebar** (left side of screen)
2. **Create a new layer**:
   - Tap "Create Layer"
   - Choose a name and color
3. **Toggle visibility** - Tap the eye icon
4. **Reorder layers** - Drag layers up/down to change z-order
5. **Edit/Delete** - Use the pencil/trash icons

### Import Data

1. **Open the menu** (three dots, top right)
2. **Select "Import"**
3. **Choose your method**:
   - **From File**: Pick a .kml, .kmz, or .gpx file
   - **From Google My Maps**: Paste the URL
4. **Preview and confirm** - See what will be imported
5. **Done!** - New layers are added to your map

### Export Your Map

1. **Open the menu** (three dots, top right)
2. **Select "Export"**
3. **Choose layers** - Select which layers to include
4. **Export as KML** - Download the file
5. **Share with clients!**

## Tips & Tricks

### Drawing Tips

- **Polygon**: Automatically closes when you tap "Finish" (minimum 3 points)
- **Polyline**: Shows real-time distance as you draw
- **Point**: Choose from 10 different icon types in layer settings

### Layer Organization

- **Color-code your layers** for easy identification
- **Drag to reorder** - Top layers render on top
- **Hide/show layers** without deleting them

### Import Shortcuts

- **Google My Maps**: Just copy the browser URL and paste
- **Multiple formats**: Supports KML, KMZ (zipped), and GPX
- **Auto-layer creation**: Each import creates a new layer

### Map Statistics

- **View map info**: Tap "Map Info" button in toolbar
- **See counts**: Total polygons, polylines, and points
- **Check bounds**: Geographic extent of all elements

## Keyboard Shortcuts

_Coming in Phase 2_

- Undo/Redo with Ctrl+Z / Ctrl+Shift+Z
- Delete selected with Delete/Backspace key
- Pan map with arrow keys

## What's Next?

Phase 1 is **complete** - you can create, edit, import, and export maps locally.

**Phase 2** (coming soon):

- Save maps to Firebase
- Multiple maps management
- Share maps with public links
- Real-time collaboration
- Offline support

## Need Help?

### Common Questions

**Q: Where are my maps saved?**  
A: Phase 1 maps are temporary - they reset when you restart the app. Phase 2 will add Firebase persistence.

**Q: Can I create multiple maps?**  
A: Not yet - Phase 1 supports one map at a time. Creating a new map replaces the current one.

**Q: How do I share with clients?**  
A: Export to KML and send the file via email or cloud storage. Phase 2 will add shareable web links.

**Q: Can multiple people edit at once?**  
A: Not yet - Phase 2 will add real-time collaboration features.

**Q: What if I lose internet connection?**  
A: Phase 1 works entirely offline (no cloud needed). Phase 2 will add offline sync.

### Known Limitations

- Only one map at a time
- No persistence (resets on app restart)
- No undo/redo for drawing (coming Phase 2)
- Web export shows in console only (actual download coming soon)

### File an Issue

If you find bugs or have feature requests, check:

- `SHAREABLE_MAPS_PHASE_1_COMPLETE.md` - Full feature list
- `SHAREABLE_MAPS_GUIDE.md` - Technical documentation
- Project GitHub issues

---

**Ready to map!** 🗺️
