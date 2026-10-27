// The only shell text in Nexus.
//
// Everything the Server Agent can do on a remote machine is written here, by a
// human, as a list of commands with a name. The model never composes a command
// and never sees a shell: when the user asks for a server, the sentence is
// matched against [kServerPlaybooks] and the *playbook's* commands run. That is
// the safety rule this feature is built around — an assistant that can write
// `rm -rf` on a machine you own because a sentence looked like permission is
// not an assistant, it is an incident.
//
// So adding a capability means adding a playbook here, with its commands
// readable in the review diff, not teaching the matcher new verbs.
//
// The commands are allowed to use `sudo` because they are part of a pre-approved
// list; nothing outside this file may. They use `sudo -n` on purpose: on a
// server without passwordless sudo they fail with a sentence instead of hanging
// on a password prompt nothing can answer.
library;

/// One thing Nexus knows how to set up on a server.
class Playbook {
  const Playbook({
    required this.id,
    required this.title,
    required this.description,
    required this.commands,
  });

  /// Stable name, used by the matcher and by tests that name a playbook rather
  /// than a sentence.
  final String id;

  /// The title on the card and in the confirmation dialog.
  final String title;

  /// What it will do, in the user's terms — including anything it agrees to on
  /// their behalf, because a confirmation that hides a licence click is not a
  /// confirmation.
  final String description;

  /// The exact bash commands, in order. Shown verbatim in the confirmation
  /// dialog: the user approves these strings, not a summary of them.
  final List<String> commands;
}

/// The Minecraft Java server, run as a container so the host stays clean.
const Playbook setupMinecraft = Playbook(
  id: 'setup_minecraft',
  title: 'Minecraft server',
  description:
      'Installs Docker if the server does not have it, then runs a Minecraft '
      'Java server on port 25565 with the world kept in a volume. Accepts the '
      'Minecraft EULA (@EULA=TRUE) on your behalf. Needs a user with '
      'passwordless sudo or docker access.',
  commands: <String>[
    // Docker, only when it is missing. The official script is the one install
    // path that works across every distribution this app can be pointed at.
    'command -v docker >/dev/null 2>&1 || '
        '(curl -fsSL https://get.docker.com | sudo -n sh)',
    'sudo -n docker pull itzg/minecraft-server:latest',
    // A second run replaces the container but not the world: the world lives in
    // the named volume below, which outlives the container.
    'sudo -n docker rm -f nexus-minecraft >/dev/null 2>&1 || true',
    'sudo -n docker run -d --name nexus-minecraft --restart unless-stopped '
        '-p 25565:25565 -e EULA=TRUE -e MEMORY=2G '
        '-v nexus-minecraft-data:/data itzg/minecraft-server:latest',
    // The last line the terminal shows is the container's own status, so a
    // green "Up" is the far end's answer rather than this app's hope.
    'sudo -n docker ps --filter name=nexus-minecraft --format "{{.Status}}"',
  ],
);

/// Everything the Server Agent knows. One entry today; the list is the contract
/// the UI and the matcher both read.
const List<Playbook> kServerPlaybooks = <Playbook>[setupMinecraft];

/// What the page says when a sentence is not a playbook. Pinned in one place so
/// the page and its test cannot drift apart.
const String kNoPlaybookText =
    'Nexus can set up a Minecraft server on a Linux server today. Say "make a '
    'Minecraft server" — it will show you the exact commands first.';

/// The words that make a sentence about Minecraft.
final RegExp _minecraft = RegExp(r'\bminecraft\b', caseSensitive: false);

/// A server, or the shape of the thing being asked for.
final RegExp _server = RegExp(r'\bservers?\b', caseSensitive: false);

/// An intent verb. "I played Minecraft" is a remark and matches nothing; "make
/// a Minecraft server" names what to build.
final RegExp _verb = RegExp(
  r'\b(make|build|create|set\s?up|setup|install|host|run|deploy|start|'
  r'spin\s?up|provision)\b',
  caseSensitive: false,
);

/// The playbook [text] asks for, or null when it asks for nothing this app can
/// do.
///
/// A regex rather than a model on purpose: the fast path exists so a request to
/// build something does not spend four seconds in a token stream first, and a
/// matcher with three patterns is auditable in a way a prompt is not.
Playbook? playbookForIntent(String text) {
  final String sentence = text.trim();
  if (sentence.isEmpty) return null;
  if (!_minecraft.hasMatch(sentence)) return null;
  if (!_server.hasMatch(sentence) && !_verb.hasMatch(sentence)) return null;
  return setupMinecraft;
}
