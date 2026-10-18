// The file behind the on-device brain: `model.gguf`, in this app's documents.
//
// A language model is not a setting and not a stream — it is 470 MB of weights
// the user chose to put on their phone, and everything that touches it needs
// the same three answers: is it here, where is it, and how do I get rid of it.
// Those answers live in one place because three surfaces ask them — the brain
// (which refuses to answer without it), the Settings row (which reports it),
// and the download button (which writes it).
//
// The path is deliberately boring: `Documents/<choice>.gguf`. Not a cache
// directory (a 470 MB download must survive a restart, and a cache is not
// promised to), and not a per-model folder — two files in one directory is what
// "two models" is, and the picker needs to ask about both without walking a
// tree. The first model's file is the fixed `model.gguf` it has always been, so
// a phone that already downloaded it is not asked to do it again.
//
// Which of the two is *selected* is [ModelChoice]: a preference, shared through
// a [ChangeNotifier], because three surfaces need the same answer — the picker
// that changes it, the status row that reports it, and the brain that loads it.
//
// The bytes are *not* fetched here: [Llm] already owns download-and-verify —
// stream to `.part`, hash the stream, rename only on a match — and a second
// implementation of that rule would be a second way to end up with a half
// model on disk. [OnDeviceModel.download] is that one implementation, pointed
// at this file.
library;

import 'dart:io';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm.dart';

/// The name every part of the app means when it says "the on-device model".
///
/// The Qwen weights' file keeps this name rather than being renamed after
/// itself, because renaming it would turn every phone that already downloaded
/// 470 MB into a phone that has to download it again. The second model is named
/// after its own weights; see [OnDeviceModelChoice.fileName].
const String kOnDeviceModelFileName = 'model.gguf';

/// The model the on-device brain loads by default: the same Qwen2.5 0.5B
/// Q4_K_M weights the first-run download already fetches (see [kPhoneModel]),
/// under the file name this app promises the user. Same URL, same hash, same
/// bytes — only the name differs, because [Llm] names its cache file after the
/// model and the user-facing file is `model.gguf`.
///
/// `final` rather than `const`: three of its four fields are read off
/// [kPhoneModel], and a constant cannot read a property off another constant.
/// One place — `llm.dart` — still pins the URL, the hash and the size.
final LlmModel kOnDeviceLlmModel = LlmModel(
  name: 'model',
  url: kPhoneModel.url,
  sha256: kPhoneModel.sha256,
  bytes: kPhoneModel.bytes,
);

/// The two models this app offers, in the order the manager lists them.
///
/// Two rather than one because the small model is not the right model for every
/// job: 470 MB answers a question in a couple of seconds on a phone, and a 0.5B
/// model drops formatting rules — the action JSON above all — the moment the
/// instruction stops being the whole prompt. The 1B is 770 MB and slow enough to
/// notice, and it follows instructions.
///
/// The file name follows the weights for everything except the first model, and
/// the reason is migration rather than taste: [kOnDeviceModelFileName] is the
/// name every installed phone already holds.
enum OnDeviceModelChoice {
  qwen(
    id: 'qwen2.5-0.5b',
    label: 'Qwen 2.5 0.5B',
    blurb: 'Fastest. Small enough to miss the action JSON now and then.',
    fileName: kOnDeviceModelFileName,
  ),
  llama(
    id: 'llama-3.2-1b',
    label: 'Llama 3.2 1B',
    blurb: 'Bigger and smarter — better at following the action JSON.',
    fileName: 'llama-3.2-1b-instruct-q4_k_m.gguf',
  );

  const OnDeviceModelChoice({
    required this.id,
    required this.label,
    required this.blurb,
    required this.fileName,
  });

  /// What is stored in preferences. Stable: a build that renames a model must
  /// keep reading the id old installs wrote.
  final String id;

  /// What the user reads in the picker.
  final String label;

  /// One line under it saying what the choice costs and buys.
  final String blurb;

  /// The file these weights live in, in this app's documents.
  ///
  /// A string rather than a [LlmModel.name] because the first model's file has
  /// to keep the name every installed phone already holds.
  final String fileName;

  /// The weights behind this choice.
  ///
  /// A getter rather than a const field, because the first model's [LlmModel]
  /// borrows its URL, hash and size from [kPhoneModel] and a constant cannot
  /// read a property off another constant. One place still pins the bytes.
  LlmModel get weights => switch (this) {
    OnDeviceModelChoice.qwen => kOnDeviceLlmModel,
    OnDeviceModelChoice.llama => kLlamaModel,
  };

