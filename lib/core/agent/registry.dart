// Every tool the agent may name, in one place.
//
// The registry is the boundary the planner cannot cross: a plan naming a name
// that is not here is rejected whole, not skipped, and the catalogue it prints
// is the exact list the model is shown. Registration refuses a tool that makes
// a change it cannot undo — that rule is what makes `change` and `destructive`
// mean something at the executor later.
import 'risk.dart';
import 'tool.dart';

class ToolRegistry {
  ToolRegistry([Iterable<Tool> tools = const <Tool>[]]) {
    tools.forEach(register);
  }

  final Map<String, Tool> _tools = <String, Tool>{};

  /// Adds [tool], or throws when the name is taken or the tool makes a change
  /// it cannot put back.
  ///
  /// Throwing at startup is deliberate: a half-reversible tool that slipped
  /// through would be a `change` step the executor could not unwind, and the
  /// failure would land on the user instead of on the developer who wired it.
  void register(Tool tool) {
    if (_tools.containsKey(tool.name)) {
      throw StateError('two tools are named ${tool.name}');
    }
    if (tool.risk != RiskTier.read && !tool.reversible) {
      throw StateError(
        '${tool.name} is ${tool.risk.name} but has no rollback, so it may not '
        'be registered above read',
      );
    }
    _tools[tool.name] = tool;
  }

  Tool? lookup(String name) => _tools[name.trim()];

  bool has(String name) => _tools.containsKey(name.trim());

  List<Tool> get tools => List<Tool>.unmodifiable(_tools.values);

  List<String> get names => _tools.keys.toList(growable: false);

  /// The tool list the planner is shown, sorted so the prompt is stable.
  String catalogue() {
    final sorted = [..._tools.values]..sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final tool in sorted)
        '- ${tool.declaration}\n  ${tool.description} [${tool.risk.label}]',
    ].join('\n');
  }
}
