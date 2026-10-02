import '../logs/log_limits.dart';
import '../trace/span_limits.dart';

/// Suffix appended to a string value cut by a value length limit
/// ([SpanLimits.attributeValueLengthLimit], [LogLimits]).
///
/// A truncated value is at most the limit long, marker included.
const String attributeValueTruncationMarker = '...[truncated]';

/// Cuts [value] to at most [limit] UTF-16 code units, marker included.
///
/// Returns [value] unchanged when [limit] is `null` or not exceeded. Never
/// splits a surrogate pair. Lengths are code units (Dart `String.length`),
/// not UTF-8 bytes: an ASCII value of N units is N bytes on the wire.
String truncateValue(String value, int? limit) {
  if (limit == null || value.length <= limit) {
    return value;
  }
  if (limit <= attributeValueTruncationMarker.length) {
    return value.substring(0, _safeCut(value, limit));
  }
  final keep = _safeCut(value, limit - attributeValueTruncationMarker.length);
  return '${value.substring(0, keep)}$attributeValueTruncationMarker';
}

/// Applies [truncateValue] to a string or to each string of a string list;
/// other values are returned unchanged.
Object limitAttributeValue(Object value, int? limit) {
  if (limit == null) {
    return value;
  }
  if (value is String) {
    return truncateValue(value, limit);
  }
  if (value is List<String> && value.any((item) => item.length > limit)) {
    return List<String>.unmodifiable(
      value.map((item) => truncateValue(item, limit)),
    );
  }
  return value;
}

/// Moves [end] back by one when it would cut between the two code units of
/// a surrogate pair.
int _safeCut(String value, int end) {
  if (end <= 0) {
    return 0;
  }
  final last = value.codeUnitAt(end - 1);
  final isHighSurrogate = last >= 0xD800 && last <= 0xDBFF;
  return isHighSurrogate ? end - 1 : end;
}
