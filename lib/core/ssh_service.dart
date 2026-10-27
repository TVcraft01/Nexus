// The one place Nexus opens an SSH connection.
//
// A server is not a paired device: there is no discovery, no code, and no
// shared key — only a login the user already has. So this is deliberately a
// small, dumb pipe: it connects, it runs one command at a time, and it reports
// what came back. It never reads a command from a model. The commands it runs
// come from [server_playbooks.dart], which is the only list in the app that
// holds shell text, and the page that calls this refuses anything not on it.
//
// Output is streamed rather than collected: a first `docker pull` takes
// minutes, and a screen that shows nothing for minutes reads as broken. Each
// command therefore yields its lines as they arrive, then one [SshExit] with
// the code the far end reported.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:dartssh2/dartssh2.dart';

/// Where a server is and who to log in as.
class SshTarget {
  const SshTarget({
    required this.host,
    required this.username,
    required this.password,
    this.port = 22,
  });

  /// A hostname or an IP address. No scheme, no path: this is passed to a
  /// socket, not to a URL parser.
  final String host;
  final int port;
  final String username;
  final String password;

  /// How the user recognises the server in a line of text.
  String get label => '$username@$host';
}

/// One thing a running command said, or the fact that it finished.
sealed class SshOutput {
  const SshOutput();
}

/// A line of stdout, stderr, or the shell's own banner. `\r` is stripped, so a
/// terminal widget can lay text out without re-deciding what a newline is.
class SshLine extends SshOutput {
  const SshLine(this.text);

  final String text;
}

/// The command exited. [code] is null when the server did not report one — a
/// connection dropped mid-command, or an implementation that never sends it.
class SshExit extends SshOutput {
  const SshExit(this.code);

  final int? code;
}

/// A failure worth a sentence rather than a stack trace: unreachable host,
/// refused login, a command the server would not start.
class SshFailure implements Exception {
  const SshFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The seam the page and its tests talk to. [SshService] is the real one; a
/// fake can hand back whatever it likes without a network or a server.
abstract class SshRunner {
  /// The server this runner speaks to.
  SshTarget get target;

  /// Runs [command] and streams its output, ending with one [SshExit].
  Stream<SshOutput> run(String command);

  /// Drops the connection. Safe to call twice, and safe on a never-connected
  /// runner.
  Future<void> close();
}

/// How a caller reaches a server. The page takes one of these so a test can
/// swap the real connection for a fake without a network or a password.
typedef SshConnector = Future<SshRunner> Function(SshTarget target);

/// The real connection, over [SSHClient].
class SshService implements SshRunner {
  SshService(this.target);

  @override
  final SshTarget target;

  SSHClient? _client;

  /// Connects once, then reuses the connection for every command in a playbook.
  /// A handshake per command would be three round trips too many on a home
  /// network, and the keys the server offers do not change between them.
  Future<SSHClient> _connected() async {
    final SSHClient? live = _client;
    if (live != null) return live;

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        target.host,
        target.port,
        timeout: const Duration(seconds: 10),
      );
    } on SocketException catch (error) {
      throw SshFailure(
        'Could not reach ${target.host} on port ${target.port}: '
        '${error.osError?.message ?? error.message}',
      );
    } on TimeoutException {
      throw SshFailure(
        'Timed out connecting to ${target.host}:${target.port}. Is the server '
        'awake and is SSH open on that port?',
      );
    }

    final SSHClient client = SSHClient(
      socket,
      username: target.username,
      // A password the user typed a moment ago. Keys are not offered yet: the
      // page asks for a password, and pretending to support a key it cannot
      // read would be a lie the first server with `PasswordAuthentication no`
      // would expose.
      onPasswordRequest: () => target.password,
      handshakeTimeout: const Duration(seconds: 15),
    );

    try {
      await client.authenticated;
    } on SSHAuthFailError {
      client.close();
      throw const SshFailure('The server refused that username and password.');
    } on SSHError catch (error) {
      client.close();
      throw SshFailure('The SSH handshake failed: $error');
    }

    return _client = client;
  }

  @override
  Stream<SshOutput> run(String command) async* {
    final SSHClient client = await _connected();

    final SSHSession session;
    try {
      // A pty merges stderr into stdout and keeps the order the far end wrote
      // them in, which is what a terminal view is supposed to show. It also
      // lets a command that happens to ask a question print its prompt instead
      // of hanging silently — nothing here answers one.
      session = await client.execute(
        command,
        pty: const SSHPtyConfig(width: 200, height: 50),
      );
    } on SSHError catch (error) {
      throw SshFailure('The server would not run that command: $error');
    }

    // utf8.decoder rather than decoding each chunk: a multi-byte character is
    // allowed to straddle a packet boundary, and decoding chunks separately
    // would turn it into replacement characters.
    final StringBuffer pending = StringBuffer();
    // `cast<List<int>>` because the decoder takes bytes, not the narrower
    // Uint8List the session happens to hand over.
    final Stream<String> decoded = session.stdout.cast<List<int>>().transform(
      const Utf8Decoder(allowMalformed: true),
    );
    await for (final String text in decoded) {
      pending.write(text);
      String rest = pending.toString();
      int newline = rest.indexOf('\n');
      while (newline >= 0) {
        yield SshLine(_clean(rest.substring(0, newline)));
        rest = rest.substring(newline + 1);
        newline = rest.indexOf('\n');
      }
      pending
        ..clear()
        ..write(rest);
    }

    final String tail = pending.toString();
    if (tail.isNotEmpty) yield SshLine(_clean(tail));

    await session.done;
    yield SshExit(session.exitCode);
  }

  @override
  Future<void> close() async {
    final SSHClient? client = _client;
    _client = null;
    if (client == null) return;
    client.close();
    // The socket's own close is asynchronous, and a test that ends the process
    // before it lands is a flaky test rather than a leak.
    await client.done.catchError((Object _) {});
  }

  /// Strips the carriage return a pty puts before every newline.
  static String _clean(String line) {
    final int end = line.endsWith('\r') ? line.length - 1 : line.length;
    return line.substring(0, end);
  }
}