  /// The download's size in bytes — what the picker and the progress row quote.
  int get bytes => weights.bytes;

  /// That size in megabytes, rounded up, the way every other row says it.
  int get megabytes => weights.megabytes;

  /// The choice a stored [id] names, or null for anything else — a preference
  /// written by a build that had a model this one does not.
  static OnDeviceModelChoice? byId(String? id) {
    for (final OnDeviceModelChoice choice in values) {
      if (choice.id == id) return choice;
    }
    return null;
  }
}

/// Storage behind the selection: one string in preferences on a phone, memory
/// in a test.
abstract class ModelChoiceStore {
  Future<String?> read();

  Future<void> write(String id);
}

/// The store a test uses. Starts empty unless it is given a value.
class MemoryModelChoiceStore implements ModelChoiceStore {
  MemoryModelChoiceStore([this._id]);

  String? _id;

  @override
  Future<String?> read() async => _id;

  @override
  Future<void> write(String id) async => _id = id;
}

/// The store the app uses: one preference, the model's [OnDeviceModelChoice.id].
///
/// A missing or unreadable store is not an error — the app opens on the small
/// model, which is the one a fresh install has anyway.
class PrefsModelChoiceStore implements ModelChoiceStore {
  /// The key the choice is stored under.
  static const String key = 'on_device_model';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('MODEL: no preferences store ($error)');
      return null;
    }
  }

  @override
  Future<String?> read() async => (await _instance())?.getString(key);

  @override
  Future<void> write(String id) async {
    await (await _instance())?.setString(key, id);
  }
}

/// Which model the app is set to run, and the one place that changes.
///
/// A [ChangeNotifier] for the same reason [ChatLog] and [PairedDevices] are:
/// the Settings picker, the status row and the brain all need the same answer,
/// and a second copy of it would be a second answer.
class ModelChoice extends ChangeNotifier {
  ModelChoice({
    ModelChoiceStore? store,
    OnDeviceModelChoice initial = OnDeviceModelChoice.qwen,
  }) : _store = store ?? PrefsModelChoiceStore(),
       _choice = initial;

  /// Test seam, in the shape the rest of the app uses: a widget test states
  /// which model is selected instead of touching the preferences plugin.
  @visibleForTesting
  static ModelChoice Function()? override;

  static ModelChoice? _instance;

  /// The app-wide selection. Built once: two of these would disagree about
  /// which file the brain should load.
  static ModelChoice get instance =>
      override?.call() ?? (_instance ??= ModelChoice());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final ModelChoiceStore _store;
  OnDeviceModelChoice _choice;
  Future<void>? _loading;

  /// The model the app is set to run. Qwen until a stored answer says otherwise.
  OnDeviceModelChoice get choice => _choice;

  /// Reads the stored choice, once. Every caller may await it — the brain does
  /// before it looks for a file, Settings before it draws the picker — and the
  /// second call costs nothing.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final String? id = await _store.read();
    final OnDeviceModelChoice? stored = OnDeviceModelChoice.byId(id);
    if (stored == null || stored == _choice) return;
    _choice = stored;
    notifyListeners();
  }

  /// Switches to [choice], now and after a restart.
  ///
  /// The notification comes before the write because the screen that asked is
  /// waiting on it: a picker that changes the file but not the row until the
  /// disk catches up is a picker that looks broken for a frame.
  Future<void> select(OnDeviceModelChoice choice) async {
    if (choice == _choice) return;
    _choice = choice;
    notifyListeners();
    await _store.write(choice.id);
  }
}

/// Reads and manages the model selected in [ModelChoice], or one named
/// explicitly — which is what the picker needs to ask about both.

/// Where `model.gguf` lives.
///
/// The directory is a function, not a string, because it cannot be known until
/// the platform answers (and because a test must be able to point it at a temp
/// directory without a platform channel). [debugDirectoryOverride] is the test
/// seam: the app never sets it.
class OnDeviceModel {
  const OnDeviceModel({
    LlmModel? model,
    OnDeviceModelChoice? choice,
    this.directory,
    this.engine,
  }) : _weights = model,
       _explicitChoice = choice;

  /// Null means the model the app ships: [kOnDeviceLlmModel]. It is not a
  /// default value because a default must be const and the weights are borrowed
  /// from [kPhoneModel] rather than copied — one place pins the URL and hash.
  final LlmModel? _weights;

