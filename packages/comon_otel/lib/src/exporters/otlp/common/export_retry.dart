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
  }) : assert(maxAttempts >= 1, 'maxAttempts must be >= 1');

  /// Maximum number of export attempts.
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Multiplier applied after each failed attempt.
  final double backoffMultiplier;

  /// Upper bound for exponential backoff and for a server `Retry-After`.
  final Duration maxDelay;
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
        onSuccessResponse?.call(response);
        return ExportResult.success;
      }

      if (!response.isRetryable || attempt >= retry.maxAttempts) {
        return ExportResult.failure;
      }

      // Honor Retry-After only up to maxDelay: an unbounded value (up to
      // 86400 s) would freeze this signal's export chain, fill its queue
      // and hold any flush the host awaits (e.g. when the app is paused).
      final retryAfter = response.retryAfter;
      if (retryAfter != null) {
        delay = retryAfter > retry.maxDelay ? retry.maxDelay : retryAfter;
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
      onSuccessResponse?.call(responseBytes);
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
