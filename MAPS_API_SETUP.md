# Google Maps API Setup Guide

## Current Status

✅ API key has been applied to `web/maps_config.js`
❓ API key validation needed

## Steps to Fix InvalidKey Error

### 1. Verify API Key in Google Cloud Console

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Navigate to **APIs & Services > Credentials**
3. Find your API key: `AIzaSyBcY9Z77L3oE3Cuw-2trlyM5N2IuRh7S6k`
4. Click on it to view details

### 2. Check API Restrictions

Make sure these APIs are enabled:

- ✅ **Maps JavaScript API**
- ✅ **Places API** (if using places features)
- ✅ **Geocoding API** (if using geocoding)

### 3. Configure Application Restrictions

In the API key settings:

- **Application restrictions**: Choose "HTTP referrer (web sites)"
- **Website restrictions**: Add these referrers:
  ```
  http://localhost:*/*
  https://localhost:*/*
  https://your-domain.com/*
  https://*.your-domain.com/*
  ```

### 4. Common Fixes

#### Option A: Create a New API Key

If the current key has issues:

1. In Google Cloud Console, create a new API key
2. Enable Maps JavaScript API
3. Set proper restrictions
4. Update `.env` file with new key:
   ```
   GOOGLE_MAPS_API_KEY=your_new_api_key_here
   ```
5. Run: `dart tools/replace_maps_key.dart`

#### Option B: Update Current Key

1. Edit the existing key in Google Cloud Console
2. Remove all restrictions temporarily to test
3. Enable Maps JavaScript API if not enabled
4. Add proper HTTP referrer restrictions

### 5. Test the Fix

After making changes:

1. Clear browser cache
2. Restart your Flutter web app: `flutter run -d chrome`
3. Check browser console for Maps API errors

### 6. For Production

When deploying to production:

1. Add your production domain to HTTP referrer restrictions
2. Consider using a separate production API key
3. Keep development and production keys separate in your `.env` files

## Troubleshooting

- If you still get InvalidKey errors, try removing all restrictions temporarily
- Check billing is enabled in Google Cloud Console
- Verify the project has Maps JavaScript API enabled
- Make sure you're not exceeding API quotas

## Current Configuration

- API Key: `AIzaSyBcY9Z77L3oE3Cuw-2trlyM5N2IuRh7S6k`
- Configuration file: `web/maps_config.js`
- Environment file: `.env`
- Update tool: `tools/replace_maps_key.dart`
