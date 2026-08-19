import 'nexus_brain.dart';

/// How an assistant reply is labelled in the transcript.
enum NexusMessageKind {
  /// A real platform action was performed (or attempted).
  action,

  /// A free-form conversational answer from the local model — nothing done.
  general,
}

/// Chooses the label kind for an assistant reply so the transcript can show
/// whether a request resulted in an action or just a conversational answer.
/// Returns null for messages that need no label (system prompts, errors, and
/// the command-mode "I don't understand" fallback).
NexusMessageKind? messageKindFor(NexusAction action) {
  if (action.isGeneralResponse) return NexusMessageKind.general;
  if (action.command != NexusCommand.unknown) return NexusMessageKind.action;
  return null;
}
