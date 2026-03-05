# Sound Assets

This directory contains sound files for app feedback:

## Required Sound Files

1. **success.mp3** - Played on successful actions (tool scan success, save success, etc.)
   - Recommended: Short pleasant beep or chime (0.2-0.5 seconds)
   - Suggested sources:
     - https://freesound.org/ (search for "success beep")
     - https://mixkit.co/free-sound-effects/success/

2. **warning.mp3** - Played on warnings/errors (tool in use, already scanned, etc.)
   - Recommended: Short alert or error beep (0.2-0.5 seconds)
   - Suggested sources:
     - https://freesound.org/ (search for "error beep")
     - https://mixkit.co/free-sound-effects/error/

3. **notification.mp3** - Played on general notifications
   - Recommended: Neutral notification sound (0.2-0.5 seconds)
   - Suggested sources:
     - https://freesound.org/ (search for "notification")
     - https://mixkit.co/free-sound-effects/notification/

## Notes

- All sounds should be in MP3 format
- Keep sounds short (under 1 second) for better UX
- Sounds will fall back to system sounds if files are not present
- Make sure sounds are not too loud or jarring
- Test sounds on actual devices as they may sound different than on desktop

## Current Status

The SoundService will gracefully fall back to system sounds (SystemSoundType.click and SystemSoundType.alert) if these MP3 files are not present. You can add custom sounds by placing MP3 files with the names above in this directory.
