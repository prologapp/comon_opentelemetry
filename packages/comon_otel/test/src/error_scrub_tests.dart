part of '../comon_otel_test.dart';

/// URL whose path carries a CPF and whose query carries an S3 signature —
/// the two things that must never reach the backend.
const String _leakyUrl =
    'https://bucket.s3.amazonaws.com/colaboradores/12345678900/foto.jpg'
    '?X-Amz-Signature=deadbeefcafe&X-Amz-Credential=AKIA#frag';

/// Fragments of [_leakyUrl] that must not survive scrubbing.
const List<String> _leakyFragments = <String>[
  '12345678900',
  'colaboradores',
  'foto.jpg',
  'X-Amz-Signature',
  'deadbeefcafe',
  'AKIA',
  '#frag',
];

final class _UrlInMessageError implements Exception {
  @override
  String toString() => 'ClientException: Connection closed, uri=$_leakyUrl';
}

StackTrace _stackWithUrl() => StackTrace.fromString(
  '#0      Uploader.put (package:app/uploader.dart:10:3)\n'
  '#1      request $_leakyUrl\n'
  '#2      main (package:app/main.dart:5:1)',
);

/// Flattens every exported string of a span (attributes, events, status).
String _flattenSpan(SpanData span) {
  final buffer = StringBuffer()
    ..writeln(span.name)
    ..writeln(span.statusDescription ?? '');
  for (final value in span.attributes.values) {
    buffer.writeln(value);
  }
  for (final event in span.events) {
    buffer.writeln(event.name);
    for (final value in event.attributes.values) {
      buffer.writeln(value);
    }
  }
  return buffer.toString();
}

/// Flattens every exported string of a log record (body and attributes).
String _flattenLog(LogRecord log) {
  final buffer = StringBuffer()..writeln(log.body);
  for (final value in log.attributes.values) {
    buffer.writeln(value);
  }
  return buffer.toString();
}

void _expectNoLeak(String flattened) {
  for (final fragment in _leakyFragments) {
    expect(flattened, isNot(contains(fragment)), reason: flattened);
  }
}

final class _TestLogBridge extends OtelLogExtension {
  @override
  SeverityNumber mapSeverity(String level) => SeverityNumber.error;
}

