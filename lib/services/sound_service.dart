import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Service for playing sound feedback in the app
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _soundEnabled = true;

  /// Enable or disable sound feedback
  void setSoundEnabled(bool enabled) {
    _soundEnabled = enabled;
  }

  /// Play success sound (for successful scans, saves, etc.)
  Future<void> playSuccess() async {
    if (!_soundEnabled) return;

    try {
      // Use system sound as fallback if custom sound not available
      await SystemSound.play(SystemSoundType.click);

      // Try to play custom success sound
      try {
        await _audioPlayer.play(AssetSource('sounds/success.mp3'));
      } catch (e) {
        // Custom sound not available, system sound already played
      }
    } catch (e) {
      // Silently fail if sound cannot be played
    }
  }

  /// Play warning/error sound (for errors, invalid scans, etc.)
  Future<void> playWarning() async {
    if (!_soundEnabled) return;

    try {
      // Use system sound as fallback if custom sound not available
      await SystemSound.play(SystemSoundType.alert);

      // Try to play custom warning sound
      try {
        await _audioPlayer.play(AssetSource('sounds/warning.mp3'));
      } catch (e) {
        // Custom sound not available, system sound already played
      }
    } catch (e) {
      // Silently fail if sound cannot be played
    }
  }

  /// Play notification sound (for general notifications)
  Future<void> playNotification() async {
    if (!_soundEnabled) return;

    try {
      await SystemSound.play(SystemSoundType.click);

      try {
        await _audioPlayer.play(AssetSource('sounds/notification.mp3'));
      } catch (e) {
        // Custom sound not available, system sound already played
      }
    } catch (e) {
      // Silently fail if sound cannot be played
    }
  }

  /// Dispose the audio player
  void dispose() {
    _audioPlayer.dispose();
  }
}
