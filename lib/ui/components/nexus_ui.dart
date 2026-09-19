import 'dart:async';

import 'package:flutter/material.dart';

import '../nexus_core.dart';
import '../theme.dart';

/// The glyph for a platform. One owner, so the device list, the pairing sheet
/// and the file destinations all name a platform the same way.
IconData platformIcon(String platform) {
  switch (platform) {
    case 'android':
      return Icons.smartphone_rounded;
    case 'linux':
    case 'windows':
      return Icons.desktop_windows_rounded;
    case 'macos':
      return Icons.laptop_mac_rounded;
    case 'ios':
      return Icons.phone_iphone_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

/// What a platform is called in front of a user — never its id.
String platformLabel(String platform) {
  switch (platform) {
    case 'android':
      return 'Phone';
    case 'linux':
      return 'Linux';
    case 'windows':
      return 'Windows';
    case 'macos':
      return 'Mac';
    case 'ios':
      return 'iPhone';
    default:
      return 'Device';
  }
}

/// The page frame every tab uses.
///
/// It owns the three things that used to be re-decided in each view — the
/// safe-area inset, the horizontal gutter, and the readable maximum width —
/// so no screen can invent a magic top padding or sit under the camera
/// cutout. Scrolling and the bottom gutter for the navigation bar live here
/// too.
class NexusPage extends StatelessWidget {
  const NexusPage({
    super.key,
    required this.children,
    this.pinnedBottom,
    this.bottomGutter = NexusSpace.xxl,
  });

  final List<Widget> children;

  /// Content that stays visible while the page scrolls — the one action a
  /// thumb should be able to reach without moving the hand.
  final Widget? pinnedBottom;

  /// Space between the last child and the bottom of the scroll view.
  final double bottomGutter;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.xl,
        NexusSpace.page,
        NexusSpace.xxxl + bottomGutter + bottom,
      ),
      children: children,
    );

    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: NexusSize.desktop),
              child: list,
            ),
          ),
        ),
        if (pinnedBottom != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: NexusSize.desktop),
              child: _PinnedBottom(child: pinnedBottom!),
            ),
          ),
      ],
    );
  }
}

/// A pinned action area: one hairline above a surface, so it reads as
/// attached to the page rather than floating over it.
class _PinnedBottom extends StatelessWidget {
  const _PinnedBottom({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.separator)),
      ),
      padding: EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.md,
        NexusSpace.page,
        NexusSpace.md + MediaQuery.paddingOf(context).bottom,
      ),
      child: child,
    );
  }
}

/// The one header for a tab: title, one line of context, and optional
/// trailing actions. Deliberately not a hero — the page below is the point.
class NexusPageHeader extends StatelessWidget {
  const NexusPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NexusSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: NexusSpace.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineMedium?.copyWith(fontSize: 24),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: NexusSpace.xs),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 2,
                  ),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// A quiet label above a group: "Your devices", "More ways to connect".
class NexusSectionHeader extends StatelessWidget {
  const NexusSectionHeader(this.title, {super.key, this.trailing, this.detail});

  final String title;
  final Widget? trailing;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.xs,
        NexusSpace.section,
        NexusSpace.xs,
        NexusSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: palette.textTertiary),
                ),
                if (detail != null) ...[
                  const SizedBox(height: NexusSpace.xs),
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A group of rows on one surface, separated by hairlines.
///
/// This replaces "a card per item": the container exists because these rows
/// belong together, not because every row needs a rounded rectangle.
class NexusGroup extends StatelessWidget {
  const NexusGroup({super.key, required this.children, this.highlighted = false});

  final List<Widget> children;

  /// Slightly brighter fill — for the group the user should look at first.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: NexusSpace.lg),
            child: Divider(height: 1, thickness: 1, color: palette.separator),
          ),
        );
      }
      rows.add(children[i]);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlighted ? palette.surfaceElevated : palette.surface,
        borderRadius: NexusRadius.card,
        border: Border.all(color: palette.separator),
      ),
      child: ClipRRect(
        borderRadius: NexusRadius.card,
        child: Column(children: rows),
      ),
    );
  }
}