void defineErrorScrubTests() {
  group('scrubUrls', () {
    test('keeps only scheme and host, dropping path, query and fragment', () {
      expect(
        scrubUrls(
          'https://bucket.s3.amazonaws.com/a/b?X-Amz-Signature=abc#frag',
        ),
        'https://bucket.s3.amazonaws.com/…',
      );
    });

    test('scrubs a URL inside NetworkImage("…")', () {
      expect(
        scrubUrls('NetworkImage("$_leakyUrl", scale: 1.0)'),
        'NetworkImage("https://bucket.s3.amazonaws.com/…", scale: 1.0)',
      );
    });

    test('scrubs a URL after uri=', () {
      expect(
        scrubUrls('ClientException: Connection closed, uri=$_leakyUrl'),
        'ClientException: Connection closed, '
        'uri=https://bucket.s3.amazonaws.com/…',
      );
    });

    test('scrubs a URL inside a DioException message', () {
      expect(
        scrubUrls(
          'DioException [bad response]: GET $_leakyUrl failed with 403\n'
          'Error: null',
        ),
        'DioException [bad response]: GET https://bucket.s3.amazonaws.com/… '
        'failed with 403\nError: null',
      );
    });

    test('scrubs every URL in the string', () {
      expect(
        scrubUrls('from http://a.example/x/1 to https://b.example:8443/y?z=2'),
        'from http://a.example/… to https://b.example:8443/…',
      );
    });

    test('drops userinfo from the authority', () {
      expect(
        scrubUrls('https://user:s3cret@api.example.com/v1?token=x'),
        'https://api.example.com/…',
      );
    });

    test('leaves a bare origin, package: and dart: frames untouched', () {
      const untouched =
          'https://api.example.com '
          '(package:app/main.dart:5:1) (dart:async/zone.dart:1:1)';
      expect(scrubUrls(untouched), untouched);
    });

    test('is idempotent', () {
      final once = scrubUrls('x $_leakyUrl y');
      expect(scrubUrls(once), once);
    });

    test('runs in linear time on a long scheme-like run before a URL', () {
      // Entrada patológica: 64 KB de caracteres válidos de esquema que não
      // terminam em `://`, seguidos de uma URL real (o `://` existe, então o
      // atalho de `contains` não se aplica). Com o esquema sem limite, cada
      // posição inicial varre o resto da sequência: O(n²), ~2,6 s medidos.
      final input = '${'a' * 65536} x https://h/p?sig=1';

      final stopwatch = Stopwatch()..start();
      final output = scrubUrls(input);
      stopwatch.stop();

      expect(output, endsWith(' x https://h/…'));
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 200)));
    });

    test('still drops path and query when the scheme exceeds 32 chars', () {
      final input = '${'a' * 40}://host/x?sig=1';

      final output = scrubUrls(input);

      expect(output, isNot(contains('sig=1')));
      expect(output, isNot(contains('/x')));
      expect(output, endsWith('://host/…'));
      expect(scrubUrls(output), output);
    });
  });

  group('error text never carries a URL path or query', () {
    test('trace records the exception and status without the URL', () async {
      expect(
        () => Otel.instance.tracer.trace<void>(
          'sync-op',
          fn: () =>
              Error.throwWithStackTrace(_UrlInMessageError(), _stackWithUrl()),
        ),
        throwsA(isA<_UrlInMessageError>()),
      );
      await Future<void>.delayed(Duration.zero);

      final span = exporter.lastSpanNamed('sync-op')!;
      expect(span.status, SpanStatus.error);
      expect(span.statusDescription, contains('bucket.s3.amazonaws.com'));
      _expectNoLeak(_flattenSpan(span));
    });

    test(
      'traceAsync records the exception and status without the URL',
      () async {
        await expectLater(
          Otel.instance.tracer.traceAsync<void>(
            'async-op',
            fn: () async => Error.throwWithStackTrace(
              _UrlInMessageError(),
              _stackWithUrl(),
            ),
          ),
          throwsA(isA<_UrlInMessageError>()),
        );

        final span = exporter.lastSpanNamed('async-op')!;
        expect(span.status, SpanStatus.error);
        _expectNoLeak(_flattenSpan(span));
      },
    );

    test('span.recordException scrubs message and stack', () async {
      final span = Otel.instance.tracer.startSpan('manual');
      span.recordException(_UrlInMessageError(), stackTrace: _stackWithUrl());
      await span.end();

      final data = exporter.lastSpanNamed('manual')!;
      final event = data.events.single;
      expect(
        event.attributes[SemanticAttributes.exceptionMessage],
        contains('uri=https://bucket.s3.amazonaws.com/…'),
      );
      expect(
        event.attributes[SemanticAttributes.exceptionStacktrace],
        contains('package:app/uploader.dart:10:3'),
      );
      _expectNoLeak(_flattenSpan(data));
    });

    test(
      'explicit recordException attributes still override exception.message',
      () async {
        final span = Otel.instance.tracer.startSpan('override');
        span.recordException(
          _UrlInMessageError(),
          attributes: const <String, Object>{
            SemanticAttributes.exceptionMessage: 'DioException[badResponse]',
          },
        );
        await span.end();

        expect(
          exporter
              .lastSpanNamed('override')!
              .events
              .single
              .attributes[SemanticAttributes.exceptionMessage],
          'DioException[badResponse]',
        );
      },
    );

    test('logger.error scrubs exception message and stack', () async {
      Otel.instance.loggerProvider
          .getLogger('scrub-logger')
          .error(
            'upload failed',
            error: _UrlInMessageError(),
            stackTrace: _stackWithUrl(),
          );
      await Otel.forceFlush();

      final log = logExporter.lastLogNamed('scrub-logger')!;
      expect(
        log.attributes[SemanticAttributes.exceptionMessage],
        contains('bucket.s3.amazonaws.com'),
      );
      _expectNoLeak(_flattenLog(log));
    });

    test('OtelLogExtension scrubs exception message and stack', () async {
      _TestLogBridge().forward(
        level: 'error',
        message: 'bridged',
        loggerName: 'scrub-bridge',
        error: _UrlInMessageError(),
        stackTrace: _stackWithUrl(),
      );
      await Otel.forceFlush();

      _expectNoLeak(_flattenLog(logExporter.lastLogNamed('scrub-bridge')!));
    });

    test('logger.error scrubs a URL in the body', () async {
      Otel.instance.loggerProvider
          .getLogger('scrub-body')
          .error(_UrlInMessageError().toString());
      await Otel.forceFlush();

      final log = logExporter.lastLogNamed('scrub-body')!;
      expect(
        log.body,
        'ClientException: Connection closed, '
        'uri=https://bucket.s3.amazonaws.com/…',
      );
      _expectNoLeak(_flattenLog(log));
    });

    test('OtelLogExtension scrubs a URL in the message', () async {
      _TestLogBridge().forward(
        level: 'error',
        message: 'GET $_leakyUrl failed',
        loggerName: 'scrub-bridge-body',
      );
      await Otel.forceFlush();

      final log = logExporter.lastLogNamed('scrub-bridge-body')!;
      expect(log.body, 'GET https://bucket.s3.amazonaws.com/… failed');
      _expectNoLeak(_flattenLog(log));
    });

    test('the body is scrubbed before it is cut to the body limit', () async {
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'scrub-body-limit',
        logLimits: const LogLimits(bodyLengthLimit: 60),
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
      );

      // Cut first, the 60-unit prefix would keep `/colaboradores/1234…`.
      Otel.instance.loggerProvider
          .getLogger('scrub-body-limit')
          .error('GET $_leakyUrl ${'x' * 200}');
      await Otel.forceFlush();

      final log = logExporter.lastLogNamed('scrub-body-limit')!;
      expect(log.body, startsWith('GET https://bucket.s3.amazonaws.com/… x'));
      expect(log.body.length, lessThanOrEqualTo(60));
      _expectNoLeak(_flattenLog(log));
    });
  });
}
