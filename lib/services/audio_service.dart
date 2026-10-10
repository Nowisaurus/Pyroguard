import 'package:audioplayers/audioplayers.dart';

class AudioService {
  static final AudioPlayer _player = AudioPlayer();

  /// Play warning beep (smoke threshold crossed)
  static Future<void> playWarning() async {
    await _player.stop();
    await _player.play(AssetSource('sounds/warning_beep.wav'));
  }

  /// Play full fire alarm (emergency)
  static Future<void> playFireAlarm() async {
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.loop); // loop until stopped
    await _player.play(AssetSource('sounds/fire_alarm.wav'));
  }

  /// Play all-clear / safe tone
  static Future<void> playSafe() async {
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.release);
    await _player.play(AssetSource('sounds/safe_tone.wav'));
  }

  /// Stop all sounds
  static Future<void> stop() async {
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.release);
  }
}