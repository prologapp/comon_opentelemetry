import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'comon_otel_flutter_config.dart';
import 'errors/otel_flutter_breadcrumbs.dart';
import 'errors/otel_flutter_error_hooks.dart';
import 'errors/otel_flutter_error_integration.dart';
import 'errors/otel_flutter_error_rate_limiter.dart';
import 'lifecycle/otel_flutter_binding_observer.dart';
import 'navigation/otel_navigator_observer.dart';
import 'performance/otel_flutter_frame_timing_observer.dart';
import 'performance/otel_flutter_ui_stall_observer.dart';
import 'resource/otel_flutter_resource_observer.dart';
import 'startup/otel_flutter_startup_tracker.dart';

/// Signature of the platform dispatcher error callback.
typedef OtelPlatformErrorCallback =
    bool Function(Object error, StackTrace stackTrace);

/// Entry point for installing Flutter-specific OpenTelemetry instrumentation.
final class ComonOtelFlutter {
  static ComonOtelFlutterInstrumentation? _active;
  static Otel? _activeOtel;

  /// Installs Flutter observers, error hooks, and startup tracking.
  ///
  /// Idempotent: while a previous installation is still active (not
  /// disposed) for the same [Otel] instance, the existing handle is returned
  /// unchanged and the arguments of this call are ignored — dispose it first
  /// to reinstall with a different configuration. An active installation
  /// left over from a previous [Otel] instance is disposed and replaced, so
  /// observers and error hooks are never chained twice.
  ///
  /// Throws an [ArgumentError] when
  /// [ComonOtelFlutterConfig.maxErrorTelemetryPerGroupPerMinute] is below 1,
  /// before any installation is touched.
  static ComonOtelFlutterInstrumentation install({
    ComonOtelFlutterConfig config = const ComonOtelFlutterConfig(),
    WidgetsBinding? binding,
    FlutterExceptionHandler? flutterExceptionHandler,
    OtelPlatformErrorCallback? platformDispatcherErrorCallback,
  }) {
    final errorLimit = config.maxErrorTelemetryPerGroupPerMinute;
    if (errorLimit != null && errorLimit < 1) {
      throw ArgumentError.value(
        errorLimit,
        'maxErrorTelemetryPerGroupPerMinute',
        'must be at least 1, or null to disable the limit',
      );
    }

    final otel = Otel.isInitialized ? Otel.instance : null;
    final active = _active;
    if (active != null && !active._disposed) {
      if (identical(otel, _activeOtel)) {
        return active;
      }
      active.dispose();
    }

    final instrumentation = _install(
      config: config,
      binding: binding,
      flutterExceptionHandler: flutterExceptionHandler,
      platformDispatcherErrorCallback: platformDispatcherErrorCallback,
    );
    _active = instrumentation;
    _activeOtel = otel;
    return instrumentation;
  }

