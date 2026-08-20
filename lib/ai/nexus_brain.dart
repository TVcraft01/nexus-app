/// Commands the local brain can understand and act on.
enum NexusCommand {
  createFolder,
  openWifiSettings,
  setReminder,
  setPreference,
  setAlarm,
  setTimer,
  playDeezerFlow,
  callContact,
  openEmail,
  navigate,
  assistApp,
  unknown,
}

/// The result of interpreting a user's words: a command, any arguments needed
/// to carry it out, and a human-readable reply.
class NexusAction {
  final NexusCommand command;
  final String reply;
  final Map<String, dynamic> args;

  /// True when this is a free-form conversational answer (an LLM "chat"
  /// response) rather than an executed action. The Talk screen uses this to
  /// label replies "General response" vs "Action", so it is never ambiguous
  /// whether something was actually done or only discussed.
  final bool isGeneralResponse;

  const NexusAction({
    required this.command,
    required this.reply,
    this.args = const {},
    this.isGeneralResponse = false,
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
