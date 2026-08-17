/// Data types for the batch-summarization task, shared by the coordinator
/// (the device that starts the task) and every worker (each participating
/// device, including the coordinator itself).
library;

/// One input file assigned to a worker for summarization. Only the text
/// content is sent — never a raw file path, so a peer can't ask another
/// device to read arbitrary files off its disk.
class TaskItem {
  final String name;
  final String content;

  const TaskItem({required this.name, required this.content});

  Map<String, dynamic> toJson() => {'name': name, 'content': content};

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        name: json['name'] as String,
        content: json['content'] as String,
      );
}

/// One summarized file returned by a worker.
class TaskResult {
  final String name;
  final String summary;

  const TaskResult({required this.name, required this.summary});

  Map<String, dynamic> toJson() => {'name': name, 'summary': summary};

  factory TaskResult.fromJson(Map<String, dynamic> json) => TaskResult(
        name: json['name'] as String,
        summary: json['summary'] as String,
      );
}
