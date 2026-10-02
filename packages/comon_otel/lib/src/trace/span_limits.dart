import '../core/attribute_value_limit.dart';

/// Limits applied to attributes, events, and links recorded on spans.
final class SpanLimits {
  /// Creates a set of span limits.
  const SpanLimits({
    this.attributeCountLimit = 128,
    this.eventCountLimit = 128,
    this.linkCountLimit = 128,
    this.attributePerEventCountLimit = 128,
    this.attributePerLinkCountLimit = 128,
    this.attributeValueLengthLimit = defaultAttributeValueLengthLimit,
  }) : assert(attributeCountLimit >= 0),
       assert(eventCountLimit >= 0),
       assert(linkCountLimit >= 0),
       assert(attributePerEventCountLimit >= 0),
       assert(attributePerLinkCountLimit >= 0),
       assert(
         attributeValueLengthLimit == null || attributeValueLengthLimit >= 0,
       );

  /// Default [attributeValueLengthLimit] (4 KiB).
  static const int defaultAttributeValueLengthLimit = 4096;

  /// Maximum number of attributes retained on a span.
  final int attributeCountLimit;

  /// Maximum number of events retained on a span.
  final int eventCountLimit;

  /// Maximum number of links retained on a span.
  final int linkCountLimit;

  /// Maximum number of attributes retained on each span event.
  final int attributePerEventCountLimit;

  /// Maximum number of attributes retained on each span link.
  final int attributePerLinkCountLimit;

  /// Maximum length of each string attribute value (and of each string in a
  /// string list) on spans, span events and span links, and of the status
  /// description, marker included ([attributeValueTruncationMarker]).
  /// `null` disables the limit.
  final int? attributeValueLengthLimit;
}
