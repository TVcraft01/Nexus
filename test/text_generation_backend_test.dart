import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/ncm_backend.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/text_generation_backend.dart';

class _FakeBackend implements TextGenerationBackend {
  _FakeBackend({this.chunks = const <String>['fake', ' ', 'answer']});

  final List<String> chunks;
  String? lastPrompt;
  List<AiTurn>? lastHistory;

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) async* {
    lastPrompt = prompt;
    lastHistory = history;
    for (final String chunk in chunks) {
      yield chunk;
    }
  }
}

void main() {
  group('TextGenerationBackend', () {
    test('NcmBackend throws UnimplementedError', () {
      const NcmBackend backend = NcmBackend();
      expect(
        () => backend.generateStream('hello'),
        throwsA(
          isA<UnimplementedError>().having(
            (UnimplementedError e) => e.message,
            'message',
            'NCM backend is not yet available on this device.',
          ),
        ),
      );
    });

    test('OnDeviceAiService delegates to custom TextGenerationBackend', () async {
      final _FakeBackend fake = _FakeBackend(chunks: const <String>['hello', ' ', 'world']);
      final OnDeviceAiService service = OnDeviceAiService(backend: fake);

      final List<String> pieces = <String>[];
      await service.generateResponseStream('test prompt').forEach(pieces.add);

      expect(pieces, <String>['hello', ' ', 'world']);
      expect(fake.lastPrompt, 'test prompt');
    });

    test('OnDeviceAiService generateResponse buffers backend stream', () async {
      final _FakeBackend fake = _FakeBackend(chunks: const <String>['one', ' ', 'two']);
      final OnDeviceAiService service = OnDeviceAiService(backend: fake);

      final String answer = await service.generateResponse('test prompt');
      expect(answer, 'one two');
    });

    test('HiveRouter and FallbackAiService implement TextGenerationBackend', () {
      final _FakeBackend fake = _FakeBackend();
      final OnDeviceAiService onDevice = OnDeviceAiService(backend: fake);
      final HiveRouter router = HiveRouter(onDevice: onDevice, pc: onDevice);
      expect(router, isA<TextGenerationBackend>());

      final FallbackAiService fallback = FallbackAiService(onDevice: onDevice, pc: onDevice);
      expect(fallback, isA<TextGenerationBackend>());
    });
  });
}
