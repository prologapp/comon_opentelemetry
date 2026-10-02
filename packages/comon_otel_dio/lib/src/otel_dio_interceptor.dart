import 'dart:async';
import 'dart:typed_data';

import 'package:comon_otel/comon_otel.dart';
import 'package:dio/dio.dart';

/// Decides whether a request should produce telemetry.
typedef OtelDioRequestFilter = bool Function(RequestOptions options);

/// Builds the span name for an outgoing Dio request.
typedef OtelDioSpanNameBuilder = String Function(RequestOptions options);

/// Instruments outgoing Dio requests with OpenTelemetry client spans.
final class OtelDioInterceptor extends Interceptor {
  /// Creates a Dio interceptor that emits OpenTelemetry spans for HTTP requests.
  OtelDioInterceptor({
    this.tracerName = 'comon_otel.dio',
    this.requestFilter,
    this.spanNameBuilder = _defaultSpanNameBuilder,
    Set<String> captureRequestHeaders = const <String>{},
    Set<String> captureResponseHeaders = const <String>{},
    Set<String> sensitiveHeaders = _defaultSensitiveHeaders,
    this.redactedHeaderValue = '[REDACTED]',
  }) : captureRequestHeaders = _normalizeHeaderSet(captureRequestHeaders),
       captureResponseHeaders = _normalizeHeaderSet(captureResponseHeaders),
       sensitiveHeaders = _normalizeHeaderSet(sensitiveHeaders);

  static const String _spanExtraKey = 'comon_otel_dio.span';
  static const Set<String> _defaultSensitiveHeaders = <String>{
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };
  static const Set<String> _standardHttpMethods = <String>{
    'CONNECT',
    'DELETE',
    'GET',
    'HEAD',
    'OPTIONS',
    'PATCH',
    'POST',
    'PUT',
    'TRACE',
  };

  /// Tracer name used when creating spans for outgoing requests.
  final String tracerName;

  /// Decides whether a request should produce telemetry.
  final OtelDioRequestFilter? requestFilter;

  /// Builds the span name for each intercepted request.
  final OtelDioSpanNameBuilder spanNameBuilder;

  /// Lower-cased request headers to copy into span attributes.
  final Set<String> captureRequestHeaders;

  /// Lower-cased response headers to copy into span attributes.
  final Set<String> captureResponseHeaders;

  /// Lower-cased headers whose values are always redacted when captured.
  final Set<String> sensitiveHeaders;

  /// Replacement value used for captured sensitive headers.
  final String redactedHeaderValue;

  static String _defaultSpanNameBuilder(RequestOptions options) {
    return 'HTTP ${options.method.toUpperCase()}';
  }

