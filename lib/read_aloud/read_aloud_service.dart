import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Listens for text selected via Android's "Process text" menu
/// (ACTION_PROCESS_TEXT) and reads it aloud using the on-device TTS engine.
///
/// This is a narrow, standard Android mechanism — the user must explicitly
/// select text and choose "Read with Nexus" from the popup. No passive
/// monitoring, no accessibility service required.
class ReadAloudService {
  static const _eventChannel =
      EventChannel('com.example.nexus_app/read_aloud');

  static final ReadAloudService instance = ReadAloudService._();
  ReadAloudService._();

  final FlutterTts _tts = FlutterTts();
  StreamSubscription<dynamic>? _subscription;
  bool _ttsReady = false;

  /// Whether TTS is currently speaking.
  final isSpeaking = ValueNotifier<bool>(false);

  /// The text currently being read (or last read).
  String? get currentText => _currentText;
  String? _currentText;

  /// Initialize the stream listener. Call once at app startup.
  void init() {
    if (!Platform.isAndroid) return;
    _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is String && event.isNotEmpty) {
        readAloud(event);
      }
    });
  }

  /// Read [text] aloud. If already speaking, stops first.
  Future<void> readAloud(String text) async {
    await stop();
    if (text.isEmpty) return;

    _currentText = text;
    isSpeaking.value = true;

    try {
      if (!_ttsReady) {
        await _tts.setLanguage('en-US');
        _ttsReady = true;
      }

      _tts.setCompletionHandler(() {
        isSpeaking.value = false;
        _currentText = null;
      });

      await _tts.speak(text);
    } catch (e) {
      debugPrint('[ReadAloud] TTS error: $e');
      isSpeaking.value = false;
      _currentText = null;
    }
  }

  /// Stop any ongoing speech.
  Future<void> stop() async {
    if (isSpeaking.value) {
      await _tts.stop();
      isSpeaking.value = false;
      _currentText = null;
    }
  }

  /// Clean up resources.
  void dispose() {
    _subscription?.cancel();
    _tts.stop();
  }
}
