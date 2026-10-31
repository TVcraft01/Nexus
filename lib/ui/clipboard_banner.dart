// The clipboard bar: a peer pushed text that would not apply itself, and this
// is where the user says yes or no.
//
// The mesh already holds the text — plain clipboard payloads never touch the
// local clipboard on arrival, only an OTP or a link applies itself — so this
// widget draws one thing: what arrived, from whom, and the two answers. It sits
// above the pages rather than inside Home because a copy made on the phone is
// looked for wherever the user happens to be, and a prompt that only appears on
// one tab is a prompt that is missed.

part of '../main_ui.dart';

/// The bar itself. Absent (zero height) whenever nothing is waiting, which is
/// the ordinary state; the key is on the bar so a test can say which it saw.
const Key kNexusClipboardBanner = Key('nexus-clipboard-banner');

/// Puts the waiting text on this device's clipboard and closes the bar.
const Key kNexusClipboardAccept = Key('nexus-clipboard-accept');

/// Forgets the waiting text without touching this device's clipboard.
const Key kNexusClipboardDismiss = Key('nexus-clipboard-dismiss');

/// One line per arriving clip, above whatever page is open.
class NexusClipboardBanner extends StatelessWidget {
  const NexusClipboardBanner({super.key, required this.mesh});

  /// The mesh that holds the pending clip. It is a [Listenable], so the bar
  /// appears and goes away on the mesh's own notification rather than on a
  /// timer of this widget's.
  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (BuildContext context, Widget? _) {
        final ClipEntry? clip = mesh.lastIncomingClip;
        // An auto-accepted payload is already on the clipboard and is reported
        // by the toast that put it there; a bar asking about it would be a
        // question with no answer left to give.
        if (clip == null || clip.autoAccepted) return const SizedBox.shrink();
        final NexusUiColors c = context.ui;
        final String from = (clip.fromName ?? '').trim().isEmpty
            ? 'a paired device'
            : clip.fromName!.trim();
        // One line of preview, whatever the payload's own newlines were: the
        // bar is a summons, not a reader. Accept is where the text becomes
        // usable.
        final String preview = clip.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        return Container(
          key: kNexusClipboardBanner,
          decoration: BoxDecoration(
            color: c.raised,
            border: Border(bottom: BorderSide(color: c.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(NexusLayout.gutter, 10, 8, 10),
          child: Row(
            children: <Widget>[
              Icon(Icons.content_paste_rounded, size: 20, color: c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Clipboard from $from',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexusType.rowTitle(c).copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexusType.rowMeta(c),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Two words rather than an icon pair: this is a decision about
              // someone else's text landing on the clipboard, and the two ways
              // out are worth reading before they are tapped.
              TextButton(
                key: kNexusClipboardAccept,
                onPressed: () => unawaited(mesh.acceptPendingClipboard()),
                child: const Text('Accept'),
              ),
              TextButton(
                key: kNexusClipboardDismiss,
                onPressed: mesh.dismissPendingClipboard,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        );
      },
    );
  }
}
