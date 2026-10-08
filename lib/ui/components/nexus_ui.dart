import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoSwitch,
        CupertinoTextThemeData,
        CupertinoTheme,
        CupertinoThemeData;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

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

/// What kind of file something is, in one glyph at one muted colour.
///
/// The Files screen lists other people's folders: a row's icon says what the
/// thing *is* so the eye can skip it, and nothing more. One colour for every
/// type — a rainbow of per-extension colours is the thing this replaces.
IconData fileTypeIcon({required String name, required bool isDir}) {
  if (isDir) return Icons.folder_rounded;
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 || dot == name.length - 1
      ? ''
      : name.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'heic' || 'svg' || 'bmp' =>
      Icons.image_outlined,
    'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => Icons.movie_outlined,
    'mp3' || 'wav' || 'flac' || 'm4a' || 'ogg' => Icons.audiotrack_rounded,
    'zip' || 'tar' || 'gz' || 'tgz' || 'bz2' || 'xz' || '7z' || 'rar' =>
      Icons.folder_zip_outlined,
    'pdf' || 'doc' || 'docx' || 'odt' || 'rtf' || 'txt' || 'md' || 'epub' =>
      Icons.description_outlined,
    'json' || 'xml' || 'yaml' || 'yml' || 'csv' || 'dart' || 'js' || 'ts' ||
      'py' || 'sh' || 'kt' || 'java' || 'html' || 'css' =>
      Icons.code_rounded,
    'apk' => Icons.android_rounded,
    _ => Icons.insert_drive_file_outlined,
  };
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

/// The Cupertino half of the app's theme.
///
/// Every Cupertino widget resolves its colours and type from an inherited
/// [CupertinoTheme], and the default one is a *light* system theme — a black
/// navigation title and a white dialog on this app's near-black background.
/// This writes that theme once, from the same tokens everything else reads, so
/// an iOS-shaped control cannot be the one surface that is the wrong colour.
///
/// It sits inside `MaterialApp`'s builder, above the navigator, so every route
/// — pushed pages, dialogs, sheets — inherits it.
class NexusCupertinoTheme extends StatelessWidget {
  const NexusCupertinoTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return CupertinoTheme(
      data: CupertinoThemeData(
        // The app ships dark; the light palette is data, not a second build.
        brightness: Brightness.dark,
        primaryColor: palette.accent,
        barBackgroundColor: palette.surface.withValues(alpha: 0.82),
        scaffoldBackgroundColor: palette.bg,
        textTheme: CupertinoTextThemeData(
          // Cupertino's own sizes, with this app's colours and tracking: the
          // nav title is the same 17pt Headline the type scale names.
          navTitleTextStyle: NexusType.title.copyWith(
            color: palette.textPrimary,
          ),
          navLargeTitleTextStyle: NexusType.display.copyWith(
            color: palette.textPrimary,
          ),
          textStyle: NexusType.body.copyWith(color: palette.textPrimary),
          actionTextStyle: NexusType.button.copyWith(color: palette.accent),
          tabLabelTextStyle: NexusType.caption.copyWith(
            fontSize: 10,
            letterSpacing: 0.1,
            color: palette.textSecondary,
          ),
          pickerTextStyle: NexusType.rowTitle.copyWith(
            color: palette.textPrimary,
          ),
        ),
      ),
      child: child,
    );
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
    // Whatever top inset this page was handed. In the shell that is nothing —
    // SafeArea has already consumed the status bar — and on a pushed page it
    // is the translucent navigation bar, which the framework reports as
    // padding and which the page must clear before its first row.
    final insets = MediaQuery.paddingOf(context);
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.xl + insets.top,
        NexusSpace.page,
        NexusSpace.xxxl + bottomGutter + insets.bottom,
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
                    style: Theme.of(context).textTheme.headlineMedium,
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

/// A tappable surface that answers the finger the instant it lands.
///
/// The first rule of a fluid interface is response: the press must show on
/// touch-**down**, not on release. A Material [InkWell] does react on down,
/// but its ripple grows outward from the touch point, so the surface reads as
/// catching up with the finger. This paints an instant tint instead, and moves
/// the surface on a critically-damped spring — which means a press that is
/// cancelled (dragged away, or taken over by a scroll) settles from wherever
/// it got to, instead of snapping back through a fixed curve.
class NexusPressable extends StatefulWidget {
  const NexusPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius = NexusRadius.row,
    this.pressedScale = 0.98,
    this.tint,
    this.enabled = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// The second gesture, for an action that would clutter the surface.
  final VoidCallback? onLongPress;

  final BorderRadiusGeometry borderRadius;

  /// How far the surface shrinks under the finger. Deliberately tiny: a row
  /// is not a button, and a list that lurches on every touch is worse than one
  /// that does nothing.
  final double pressedScale;

  /// The press colour. Defaults to a faint accent tint.
  final Color? tint;

  final bool enabled;
  final HitTestBehavior behavior;

