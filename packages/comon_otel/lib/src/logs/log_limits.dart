import '../core/attribute_value_limit.dart';
import 'logger_provider.dart';

/// Limits applied to log records by [LoggerProvider.emit].
final class LogLimits {
  /// Creates a set of log limits. `null` disables a limit.
  const LogLimits({
    this.attributeValueLengthLimit = defaultValueLengthLimit,
    this.bodyLengthLimit = defaultValueLengthLimit,
  }) : assert(
         attributeValueLengthLimit == null || attributeValueLengthLimit >= 0,
       ),
       assert(bodyLengthLimit == null || bodyLengthLimit >= 0);

  /// Default limit (4 KiB) for string attribute values and the body.
  static const int defaultValueLengthLimit = 4096;

  /// Maximum length of each string attribute value (and of each string in a
  /// string list), marker included; see [attributeValueTruncationMarker].
  final int? attributeValueLengthLimit;

  /// Maximum length of the log body, marker included.
  ///
  /// A body cut here is no longer valid JSON if it was JSON.
  final int? bodyLengthLimit;
}
