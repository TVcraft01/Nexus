// One file the assistant wrote, full screen, with the one control the card
// cannot offer: Save.
//
// The card in the thread is a promise — "this is a real file, not a paragraph"
// — and this page is where the promise is kept. It shows the code exactly as
// written (monospaced, selectable, scroll both ways for the one long line a
// model always produces) and writes it where the app writes everything the user
// keeps: the same Downloads folder the rest of Nexus uses.
//
// Saving through [saveLocalFileAs] rather than a path of this page's own means
// the platform's save dialog is used where there is one, and Android's
// de-duplicated Downloads copy where there is not. The page never overwrites an
// existing file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/artifacts.dart' show NexusArtifact;
import 'local_files.dart' show saveLocalFileAs;

/// The button that writes the file.
const Key kArtifactSave = ValueKey<String>('artifact-save');

/// The code pane.
const Key kArtifactCode = ValueKey<String>('artifact-code');

/// The sentence a successful save leaves on the page.
const Key kArtifactSavedNote = ValueKey<String>('artifact-saved-note');

class NexusArtifactPage extends StatefulWidget {
  const NexusArtifactPage({super.key, required this.artifact});

  final NexusArtifact artifact;

  static Future<void> open(BuildContext context, NexusArtifact artifact) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            NexusArtifactPage(artifact: artifact),
      ),
    );
  }

  @override
  State<NexusArtifactPage> createState() => _NexusArtifactPageState();
}

class _NexusArtifactPageState extends State<NexusArtifactPage> {
  bool _saving = false;
  String? _savedAt;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    File? temp;
    try {
      temp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        '${widget.artifact.safeFilename}',
      );
      await temp.writeAsString(widget.artifact.code, flush: true);
      final String? saved = await saveLocalFileAs(temp.path);
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (saved == null) {
          _error = 'The file was not saved.';
        } else {
          _savedAt = saved;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'The file was not saved ($error).';
      });
    } finally {
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {
        // A temp copy that survives is the system's to sweep; the save already
        // happened, and failing it over the cleanup would be a second failure.
      }
    }
  }

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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              widget.artifact.safeFilename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              widget.artifact.languageLabel,
              style: TextStyle(color: muted, fontSize: 11.5),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: widget.artifact.code),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    widget.artifact.code,
                    key: kArtifactCode,
                    style: TextStyle(
                      color: ink,
                      fontSize: 13,
                      height: 1.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
            if (_savedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Saved to $_savedAt',
                  key: kArtifactSavedNote,
                  maxLines: 2,
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  _error!,
                  maxLines: 2,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                key: kArtifactSave,
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 18),
                label: Text(_saving ? 'Saving…' : 'Save File'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
