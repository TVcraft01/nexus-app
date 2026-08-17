/// Commands the local brain can understand and act on.
enum NexusCommand { createFolder, openWifiSettings, setReminder, unknown }

/// The result of interpreting a user's words: a command, any arguments needed
/// to carry it out, and a human-readable reply.
class NexusAction {
  final NexusCommand command;
  final String reply;
  final Map<String, dynamic> args;

  const NexusAction({
    required this.command,
    required this.reply,
    this.args = const {},
  });
}

/// The single seam through which Nexus decides what a user's words mean.
///
/// Today this is a small, fully-offline keyword parser ([KeywordBrain]) that
/// guarantees a minimum intelligence level on any hardware. Later, a real
/// on-device LLM (e.g. a small model via llama.cpp) can implement this same
/// interface and be swapped in without touching the UI or the action runner.
abstract class NexusBrain {
  Future<NexusAction> interpret(String input);
}