  static ComonOtelFlutterInstrumentation _install({
    required ComonOtelFlutterConfig config,
    required WidgetsBinding? binding,
    required FlutterExceptionHandler? flutterExceptionHandler,
    required OtelPlatformErrorCallback? platformDispatcherErrorCallback,
  }) {
    final resolvedBinding =
        binding ?? WidgetsFlutterBinding.ensureInitialized();
    final dispatcher = resolvedBinding.platformDispatcher;

    OtelFlutterBreadcrumbs.configure(
      enabled: config.trackBreadcrumbs,
      capacity: config.breadcrumbCapacity,
    );
    OtelFlutterErrorHooks.configure(
      breadcrumbListener: config.breadcrumbListener,
      frameworkErrorListener: config.frameworkErrorListener,
      platformErrorListener: config.platformErrorListener,
    );
    OtelFlutterErrorRateLimiter.configure(
      maxPerMinute: config.maxErrorTelemetryPerGroupPerMinute,
      now: config.now,
    );
    if (config.trackBreadcrumbs) {
      OtelFlutterBreadcrumbs.clear();
    }

    final lifecycleObserver = config.observeAppLifecycle
        ? OtelFlutterBindingObserver(
            loggerName: config.loggerName,
            logLifecycleTransitions: config.logLifecycleTransitions,
            trackLifecycleDurations: config.trackLifecycleDurations,
            foregroundDurationMetricName: config.foregroundDurationMetricName,
            backgroundDurationMetricName: config.backgroundDurationMetricName,
            trackMemoryPressureMetrics: config.trackMemoryPressureMetrics,
            memoryPressureCountMetricName: config.memoryPressureCountMetricName,
            now: config.now,
          )
        : null;

    if (lifecycleObserver != null) {
      resolvedBinding.addObserver(lifecycleObserver);
    }

    final navigatorObserver = config.trackNavigatorRoutes
        ? OtelNavigatorObserver(
            spanNamePrefix: config.routeSpanNamePrefix,
            screenReadySpanNamePrefix: config.screenReadySpanNamePrefix,
            trackScreenReady: config.trackScreenReady,
            loggerName: config.loggerName,
          )
        : null;

    final frameTimingObserver = config.trackFrameTimings
        ? OtelFlutterFrameTimingObserver(
            loggerName: config.loggerName,
            frameDurationMetricName: config.frameDurationMetricName,
            buildDurationMetricName: config.buildDurationMetricName,
            rasterDurationMetricName: config.rasterDurationMetricName,
            slowFrameCountMetricName: config.slowFrameCountMetricName,
            jankFrameCountMetricName: config.jankFrameCountMetricName,
            slowFrameThreshold: config.slowFrameThreshold,
            jankFrameThreshold: config.jankFrameThreshold,
            staticAttributes: config.staticMetricAttributes,
          )
        : null;

    final uiStallObserver = config.trackUiStalls
        ? OtelFlutterUiStallObserver(
            loggerName: config.loggerName,
            durationMetricName: config.uiStallDurationMetricName,
            countMetricName: config.uiStallCountMetricName,
            logName: config.uiStallLogName,
            checkInterval: config.uiStallCheckInterval,
            threshold: config.uiStallThreshold,
            now: config.now,
            staticAttributes: config.staticMetricAttributes,
          )
        : null;

    if (frameTimingObserver != null) {
      resolvedBinding.addTimingsCallback(frameTimingObserver.onFrameTimings);
    }

    uiStallObserver?.start(binding: resolvedBinding);

    final resourceObserver =
        (config.trackBatteryMetrics ||
            config.trackThermalMetrics ||
            config.trackStorageMetrics ||
            config.trackRssMetrics)
        ? OtelFlutterResourceObserver(
            loggerName: config.loggerName,
            trackStorageMetrics: config.trackStorageMetrics,
            trackBatteryMetrics: config.trackBatteryMetrics,
            trackThermalMetrics: config.trackThermalMetrics,
            trackRssMetrics: config.trackRssMetrics,
            storageFreeMetricName: config.storageFreeMetricName,
            batteryLevelMetricName: config.batteryLevelMetricName,
            batteryStateMetricName: config.batteryStateMetricName,
            thermalCountMetricName: config.thermalCountMetricName,
            processRssMetricName: config.processRssMetricName,
            staticAttributes: config.staticMetricAttributes,
            storageFreeBytesGetter: config.storageFreeBytesGetter,
            thermalStateStreamGetter: config.thermalStateStreamGetter,
          )
        : null;

    resourceObserver?.start();

    final startupTracker = config.trackAppStartup
        ? OtelFlutterStartupTracker.start(
            binding: resolvedBinding,
            loggerName: config.loggerName,
            spanName: config.appStartupSpanName,
            firstFrameEventName: config.firstFrameEventName,
            firstInteractionLogName: config.firstInteractionLogName,
            startTime: config.appStartupStartTime,
            markFirstFrame: config.markFirstFrame,
            appStartupAttributes: config.appStartupAttributes,
            staticMetricAttributes: config.staticMetricAttributes,
          )
        : null;

    final previousFlutterErrorHandler = FlutterError.onError;
    final previousPlatformErrorHandler = dispatcher.onError;

    if (config.captureFlutterErrors) {
      FlutterError.onError = (details) {
        recordFlutterFrameworkError(
          details,
          loggerName: config.loggerName,
          fallback: flutterExceptionHandler ?? previousFlutterErrorHandler,
        );
      };
    }

    if (config.capturePlatformDispatcherErrors) {
      dispatcher.onError = (error, stackTrace) {
        return recordFlutterPlatformError(
          error,
          stackTrace,
          loggerName: config.loggerName,
          fallback:
              platformDispatcherErrorCallback ?? previousPlatformErrorHandler,
        );
      };
    }

    return ComonOtelFlutterInstrumentation._(
      binding: resolvedBinding,
      lifecycleObserver: lifecycleObserver,
      navigatorObserver: navigatorObserver,
      frameTimingObserver: frameTimingObserver,
      uiStallObserver: uiStallObserver,
      resourceObserver: resourceObserver,
      startupTracker: startupTracker,
      previousFlutterErrorHandler: previousFlutterErrorHandler,
      previousPlatformErrorHandler: previousPlatformErrorHandler,
      restoreFlutterErrors: config.captureFlutterErrors,
      restorePlatformErrors: config.capturePlatformDispatcherErrors,
    );
  }
}

