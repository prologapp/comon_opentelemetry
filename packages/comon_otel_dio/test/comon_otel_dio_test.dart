import 'dart:convert';
import 'dart:typed_data';

import 'package:comon_otel/comon_otel.dart';
import 'package:comon_otel_dio/comon_otel_dio.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late InMemorySpanExporter spanExporter;

  setUp(() async {
    spanExporter = InMemorySpanExporter();
    await Otel.shutdown();
    await Otel.init(
      serviceName: 'dio-test-app',
      spanProcessors: <SpanProcessor>[SimpleSpanProcessor(spanExporter)],
      metricReaders: const <MetricReader>[],
      logProcessors: const <LogProcessor>[],
    );
  });

  tearDown(() async {
    await Otel.shutdown();
  });

  test('interceptor injects propagation headers and records success', () async {
    late RequestOptions capturedOptions;
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        capturedOptions = options;
        return ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      })
      ..interceptors.add(OtelDioInterceptor());

    final response = await dio.get<dynamic>('https://example.com/users');
    await Otel.forceFlush();

    expect(response.statusCode, 200);
    expect(capturedOptions.headers['traceparent'], isNotNull);

    final span = spanExporter.spans.singleWhere(
      (span) => span.name == 'HTTP GET',
    );
    expect(span.kind, SpanKind.client);
    expect(span.attributes[SemanticAttributes.httpMethod], 'GET');
    expect(
      span.attributes[SemanticAttributes.httpUrl],
      'https://example.com/users',
    );
    expect(span.attributes.containsKey(SemanticAttributes.httpRoute), isFalse);
    expect(span.attributes[SemanticAttributes.httpStatusCode], 200);
    expect(span.status, SpanStatus.ok);
  });

  test('requestFilter can skip telemetry for a request', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString('ok', 200);
      })
      ..interceptors.add(
        OtelDioInterceptor(
          requestFilter: (options) => !options.uri.path.contains('health'),
        ),
      );

    await dio.get<dynamic>('https://example.com/health');
    await Otel.forceFlush();

    expect(spanExporter.spans, isEmpty);
  });

  test('custom span name builder is used', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString('ok', 204);
      })
      ..interceptors.add(
        OtelDioInterceptor(
          spanNameBuilder: (options) => 'dio ${options.uri.path}',
        ),
      );

    await dio.delete<dynamic>('https://example.com/users/42');
    await Otel.forceFlush();

    expect(spanExporter.spans.single.name, 'dio /users/42');
  });

  test('records redirect count and response content type', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        final responseBody = ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
            Headers.contentLengthHeader: <String>['11'],
          },
        );
        responseBody.redirects = <RedirectRecord>[
          RedirectRecord(
            302,
            'GET',
            Uri.parse('https://example.com/final-users'),
          ),
        ];
        return responseBody;
      })
      ..interceptors.add(OtelDioInterceptor());

    await dio.get<dynamic>('https://example.com/users');
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(span.attributes[SemanticAttributes.httpResendCount], 1);
    expect(
      span.attributes[SemanticAttributes.httpResponseContentType],
      'application/json',
    );
    expect(span.status, SpanStatus.ok);
  });

  test('4xx responses keep span status unset', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          '{"error":"missing"}',
          404,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      })
      ..interceptors.add(OtelDioInterceptor());

    await expectLater(
      dio.get<dynamic>('https://example.com/missing'),
      throwsA(isA<DioException>()),
    );
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(span.attributes[SemanticAttributes.httpStatusCode], 404);
    expect(span.status, SpanStatus.unset);
    expect(span.events.where((event) => event.name == 'exception'), isEmpty);
  });

  test('5xx responses mark span status as error', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString('boom', 503);
      })
      ..interceptors.add(OtelDioInterceptor());

    await expectLater(
      dio.get<dynamic>('https://example.com/unavailable'),
      throwsA(isA<DioException>()),
    );
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(span.attributes[SemanticAttributes.httpStatusCode], 503);
    expect(span.status, SpanStatus.error);
  });

  test('interceptor records Dio failures', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        throw DioException(
          requestOptions: options,
          message: 'dio boom',
          error: StateError('dio boom'),
        );
      })
      ..interceptors.add(OtelDioInterceptor());

    await expectLater(
      dio.post<dynamic>('https://example.com/orders'),
      throwsA(isA<DioException>()),
    );
    await Otel.forceFlush();

    final span = spanExporter.spans.singleWhere(
      (span) => span.name == 'HTTP POST',
    );
    expect(span.status, SpanStatus.error);
    expect(span.statusDescription, 'unknown');
    final exceptionEvent = span.events.singleWhere(
      (event) => event.name == 'exception',
    );
    // The raw Dio message embeds the URL; only the closed-set type is kept.
    expect(
      exceptionEvent.attributes[SemanticAttributes.exceptionMessage],
      'DioException[unknown]',
    );
    expect(
      exceptionEvent.attributes[SemanticAttributes.exceptionType],
      'DioException',
    );
  });

  test('interceptor records timeout failures as span errors', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
          message: 'timed out',
        );
      })
      ..interceptors.add(OtelDioInterceptor());

    await expectLater(
      dio.get<dynamic>('https://example.com/timeout'),
      throwsA(isA<DioException>()),
    );
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(span.status, SpanStatus.error);
    expect(span.statusDescription, 'connectionTimeout');
    expect(
      span.events.single.attributes[SemanticAttributes.exceptionMessage],
      'DioException[connectionTimeout]',
    );
  });

  test(
    'network errors never leak the URL or the raw error message into the span',
    () async {
      // CPF in the path + pre-signed S3 query: both must stay out of every
      // span surface except `http.url` (sanitized app-side by a span
      // processor at onStart).
      const sensitiveUrl =
          'https://bucket.s3.amazonaws.com/colaboradores/12345678909/foto.jpg'
          '?X-Amz-Signature=deadbeefcafebabe&X-Amz-Credential=AKIASECRET';
      const sensitiveFragments = <String>[
        '12345678909',
        'X-Amz-Signature',
        'deadbeefcafebabe',
        'AKIASECRET',
        '/colaboradores/',
      ];
      final dio = Dio()
        ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'connection failed for ${options.uri}',
            error: StateError('socket closed while fetching ${options.uri}'),
          );
        })
        ..interceptors.add(OtelDioInterceptor());

      await expectLater(
        dio.put<dynamic>(sensitiveUrl, data: 'x'),
        throwsA(isA<DioException>()),
      );
      await Otel.forceFlush();

      final span = spanExporter.spans.single;
      final surfaces = <String>[
        for (final entry in span.attributes.entries)
          if (entry.key != SemanticAttributes.httpUrl)
            '${entry.key}=${entry.value}',
        for (final event in span.events) ...<String>[
          event.name,
          for (final entry in event.attributes.entries)
            '${entry.key}=${entry.value}',
        ],
        span.statusDescription ?? '',
      ];
      for (final fragment in sensitiveFragments) {
        expect(
          surfaces.where((surface) => surface.contains(fragment)),
          isEmpty,
          reason: 'span leaked "$fragment"',
        );
      }

      expect(span.status, SpanStatus.error);
      expect(span.statusDescription, 'connectionError');
      final exceptionEvent = span.events.singleWhere(
        (event) => event.name == 'exception',
      );
      expect(
        exceptionEvent.attributes[SemanticAttributes.exceptionMessage],
        'DioException[connectionError]',
      );
    },
  );

  test('concurrent requests keep spans isolated', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.uri.path.endsWith('/slow')) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return ResponseBody.fromString('ok', 200);
      })
      ..interceptors.add(OtelDioInterceptor());

    await Future.wait(<Future<Response<dynamic>>>{
      dio.get<dynamic>('https://example.com/slow'),
      dio.get<dynamic>('https://example.com/fast'),
    });
    await Otel.forceFlush();

    final spansByUrl = <String, SpanData>{
      for (final span in spanExporter.spans)
        span.attributes[SemanticAttributes.httpUrl]! as String: span,
    };
    expect(
      spansByUrl.keys,
      containsAll(<String>[
        'https://example.com/slow',
        'https://example.com/fast',
      ]),
    );
    expect(
      spansByUrl['https://example.com/slow']?.attributes[SemanticAttributes
          .httpUrl],
      'https://example.com/slow',
    );
    expect(
      spansByUrl['https://example.com/fast']?.attributes[SemanticAttributes
          .httpUrl],
      'https://example.com/fast',
    );
  });

  test('captures request and response body sizes', () async {
    final payload = <String, Object>{'note': 'ship it'};
    final payloadSize = utf8.encode(jsonEncode(payload)).length;
    final responseBody = '{"ok":true}';
    final responseBodySize = utf8.encode(responseBody).length;

    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          responseBody,
          201,
          headers: <String, List<String>>{
            Headers.contentLengthHeader: <String>['$responseBodySize'],
          },
        );
      })
      ..interceptors.add(OtelDioInterceptor());

    await dio.post<dynamic>('https://example.com/orders', data: payload);
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(
      span.attributes[SemanticAttributes.httpRequestBodySize],
      payloadSize,
    );
    expect(
      span.attributes[SemanticAttributes.httpResponseBodySize],
      responseBodySize,
    );
  });

  test(
    'captures configured headers and redacts sensitive request headers',
    () async {
      final dio = Dio()
        ..options.headers['authorization'] = 'Bearer secret-token'
        ..options.headers['x-trace-id'] = 'trace-123'
        ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
          return ResponseBody.fromString(
            'ok',
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/plain'],
              'x-request-id': <String>['req-42'],
            },
          );
        })
        ..interceptors.add(
          OtelDioInterceptor(
            captureRequestHeaders: const <String>{
              'authorization',
              'x-trace-id',
            },
            captureResponseHeaders: const <String>{
              'content-type',
              'x-request-id',
            },
          ),
        );

      await dio.get<dynamic>('https://example.com/users');
      await Otel.forceFlush();

      final span = spanExporter.spans.single;
      expect(
        span.attributes['http.request.header.authorization'],
        '[REDACTED]',
      );
      expect(span.attributes['http.request.header.x_trace_id'], 'trace-123');
      expect(
        span.attributes['http.response.header.content_type'],
        'text/plain',
      );
      expect(span.attributes['http.response.header.x_request_id'], 'req-42');
    },
  );

  test('request proceeds even when instrumentation throws', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString('ok', 200);
      })
      ..interceptors.add(
        OtelDioInterceptor(
          spanNameBuilder: (_) => throw StateError('instrumentation boom'),
        ),
      );

    final response = await dio.get<dynamic>('https://example.com/users');
    expect(response.statusCode, 200);
  });

  // The onResponse/onError handlers wrap their telemetry in the same try/catch
  // as onRequest and always call handler.next. They are not exercised by a
  // dedicated forced-throw test because there is no clean public seam to make
  // the inner telemetry throw: `Span` is a `final` class (cannot be subclassed
  // into a throwing fake) and `_takeSpan` is null-safe, so a real SDK span is
  // always used and its setAttribute/setStatus/end calls do not throw for valid
  // responses. Forcing it would require adding a production-only test seam,
  // which is not warranted for this swallow path; the onRequest test above plus
  // the success/5xx/timeout tests cover the handler.next contract on every path.

  test('records method_original for non-standard methods', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeHttpClientAdapter((options) async {
        return ResponseBody.fromString('ok', 200);
      })
      ..interceptors.add(OtelDioInterceptor());

    await dio.request<dynamic>(
      'https://example.com/query',
      options: Options(method: 'PROPFIND'),
    );
    await Otel.forceFlush();

    final span = spanExporter.spans.single;
    expect(span.attributes[SemanticAttributes.httpMethod], 'PROPFIND');
    expect(span.attributes[SemanticAttributes.httpMethodOriginal], 'PROPFIND');
  });
}

final class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }
}
