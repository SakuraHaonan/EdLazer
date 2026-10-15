import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/lyrics.dart';
import '../theme/design_tokens.dart';
import 'accessible_controls.dart';

String selectedLyricsText(List<LyricLine> lines, Set<int> selected) =>
    (selected.toList()..sort())
        .where((i) => i >= 0 && i < lines.length)
        .map(
          (i) => [
            lines[i].text,
            if (lines[i].translation?.isNotEmpty ?? false)
              lines[i].translation!,
          ].join('\n'),
        )
        .join('\n\n');

class LyricSelectionSheet extends StatefulWidget {
  const LyricSelectionSheet({
    super.key,
    required this.lines,
    required this.initialIndex,
  });
  final List<LyricLine> lines;
  final int initialIndex;
  @override
  State<LyricSelectionSheet> createState() => _LyricSelectionSheetState();
}

class _LyricSelectionSheetState extends State<LyricSelectionSheet> {
  late final Set<int> _selected = {widget.initialIndex};
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset:
        (widget.initialIndex - 2).clamp(0, widget.lines.length) * 76.0,
  );
  bool _copied = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
            child: Row(
              children: [
                const Expanded(
                  child: TrText('选择歌词', style: AppText.subheading),
                ),
                AccessibleIconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                TrText(
                  '已选择 ${_selected.length} 行',
                  style: AppText.captionMuted,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _copied = false;
                    if (_selected.length == widget.lines.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(
                        List.generate(widget.lines.length, (i) => i),
                      );
                    }
                  }),
                  child: TrText(
                    _selected.length == widget.lines.length ? '取消全选' : '全选',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: widget.lines.length,
              itemBuilder: (context, i) => CheckboxListTile(
                key: ValueKey('select-lyric-$i'),
                controlAffinity: ListTileControlAffinity.leading,
                selected: _selected.contains(i),
                value: _selected.contains(i),
                title: Text(widget.lines[i].text, style: AppText.body),
                subtitle: widget.lines[i].translation == null
                    ? null
                    : Text(
                        widget.lines[i].translation!,
                        style: AppText.captionMuted,
                      ),
                onChanged: (_) => setState(() {
                  _copied = false;
                  if (!_selected.add(i)) _selected.remove(i);
                }),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: Icon(_copied ? Icons.check : Icons.copy),
                onPressed: _selected.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: selectedLyricsText(widget.lines, _selected),
                          ),
                        );
                        if (mounted) setState(() => _copied = true);
                      },
                label: TrText(_copied ? '已复制' : '复制所选歌词'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
