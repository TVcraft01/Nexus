// The file behind the on-device brain: `model.gguf`, in this app's documents.
//
// A language model is not a setting and not a stream — it is 470 MB of weights
// the user chose to put on their phone, and everything that touches it needs
// the same three answers: is it here, where is it, and how do I get rid of it.
// Those answers live in one place because three surfaces ask them — the brain
// (which refuses to answer without it), the Settings row (which reports it),
// and the download button (which writes it).
//
// The path is deliberately boring and fixed: `Documents/model.gguf`. Not a
// cache directory (a 470 MB download must survive a restart, and a cache is not
// promised to), not a per-model folder (the app ships one model, and a second
// would be a different feature, not a second filename).
//
// The bytes are *not* fetched here: [Llm] already owns download-and-verify —
// stream to `.part`, hash the stream, rename only on a match — and a second
// implementation of that rule would be a second way to end up with a half
// model on disk. [OnDeviceModel.download] is that one implementation, pointed
// at this file.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'llm.dart';

/// The name every part of the app means when it says "the on-device model".
const String kOnDeviceModelFileName = 'model.gguf';

/// The model the on-device brain loads: the same Qwen2.5 0.5B Q4_K_M weights
/// the first-run download already fetches (see [kPhoneModel]), under the file
/// name this app promises the user. Same URL, same hash, same bytes — only the
/// name differs, because [Llm] names its cache file after the model and the
/// user-facing file is `model.gguf`.
final LlmModel kOnDeviceLlmModel = LlmModel(
  name: 'model',
  url: kPhoneModel.url,
  sha256: kPhoneModel.sha256,
  bytes: kPhoneModel.bytes,
);

/// Where `model.gguf` lives.
///
/// The directory is a function, not a string, because it cannot be known until
/// the platform answers (and because a test must be able to point it at a temp
/// directory without a platform channel). [debugDirectoryOverride] is the test
/// seam: the app never sets it.
class OnDeviceModel {
  const OnDeviceModel({LlmModel? model, this.directory, this.engine})
    : _weights = model;

  /// Null means the model the app ships: [kOnDeviceLlmModel]. It is not a
  /// default value because a default must be const and the weights are borrowed
  /// from [kPhoneModel] rather than copied — one place pins the URL and hash.
  final LlmModel? _weights;

  /// Where to look, or null for the app's own documents directory.
  final Future<Directory> Function()? directory;

  /// The fetcher, or null for the real one: an [Llm] over [model] writing into
  /// [directoryFor]. A test points this at an [Llm] whose download reports
  /// progress without a socket, so the progress bar can be walked in a widget
  /// test as well as measured on the wire.
  final Llm Function()? engine;

  /// The weights this file is expected to be.
  LlmModel get model => _weights ?? kOnDeviceLlmModel;

  /// What the user reads where this model is named.
  ///
  /// The file name is fixed (`model.gguf`), so the weights' own name cannot be
  /// borrowed for display; this says which weights those are. A test model
  /// names itself.
  String get label =>
      identical(model, kOnDeviceLlmModel) ? kPhoneModel.label : model.label;

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
  Future<File> file() async =>
      File('${(await directoryFor()).path}/$kOnDeviceModelFileName');

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
