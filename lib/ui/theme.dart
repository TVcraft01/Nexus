import 'package:flutter/material.dart';

import 'nexus_v2/design_system.dart';

/// Compatibility bridge for legacy UI components that still reference the
/// original NexusColors names. New UI uses NexusV2Colors directly.
class NexusColors {
  static const bg = NexusV2Colors.background;
  static const surface = NexusV2Colors.surface;
  static const surfaceHi = NexusV2Colors.elevated;
  static const border = NexusV2Colors.separator;
  static const text = NexusV2Colors.primaryText;
  static const muted = NexusV2Colors.secondaryText;
  static const accent = NexusV2Colors.accent;
  static const accentStrong = NexusV2Colors.accent;
  static const ok = NexusV2Colors.positive;
  static const warn = NexusV2Colors.warning;
  static const danger = NexusV2Colors.destructive;
}

ThemeData buildNexusTheme() => buildNexusV2Theme(brightness: Brightness.dark);