  @override
  State<NexusPressable> createState() => _NexusPressableState();
}

class _NexusPressableState extends State<NexusPressable>
    with SingleTickerProviderStateMixin {
  /// Unbounded on purpose: the scale is a live value a spring can be handed,
  /// not a 0..1 progress bar.
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  bool _pressed = false;

  /// The finger that is currently on this surface, and where it landed.
  ///
  /// The press is read from raw pointer events, not from the tap recogniser:
  /// inside a scrollable the tap has to wait for the gesture arena to decide
  /// it is not a drag (`kPressTimeout`, 100 ms) before `onTapDown` is called,
  /// and a highlight that arrives a tenth of a second late is exactly the lag
  /// the rule removes. The pointer stream is available in the same frame.
  int? _pointer;
  Offset? _downAt;

  /// Whether the platform is refusing animations, read once per dependency
  /// change and cached: a pointer that lands while this surface is being torn
  /// down must not look up an inherited widget, which is not safe there.
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || _pointer != null) return;
    _pointer = event.pointer;
    _downAt = event.position;
    _setPressed(true);
  }

  /// Once the finger has travelled past the touch slop the gesture is not a
  /// press any more — it is a scroll, so the surface steps back out of the
  /// way. A small threshold first, then commit: a press that flickers on the
  /// smallest jitter reads as nervous.
  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downAt == null) return;
    if ((event.position - _downAt!).distance > kTouchSlop) _endPress(event.pointer);
  }

  void _endPress(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _downAt = null;
    _setPressed(false);
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    // A pointer that has already left the tree (a page that popped under the
    // finger) still reports its release here; there is nothing left to light.
    if (!mounted || !context.mounted) return;
    // The tint is synchronous: it is on screen in the frame the finger lands
    // in, which is the whole point of the rule.
    setState(() => _pressed = pressed);

    final target = pressed ? widget.pressedScale : 1.0;
    if (_reducedMotion) {
      _scale.value = target;
      return;
    }
    // From the current value *and* the current velocity: a press grabbed again
    // mid-settle continues its motion rather than restarting it.
    _scale.animateWith(
      SpringSimulation(
        NexusSpring.of(),
        _scale.value,
        target,
        _scale.velocity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final tint = widget.tint ?? palette.accentTint(0.10);
    return Listener(
      behavior: widget.behavior,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (event) => _endPress(event.pointer),
      onPointerCancel: (event) => _endPress(event.pointer),
      child: GestureDetector(
        behavior: widget.behavior,
        // The recogniser still owns the press: when it is rejected (a scroll,
        // a long press that won), the highlight ends with it.
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        child: AnimatedBuilder(
        animation: _scale,
          builder: (context, child) =>
              Transform.scale(scale: _scale.value, child: child),
          child: AnimatedContainer(
            // On press the tint is already there (zero duration); the fade
            // only exists so the colour does not pop off the moment the finger
            // lifts.
            duration: _pressed
                ? Duration.zero
                : NexusMotion.scaled(context, NexusMotion.fast),
            decoration: BoxDecoration(
              color: _pressed ? tint : Colors.transparent,
              borderRadius: widget.borderRadius,
            ),
            child: widget.child,
          ),
        ),
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
    this.onLongPress,
    this.chevron = false,
    this.destructive = false,
    this.minHeight = NexusSize.row,
    this.semanticLabel,
    this.customActions = const {},
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// The row's second gesture. Only for the surfaces that would otherwise
  /// carry a column of little buttons — a file, an item you manage in place.
  final VoidCallback? onLongPress;

  final bool chevron;
  final bool destructive;
  final double minHeight;
  final String? semanticLabel;

  /// Actions a long press opens, published as custom semantics actions too:
  /// a screen reader cannot perform "press and hold", so the same four
  /// actions must be reachable from the accessibility menu.
  final Map<CustomSemanticsAction, VoidCallback> customActions;

  /// A row that has an action but cannot take it right now — a file already
  /// being downloaded. It keeps its shape and loses only its response, so the
  /// row the user pressed is still the row they are looking at.
  final bool enabled;

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

    if (onTap == null && onLongPress == null) {
      return Semantics(container: true, label: semantics, child: row);
    }
    return Semantics(
      container: true,
      button: true,
      label: semantics,
      customSemanticsActions: customActions,
      child: NexusPressable(
        enabled: enabled,
        onTap: onTap,
        onLongPress: onLongPress,
        child: row,
      ),
    );
  }
}

/// A row's value: what the label answers to, right-aligned, a size smaller
/// than the label and dimmer, so the eye reads the setting first.
class NexusRowValue extends StatelessWidget {
  const NexusRowValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: NexusPalette.of(context).textTertiary,
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
        // The iOS switch, in this app's accent — one accent, and it is the one
        // the row's label already uses for anything live.
        child: CupertinoSwitch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: NexusPalette.of(context).accent,
          inactiveTrackColor: NexusPalette.of(context).surfaceSecondary,
        ),
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
          CupertinoActivityIndicator(radius: 8, color: palette.onAccent)
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
