# Debug Guide: Image Upload in Edit Tool

## What to Watch For in Console Logs

When you edit a tool and update its image, you'll see comprehensive debugging output. Here's what each section means:

### 1. Image Picker (when selecting image)

```
=== IMAGE PICKER STARTED ===
Image selected: /path/to/image
Image name: photo.jpg
Image size: 123456 bytes (120.56 KB)
Image preview updated in UI
Edit mode: true
Existing tool image URL: https://...
```

### 2. Edit Tool Save Process

```
========== EDIT TOOL MODE ==========
Tool ID: abc123
Tool Name: Squeegee
Current Image URL: https://firebasestorage...
New tool name: Squeegee
New image selected: true
```

### 3. Image Upload to Firebase Storage

```
--- Starting Image Upload Process ---
Image file path: /path/to/image
Image file name: photo.jpg
Image size: 123456 bytes (120.56 KB)
Tool name for storage: Squeegee

====== INVENTORY SERVICE: UPLOAD IMAGE ======
Tool name: Squeegee
Sanitized filename: squeegee.png
Storage path: inventory_tools/squeegee.png
Storage reference created: inventory_tools/squeegee.png

--- Platform: WEB or MOBILE/DESKTOP ---
Reading image bytes...
✓ Image bytes loaded: 123456 bytes (120.56 KB)
Starting upload to Firebase Storage...
Waiting for upload completion...
✓ Upload completed. State: success
Getting download URL...
✓ Download URL obtained: https://firebasestorage.googleapis.com/...
====== UPLOAD SUCCESSFUL ======

--- Upload Complete ---
Upload result: https://firebasestorage.googleapis.com/...
✓ Image uploaded successfully!
New image URL: https://firebasestorage.googleapis.com/...
```

### 4. Old Image Deletion (if different)

```
--- Deleting Old Image ---
Old image URL: https://firebasestorage.../old_image.png
New image URL: https://firebasestorage.../new_image.png
URLs are different: true
✓ Old image deleted from storage
```

### 5. Update All Related Tools

```
--- Updating Image URL for All Related Tools ---
Base tool name: Squeegee
New image URL: https://firebasestorage.../squeegee.png

====== UPDATE IMAGE FOR ALL TOOLS ======
Input tool name: Squeegee
New image URL: https://firebasestorage.../squeegee.png
Base name (without #): Squeegee
Fetching all tools from Firestore...
Total tools in collection: 25
  ✓ Match found: Squeegee #1 (ID: abc123)
  ✓ Match found: Squeegee #2 (ID: def456)
  ✓ Match found: Squeegee #3 (ID: ghi789)

Committing batch update for 3 tools...
✓ Batch committed successfully!
Updated tools: Squeegee #1, Squeegee #2, Squeegee #3
====== UPDATE COMPLETE ======

✓ Image URL updated for all related tools
```

### 6. Final Tool Update

```
--- Updating Tool Record ---
Updated tool data:
  ID: abc123
  Name: Squeegee
  Category: Squeegees
  Image URL: https://firebasestorage.../squeegee.png
  Description: Professional window squeegee
✓ Tool record updated in Firestore

--- Testing Image Access ---
Final image URL: https://firebasestorage.../squeegee.png
Image should be accessible at this URL
You can test by opening this URL in a browser
========== EDIT COMPLETE ==========
```

## Testing the Uploaded Image

After editing a tool:

1. **View the tool details** - Click on the tool card
2. **Check the Debug section** - You'll see the image URL displayed
3. **Click "Test Image URL"** - This will:
   - Print the URL to console logs
   - Show a snackbar with the URL
   - You can copy the URL and paste it in a browser

4. **Verify the image loads** - The image should display in the tool card and details dialog

## Common Issues to Watch For

### Upload Fails

If you see:

```
====== UPLOAD FAILED ======
ERROR: ...
```

Check:

- Firebase Storage permissions
- Network connection
- File size and format

### No Tools Updated

If you see:

```
⚠ No matching tools found for base name: ...
```

Check:

- Tool naming convention
- Database has matching tools

### Image Not Displaying

If upload succeeds but image doesn't show:

- Check the final URL in browser
- Verify Firebase Storage CORS settings
- Check browser console for CORS errors

## Success Indicators

✅ All sections show green checkmarks (✓)
✅ Upload result shows valid HTTPS URL
✅ Batch update shows count > 0
✅ Image displays in UI after dialog closes
✅ Test URL button opens image in browser
