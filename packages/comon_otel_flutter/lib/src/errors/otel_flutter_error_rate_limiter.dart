import 'dart:collection';

/// Per-group rate limit for error telemetry (the span and the log with the
/// stack trace emitted for each captured error).
///
/// An error in a loop (e.g. a widget that throws on every frame) would
/// otherwise export a span plus a multi-KB log per occurrence. Each group
/// (the `error.group.name` attribute) gets at most [maxPerMinute] exported
/// occurrences per one-minute window, starting at the group's first
/// occurrence. Occurrences above the limit are not exported; they are only
/// counted (see `flutter.error.suppressed.count`).
///
/// At most [maxTrackedGroups] groups are tracked. A group whose window is
/// still active is never forgotten: forgetting it would hand it a fresh
/// quota on its next occurrence and let it exceed the limit. With the table
/// full, groups whose window is over are dropped first; if every tracked
/// window is still active, an occurrence of a group not yet tracked is
/// suppressed (and counted) until a window ends.
///
/// The limit never applies to the app's error fallback (Sentry, error
/// screen) nor to error hooks: those run for every occurrence.
final class OtelFlutterErrorRateLimiter {
  OtelFlutterErrorRateLimiter._();

  /// Default number of exported occurrences per group per minute.
  static const int defaultMaxPerMinute = 5;

  /// Length of a rate-limit window.
  static const Duration window = Duration(minutes: 1);

  /// Maximum number of groups tracked at once. Past it, only groups whose
  /// window is over are dropped; a new group is suppressed while every
  /// tracked window is still active.
  static const int maxTrackedGroups = 256;

  static int? _maxPerMinute = defaultMaxPerMinute;
  static DateTime Function() _now = DateTime.now;
  static final LinkedHashMap<String, _GroupWindow> _windows =
      LinkedHashMap<String, _GroupWindow>();

  /// Current limit per group per minute; `null` means unlimited.
  static int? get maxPerMinute => _maxPerMinute;

  /// Sets the limit ([maxPerMinute]; `null` disables limiting) and the clock
  /// ([now], mainly for tests). Clears every tracked window.
  ///
  /// Throws an [ArgumentError] when [maxPerMinute] is below 1, leaving the
  /// current limit, clock and windows untouched.
  static void configure({
    int? maxPerMinute = defaultMaxPerMinute,
    DateTime Function()? now,
  }) {
    if (maxPerMinute != null && maxPerMinute < 1) {
      throw ArgumentError.value(
        maxPerMinute,
        'maxPerMinute',
        'must be at least 1, or null to disable the limit',
      );
    }
    _maxPerMinute = maxPerMinute;
    _now = now ?? DateTime.now;
    _windows.clear();
  }

  /// Restores the defaults and clears every tracked window.
  static void reset() => configure();

  /// Whether an occurrence of [group] may be exported now. Consumes one slot
  /// of the group's current window when it returns `true`. Returns `false`
  /// for a group not yet tracked while [maxTrackedGroups] active windows are
  /// tracked.
  static bool tryAcquire(String group) {
    final limit = _maxPerMinute;
    if (limit == null) {
      return true;
    }

    final now = _now();
    var current = _windows[group];
    if (current == null || current.isOverAt(now)) {
      _windows.remove(group);
      if (_windows.length >= maxTrackedGroups) {
        _windows.removeWhere((_, value) => value.isOverAt(now));
      }
      if (_windows.length >= maxTrackedGroups) {
        return false;
      }
      current = _GroupWindow(now);
      _windows[group] = current;
    }

    if (current.exported >= limit) {
      return false;
    }
    current.exported += 1;
    return true;
  }
}

final class _GroupWindow {
  _GroupWindow(this.start);

  final DateTime start;
  int exported = 0;

  /// Over once a full [OtelFlutterErrorRateLimiter.window] has elapsed, or
  /// when the clock went backwards (a fresh window is safer than a stuck one).
  bool isOverAt(DateTime now) =>
      now.isBefore(start) ||
      now.difference(start) >= OtelFlutterErrorRateLimiter.window;
}
