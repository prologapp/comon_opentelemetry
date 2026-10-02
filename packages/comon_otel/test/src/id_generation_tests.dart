part of '../comon_otel_test.dart';

Tracer _idTestTracer() {
  return TracerProvider(
    resource: Resource.empty(),
    spanProcessors: const <SpanProcessor>[],
    sampler: const AlwaysOnSampler(),
  ).getTracer('ids');
}

/// The id generation used before this change: one `Random.secure()` call
/// per byte (24 per span). Kept here only as the cost reference.
String _secureBytewiseHex(Random random, int length) {
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString().substring(0, length);
}

final RegExp _lowerHex = RegExp(r'^[0-9a-f]+$');

void defineIdGenerationTests() {
  group('trace and span ids', () {
    test('ids are lowercase hex of the right size and never all zero', () {
      final tracer = _idTestTracer();
      for (var i = 0; i < 1000; i++) {
        final root = tracer.startSpan('root-$i');
        final context = root.spanContext;
        expect(context.traceId, hasLength(32));
        expect(context.spanId, hasLength(16));
        expect(_lowerHex.hasMatch(context.traceId), isTrue);
        expect(_lowerHex.hasMatch(context.spanId), isTrue);
        expect(context.traceId, isNot('0' * 32));
        expect(context.spanId, isNot('0' * 16));
        expect(context.isValid, isTrue);
      }
    });

    test('random flag behavior is unchanged', () {
      final tracer = _idTestTracer();
      final root = tracer.startSpan('root');
      expect(root.spanContext.traceFlags.isRandom, isTrue);

      final child = tracer.startSpan('child', parent: root);
      expect(child.spanContext.traceId, root.spanContext.traceId);
      expect(child.spanContext.spanId, isNot(root.spanContext.spanId));
      expect(child.spanContext.traceFlags.isRandom, isTrue);

      final remoteParent = SpanContext(
        traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
        spanId: '00f067aa0ba902b7',
        sampled: true,
        isRemote: true,
      );
      final fromRemote = tracer.startSpan(
        'remote',
        parentContext: remoteParent,
      );
      expect(fromRemote.spanContext.traceFlags.isRandom, isFalse);
    });

    test('100k spans produce no colliding ids', () {
      final tracer = _idTestTracer();
      final traceIds = <String>{};
      final spanIds = <String>{};
      const count = 100000;
      for (var i = 0; i < count; i++) {
        final context = tracer.startSpan('s').spanContext;
        traceIds.add(context.traceId);
        spanIds.add(context.spanId);
      }
      expect(traceIds, hasLength(count));
      expect(spanIds, hasLength(count));
    });

    test('span start costs far less than per-byte secure id generation', () {
      final tracer = _idTestTracer();
      final secure = Random.secure();
      const rounds = 2000;

      // Warm-up both paths so neither is dominated by JIT.
      for (var i = 0; i < 200; i++) {
        tracer.startSpan('warm');
        _secureBytewiseHex(secure, 32);
        _secureBytewiseHex(secure, 16);
      }

      // Best of 5 runs per side: a process pause (GC, scheduler) during one
      // loop inflates that sample only, not the minimum. The measured margin
      // is ~600x; the bound required here is 5x.
      int bestOf5(void Function() body) {
        var best = 1 << 62;
        for (var r = 0; r < 5; r++) {
          final watch = Stopwatch()..start();
          body();
          watch.stop();
          if (watch.elapsedMicroseconds < best) {
            best = watch.elapsedMicroseconds;
          }
        }
        return best;
      }

      final referenceMicros = bestOf5(() {
        for (var i = 0; i < rounds; i++) {
          _secureBytewiseHex(secure, 32);
          _secureBytewiseHex(secure, 16);
        }
      });

      final startSpanMicros = bestOf5(() {
        for (var i = 0; i < rounds; i++) {
          tracer.startSpan('s');
        }
      });

      // A whole span start (ids included) must cost a fraction of what the
      // old id generation alone cost.
      expect(
        startSpanMicros,
        lessThan(referenceMicros / 5),
        reason:
            'startSpan: ${startSpanMicros}us vs per-byte secure ids: '
            '${referenceMicros}us for $rounds spans (best of 5)',
      );
    });
  });
}
