import 'dart:math';
import 'package:flutter/material.dart';

import 'brain_store.dart';

/// A node in the knowledge graph, with a position that gets nudged by
/// the force simulation.
class _GraphNode {
  final BrainNote note;
  Offset position;
  Offset velocity = Offset.zero;
  double radius;

  _GraphNode({required this.note, required this.position})
      : radius = 12 + min(note.content.length / 200, 12);
}

/// Draws the knowledge graph: notes as circles, [[links]] as lines.
/// Runs a simple force-directed layout on every paint (enough for <100 notes;
/// no separate animation loop needed — the framework repaints on gesture).
class GraphPainter extends CustomPainter {
  final List<BrainNote> notes;
  final Map<String, BrainNote> _byTitle;
  final Set<String> _linkedNoteIds;

  List<_GraphNode> _nodes = [];
  final Random _rng = Random(42);

  GraphPainter({required this.notes})
      : _byTitle = {for (final n in notes) n.title.toLowerCase(): n},
        _linkedNoteIds = _linkedIds(notes);

  static Set<String> _linkedIds(List<BrainNote> notes) {
    final ids = <String>{};
    for (final n in notes) {
      for (final link in n.outgoingLinks) {
        final target = notes.where(
          (t) => t.title.toLowerCase() == link.toLowerCase(),
        );
        if (target.isNotEmpty) {
          ids.add(n.id);
          ids.add(target.first.id);
        }
      }
    }
    return ids;
  }

  /// Hit-test: returns the note under [position], or null.
  BrainNote? noteAt(Offset position) {
    for (final node in _nodes) {
      if ((node.position - position).distance <= node.radius + 4) {
        return node.note;
      }
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (notes.isEmpty) return;

    _ensureNodes(size);
    _stepForces();

    final edgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final linkedPaint = Paint()
      ..color = const Color(0xFF7C4DFF).withValues(alpha: 0.5)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;

    final unlinkedPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // Draw edges
    for (final note in notes) {
      final fromNode = _nodeFor(note);
      if (fromNode == null) continue;
      for (final linkTitle in note.outgoingLinks) {
        final target = _byTitle[linkTitle.toLowerCase()];
        if (target == null) continue;
        final toNode = _nodeFor(target);
        if (toNode == null) continue;

        final paint = (fromNode.radius > 16 || toNode.radius > 16)
            ? linkedPaint
            : edgePaint;
        canvas.drawLine(fromNode.position, toNode.position, paint);
      }
    }

    // Draw unlinked edges (faint)
    for (final note in notes) {
      if (note.outgoingLinks.isEmpty) continue;
      final fromNode = _nodeFor(note);
      if (fromNode == null) continue;
      for (final linkTitle in note.outgoingLinks) {
        if (_byTitle.containsKey(linkTitle.toLowerCase())) continue;
        // Link to a non-existent note — draw a faint dead-end line
        final angle = _rng.nextDouble() * 2 * pi;
        final end = fromNode.position + Offset(cos(angle), sin(angle)) * 40;
        canvas.drawLine(fromNode.position, end, unlinkedPaint);
      }
    }

    // Draw nodes
    for (final node in _nodes) {
      final isLinked = _linkedNoteIds.contains(node.note.id);
      final isIsolated = node.note.outgoingLinks.isEmpty && !isLinked;

      // Node circle
      final nodePaint = Paint()
        ..color = isLinked
            ? const Color(0xFF7C4DFF).withValues(alpha: 0.85)
            : isIsolated
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(node.position, node.radius, nodePaint);

      // Glow for linked nodes
      if (isLinked) {
        final glowPaint = Paint()
          ..color = const Color(0xFF7C4DFF).withValues(alpha: 0.15)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(node.position, node.radius + 6, glowPaint);
      }

      // Title label
      final tp = TextPainter(
        text: TextSpan(
          text: node.note.title,
          style: TextStyle(
            color: Colors.white.withValues(alpha: isLinked ? 0.9 : 0.5),
            fontSize: max(10, node.radius * 0.7),
            fontWeight: isLinked ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: node.radius * 4);
      tp.paint(
        canvas,
        Offset(
          node.position.dx - tp.width / 2,
          node.position.dy + node.radius + 4,
        ),
      );
    }
  }

  void _ensureNodes(Size size) {
    if (_nodes.length == notes.length) return;

    final existing = {for (final n in _nodes) n.note.id: n};
    _nodes = [];
    for (final note in notes) {
      if (existing.containsKey(note.id)) {
        _nodes.add(existing[note.id]!);
      } else {
        // Place new nodes near the center with some jitter
        _nodes.add(_GraphNode(
          note: note,
          position: Offset(
            size.width / 2 + (_rng.nextDouble() - 0.5) * size.width * 0.5,
            size.height / 2 + (_rng.nextDouble() - 0.5) * size.height * 0.5,
          ),
        ));
      }
    }
  }

  _GraphNode? _nodeFor(BrainNote note) {
    for (final n in _nodes) {
      if (n.note.id == note.id) return n;
    }
    return null;
  }

  /// Simple force simulation step: repulsion between all nodes, attraction
  /// along edges, centering force. One step per paint is enough for <100 nodes.
  void _stepForces() {
    const repulsion = 2500.0;
    const attraction = 0.005;
    const centerPull = 0.001;
    const damping = 0.85;
    const dt = 0.5;

    for (final a in _nodes) {
      Offset force = Offset.zero;

      // Repulsion from all other nodes
      for (final b in _nodes) {
        if (a.note.id == b.note.id) continue;
        final delta = a.position - b.position;
        final dist = max(delta.distance, 1.0);
        force += delta / dist * (repulsion / (dist * dist));
      }

      // Attraction along edges
      for (final linkTitle in a.note.outgoingLinks) {
        final target = _byTitle[linkTitle.toLowerCase()];
        if (target == null) continue;
        final b = _nodeFor(target);
        if (b == null) continue;
        final delta = b.position - a.position;
        force += delta * attraction;
      }

      // Centering pull
      force += -a.position * centerPull;

      // Update velocity and position
      a.velocity = (a.velocity + force * dt) * damping;
      a.position += a.velocity * dt;
    }
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) =>
      notes != oldDelegate.notes;
}
