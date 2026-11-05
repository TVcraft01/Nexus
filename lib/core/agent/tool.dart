// What a tool is, from the agent core's side.
//
// The model is told the tools' names, arguments and descriptions; nothing else
// about a tool is the model's to decide. [risk] is declared here, once, and the
// executor reads it off the registered tool — a step can never carry a tier the
// model wrote. [reversible] is what makes a tier above reading registrable at
// all: a tool that cannot put its change back has no business making one.
//
// `run` says what happened in plain words (the sentence a report reuses),
// `verify` reads the change back off the device, and `rollback` returns the
// closure that puts it back — the closure, not the result, because the executor
// stores it on the step at validation time and calls it later, newest-first.
import 'risk.dart';
import 'rollback.dart';
import 'verification.dart';

/// The types an argument may have. Three is enough for the tools this core
/// runs, and a closed set is what lets the validator check a plan before the
/// user sees it.
enum ArgType { text, flag, whole }

class ToolArg {
  const ToolArg(this.type, {this.required = true, this.example = ''});

  final ArgType type;
  final bool required;

  /// An example value, shown to the model in the tool's declaration.
  final String example;
}

abstract class Tool {
  /// The registered name. Lower snake case, and the only thing a plan may
  /// name.
  String get name;

  /// One sentence: what it does, in the user's terms.
  String get description;

  /// The tier this tool's steps are. Never supplied by the model.
  RiskTier get risk;

  /// Every argument it takes, with its type and whether it is required.
  Map<String, ToolArg> get args;

  /// Whether [rollback] really restores the previous state. A tool above
  /// [RiskTier.read] that is not reversible is refused at registration.
  bool get reversible => false;

  /// What would change, in plain words, before anything is touched.
  ///
  /// Defaults to the description: a tool that has nothing to preview says what
  /// it does.
  Future<String> dryRun(Map<String, Object?> args) async => description;

  /// Does the work. The sentence returned is what the report reuses, so it
  /// says what happened — not what was attempted.
  Future<String> run(Map<String, Object?> args);

  /// Reads the change back off the device.
  Future<VerificationResult> verify(Map<String, Object?> args);

  /// A closure that puts this step back, or null when the tool cannot.
  ///
  /// Called at validation time with the step's arguments; it is expected to
  /// read the before-state when it runs, so the executor can call it after the
  /// fact.
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      null;

  /// The device a destructive step must name in its description.
  ///
  /// Defaults to the step's `device` argument: a destructive step about a
  /// named machine has to say which machine in the words the user reads, and
  /// this is how the validator finds the name to look for.
  String? deviceName(Map<String, Object?> args) {
    final Object? value = args['device'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  /// One line for the planner's prompt: `name {"arg": "example"}`.
  String get declaration {
    final parts = <String>[
      for (final entry in args.entries)
        '"${entry.key}": ${_exampleJson(entry.value)}',
    ];
    return '$name {${parts.join(', ')}}';
  }

  static String _exampleJson(ToolArg arg) => switch (arg.type) {
    ArgType.text => '"${arg.example.isEmpty ? 'text' : arg.example}"',
    ArgType.flag => arg.example.isEmpty ? 'true' : arg.example,
    ArgType.whole => arg.example.isEmpty ? '0' : arg.example,
  };
}

/// A tool saying no before it touched anything.
///
/// Distinct from an error on purpose: nothing was changed, so there is nothing
/// to unwind, and the reason is a rule the user can read (a hotspot this PC
/// must not reconfigure, a CI run in progress, a value that is not one this
/// setting accepts) rather than a failure of the work itself.
class ToolRefused implements Exception {
  const ToolRefused(this.message);

  final String message;

  @override
  String toString() => 'ToolRefused($message)';
}
