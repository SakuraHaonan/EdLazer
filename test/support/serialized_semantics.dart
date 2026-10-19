import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Replays incremental engine updates, rather than merely inspecting the
/// framework's final tree. The latter misses orphan nodes sent to AXTree.
class SerializedSemanticsRecorder {
  final Map<int, List<int>> _accepted = {};
  final List<String> errors = [];
  int commits = 0;
  bool enabled = false;

  void reset() {
    _accepted.clear();
    errors.clear();
    commits = 0;
    enabled = true;
  }

  void commit(Map<int, List<int>> updates) {
    if (!enabled || updates.isEmpty) return;
    commits++;
    final candidate = {..._accepted, ...updates};
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in candidate[id] ?? const <int>[]) {
        visit(child);
      }
    }

    visit(0);
    final orphans = updates.keys.where((id) => !reachable.contains(id));
    final missing = reachable.where((id) => !candidate.containsKey(id));
    if (orphans.isNotEmpty || missing.isNotEmpty) {
      errors.add(
        'commit $commits: orphan=${orphans.toList()}, missing=${missing.toList()}',
      );
      return; // A rejected AXTree update cannot become the next baseline.
    }
    _accepted
      ..clear()
      ..addEntries(
        candidate.entries.where((entry) => reachable.contains(entry.key)),
      );
  }
}

class RecordingSemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final recorder = SerializedSemanticsRecorder();
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(recorder);
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this.recorder);
  final SerializedSemanticsRecorder recorder;
  final ui.SemanticsUpdateBuilder _native = ui.SemanticsUpdateBuilder();
  final Map<int, List<int>> updates = {};

  // Forward every argument to the real builder, including SDK-specific flags.
  // Only record the graph, so this test does not rewrite semantics payloads.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final arguments = invocation.namedArguments;
      updates[arguments[#id] as int] = List<int>.of(
        arguments[#childrenInTraversalOrder] as Iterable<int>,
      );
      return Function.apply(
        _native.updateNode,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _native.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );
  @override
  ui.SemanticsUpdate build() {
    recorder.commit(updates);
    return _native.build();
  }
}