/// One row in a [NexusGroup]. Uses the whole row as the target, keeps a
/// minimum touch height, and announces title and subtitle as one label so a
/// screen reader does not read them as two unrelated things.
class NexusRow extends StatelessWidget {
  const NexusRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
    this.minHeight = NexusSize.row,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool destructive;
  final double minHeight;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final titleColor = destructive ? palette.danger : palette.textPrimary;

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.lg,
        vertical: NexusSpace.md,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: NexusSpace.md),
          ],
          // The row's own label below already says the title and subtitle
          // once. Leaving the Text widgets with their own semantics makes a
          // screen reader read every row twice, which is what the phone
          // showed; the words are excluded here, the row speaks for them.
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: titleColor),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: NexusSpace.xxs),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: NexusSpace.sm),
            trailing!,
          ],
          if (chevron) ...[
            const SizedBox(width: NexusSpace.xs),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: palette.textTertiary,
            ),
          ],
        ],
      ),
    );

    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: content,
    );

    final semantics = semanticLabel ??
        (subtitle == null ? title : '$title. $subtitle');

    if (onTap == null) {
      return Semantics(container: true, label: semantics, child: row);
    }
    return Semantics(
      container: true,
      button: true,
      label: semantics,
      child: Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: row),
      ),
    );
  }
}

/// A row whose action is a switch. The whole row toggles, the switch is only
/// the indicator — a 48dp target on a 20dp thumb is how settings get missed.
class NexusSwitchRow extends StatelessWidget {
  const NexusSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return NexusRow(
      title: title,
      subtitle: subtitle,
      minHeight: NexusSize.row,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      semanticLabel:
          '$title. ${value ? 'On' : 'Off'}${subtitle == null ? '' : '. $subtitle'}',
      trailing: ExcludeSemantics(
        child: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

/// What a row's status means, in colour *and* words. Colour is never the only
/// carrier: every use pairs a level with a label.
enum NexusStatusLevel {
  online,
  nearby,
  offline,
  working,
  failed;

  Color color(NexusPalette palette) => switch (this) {
    NexusStatusLevel.online => palette.success,
    NexusStatusLevel.nearby => palette.warning,
    NexusStatusLevel.offline => palette.textTertiary,
    NexusStatusLevel.working => palette.accent,
    NexusStatusLevel.failed => palette.danger,
  };
}

/// A dot that encodes a status. It pulses only while something is genuinely
/// in progress, so a resting screen is still.
class NexusStatusDot extends StatefulWidget {
  const NexusStatusDot({
    super.key,
    required this.level,
    this.size = 10,
    this.animate,
  });

  final NexusStatusLevel level;
  final double size;

  /// Defaults to true for [NexusStatusLevel.working] only.
  final bool? animate;

  @override
  State<NexusStatusDot> createState() => _NexusStatusDotState();
}

class _NexusStatusDotState extends State<NexusStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool get _shouldAnimate =>
      widget.animate ?? widget.level == NexusStatusLevel.working;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant NexusStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level ||
        oldWidget.animate != widget.animate) {
      _sync();
    }
  }

  void _sync() {
    if (_shouldAnimate) {
      _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _pulse.stop();
    } else if (_shouldAnimate && !_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final color = widget.level.color(palette);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_shouldAnimate)
            FadeTransition(
              opacity: Tween<double>(begin: 0.45, end: 0).animate(_pulse),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 2.0).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeOut),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(width: widget.size, height: widget.size),
                ),
              ),
            ),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }
}

/// An empty screen that teaches: what this is, and the one thing to do next.
class NexusEmptyState extends StatelessWidget {
  const NexusEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.xl,
        vertical: NexusSpace.xxxl,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: NexusRadius.card,
        border: Border.all(color: palette.separator),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: palette.accentTint(0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 26, color: palette.accent),
          ),
          const SizedBox(height: NexusSpace.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
          ),
          const SizedBox(height: NexusSpace.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: NexusSpace.xl),
            action!,
          ],
          if (secondaryAction != null) ...[
            const SizedBox(height: NexusSpace.sm),
            secondaryAction!,
          ],
        ],
      ),
    );
  }
}

