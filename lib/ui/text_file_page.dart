// A text file, read-only, full screen.
//
// The Files tab can open a photo with the viewer and any other file with the
// platform's own app. A `.txt` or a `.md` should not need another app just to be
// *read* — that is a round trip through a chooser to see four lines — so this
// page is the third verb: open it here, scroll, select, copy.
//
// It reads a bounded prefix rather than the whole file: a 50 MB log is not a
// preview, and a Text widget holding it is a frozen phone. The page says when
// it stopped, so a truncated read is never mistaken for the whole file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../l10n/copy.dart';

/// The close control, named so a test can leave the page.
const Key kTextFileClose = ValueKey<String>('text-file-close');

/// The code itself.
const Key kTextFileBody = ValueKey<String>('text-file-body');

class TextFilePage extends StatefulWidget {
  const TextFilePage({
    super.key,
    required this.path,
    required this.name,
    this.maxBytes = 256 * 1024,
  });

  final String path;
  final String name;

  /// How much of the file is read. Enough for a config, a note, or a page of
  /// code; far too little to stall a frame on.
  final int maxBytes;

  /// How the page gets its words. The app reads the file; a widget test hands
  /// back the text, because a test's clock is fake and a future waiting on the
  /// disk never finishes inside `pumpAndSettle`.
  @visibleForTesting
  static Future<String> Function(String path, int maxBytes)? readOverride;

  static Future<void> open(
    BuildContext context, {
    required String path,
    required String name,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => TextFilePage(path: path, name: name),
      ),
    );
  }

  @override
  State<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends State<TextFilePage> {
  String? _body;
  String? _error;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final Future<String> Function(String, int)? override =
        TextFilePage.readOverride;
    if (override != null) {
      try {
        final String text = await override(widget.path, widget.maxBytes);
        if (!mounted) return;
        setState(() => _body = text);
      } catch (error) {
        if (mounted) {
          setState(() => _error = 'Nexus could not read this file ($error).');
        }
      }
      return;
    }
    final File file = File(widget.path);
    try {
      if (!await file.exists()) {
        if (mounted) {
          setState(() => _error = 'This file is no longer on the device.');
        }
        return;
      }
      final int length = await file.length();
      final List<int> bytes = await file
          .openRead(0, _atMost(length))
          .fold(
            <int>[],
            (List<int> all, List<int> chunk) => all..addAll(chunk),
          );
      final String text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _body = text;
        _truncated = length > bytes.length;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Nexus could not read this file ($error).');
      }
    }
  }

  int _atMost(int length) =>
      length < widget.maxBytes ? length : widget.maxBytes;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color ink = dark ? const Color(0xFFEDEDEA) : const Color(0xFF1D1D1B);
    final Color muted = dark
        ? const Color(0xFF9A9A95)
        : const Color(0xFF75756F);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: <Widget>[
          IconButton(
            key: kTextFileClose,
            tooltip: context.l10n.close,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: switch ((_body, _error)) {
          (_, final String error) => Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.description_outlined, size: 38, color: muted),
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 14),
                ),
              ],
            ),
          ),
          (final String body, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: SelectableText(
                    body,
                    key: kTextFileBody,
                    style: TextStyle(
                      color: ink,
                      fontSize: 13.5,
                      height: 1.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              if (_truncated)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Text(
                    'Showing the first ${widget.maxBytes ~/ 1024} KB of a '
                    'larger file.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
            ],
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}