/// Handle returned by [ComonOtelFlutter.install].
final class ComonOtelFlutterInstrumentation {
  /// Internal constructor for an installed instrumentation bundle.
  ComonOtelFlutterInstrumentation._({
    required WidgetsBinding binding,
    required this.lifecycleObserver,
    required this.navigatorObserver,
    required this.frameTimingObserver,
    required this.uiStallObserver,
    required this.resourceObserver,
    required this.startupTracker,
    required this.previousFlutterErrorHandler,
    required this.previousPlatformErrorHandler,
    required this.restoreFlutterErrors,
    required this.restorePlatformErrors,
  }) : _binding = binding;

  final WidgetsBinding _binding;
  final OtelFlutterBindingObserver? lifecycleObserver;
  final OtelNavigatorObserver? navigatorObserver;
  final OtelFlutterFrameTimingObserver? frameTimingObserver;
  final OtelFlutterUiStallObserver? uiStallObserver;

  /// Observer for device-resource metrics (storage/battery/thermal/RSS).
  /// Non-null only when at least one of `trackBatteryMetrics`,
  /// `trackThermalMetrics`, `trackStorageMetrics`, or `trackRssMetrics` was
  /// enabled — use it to call [OtelFlutterResourceObserver.recordStorageMilestone]
  /// / [OtelFlutterResourceObserver.recordBatteryMoment] from the app.
  final OtelFlutterResourceObserver? resourceObserver;
  final OtelFlutterStartupTracker? startupTracker;
  final FlutterExceptionHandler? previousFlutterErrorHandler;
  final OtelPlatformErrorCallback? previousPlatformErrorHandler;
  final bool restoreFlutterErrors;
  final bool restorePlatformErrors;

  /// Records the first meaningful user interaction.
  void markFirstInteraction({Map<String, Object>? attributes}) {
    startupTracker?.markFirstInteraction(attributes: attributes);
  }

  bool _disposed = false;

  /// Removes installed observers and restores previous error handlers.
  /// Calling it more than once is a no-op.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (lifecycleObserver != null) {
      _binding.removeObserver(lifecycleObserver!);
    }
    if (frameTimingObserver != null) {
      _binding.removeTimingsCallback(frameTimingObserver!.onFrameTimings);
    }
    uiStallObserver?.dispose();
    resourceObserver?.dispose();
    navigatorObserver?.dispose();
    startupTracker?.dispose();
    if (restoreFlutterErrors) {
      FlutterError.onError = previousFlutterErrorHandler;
    }
    if (restorePlatformErrors) {
      _binding.platformDispatcher.onError = previousPlatformErrorHandler;
    }
    OtelFlutterErrorHooks.clear();
    OtelFlutterBreadcrumbs.clear();
    OtelFlutterErrorRateLimiter.reset();
  }
}