/// The assistant's presence: the Core, what it is doing, and the one line of
/// context that makes the screen self-explanatory. It is the app's identity,
/// so it lives in exactly one place.
class NexusPresence extends StatelessWidget {
  const NexusPresence({
    super.key,
    required this.state,
    this.contextLine,
    this.trailing = const [],
    this.coreSize = 44,
  });

  final NexusCoreState state;
  final String? contextLine;
  final List<Widget> trailing;
  final double coreSize;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: NexusSpace.md),
      child: Row(
        children: [
          NexusCore(state: state, size: coreSize),
          const SizedBox(width: NexusSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Nexus',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: NexusSpace.xxs),
                Row(
                  children: [
                    NexusStatusDot(
                      level: switch (state) {
                        NexusCoreState.idle => NexusStatusLevel.online,
                        NexusCoreState.listening ||
                        NexusCoreState.thinking ||
                        NexusCoreState.working => NexusStatusLevel.working,
                        NexusCoreState.offline => NexusStatusLevel.offline,
                        NexusCoreState.error => NexusStatusLevel.failed,
                      },
                      size: 8,
                    ),
                    const SizedBox(width: NexusSpace.sm),
                    Expanded(
                      child: Text(
                        contextLine ?? state.label,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: state == NexusCoreState.error
                              ? palette.danger
                              : palette.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// A button that reports what it is doing.
///
/// Idle → busy → done/failed, in one control, so no tap is ever left
/// unanswered. The result is announced to screen readers too.
class NexusAsyncButton extends StatefulWidget {
  const NexusAsyncButton({
    super.key,
    required this.label,
    required this.onRun,
    this.icon,
    this.busyLabel,
    this.successLabel,
    this.failureLabel,
    this.filled = true,
    this.expand = false,
  });

  final String label;

  /// The work. Return true for success, false for a failure the user should
  /// see; throw for a failure with the same effect.
  final Future<bool> Function() onRun;

  final IconData? icon;
  final String? busyLabel;
  final String? successLabel;
  final String? failureLabel;
  final bool filled;
  final bool expand;

  @override
  State<NexusAsyncButton> createState() => _NexusAsyncButtonState();
}

enum _AsyncPhase { idle, busy, done, failed }

class _NexusAsyncButtonState extends State<NexusAsyncButton> {
  _AsyncPhase _phase = _AsyncPhase.idle;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_phase == _AsyncPhase.busy) return;
    setState(() => _phase = _AsyncPhase.busy);
    var ok = false;
    try {
      ok = await widget.onRun();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _phase = ok ? _AsyncPhase.done : _AsyncPhase.failed);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _phase = _AsyncPhase.idle);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final (String label, IconData? icon) = switch (_phase) {
      _AsyncPhase.busy => (widget.busyLabel ?? 'Working…', null),
      _AsyncPhase.done => (
        widget.successLabel ?? 'Done',
        Icons.check_rounded,
      ),
      _AsyncPhase.failed => (
        widget.failureLabel ?? 'Failed',
        Icons.error_outline_rounded,
      ),
      _AsyncPhase.idle => (widget.label, widget.icon),
    };

    final child = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_phase == _AsyncPhase.busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.onAccent,
            ),
          )
        else if (icon != null)
          Icon(icon, size: 18),
        if (icon != null || _phase == _AsyncPhase.busy)
          const SizedBox(width: NexusSpace.sm),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );

    final onPressed = _phase == _AsyncPhase.busy ? null : _run;
    final style = _phase == _AsyncPhase.failed && widget.filled
        ? FilledButton.styleFrom(
            backgroundColor: palette.danger,
            foregroundColor: palette.onDanger,
          )
        : null;

    final button = widget.filled
        ? FilledButton(
            onPressed: onPressed,
            style: style,
            child: child,
          )
        : OutlinedButton(onPressed: onPressed, style: style, child: child);

    return Semantics(
      liveRegion: _phase != _AsyncPhase.idle,
      label: _phase == _AsyncPhase.idle ? null : label,
      child: widget.expand
          ? SizedBox(width: double.infinity, child: button)
          : button,
    );
  }
}
