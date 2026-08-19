import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/llm_brain.dart';
import 'package:nexus_app/ai/message_kind.dart';
import 'package:nexus_app/ai/nexus_brain.dart';

void main() {
  // parseAction is pure — constructing LlmBrain doesn't load a model.
  final brain = LlmBrain(modelPath: 'unused', contextSize: 1);

  group('LlmBrain.parseAction general-response flag', () {
    test('a "chat" command is a general response, not an action', () {
      final a = brain.parseAction(
        '{"command":"chat","reply":"The capital of France is Paris."}',
      );
      expect(a, isNotNull);
      expect(a!.command, NexusCommand.unknown);
      expect(a.isGeneralResponse, isTrue);
      expect(a.reply, 'The capital of France is Paris.');
    });

    test('a real action is not a general response', () {
      final a = brain.parseAction(
        '{"command":"navigate","args":{"destination":"work"},'
        '"reply":"Opening navigation…"}',
      );
      expect(a, isNotNull);
      expect(a!.command, NexusCommand.navigate);
      expect(a.args['destination'], 'work');
      expect(a.isGeneralResponse, isFalse);
    });
  });

  group('messageKindFor', () {
    test('labels a general response as general', () {
      expect(
        messageKindFor(const NexusAction(
          command: NexusCommand.unknown,
          reply: 'answer',
          isGeneralResponse: true,
        )),
        NexusMessageKind.general,
      );
    });

    test('labels a real action as action', () {
      expect(
        messageKindFor(const NexusAction(
          command: NexusCommand.openEmail,
          reply: 'opening',
        )),
        NexusMessageKind.action,
      );
    });

    test('leaves system/unknown messages unlabelled', () {
      expect(
        messageKindFor(const NexusAction(
          command: NexusCommand.unknown,
          reply: "I don't understand",
        )),
        isNull,
      );
    });
  });
}