  /// The choice this object is about, or null for "whichever is selected now".
  ///
  /// Null is the right default for the brain: it is asked for the *current*
  /// model on every question, and a choice captured when the app started would
  /// keep loading the old file after the user switched.
  final OnDeviceModelChoice? _explicitChoice;

  /// The choice this object speaks for: its own, or the selected one.
  OnDeviceModelChoice get choice =>
      _explicitChoice ?? ModelChoice.instance.choice;

  /// This same model — same directory, same fetcher — for [other].
  ///
  /// How the picker asks "is *that* one downloaded" without losing the test's
  /// temp directory or fake fetcher.
  OnDeviceModel withChoice(OnDeviceModelChoice other) => OnDeviceModel(
    choice: other,
    directory: directory,
    engine: engine,
  );

  /// Where to look, or null for the app's own documents directory.
  final Future<Directory> Function()? directory;

  /// The fetcher, or null for the real one: an [Llm] over [model] writing into
  /// [directoryFor]. A test points this at an [Llm] whose download reports
  /// progress without a socket, so the progress bar can be walked in a widget
  /// test as well as measured on the wire.
  final Llm Function()? engine;

  /// The weights this file is expected to be.
  LlmModel get model => _weights ?? choice.weights;

  /// What the user reads where this model is named.
  ///
  /// The choice's own label for the things the user picked, and the weights' for
  /// a model a test made up.
  String get label => _weights != null ? _weights.label : choice.label;

  /// The file these weights live in.
  String get fileName => _weights != null ? '${_weights.name}.gguf' : choice.fileName;

  /// A test seam: a widget or unit test points the model at a temp directory.
  /// Set by tests only, and always restored.
  static Future<Directory> Function()? debugDirectoryOverride;

  /// The directory holding `model.gguf` — and the one [Llm] downloads into.
  Future<Directory> directoryFor() async {
    final chosen = directory;
    if (chosen != null) return chosen();
    final override = debugDirectoryOverride;
    if (override != null) return override();
    return getApplicationDocumentsDirectory();
  }

  /// The file itself, whether or not it exists.
  ///
  /// Named after the choice ([fileName]), which is `model.gguf` for the model
  /// the app shipped first — the name every installed phone already has.
  Future<File> file() async =>
      File('${(await directoryFor()).path}/$fileName');

  /// True when a model file is on disk.
  ///
  /// Presence, not integrity: a verified download only ever renames a complete,
  /// hashed file into place, so a file here is a model. An empty file is the
  /// one shape that is never useful, and it is also what a half-written copy
  /// looks like — it does not count. Never throws: a status row may not break
  /// the screen because a platform channel is missing.
  Future<bool> isPresent() async {
    try {
      final modelFile = await file();
      return modelFile.existsSync() && modelFile.lengthSync() > 0;
    } on Object catch (e) {
      debugPrint('MODEL: no documents directory ($e)');
      return false;
    }
  }

  /// The bytes the file occupies, or 0 when there is no file.
  Future<int> sizeBytes() async {
    try {
      final modelFile = await file();
      return modelFile.existsSync() ? modelFile.lengthSync() : 0;
    } on Object catch (e) {
      debugPrint('MODEL: no model size ($e)');
      return 0;
    }
  }

  /// Fetches the model into [directoryFor] unless it is already there, reporting
  /// progress from 0 to 1, and answers true only when a verified file is on
  /// disk. Never throws: a download that failed is a false and a sentence the
  /// caller chooses, not an exception on its way to a crash reporter.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    final llm = engine?.call() ??
        Llm(model: model, modelsDir: directoryFor);
    try {
      return await llm.download(onProgress: onProgress);
    } finally {
      // This Llm exists only to fetch; nothing was asked of a runtime.
      await llm.dispose();
    }
  }

  /// Deletes the model — and any `.part` a killed download left behind — and
  /// answers how many bytes that freed. Missing is not an error: a delete that
  /// has nothing to delete has already done its job.
  Future<int> delete() async {
    var freed = 0;
    try {
      final modelFile = await file();
      final part = File('${modelFile.path}.part');
      for (final target in <File>[modelFile, part]) {
        if (target.existsSync()) {
          freed += target.lengthSync();
          target.deleteSync();
        }
      }
    } on Object catch (e) {
      debugPrint('MODEL: could not delete the model ($e)');
    }
    return freed;
  }
}
