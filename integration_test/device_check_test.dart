import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nexus_app/ai/vosk_ffi.dart';
import 'package:nexus_app/ai/vosk_service.dart';

/// On-device verification (test pass only, not a shipped feature):
/// 1. Captures the raw local-LLM output for a command to check the
///    chat-template "system:" quirk.
/// 2. Feeds a synthesized speech WAV through the app's Vosk bindings to verify
///    offline transcription works on real hardware.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LLM raw output for a folder command', (tester) async {
    final support = await getApplicationSupportDirectory();
    final modelFile = File(p.join(support.path, 'models', 'compact.gguf'));
    if (!modelFile.existsSync()) {
      fail('Model not downloaded yet: ${modelFile.path}');
    }
    final client = LlamaOpenAIClient(
      models: {
        'local': LlamaModelConfig(modelPath: modelFile.path, contextSize: 2048),
      },
    );
    final completion = await client.chat.completions.create(
      model: 'local',
      messages: const [
        LlamaChatMessage(
          role: 'system',
          content: 'You are Nexus, a private on-device assistant. '
              'Respond with ONLY one JSON object and nothing else, with this '
              'shape: {"command":"createFolder|openWifiSettings|setReminder|'
              'chat","args":{},"reply":"short reply to the user (max 2 '
              'sentences)". Rules: for createFolder put the folder name in '
              'args.name. For setReminder put an ISO-8601 time in args.when '
              'and the thing to remember in args.message. For anything else '
              'use command "chat" and write your helpful answer in reply.',
        ),
        LlamaChatMessage(
          role: 'user',
          content: 'create a folder named LLMFolder',
        ),
      ],
      maxTokens: 220,
      temperature: 0.2,
    );
    final raw = llamaContentToPlainText(completion.choices.first.message.content);
    // ignore: avoid_print
    print('RAW_LLM_OUTPUT>>>$raw<<<');
    // ignore: avoid_print
    print('LLM_FINISH=${completion.choices.first.finishReason}');

    // Second call with a trivial prompt to isolate the JSON-instruction effect.
    final simple = await client.chat.completions.create(
      model: 'local',
      messages: const [
        LlamaChatMessage(role: 'user', content: 'Say hello in one word.'),
      ],
      maxTokens: 16,
      temperature: 0.2,
    );
    final simpleRaw =
        llamaContentToPlainText(simple.choices.first.message.content);
    // ignore: avoid_print
    print('SIMPLE_LLM_OUTPUT>>>$simpleRaw<<<');
    expect(simpleRaw.trim().isNotEmpty, isTrue,
        reason: 'Expected the model to produce text even for a simple prompt');
  });

  testWidgets('Vosk transcribes a synthesized WAV on-device', (tester) async {
    final ext = await getExternalStorageDirectory();
    final wavFile = File(p.join(
      ext?.path ?? '',
      'test.wav',
    ));
    if (!wavFile.existsSync()) {
      fail('WAV not found: ${wavFile.path}');
    }
    final bytes = await wavFile.readAsBytes();

    // Strip the 44-byte WAV header; Vosk wants raw PCM16 mono.
    final pcm = bytes.sublist(44);
    // ignore: avoid_print
    print('VOSK_PCM_BYTES=${pcm.length}');

    final service = VoskService();
    final ok = await service.ensureModel();
    // ignore: avoid_print
    print('VOSK_MODEL_READY=$ok');
    expect(ok, isTrue);

    // Load via the app's own FFI bindings.
    final modelDir = p.join((await getApplicationSupportDirectory()).path,
        'vosk', 'vosk-model-small-en-us-0.15');
    final model = voskModelNew(modelDir);
    expect(model, isNotNull);
    final rec = voskRecognizerNew(model!, 16000.0);
    if (rec == null) {
      fail('Could not create Vosk recognizer');
    }

    final buffer = StringBuffer();
    const chunkSize = 8000;
    for (var i = 0; i < pcm.length; i += chunkSize) {
      final end = (i + chunkSize) < pcm.length ? i + chunkSize : pcm.length;
      final chunk = pcm.sublist(i, end);
      final accepted = voskAcceptWaveform(rec, chunk);
      if (accepted == 1) {
        buffer.write(_textFromJson(voskResult(rec)));
      }
    }
    final finalText = _textFromJson(voskFinal(rec));
    voskRecognizerFree(rec);
    voskModelFree(model);
    // ignore: avoid_print
    print('VOSK_TRANSCRIPT>>>$finalText<<<');
    // ignore: avoid_print
    print('VOSK_PARTIALS>>>$buffer<<<');
    expect(finalText.trim().isNotEmpty, isTrue,
        reason: 'Expected Vosk to transcribe the spoken WAV');
  });
}

String _textFromJson(String json) {
  try {
    final start = json.indexOf('"text"');
    if (start < 0) return '';
    final colon = json.indexOf(':', start);
    final vStart = json.indexOf('"', colon + 1);
    final vEnd = json.indexOf('"', vStart + 1);
    return json.substring(vStart + 1, vEnd);
  } catch (_) {
    return '';
  }
}