  static Set<String> _normalizeHeaderSet(Set<String> headers) {
    return <String>{for (final header in headers) header.toLowerCase()};
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      if (Otel.isInitialized && (requestFilter?.call(options) ?? true)) {
        _startRequestSpan(options);
      }
    } catch (_) {
      // Instrumentation must never break the real request.
    }
    handler.next(options);
  }

  void _startRequestSpan(RequestOptions options) {
    final uri = options.uri;
    final originalMethod = options.method;
    final method = originalMethod.toUpperCase();
    final requestBodySize = _estimateRequestBodySize(options);
    final attributes = <String, Object>{
      SemanticAttributes.httpMethod: method,
      SemanticAttributes.httpUrl: uri.toString(),
      SemanticAttributes.netPeerName: uri.host,
      if (uri.hasPort) SemanticAttributes.netPeerPort: uri.port,
      SemanticAttributes.networkProtocolName: uri.scheme,
      if (_shouldCaptureOriginalMethod(originalMethod, method))
        SemanticAttributes.httpMethodOriginal: originalMethod,
    };
    if (requestBodySize != null) {
      attributes[SemanticAttributes.httpRequestBodySize] = requestBodySize;
    }

    final span = Otel.instance.tracerProvider
        .getTracer(tracerName, version: '0.1.0')
        .startSpan(
          spanNameBuilder(options),
          kind: SpanKind.client,
          parentSnapshot: OtelContext.current,
          attributes: attributes,
        );

    options.extra[_spanExtraKey] = span;

    final carrier = <String, String>{
      for (final entry in options.headers.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    };
    Otel.propagator.inject(
      OtelContextSnapshot(
        spanContext: span.spanContext,
        baggage: OtelContext.currentBaggage,
      ),
      carrier,
    );
    options.headers.addAll(carrier);

    final capturedRequestHeaders = <String, Object>{};
    _addCapturedHeaderAttributes(
      capturedRequestHeaders,
      <String, List<String>>{
        for (final entry in options.headers.entries)
          entry.key: <String>[if (entry.value != null) entry.value.toString()],
      },
      prefix: 'http.request.header.',
      allowList: captureRequestHeaders,
    );
    for (final entry in capturedRequestHeaders.entries) {
      span.setAttribute(entry.key, entry.value);
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    try {
      final span = _takeSpan(response.requestOptions);
      if (span != null) {
        _applyResponseMetadata(span, response);
        _applyHttpStatus(span, response.statusCode);
        unawaited(span.end());
      }
    } catch (_) {
      // Instrumentation must never break the real response.
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      final span = _takeSpan(err.requestOptions);
      if (span != null) {
        final response = err.response;
        final statusCode = response?.statusCode;
        if (response != null) {
          _applyResponseMetadata(span, response);
        }
        final shouldRecordException = statusCode == null || statusCode >= 500;
        if (shouldRecordException) {
          // Never put err.toString()/err.message/err.error into the span:
          // Dio embeds the full request URL there (path PII such as CPF,
          // pre-signed query signatures). Only the closed-set error type is
          // exported.
          final errorType = err.type.name;
          span.recordException(
            err,
            stackTrace: err.stackTrace,
            attributes: <String, Object>{
              SemanticAttributes.exceptionMessage: 'DioException[$errorType]',
            },
          );
          span.setStatus(SpanStatus.error, description: errorType);
        } else {
          _applyHttpStatus(span, statusCode);
        }
        unawaited(span.end());
      }
    } catch (_) {
      // Instrumentation must never break error propagation.
    }
    handler.next(err);
  }

  void _applyResponseMetadata(Span span, Response<dynamic> response) {
    final statusCode = response.statusCode;
    if (statusCode != null) {
      span.setAttribute(SemanticAttributes.httpStatusCode, statusCode);
    }

    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (contentType != null && contentType.isNotEmpty) {
      span.setAttribute(
        SemanticAttributes.httpResponseContentType,
        contentType,
      );
    }

    if (_estimateResponseBodySize(response) case final responseBodySize?) {
      span.setAttribute(
        SemanticAttributes.httpResponseBodySize,
        responseBodySize,
      );
    }

    if (response.redirects.isNotEmpty) {
      span.setAttribute(
        SemanticAttributes.httpResendCount,
        response.redirects.length,
      );
    }

    final capturedResponseHeaders = <String, Object>{};
    _addCapturedHeaderAttributes(
      capturedResponseHeaders,
      response.headers.map,
      prefix: 'http.response.header.',
      allowList: captureResponseHeaders,
    );
    for (final entry in capturedResponseHeaders.entries) {
      span.setAttribute(entry.key, entry.value);
    }
  }

  void _applyHttpStatus(Span span, int? statusCode) {
    if (statusCode == null) {
      return;
    }
    if (statusCode >= 500) {
      span.setStatus(SpanStatus.error, description: 'HTTP $statusCode');
      return;
    }
    if (statusCode >= 400) {
      span.setStatus(SpanStatus.unset);
      return;
    }
    span.setStatus(SpanStatus.ok);
  }

  void _addCapturedHeaderAttributes(
    Map<String, Object> attributes,
    Map<String, List<String>> headers, {
    required String prefix,
    required Set<String> allowList,
  }) {
    if (allowList.isEmpty) {
      return;
    }

    for (final entry in headers.entries) {
      final headerName = entry.key.toLowerCase();
      if (!allowList.contains(headerName)) {
        continue;
      }

      final normalizedAttributeName = headerName.replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '_',
      );
      final values = entry.value.where((value) => value.isNotEmpty).toList();
      if (values.isEmpty) {
        continue;
      }

      attributes['$prefix$normalizedAttributeName'] =
          sensitiveHeaders.contains(headerName)
          ? redactedHeaderValue
          : values.join(', ');
    }
  }

  bool _shouldCaptureOriginalMethod(String originalMethod, String method) {
    return originalMethod != method || !_standardHttpMethods.contains(method);
  }

  int? _estimateRequestBodySize(RequestOptions options) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == Headers.contentLengthHeader) {
        final parsed = _parseContentLength(entry.value?.toString());
        if (parsed != null) {
          return parsed;
        }
      }
    }

    return _estimateBodySize(options.data);
  }

  int? _estimateResponseBodySize(Response<dynamic> response) {
    final parsed = _parseContentLength(
      response.headers.value(Headers.contentLengthHeader),
    );
    if (parsed != null) {
      return parsed;
    }

    return _estimateBodySize(response.data);
  }

  int? _parseContentLength(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  /// Measures only sizes that are already cheaply available on the main
  /// isolate. Structured bodies (Map/List/objects) are never re-serialized
  /// just to be measured: without a Content-Length the attribute is omitted.
  int? _estimateBodySize(Object? data) {
    if (data is Uint8List) {
      return data.lengthInBytes;
    }
    if (data is List<int>) {
      return data.length;
    }
    if (data is String) {
      return _utf8Length(data);
    }
    if (data is FormData) {
      return data.length;
    }
    return null;
  }

  /// UTF-8 byte length of [value] without allocating an encoded copy.
  static int _utf8Length(String value) {
    var length = 0;
    final codeUnits = value.codeUnits;
    for (var index = 0; index < codeUnits.length; index++) {
      final unit = codeUnits[index];
      if (unit < 0x80) {
        length += 1;
      } else if (unit < 0x800) {
        length += 2;
      } else if (unit >= 0xD800 &&
          unit <= 0xDBFF &&
          index + 1 < codeUnits.length &&
          codeUnits[index + 1] >= 0xDC00 &&
          codeUnits[index + 1] <= 0xDFFF) {
        // Valid surrogate pair: one 4-byte code point.
        length += 4;
        index++;
      } else {
        // BMP char or lone surrogate (utf8.encode emits U+FFFD, 3 bytes).
        length += 3;
      }
    }
    return length;
  }

  Span? _takeSpan(RequestOptions options) {
    final value = options.extra.remove(_spanExtraKey);
    if (value is Span) {
      return value;
    }
    return null;
  }
}
