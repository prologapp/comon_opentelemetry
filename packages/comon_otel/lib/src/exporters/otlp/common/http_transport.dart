import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;

/// Supported OTLP payload compression algorithms.
enum OtlpCompression { none, gzip }

/// HTTP request sent through an [OtlpHttpTransport].
final class OtlpHttpRequest {
  /// Creates an OTLP HTTP request.
  const OtlpHttpRequest({
    required this.uri,
    this.body = '',
    this.rawBody,
    required this.headers,
    required this.timeout,
    this.compression = OtlpCompression.none,
  });

  /// Target URI.
  final Uri uri;

  /// UTF-8 string body when [rawBody] is not provided.
  final String body;

  /// Raw request body bytes.
  final List<int>? rawBody;

  /// Request headers.
  final Map<String, String> headers;

  /// Per-request timeout.
  final Duration timeout;

  /// Compression algorithm applied to the body.
  final OtlpCompression compression;

  /// Encoded body bytes after optional compression.
  List<int> get bodyBytes {
    final bytes = rawBody ?? utf8.encode(body);
    switch (compression) {
      case OtlpCompression.none:
        return bytes;
      case OtlpCompression.gzip:
        return GZipEncoder().encode(bytes);
    }
  }
}

/// HTTP response returned by an [OtlpHttpTransport].
final class OtlpHttpResponse {
  /// Creates an OTLP HTTP response.
  const OtlpHttpResponse({
    required this.statusCode,
    this.body = '',
    this.rawBody = const <int>[],
    this.headers = const <String, String>{},
  });

  /// HTTP status code.
  final int statusCode;

  /// Decoded text response body.
  final String body;

  /// Raw response body bytes.
  final List<int> rawBody;

  /// Response headers.
  final Map<String, String> headers;

  /// Whether the status code is in the `2xx` range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Whether the status code is commonly considered retryable for OTLP.
  bool get isRetryable =>
      statusCode == 429 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  /// Parsed `Retry-After` duration when provided by the server.
  Duration? get retryAfter {
    if (statusCode != 429 && statusCode != 503) {
      return null;
    }

    String? rawValue;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        rawValue = entry.value;
        break;
      }
    }

    if (rawValue == null || rawValue.trim().isEmpty) {
      return null;
    }

    final seconds = int.tryParse(rawValue.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(0, 86400));
    }

    // RFC 9110 sends the date form as an HTTP-date (IMF-fixdate, e.g.
    // "Wed, 21 Oct 2015 07:28:00 GMT"); ISO 8601 is still accepted.
    final retryAt =
        (_tryParseHttpDate(rawValue.trim()) ??
                DateTime.tryParse(rawValue.trim()))
            ?.toUtc();
    if (retryAt == null) {
      return null;
    }

    final remaining = retryAt.difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

DateTime? _tryParseHttpDate(String value) {
  try {
    return parseHttpDate(value);
  } on FormatException {
    return null;
  }
}

/// Transport used by OTLP HTTP exporters.
abstract interface class OtlpHttpTransport {
  /// Sends a JSON request.
  Future<OtlpHttpResponse> postJson(OtlpHttpRequest request);

  /// Sends a binary request.
  Future<OtlpHttpResponse> postBytes(OtlpHttpRequest request);

  /// Releases transport resources.
  Future<void> shutdown();
}

/// Default OTLP HTTP transport backed by `package:http`.
final class DefaultOtlpHttpTransport implements OtlpHttpTransport {
  /// Creates a default OTLP HTTP transport.
  DefaultOtlpHttpTransport({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<OtlpHttpResponse> postJson(OtlpHttpRequest request) async {
    return _post(request);
  }

  @override
  Future<OtlpHttpResponse> postBytes(OtlpHttpRequest request) async {
    return _post(request);
  }

  Future<OtlpHttpResponse> _post(OtlpHttpRequest request) async {
    // `Future.timeout` alone only stops waiting: the request keeps its
    // socket open against a server that never answers. The abort trigger
    // makes the client actually tear the connection down, and one deadline
    // covers both the send and the body read.
    final abort = Completer<void>();
    final deadline = Timer(request.timeout, () {
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    var completed = false;
    try {
      final httpRequest =
          http.AbortableRequest('POST', request.uri, abortTrigger: abort.future)
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes;
      // The `.timeout` calls remain as a fallback for injected clients that
      // ignore the abort trigger.
      final streamedResponse = await _client
          .send(httpRequest)
          .timeout(request.timeout);
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(request.timeout);
      completed = true;

      return OtlpHttpResponse(
        statusCode: response.statusCode,
        body: response.body,
        rawBody: response.bodyBytes,
        headers: Map<String, String>.unmodifiable(response.headers),
      );
    } on http.RequestAbortedException {
      throw TimeoutException(
        'OTLP HTTP request exceeded ${request.timeout}',
        request.timeout,
      );
    } finally {
      deadline.cancel();
      // Any failure path (fallback timeout included) releases the connection.
      if (!completed && !abort.isCompleted) {
        abort.complete();
      }
    }
  }

  @override
  Future<void> shutdown() async {
    _client.close();
  }
}

@Deprecated('Use DefaultOtlpHttpTransport instead.')
final class IoOtlpHttpTransport extends DefaultOtlpHttpTransport {
  IoOtlpHttpTransport({Object? httpClient, super.client});
}

/// Resolves a signal-specific OTLP URI from [endpoint] and [signalPath].
Uri resolveOtlpSignalUri(String endpoint, String signalPath) {
  final baseUri = Uri.parse(endpoint);
  if (baseUri.path.endsWith(signalPath)) {
    return baseUri;
  }

  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedSignalPath = signalPath.startsWith('/')
      ? signalPath
      : '/$signalPath';

  return baseUri.replace(path: '$normalizedBasePath$normalizedSignalPath');
}
