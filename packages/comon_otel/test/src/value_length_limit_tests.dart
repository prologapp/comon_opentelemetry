part of '../comon_otel_test.dart';

/// ~20 KiB stack trace, well above the default 4 KiB value limit.
final String _hugeStack = List<String>.generate(
  260,
  (i) =>
      '#$i      SomeWidgetState.build '
      '(package:app/feature/screens/x_screen.dart:${100 + i}:7)',
).join('\n');

const int _defaultValueLimit = 4096;

Future<void> _reinitWithLimits({
  SpanLimits spanLimits = const SpanLimits(),
  LogLimits logLimits = const LogLimits(),
}) async {
  await Otel.shutdown();
  await Otel.init(
    serviceName: 'value-limits-test',
    spanLimits: spanLimits,
    logLimits: logLimits,
    spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
    metricReaders: <MetricReader>[
      ExportingMetricReader(exporter: metricExporter),
    ],
    logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
  );
}

void _expectTruncatedTo(Object? value, int limit) {
  expect(value, isA<String>());
  final text = value! as String;
  expect(text.length, lessThanOrEqualTo(limit));
  expect(text, endsWith(attributeValueTruncationMarker));
}

void defineValueLengthLimitTests() {
  group('attribute value length limit', () {
    test('defaults to 4 KiB for span attributes, the exception event and '
        'the status description', () async {
      expect(_hugeStack.length, greaterThan(20 * 1024));
      final span = Otel.instance.tracer.startSpan(
        'huge',
        attributes: <String, Object>{'big': _hugeStack, 'small': 'ok'},
      );
      span.setAttribute('later', _hugeStack);
      span.recordException(
        StateError('boom'),
        stackTrace: StackTrace.fromString(_hugeStack),
      );
      span.setStatus(SpanStatus.error, description: _hugeStack);
      await span.end();

      final data = exporter.lastSpanNamed('huge')!;
      _expectTruncatedTo(data.attributes['big'], _defaultValueLimit);
      _expectTruncatedTo(data.attributes['later'], _defaultValueLimit);
      expect(data.attributes['small'], 'ok');
      _expectTruncatedTo(
        data.events.single.attributes[SemanticAttributes.exceptionStacktrace],
        _defaultValueLimit,
      );
      _expectTruncatedTo(data.statusDescription, _defaultValueLimit);
      expect(
        (data.attributes['big']! as String).startsWith(
          _hugeStack.substring(0, 100),
        ),
        isTrue,
      );
    });

    test('defaults to 4 KiB for log attributes and body', () async {
      Otel.instance.loggerProvider
          .getLogger('huge-logger')
          .error(
            _hugeStack,
            attributes: <String, Object>{'big': _hugeStack},
            error: StateError('boom'),
            stackTrace: StackTrace.fromString(_hugeStack),
          );
      await Otel.forceFlush();

      final log = logExporter.lastLogNamed('huge-logger')!;
      _expectTruncatedTo(log.body, _defaultValueLimit);
      _expectTruncatedTo(log.attributes['big'], _defaultValueLimit);
      _expectTruncatedTo(
        log.attributes[SemanticAttributes.exceptionStacktrace],
        _defaultValueLimit,
      );
      expect(
        log.attributes[SemanticAttributes.exceptionMessage],
        'Bad state: boom',
      );
    });

    test('truncates each string of a string list', () async {
      final span = Otel.instance.tracer.startSpan(
        'list',
        attributes: <String, Object>{
          'items': <String>[_hugeStack, 'short'],
        },
      );
      await span.end();

      final items =
          exporter.lastSpanNamed('list')!.attributes['items']! as List<Object?>;
      _expectTruncatedTo(items.first, _defaultValueLimit);
      expect(items.last, 'short');
    });

    test('custom limits passed to Otel.init reach spans and logs', () async {
      await _reinitWithLimits(
        spanLimits: const SpanLimits(attributeValueLengthLimit: 100),
        logLimits: const LogLimits(
          attributeValueLengthLimit: 50,
          bodyLengthLimit: 60,
        ),
      );
      expect(Otel.instance.config.spanLimits.attributeValueLengthLimit, 100);
      expect(Otel.instance.config.logLimits.attributeValueLengthLimit, 50);
      expect(Otel.instance.config.logLimits.bodyLengthLimit, 60);

      await Otel.instance.tracer
          .startSpan('custom', attributes: <String, Object>{'big': _hugeStack})
          .end();
      Otel.instance.loggerProvider
          .getLogger('custom-logger')
          .info(_hugeStack, attributes: <String, Object>{'big': _hugeStack});
      await Otel.forceFlush();

      _expectTruncatedTo(
        exporter.lastSpanNamed('custom')!.attributes['big'],
        100,
      );
      final log = logExporter.lastLogNamed('custom-logger')!;
      _expectTruncatedTo(log.attributes['big'], 50);
      _expectTruncatedTo(log.body, 60);
    });

    test('null disables the limit', () async {
      await _reinitWithLimits(
        spanLimits: const SpanLimits(attributeValueLengthLimit: null),
        logLimits: const LogLimits(
          attributeValueLengthLimit: null,
          bodyLengthLimit: null,
        ),
      );

      await Otel.instance.tracer
          .startSpan(
            'unlimited',
            attributes: <String, Object>{'big': _hugeStack},
          )
          .end();
      Otel.instance.loggerProvider
          .getLogger('unlimited-logger')
          .info(_hugeStack);
      await Otel.forceFlush();

      expect(
        exporter.lastSpanNamed('unlimited')!.attributes['big'],
        _hugeStack,
      );
      expect(logExporter.lastLogNamed('unlimited-logger')!.body, _hugeStack);
    });

    test('never splits a surrogate pair', () async {
      await _reinitWithLimits(
        spanLimits: const SpanLimits(attributeValueLengthLimit: 20),
      );
      // Each emoji is two UTF-16 code units.
      final emojis = List<String>.filled(20, '\u{1F600}').join();
      await Otel.instance.tracer
          .startSpan('emoji', attributes: <String, Object>{'e': emojis})
          .end();

      final value = exporter.lastSpanNamed('emoji')!.attributes['e']! as String;
      _expectTruncatedTo(value, 20);
      final kept = value.substring(
        0,
        value.length - attributeValueTruncationMarker.length,
      );
      expect(kept.length.isEven, isTrue);
      expect(kept.runes.every((rune) => rune == 0x1F600), isTrue);
    });
  });
}
