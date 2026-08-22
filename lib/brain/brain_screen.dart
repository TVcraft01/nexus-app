import 'package:flutter/material.dart';

import 'brain_store.dart';
import 'graph_painter.dart';

/// The Brain tab: a read-only view of what the AI knows. The AI writes
/// notes here automatically from conversations. The user can browse,
/// search, and see how ideas connect — but doesn't create notes manually.
/// This is the AI's memory, not the user's notebook.
class BrainScreen extends StatefulWidget {
  const BrainScreen({super.key});

  @override
  State<BrainScreen> createState() => _BrainScreenState();
}

class _BrainScreenState extends State<BrainScreen> {
  final _store = BrainStore.instance;
  String _searchQuery = '';
  VoidCallback? _storeListener;

  @override
  void initState() {
    super.initState();
    _storeListener = () {
      if (mounted) setState(() {});
    };
    _store.addListener(_storeListener!);
  }

  @override
  void dispose() {
    if (_storeListener != null) _store.removeListener(_storeListener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _searchQuery.isEmpty
        ? _store.notesByRecent
        : _store.search(_searchQuery);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D12),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Brain',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w300,
            letterSpacing: 1.2,
            fontSize: 20,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.search,
              color: Colors.white.withValues(alpha: 0.5),
            ),
            onPressed: () => _showSearch(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Graph canvas ────────────────────────────────────────────
          if (notes.isNotEmpty)
            SizedBox(
              height: 260,
              child: CustomPaint(
                size: Size.infinite,
                painter: GraphPainter(notes: notes),
              ),
            ),

          // ── Divider ─────────────────────────────────────────────────
          if (notes.isNotEmpty)
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    const Color(0xFF7C4DFF).withValues(alpha: 0.3),
                    Colors.transparent,
                  ],
                ),
              ),
            ),

          // ── Memory count ────────────────────────────────────────────
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 6, color: const Color(0xFF7C4DFF)),
                  const SizedBox(width: 8),
                  Text(
                    '${notes.length} memories',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  if (_searchQuery.isNotEmpty)
                    Text(
                      'filtered',
                      style: TextStyle(
                        color: const Color(0xFF7C4DFF).withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),

          // ── Notes list ──────────────────────────────────────────────
          Expanded(
            child: notes.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: notes.length,
                    itemBuilder: (context, i) => _MemoryCard(
                      note: notes[i],
                      store: _store,
                      onTap: () => _openDetail(context, notes[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hub_outlined,
            size: 80,
            color: const Color(0xFF7C4DFF).withValues(alpha: 0.15),
          ),
          const SizedBox(height: 20),
          Text(
            'The brain is empty',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 18,
              fontWeight: FontWeight.w300,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Talk to Nexus — it learns as you chat',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.25),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  void _showSearch(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A24),
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search memories…',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            prefixIcon:
                Icon(Icons.search, color: Colors.white.withValues(alpha: 0.3)),
            border: const OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          onChanged: (q) => setState(() => _searchQuery = q),
          onSubmitted: (_) => Navigator.pop(context),
        ),
      ),
    ).whenComplete(() {
      // Keep the search filter active after closing the sheet.
    });
  }

  void _openDetail(BuildContext context, BrainNote note) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _MemoryDetail(note: note, store: _store)),
    );
  }
}

// ── Memory card ──────────────────────────────────────────────────────

class _MemoryCard extends StatelessWidget {
  final BrainNote note;
  final BrainStore store;
  final VoidCallback onTap;

  const _MemoryCard({
    required this.note,
    required this.store,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final links = note.outgoingLinks;
    final backlinks = store.backlinksFor(note.id);
    final isLinked = links.isNotEmpty || backlinks.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isLinked
              ? const Color(0xFF7C4DFF).withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isLinked
                ? const Color(0xFF7C4DFF).withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.04),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.title,
              style: TextStyle(
                color: isLinked
                    ? const Color(0xFFB388FF)
                    : Colors.white.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (note.content.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                note.content.length > 120
                    ? '${note.content.substring(0, 120)}…'
                    : note.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            if (links.isNotEmpty || backlinks.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (links.isNotEmpty)
                    _Badge(
                      icon: Icons.arrow_outward,
                      count: links.length,
                      color: const Color(0xFF7C4DFF),
                    ),
                  if (links.isNotEmpty && backlinks.isNotEmpty)
                    const SizedBox(width: 8),
                  if (backlinks.isNotEmpty)
                    _Badge(
                      icon: Icons.arrow_back,
                      count: backlinks.length,
                      color: const Color(0xFF00BFA5),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;

  const _Badge({required this.icon, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2),
          Text(
            '$count',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Memory detail (read-only) ───────────────────────────────────────

class _MemoryDetail extends StatelessWidget {
  final BrainNote note;
  final BrainStore store;

  const _MemoryDetail({required this.note, required this.store});

  @override
  Widget build(BuildContext context) {
    final backlinks = store.backlinksFor(note.id);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D12),
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          note.title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w300,
            fontSize: 18,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Content
            Text(
              note.content,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 15,
                height: 1.7,
              ),
            ),

            // Backlinks
            if (backlinks.isNotEmpty) ...[
              const SizedBox(height: 24),
              Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      const Color(0xFF00BFA5).withValues(alpha: 0.2),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'CONNECTED TO',
                style: TextStyle(
                  color: const Color(0xFF00BFA5).withValues(alpha: 0.5),
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (final link in backlinks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00BFA5).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      link.title,
                      style: const TextStyle(
                        color: Color(0xFF00BFA5),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],

            // Metadata
            const SizedBox(height: 24),
            Text(
              'stored ${_timeAgo(note.createdAt)}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.15),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
