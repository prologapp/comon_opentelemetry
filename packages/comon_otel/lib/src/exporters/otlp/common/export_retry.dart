import '../../span_exporter.dart';
import '../grpc/grpc_transport.dart';
import 'http_transport.dart';

/// Retry settings used by OTLP exporters.
final class OtlpRetryConfig {
  /// Creates an OTLP retry policy.
  const OtlpRetryConfig({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.backoffMultiplier = 2.0,
    this.maxDelay = const Duration(seconds: 2),
    this.maxRetryAfter = const Duration(seconds: 30),
  }) : assert(maxAttempts >= 1, 'maxAttempts must be >= 1');

  /// Maximum number of export attempts.
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Multiplier applied after each failed attempt.
  final double backoffMultiplier;

  /// Upper bound for exponential backoff.
  final Duration maxDelay;

  /// Longest server `Retry-After` the exporter will wait for before
  /// retrying. A longer one makes the export fail at once (no retry) instead
  /// of blocking the signal's export chain; a shorter one is honored as sent.
  final Duration maxRetryAfter;
}

/// Executes an OTLP HTTP export with retry semantics.
Future<ExportResult> executeOtlpExportWithRetry({
  required OtlpRetryConfig retry,
  required Future<OtlpHttpResponse> Function() send,
  void Function(OtlpHttpResponse response)? onSuccessResponse,
}) async {
  var attempt = 0;
  var delay = retry.initialDelay;

  while (attempt < retry.maxAttempts) {
    attempt += 1;

    try {
      final response = await send();
      if (response.isSuccess) {
        _reportSuccessResponse(() => onSuccessResponse?.call(response));
        return ExportResult.success;
      }

      if (!response.isRetryable || attempt >= retry.maxAttempts) {
        return ExportResult.failure;
      }

      // Never resend earlier than the server asked: when a collector is
      // overloaded, retrying early from a whole fleet is what Retry-After
      // exists to prevent. A wait longer than maxRetryAfter (delta-seconds up
      // to 86400 s, or an HTTP-date) would instead freeze this signal's export
      // chain and hold any flush the host awaits, so that batch fails now
      // and follows the normal failure path.
      final retryAfter = response.retryAfter;
      if (retryAfter != null) {
        if (retryAfter > retry.maxRetryAfter) {
          return ExportResult.failure;
        }
        delay = retryAfter;
      }
    } catch (_) {
      if (attempt >= retry.maxAttempts) {
        return ExportResult.failure;
      }
    }

    await Future<void>.delayed(delay);
    final nextMillis = (delay.inMilliseconds * retry.backoffMultiplier).round();
    delay = Duration(
      milliseconds: nextMillis.clamp(
        retry.initialDelay.inMilliseconds,
        retry.maxDelay.inMilliseconds,
      ),
    );
  }

  return ExportResult.failure;
}

/// Executes an OTLP gRPC export with retry semantics.
Future<ExportResult> executeOtlpGrpcExportWithRetry({
  required OtlpRetryConfig retry,
  required Future<List<int>> Function() send,
  void Function(List<int> responseBytes)? onSuccessResponse,
}) async {
  var attempt = 0;
  var delay = retry.initialDelay;

  while (attempt < retry.maxAttempts) {
    attempt += 1;

    try {
      final responseBytes = await send();
      _reportSuccessResponse(() => onSuccessResponse?.call(responseBytes));
      return ExportResult.success;
    } on OtlpGrpcTransportException catch (error) {
      if (!error.retryable || attempt >= retry.maxAttempts) {
        return ExportResult.failure;
      }
    } catch (_) {
      if (attempt >= retry.maxAttempts) {
        return ExportResult.failure;
      }
    }

    await Future<void>.delayed(delay);
    final nextMillis = (delay.inMilliseconds * retry.backoffMultiplier).round();
    delay = Duration(
      milliseconds: nextMillis.clamp(
        retry.initialDelay.inMilliseconds,
        retry.maxDelay.inMilliseconds,
      ),
    );
  }

  return ExportResult.failure;
}

/// Runs the partial-success handler of a response the server already
/// accepted. A body it cannot parse (e.g. a captive portal answering 200
/// with HTML) must not turn the export into a failure: that would make the
/// retry loop resend a batch the server has already taken.
void _reportSuccessResponse(void Function() report) {
  try {
    report();
  } catch (_) {
    // Partial-success reporting is best effort.
  }
}
