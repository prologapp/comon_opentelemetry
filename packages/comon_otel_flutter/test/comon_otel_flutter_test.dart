import 'dart:async';
import 'dart:ui';

import 'package:comon_otel/comon_otel.dart';
import 'package:comon_otel_flutter/comon_otel_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CountingSpanExporter implements SpanExporter {
  int forceFlushCount = 0;
  final List<SpanData> spans = <SpanData>[];

  @override
  Future<ExportResult> export(List<SpanData> data) async {
    spans.addAll(data);
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {
    forceFlushCount += 1;
  }

  @override
  Future<void> shutdown() async {}
}

final class _ThrowingFlushSpanExporter implements SpanExporter {
  bool failFlush = true;

  @override
  Future<ExportResult> export(List<SpanData> data) async =>
      ExportResult.success;

  @override
  Future<void> forceFlush() async {
    if (failFlush) {
      throw StateError('flush boom');
    }
  }

  @override
  Future<void> shutdown() async {}
}

void main() {
  late InMemorySpanExporter spanExporter;
  late InMemoryMetricExporter metricExporter;
  late InMemoryLogExporter logExporter;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    spanExporter = InMemorySpanExporter();
    metricExporter = InMemoryMetricExporter();
    logExporter = InMemoryLogExporter();

    await Otel.shutdown();
    await Otel.init(
      serviceName: 'flutter-test-app',
      spanProcessors: <SpanProcessor>[SimpleSpanProcessor(spanExporter)],
      metricReaders: <MetricReader>[
        ExportingMetricReader(exporter: metricExporter),
      ],
      logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
    );
  });

  tearDown(() async {
    await Otel.shutdown();
    FlutterError.onError = FlutterError.presentError;
    PlatformDispatcher.instance.onError = null;
    OtelFlutterErrorHooks.clear();
    OtelFlutterBreadcrumbs.clear();
    OtelFlutterRouteContext.clear();
  });

  test('mobileResourceAttributesFrom builds OTel resource attributes', () {
    final attributes = mobileResourceAttributesFrom(
      osName: 'iOS',
      osVersion: '17.4',
      deviceModelIdentifier: 'iPhone15,2',
      deviceManufacturer: 'Apple',
      serviceVersion: '2.0.1',
    );

    expect(attributes['os.name'], 'iOS');
    expect(attributes['os.version'], '17.4');
    expect(attributes['device.model.identifier'], 'iPhone15,2');
    expect(attributes['device.manufacturer'], 'Apple');
    expect(attributes['service.version'], '2.0.1');
    expect(attributes.containsKey('host.name'), isFalse);
  });

  test('install exposes the navigator observer by default', () {
    final instrumentation = ComonOtelFlutter.install(
      config: const ComonOtelFlutterConfig(observeAppLifecycle: false),
    );

    expect(instrumentation.navigatorObserver, isNotNull);
    expect(instrumentation.frameTimingObserver, isNotNull);
    expect(instrumentation.uiStallObserver, isNotNull);
    expect(instrumentation.startupTracker, isNotNull);

    instrumentation.dispose();
  });

  testWidgets('install records startup span through first frame', (
    tester,
  ) async {
    final instrumentation = ComonOtelFlutter.install(
      config: ComonOtelFlutterConfig(
        observeAppLifecycle: false,
        trackNavigatorRoutes: false,
        appStartupStartTime: DateTime.now().toUtc().subtract(
          const Duration(milliseconds: 25),
        ),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('startup'))),
    );
    await tester.pump();
    await Otel.forceFlush();

    final startupSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'app.startup',
    );
    expect(startupSpan.endTime, isNotNull);
    expect(
      startupSpan.events.map((event) => event.name),
      contains('flutter.first_frame'),
    );
    expect(startupSpan.attributes['flutter.startup.completed'], true);
    expect(
      logExporter.logs.where((log) => log.body == 'app.first_frame'),
      hasLength(1),
    );

    instrumentation.dispose();
  });

  test(
    'completeStartup with markFirstFrame:false emits no first-frame marker',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );
      addTearDown(instrumentation.dispose);

      // Closed explicitly by the host (not at the first frame).
      await instrumentation.startupTracker!.completeStartup();
      await Otel.forceFlush();

      final rootSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup',
      );
      expect(rootSpan.attributes['flutter.startup.completed'], true);
      expect(
        rootSpan.events.map((event) => event.name),
        isNot(contains('flutter.first_frame')),
      );
      expect(
        logExporter.logs.where((log) => log.body == 'app.first_frame'),
        isEmpty,
      );
    },
  );

  test('startPhase creates a child span of the startup root', () async {
    final instrumentation = ComonOtelFlutter.install(
      config: const ComonOtelFlutterConfig(
        observeAppLifecycle: false,
        trackNavigatorRoutes: false,
        markFirstFrame: false,
      ),
    );

    final phaseSpan = instrumentation.startupTracker!.startPhase('di');
    expect(phaseSpan, isNotNull);
    expect(phaseSpan!.name, 'app.startup.di');
    expect(phaseSpan.attributes['app.startup.phase'], 'di');
    await phaseSpan.end();
    await instrumentation.startupTracker!.completeStartup();
    await Otel.forceFlush();

    final rootSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'app.startup',
    );
    final exportedPhaseSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'app.startup.di',
    );
    expect(
      exportedPhaseSpan.parentSpanContext?.spanId,
      rootSpan.spanContext.spanId,
    );

    instrumentation.dispose();
  });

  test('trackPhase records a span and a histogram sample on success', () async {
    final instrumentation = ComonOtelFlutter.install(
      config: const ComonOtelFlutterConfig(
        observeAppLifecycle: false,
        trackNavigatorRoutes: false,
        markFirstFrame: false,
      ),
    );

    final result = await instrumentation.startupTracker!.trackPhase<int>(
      'firebase',
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 42;
      },
    );
    await Otel.forceFlush();

    expect(result, 42);
    final phaseSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'app.startup.firebase',
    );
    expect(phaseSpan.attributes['app.startup.phase'], 'firebase');
    expect(phaseSpan.status, SpanStatus.ok);

    final histogram = metricExporter.lastMetricNamed(
      'app.startup.phase.duration',
    );
    expect(histogram, isNotNull);
    final point = histogram!.points.single;
    expect(point.count, 1);
    expect(point.attributes['app.startup.phase'], 'firebase');

    instrumentation.dispose();
  });

  test(
    'trackPhase records the error status and histogram, then rethrows',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      await expectLater(
        instrumentation.startupTracker!.trackPhase<void>('auth_restore', () {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      await Otel.forceFlush();

      final phaseSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup.auth_restore',
      );
      expect(phaseSpan.status, SpanStatus.error);
      expect(
        phaseSpan.events.map((event) => event.name),
        contains('exception'),
      );

      final histogram = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(histogram, isNotNull);
      expect(
        histogram!.points.single.attributes['app.startup.phase'],
        'auth_restore',
      );

      instrumentation.dispose();
    },
  );

  test(
    'trackPhase after completeStartup skips the span but still records the histogram',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      await instrumentation.startupTracker!.completeStartup();
      spanExporter.spans.clear();

      final result = await instrumentation.startupTracker!.trackPhase<int>(
        'migrations',
        () async => 7,
      );
      await Otel.forceFlush();

      expect(result, 7);
      expect(
        spanExporter.spans.any((span) => span.name == 'app.startup.migrations'),
        isFalse,
      );

      final histogram = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(histogram, isNotNull);
      expect(
        histogram!.points.single.attributes['app.startup.phase'],
        'migrations',
      );

      instrumentation.dispose();
    },
  );

  test(
    'recordCompletedPhase creates a child span with the explicit start/end times',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      final start = DateTime.utc(2026, 3, 20, 10, 0, 0);
      final end = DateTime.utc(2026, 3, 20, 10, 0, 0, 240);
      instrumentation.startupTracker!.recordCompletedPhase(
        'di',
        start: start,
        end: end,
      );
      await instrumentation.startupTracker!.completeStartup();
      await Otel.forceFlush();

      final phaseSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup.di',
      );
      expect(phaseSpan.attributes['app.startup.phase'], 'di');
      expect(phaseSpan.startTime, start);
      expect(phaseSpan.endTime, end);
      expect(phaseSpan.status, SpanStatus.ok);

      final rootSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup',
      );
      expect(phaseSpan.parentSpanContext?.spanId, rootSpan.spanContext.spanId);

      final histogram = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(histogram, isNotNull);
      final point = histogram!.points.single;
      expect(point.attributes['app.startup.phase'], 'di');
      expect(point.sum, closeTo(240, 0.001));

      instrumentation.dispose();
    },
  );

  test(
    'recordCompletedPhase clamps a negative duration to zero but still records',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      final start = DateTime.utc(2026, 3, 20, 10, 0, 1);
      final end = DateTime.utc(2026, 3, 20, 10, 0, 0);
      instrumentation.startupTracker!.recordCompletedPhase(
        'remote_config',
        start: start,
        end: end,
      );
      await Otel.forceFlush();

      final histogram = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(histogram, isNotNull);
      final point = histogram!.points.single;
      expect(point.attributes['app.startup.phase'], 'remote_config');
      expect(point.sum, 0);

      instrumentation.dispose();
    },
  );

  test(
    'recordCompletedPhase after completeStartup skips the span but still records the histogram',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      await instrumentation.startupTracker!.completeStartup();
      spanExporter.spans.clear();

      instrumentation.startupTracker!.recordCompletedPhase(
        'migrations',
        start: DateTime.utc(2026, 3, 20, 10, 0, 0),
        end: DateTime.utc(2026, 3, 20, 10, 0, 0, 100),
      );
      await Otel.forceFlush();

      expect(
        spanExporter.spans.any((span) => span.name == 'app.startup.migrations'),
        isFalse,
      );

      final histogram = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(histogram, isNotNull);
      final point = histogram!.points.single;
      expect(point.attributes['app.startup.phase'], 'migrations');
      expect(point.sum, closeTo(100, 0.001));

      instrumentation.dispose();
    },
  );

  test(
    'recordCompletedPhase is a full no-op once Otel has shut down',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );
      addTearDown(instrumentation.dispose);
      final tracker = instrumentation.startupTracker!;

      await Otel.shutdown();

      expect(
        () => tracker.recordCompletedPhase(
          'di',
          start: DateTime.utc(2026, 3, 20, 10, 0, 0),
          end: DateTime.utc(2026, 3, 20, 10, 0, 0, 100),
        ),
        returnsNormally,
      );
    },
  );

  test(
    'startPhase and trackPhase are no-ops when Otel is not initialized',
    () async {
      await Otel.shutdown();

      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );
      addTearDown(instrumentation.dispose);

      expect(instrumentation.startupTracker, isNull);
    },
  );

  test(
    'setStartupAttribute sets the value on the root span before end, is a no-op after',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      instrumentation.startupTracker!.setStartupAttribute(
        'launch.source',
        'push',
      );
      await instrumentation.startupTracker!.completeStartup();
      // No-op after end: must not throw, and must not overwrite what was
      // already recorded on the (now ended) root span.
      instrumentation.startupTracker!.setStartupAttribute(
        'launch.source',
        'normal',
      );
      await Otel.forceFlush();

      final startupSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup',
      );
      expect(startupSpan.attributes['launch.source'], 'push');

      instrumentation.dispose();
    },
  );

  test(
    'appStartupAttributes are present on the root span from creation',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
          appStartupAttributes: <String, Object>{'launch.source': 'normal'},
        ),
      );

      await instrumentation.startupTracker!.completeStartup();
      await Otel.forceFlush();

      final startupSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup',
      );
      expect(startupSpan.attributes['launch.source'], 'normal');

      instrumentation.dispose();
    },
  );

  test(
    'staticMetricAttributes are merged into frame, stall, and startup-phase metrics with per-record override',
    () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
          staticMetricAttributes: <String, Object>{'device.tier': 'low'},
        ),
      );

      instrumentation.frameTimingObserver!.recordFrameSample(
        totalSpan: const Duration(milliseconds: 10),
        buildDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: 4),
      );
      instrumentation.uiStallObserver!.recordTick(DateTime.utc(2026, 1, 1));
      instrumentation.uiStallObserver!.recordTick(
        DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
      await instrumentation.startupTracker!.trackPhase<void>('di', () async {});
      await Otel.forceFlush();

      final frameMetric = metricExporter.lastMetricNamed(
        'flutter.frame.duration',
      );
      expect(frameMetric!.points.single.attributes['device.tier'], 'low');

      final stallMetric = metricExporter.lastMetricNamed(
        'flutter.ui.stall.duration',
      );
      expect(stallMetric!.points.single.attributes['device.tier'], 'low');

      final phaseMetric = metricExporter.lastMetricNamed(
        'app.startup.phase.duration',
      );
      expect(phaseMetric!.points.single.attributes['device.tier'], 'low');

      instrumentation.dispose();
    },
  );

  test('instrumentation records a first interaction marker once', () async {
    final instrumentation = ComonOtelFlutter.install(
      config: const ComonOtelFlutterConfig(observeAppLifecycle: false),
    );

    instrumentation.markFirstInteraction(
      attributes: const <String, Object>{'flutter.interaction.type': 'tap'},
    );
    instrumentation.markFirstInteraction(
      attributes: const <String, Object>{'flutter.interaction.type': 'tap'},
    );
    await Otel.forceFlush();

    final firstInteractionLogs = logExporter.logs.where(
      (log) => log.body == 'app.first_interaction',
    );
    expect(firstInteractionLogs, hasLength(1));
    expect(
      firstInteractionLogs.single.attributes['flutter.interaction.type'],
      'tap',
    );

    instrumentation.dispose();
  });

  test('binding observer logs lifecycle transitions', () async {
    final observer = OtelFlutterBindingObserver();

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Otel.forceFlush();

    final log = logExporter.logs.single;
    expect(log.body, 'app.lifecycle');
    expect(log.attributes['flutter.lifecycle.state'], 'resumed');
    expect(log.attributes[SemanticAttributes.appLifecycleState], 'resumed');
  });

  for (final state in <AppLifecycleState>[
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test('flushes telemetry when the app is backgrounded ($state)', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final exporter = _CountingSpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'lifecycle-test',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      final observer = OtelFlutterBindingObserver();
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(state);

      // Let the unawaited forceFlush microtask run.
      await Future<void>.delayed(Duration.zero);

      expect(exporter.forceFlushCount, greaterThanOrEqualTo(1));

      await Otel.shutdown();
    });
  }

  group('background flush policy', () {
    late _CountingSpanExporter spans;
    late InMemoryLogExporter logs;

    setUp(() async {
      spans = _CountingSpanExporter();
      logs = InMemoryLogExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'lifecycle-test',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(spans)],
        metricReaders: const <MetricReader>[],
        // Long schedule: a record only reaches the exporter through a flush.
        logProcessors: <LogProcessor>[
          BatchLogProcessor(
            exporter: logs,
            scheduleDelay: const Duration(hours: 1),
          ),
        ],
      );
    });

    tearDown(Otel.shutdown);

    Future<void> drain() => Future<void>.delayed(Duration.zero);

    test('detached always flushes, so its own log is exported', () async {
      final observer = OtelFlutterBindingObserver();
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await drain();
      observer.didChangeAppLifecycleState(AppLifecycleState.detached);
      await drain();

      // paused + detached.
      expect(spans.forceFlushCount, 2);
      expect(
        logs.logs.where(
          (log) => log.attributes['flutter.lifecycle.state'] == 'detached',
        ),
        hasLength(1),
      );
    });

    test('repeated paused without resuming flushes once', () async {
      final observer = OtelFlutterBindingObserver();
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      // Back and forth between background states without reaching resumed.
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await drain();

      expect(spans.forceFlushCount, 1);
    });

    test('returning to resumed re-arms the flush for the next trip', () async {
      final observer = OtelFlutterBindingObserver();
      for (var trip = 0; trip < 2; trip++) {
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
        observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        await drain();
      }

      expect(spans.forceFlushCount, 2);
    });
  });

  test(
    'a failing background flush never surfaces as an unhandled error',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final exporter = _ThrowingFlushSpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'lifecycle-test',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final observer = OtelFlutterBindingObserver();
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        observer.didChangeAppLifecycleState(AppLifecycleState.detached);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }, (error, stackTrace) => uncaught.add(error));

      exporter.failFlush = false;
      await Otel.shutdown();
      expect(uncaught, isEmpty);
    },
  );

  test('does not flush on non-backgrounding lifecycle states', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final exporter = _CountingSpanExporter();
    await Otel.shutdown();
    await Otel.init(
      serviceName: 'lifecycle-test',
      spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
      metricReaders: const <MetricReader>[],
      logProcessors: const <LogProcessor>[],
    );

    final observer = OtelFlutterBindingObserver();
    observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);

    // Let any (unexpected) unawaited forceFlush microtask run.
    await Future<void>.delayed(Duration.zero);

    expect(exporter.forceFlushCount, 0);

    await Otel.shutdown();
  });

  test('breadcrumbs keep only the configured tail', () {
    OtelFlutterBreadcrumbs.configure(enabled: true, capacity: 2);

    OtelFlutterBreadcrumbs.add(category: 'test', message: 'first');
    OtelFlutterBreadcrumbs.add(category: 'test', message: 'second');
    OtelFlutterBreadcrumbs.add(category: 'test', message: 'third');

    final trail = OtelFlutterBreadcrumbs.serialize();
    expect(trail, isNotNull);
    expect(trail, isNot(contains('first')));
    expect(trail, contains('second'));
    expect(trail, contains('third'));

    OtelFlutterBreadcrumbs.configure(enabled: true, capacity: 20);
  });

  test(
    'external coexistence hooks receive breadcrumbs and errors with fallback preserved',
    () async {
      final receivedBreadcrumbs = <OtelFlutterBreadcrumbEntry>[];
      final receivedFrameworkErrors = <OtelFlutterErrorSnapshot>[];
      final receivedPlatformErrors = <OtelFlutterErrorSnapshot>[];
      var frameworkFallbackCalls = 0;
      var platformFallbackCalls = 0;

      OtelFlutterErrorHooks.configure(
        breadcrumbListener: receivedBreadcrumbs.add,
        frameworkErrorListener: receivedFrameworkErrors.add,
        platformErrorListener: receivedPlatformErrors.add,
      );

      OtelFlutterBreadcrumbs.add(
        category: 'manual',
        message: 'before_error',
        attributes: const <String, Object>{'step': 1},
      );

      recordFlutterFrameworkError(
        FlutterErrorDetails(
          exception: StateError('coexist framework boom'),
          stack: StackTrace.current,
          context: ErrorDescription('during coexist framework test'),
        ),
        fallback: (_) {
          frameworkFallbackCalls += 1;
        },
      );
      final platformHandled = recordFlutterPlatformError(
        ArgumentError('coexist platform boom'),
        StackTrace.current,
        fallback: (error, stackTrace) {
          platformFallbackCalls += 1;
          return false;
        },
      );

      await Otel.forceFlush();

      expect(receivedBreadcrumbs, isNotEmpty);
      expect(receivedBreadcrumbs.last.message, 'before_error');
      expect(receivedFrameworkErrors, hasLength(1));
      expect(receivedFrameworkErrors.single.source, 'framework');
      expect(
        receivedFrameworkErrors.single.attributes[SemanticAttributes
            .exceptionMessage],
        contains('coexist framework boom'),
      );
      expect(receivedFrameworkErrors.single.breadcrumbs, isNotEmpty);
      expect(receivedPlatformErrors, hasLength(1));
      expect(receivedPlatformErrors.single.source, 'platform_dispatcher');
      expect(
        receivedPlatformErrors.single.attributes[SemanticAttributes
            .exceptionMessage],
        contains('coexist platform boom'),
      );
      expect(frameworkFallbackCalls, 1);
      expect(platformFallbackCalls, 1);
      // The fallback returned false: the error stays unhandled.
      expect(platformHandled, isFalse);
    },
  );

  test(
    'binding observer records foreground and background duration metrics',
    () async {
      final timeline = <DateTime>[
        DateTime.utc(2026, 3, 20, 10, 0, 0, 0),
        DateTime.utc(2026, 3, 20, 10, 0, 1, 500),
        DateTime.utc(2026, 3, 20, 10, 0, 3, 0),
      ];
      var index = 0;
      final observer = OtelFlutterBindingObserver(now: () => timeline[index++]);

      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Otel.forceFlush();

      final foregroundMetric = metricExporter.lastMetricNamed(
        'app.foreground.duration',
      );
      final backgroundMetric = metricExporter.lastMetricNamed(
        'app.background.duration',
      );

      expect(foregroundMetric, isNotNull);
      expect(backgroundMetric, isNotNull);

      final foregroundPoint = foregroundMetric!.points.single;
      final backgroundPoint = backgroundMetric!.points.single;
      expect(foregroundPoint.count, 1);
      expect(foregroundPoint.sum, closeTo(1500, 0.001));
      expect(foregroundPoint.attributes['app.lifecycle.from'], 'resumed');
      expect(foregroundPoint.attributes['app.lifecycle.to'], 'paused');
      expect(backgroundPoint.count, 1);
      expect(backgroundPoint.sum, closeTo(1500, 0.001));
      expect(backgroundPoint.attributes['app.lifecycle.from'], 'paused');
      expect(backgroundPoint.attributes['app.lifecycle.to'], 'resumed');
    },
  );

  test('binding observer records memory pressure log and counter', () async {
    final observer = OtelFlutterBindingObserver();

    observer.didHaveMemoryPressure();
    await Otel.forceFlush();

    final memoryPressureMetric = metricExporter.lastMetricNamed(
      'app.memory_pressure.count',
    );

    expect(memoryPressureMetric, isNotNull);
    expect(memoryPressureMetric!.instrumentType, MetricInstrumentType.counter);
    expect(memoryPressureMetric.points.single.value, 1);
    expect(logExporter.logs.last.body, 'app.memory_pressure');
  });

  testWidgets('navigation emits only a sanitized screen_ready span', (
    tester,
  ) async {
    final observer = OtelNavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        routes: <String, WidgetBuilder>{
          '/order/12345': (_) => const Scaffold(body: Text('order')),
        },
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () =>
                    Navigator.of(context).pushNamed('/order/12345'),
                child: const Text('go'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // fires the post-frame callback that ends screen_ready
    await tester.pump();
    await Otel.forceFlush();

    final names = spanExporter.spans.map((span) => span.name).toList();
    expect(names, contains('flutter.screen_ready /order/:id'));
    expect(
      names.any((name) => name.startsWith('flutter.route ')),
      isFalse,
      reason: 'umbrella route span must no longer be created',
    );
    expect(
      names.any((name) => name.contains('12345')),
      isFalse,
      reason: 'route names must be sanitized against cardinality',
    );

    observer.dispose();
  });

  testWidgets('navigator observer records screen-ready spans', (tester) async {
    final observer = OtelNavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
        routes: <String, WidgetBuilder>{
          '/details': (_) => const Scaffold(body: Text('details')),
        },
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/details'),
                child: const Text('go'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
    await Otel.forceFlush();

    final readySpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'flutter.screen_ready /details',
    );
    expect(readySpan.attributes['flutter.route.ready'], true);
    expect(
      readySpan.events.map((event) => event.name),
      contains('flutter.screen_ready'),
    );
    expect(readySpan.attributes[SemanticAttributes.flutterRoute], '/details');
    expect(readySpan.attributes['screen.name'], '/details');
    expect(readySpan.attributes['screen.class'], isNotNull);
    expect(readySpan.attributes['flutter.navigation.action'], 'push');
  });

  test(
    'frame timing observer records frame histograms and slow/jank counters',
    () async {
      final observer = OtelFlutterFrameTimingObserver(
        slowFrameThreshold: const Duration(milliseconds: 16),
        jankFrameThreshold: const Duration(milliseconds: 32),
      );

      observer.recordFrameSample(
        totalSpan: const Duration(milliseconds: 12),
        buildDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: 5),
      );
      observer.recordFrameSample(
        totalSpan: const Duration(milliseconds: 20),
        buildDuration: const Duration(milliseconds: 8),
        rasterDuration: const Duration(milliseconds: 9),
      );
      observer.recordFrameSample(
        totalSpan: const Duration(milliseconds: 40),
        buildDuration: const Duration(milliseconds: 15),
        rasterDuration: const Duration(milliseconds: 18),
      );
      await Otel.forceFlush();

      final frameDurationMetric = metricExporter.lastMetricNamed(
        'flutter.frame.duration',
      );
      final buildDurationMetric = metricExporter.lastMetricNamed(
        'flutter.build.duration',
      );
      final rasterDurationMetric = metricExporter.lastMetricNamed(
        'flutter.raster.duration',
      );
      final slowFrameMetric = metricExporter.lastMetricNamed(
        'flutter.frame.slow.count',
      );
      final jankFrameMetric = metricExporter.lastMetricNamed(
        'flutter.frame.jank.count',
      );

      expect(frameDurationMetric, isNotNull);
      expect(
        frameDurationMetric!.instrumentType,
        MetricInstrumentType.histogram,
      );
      expect(frameDurationMetric.points.single.count, 3);
      expect(frameDurationMetric.points.single.sum, closeTo(72, 0.001));

      expect(buildDurationMetric, isNotNull);
      expect(buildDurationMetric!.points.single.count, 3);
      expect(buildDurationMetric.points.single.sum, closeTo(27, 0.001));

      expect(rasterDurationMetric, isNotNull);
      expect(rasterDurationMetric!.points.single.count, 3);
      expect(rasterDurationMetric.points.single.sum, closeTo(32, 0.001));

      expect(slowFrameMetric, isNotNull);
      expect(slowFrameMetric!.instrumentType, MetricInstrumentType.counter);
      expect(slowFrameMetric.points.single.value, 1);
      expect(
        slowFrameMetric
            .points
            .single
            .attributes['flutter.frame.classification'],
        'slow',
      );

      expect(jankFrameMetric, isNotNull);
      expect(jankFrameMetric!.instrumentType, MetricInstrumentType.counter);
      expect(jankFrameMetric.points.single.value, 1);
      expect(
        jankFrameMetric
            .points
            .single
            .attributes['flutter.frame.classification'],
        'jank',
      );
    },
  );

  test(
    'ui stall observer records stall metric, counter, and warning log',
    () async {
      final observer = OtelFlutterUiStallObserver(
        checkInterval: const Duration(milliseconds: 50),
        threshold: const Duration(milliseconds: 100),
      );
      final startedAt = DateTime.utc(2026, 3, 20, 12, 0, 0);

      observer.recordTick(startedAt);
      observer.recordTick(startedAt.add(const Duration(milliseconds: 50)));
      observer.recordTick(startedAt.add(const Duration(milliseconds: 250)));
      await Otel.forceFlush();

      final durationMetric = metricExporter.lastMetricNamed(
        'flutter.ui.stall.duration',
      );
      final countMetric = metricExporter.lastMetricNamed(
        'flutter.ui.stall.count',
      );
      final stallLog = logExporter.logs.singleWhere(
        (log) => log.body == 'flutter.ui_stall',
      );

      expect(durationMetric, isNotNull);
      expect(durationMetric!.instrumentType, MetricInstrumentType.histogram);
      expect(durationMetric.points.single.count, 1);
      expect(durationMetric.points.single.sum, closeTo(150, 0.001));

      expect(countMetric, isNotNull);
      expect(countMetric!.instrumentType, MetricInstrumentType.counter);
      expect(countMetric.points.single.value, 1);
      expect(stallLog.attributes['flutter.ui_stall.delay_ms'], 150.0);
    },
  );

  test(
    'ui stall metrics keep a constant series count regardless of stall delays',
    () async {
      final observer = OtelFlutterUiStallObserver(
        checkInterval: const Duration(milliseconds: 50),
        threshold: const Duration(milliseconds: 100),
        staticAttributes: const <String, Object>{'device.tier': 'low'},
      );
      var at = DateTime.utc(2026, 3, 20, 12, 0, 0);
      observer.recordTick(at);
      final delaysMs = <int>[];
      for (var i = 0; i < 25; i++) {
        final delayMs = 150 + i * 37;
        delaysMs.add(delayMs);
        at = at.add(Duration(milliseconds: 50 + delayMs));
        observer.recordTick(at);
      }
      await Otel.forceFlush();

      final durationMetric = metricExporter.lastMetricNamed(
        'flutter.ui.stall.duration',
      )!;
      final countMetric = metricExporter.lastMetricNamed(
        'flutter.ui.stall.count',
      )!;
      // One attribute set per instrument, no matter how many distinct
      // delays: the delay is the histogram VALUE, never a label.
      expect(durationMetric.points, hasLength(1));
      expect(countMetric.points, hasLength(1));
      expect(durationMetric.points.single.count, delaysMs.length);
      expect(
        durationMetric.points.single.sum,
        closeTo(delaysMs.fold<int>(0, (a, b) => a + b), 0.001),
      );
      expect(countMetric.points.single.value, delaysMs.length);
      expect(durationMetric.points.single.attributes, const <String, Object>{
        'device.tier': 'low',
      });

      // The per-stall detail stays available on the log record.
      final stallLogs = logExporter.logs.where(
        (log) => log.body == 'flutter.ui_stall',
      );
      expect(stallLogs, hasLength(delaysMs.length));
      expect(stallLogs.first.attributes['flutter.ui_stall.delay_ms'], 150.0);
    },
  );

  testWidgets(
    'ui stall timer only measures while resumed (no false stall after a freeze)',
    (tester) async {
      var wallClock = DateTime.utc(2026, 3, 20, 12, 0, 0);
      var monotonic = Duration.zero;
      void advance(Duration by) {
        wallClock = wallClock.add(by);
        monotonic += by;
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final observer = OtelFlutterUiStallObserver(
        checkInterval: const Duration(milliseconds: 50),
        threshold: const Duration(milliseconds: 100),
        now: () => wallClock,
        elapsed: () => monotonic,
      )..start();

      Future<void> healthyTicks(int count) async {
        for (var i = 0; i < count; i++) {
          advance(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await healthyTicks(3);
      // Positive control: a real 300 ms stall while resumed is recorded.
      advance(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 50));
      await healthyTicks(3);

      // App goes to background and the process is frozen for 30 minutes; the
      // timer may still get a late tick when the process thaws.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      advance(const Duration(minutes: 30));
      await tester.pump(const Duration(milliseconds: 50));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await healthyTicks(3);

      observer.dispose();
      await Otel.forceFlush();

      final stallLogs = logExporter.logs
          .where((log) => log.body == 'flutter.ui_stall')
          .toList();
      expect(stallLogs, hasLength(1));
      expect(stallLogs.single.attributes['flutter.ui_stall.delay_ms'], 300.0);
    },
  );

  testWidgets(
    'ui stall poller ignores wall-clock jumps (measures on the monotonic clock)',
    (tester) async {
      var wallClock = DateTime.utc(2026, 3, 20, 12, 0, 0);
      var monotonic = Duration.zero;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final observer = OtelFlutterUiStallObserver(
        checkInterval: const Duration(milliseconds: 50),
        threshold: const Duration(milliseconds: 100),
        now: () => wallClock,
        elapsed: () => monotonic,
      )..start();
      expect(observer.isPolling, isTrue);

      Future<void> healthyTick() async {
        monotonic += const Duration(milliseconds: 50);
        wallClock = wallClock.add(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
      }

      List<LogRecord> stallLogs() => logExporter.logs
          .where((log) => log.body == 'flutter.ui_stall')
          .toList();

      await healthyTick();
      // Wall clock jumps forward 30 min (NTP / user change) while the UI
      // thread stays healthy: the monotonic clock only moves one interval.
      wallClock = wallClock.add(const Duration(minutes: 30));
      await healthyTick();
      // ...and back again.
      wallClock = wallClock.subtract(const Duration(minutes: 30));
      await healthyTick();
      await healthyTick();
      await Otel.forceFlush();
      expect(stallLogs(), isEmpty, reason: 'a wall-clock jump is not a stall');

      // Positive control: a real 300 ms stall on the monotonic clock only.
      monotonic += const Duration(milliseconds: 350);
      await tester.pump(const Duration(milliseconds: 50));
      await Otel.forceFlush();
      expect(stallLogs(), hasLength(1));
      expect(stallLogs().single.attributes['flutter.ui_stall.delay_ms'], 300.0);

      observer.dispose();
    },
  );

  testWidgets('ui stall timer never starts without a resumed lifecycle', (
    tester,
  ) async {
    // Headless isolates (e.g. WorkManager) never report a lifecycle state.
    expect(tester.binding.lifecycleState, isNull);
    final observer = OtelFlutterUiStallObserver(elapsed: () => Duration.zero)
      ..start();
    expect(observer.isPolling, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(observer.isPolling, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(observer.isPolling, isFalse);

    observer.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(observer.isPolling, isFalse);
  });

  test('install is idempotent: a second call never duplicates hooks', () async {
    const config = ComonOtelFlutterConfig(
      observeAppLifecycle: false,
      trackNavigatorRoutes: false,
      markFirstFrame: false,
    );
    final first = ComonOtelFlutter.install(config: config);
    final second = ComonOtelFlutter.install(config: config);
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(identical(first, second), isTrue);

    FlutterError.onError?.call(
      FlutterErrorDetails(
        exception: StateError('once'),
        stack: StackTrace.current,
      ),
    );
    await Otel.forceFlush();
    expect(
      spanExporter.spans.where((span) => span.name == 'flutter.error'),
      hasLength(1),
    );

    second.dispose();
    first.dispose(); // A repeated dispose is a no-op.
    expect(FlutterError.onError, same(FlutterError.presentError));
  });

  test(
    'install against a new Otel instance replaces the stale installation',
    () async {
      const config = ComonOtelFlutterConfig(
        observeAppLifecycle: false,
        trackNavigatorRoutes: false,
        markFirstFrame: false,
      );
      final stale = ComonOtelFlutter.install(config: config);
      addTearDown(stale.dispose);

      final exporter = InMemorySpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'reinit',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );
      final fresh = ComonOtelFlutter.install(config: config);
      addTearDown(fresh.dispose);
      expect(identical(stale, fresh), isFalse);

      FlutterError.onError?.call(
        FlutterErrorDetails(
          exception: StateError('once'),
          stack: StackTrace.current,
        ),
      );
      await Otel.forceFlush();
      expect(
        exporter.spans.where((span) => span.name == 'flutter.error'),
        hasLength(1),
      );

      // Disposing the stale handle late must not clobber the live hooks.
      stale.dispose();
      expect(FlutterError.onError, isNot(same(FlutterError.presentError)));
      fresh.dispose();
      expect(FlutterError.onError, same(FlutterError.presentError));
    },
  );

  test('flutter framework errors are recorded as telemetry', () async {
    final instrumentation = ComonOtelFlutter.install(
      config: const ComonOtelFlutterConfig(observeAppLifecycle: false),
    );

    FlutterError.onError?.call(
      FlutterErrorDetails(
        exception: StateError('framework boom'),
        stack: StackTrace.current,
        context: ErrorDescription('during widget build'),
      ),
    );
    await Otel.forceFlush();

    final errorSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'flutter.error',
    );
    final errorLog = logExporter.logs.singleWhere(
      (log) => log.body == 'flutter.framework_error',
    );

    expect(errorSpan.status, SpanStatus.error);
    expect(
      errorLog.attributes[SemanticAttributes.exceptionMessage],
      contains('framework boom'),
    );

    instrumentation.dispose();
  });

  testWidgets('framework errors include breadcrumb trail from recent signals', (
    tester,
  ) async {
    final lifecycleObserver = OtelFlutterBindingObserver();
    final navigatorObserver = OtelNavigatorObserver();
    final stallObserver = OtelFlutterUiStallObserver(
      checkInterval: const Duration(milliseconds: 50),
      threshold: const Duration(milliseconds: 100),
    );
    final startedAt = DateTime.utc(2026, 3, 20, 15, 0, 0);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[navigatorObserver],
        routes: <String, WidgetBuilder>{
          '/details': (_) => const Scaffold(body: Text('details')),
        },
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/details'),
                child: const Text('go'),
              );
            },
          ),
        ),
      ),
    );

    lifecycleObserver.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    stallObserver.recordTick(startedAt);
    stallObserver.recordTick(startedAt.add(const Duration(milliseconds: 250)));

    recordFlutterFrameworkError(
      FlutterErrorDetails(
        exception: StateError('breadcrumb boom'),
        stack: StackTrace.current,
        context: ErrorDescription('during breadcrumb capture'),
      ),
      fallback: (_) {},
    );
    await Otel.forceFlush();

    final errorLog = logExporter.logs.singleWhere(
      (log) => log.body == 'flutter.framework_error',
    );
    final breadcrumbs =
        errorLog.attributes['flutter.error.breadcrumbs'] as String;

    expect(breadcrumbs, contains('lifecycle resumed'));
    expect(breadcrumbs, contains('navigation push'));
    expect(breadcrumbs, contains('performance ui_stall'));
    expect(breadcrumbs, contains('/details'));

    navigatorObserver.dispose();
    stallObserver.dispose();
  });

  testWidgets(
    'framework errors include grouping, route, and diagnostic context',
    (tester) async {
      final observer = OtelNavigatorObserver();

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[observer],
          routes: <String, WidgetBuilder>{
            '/details': (_) => const Scaffold(body: Text('details')),
          },
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () => Navigator.of(context).pushNamed('/details'),
                  child: const Text('go'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      recordFlutterFrameworkError(
        FlutterErrorDetails(
          exception: StateError('framework grouped boom'),
          stack: StackTrace.current,
          context: ErrorDescription('during grouped widget build'),
          informationCollector: () sync* {
            yield DiagnosticsNode.message('widget: DetailsScreen');
            yield DiagnosticsNode.message(
              'tree: MaterialApp > Navigator > Details',
            );
          },
        ),
        fallback: (_) {},
      );
      await Otel.forceFlush();

      final errorSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'flutter.error',
      );
      final errorLog = logExporter.logs.singleWhere(
        (log) => log.body == 'flutter.framework_error',
      );

      expect(
        errorSpan.attributes['error.group.name'],
        contains('framework:StateError'),
      );
      expect(errorSpan.attributes['flutter.route.name'], '/details');
      expect(errorSpan.attributes['screen.name'], '/details');
      expect(
        errorSpan.attributes['flutter.error.diagnostics'],
        contains('DetailsScreen'),
      );
      expect(
        errorLog.attributes['error.group.name'],
        contains('framework:StateError'),
      );
      expect(errorLog.attributes['flutter.route.name'], '/details');

      observer.dispose();
    },
  );

  test(
    'a failure inside error telemetry never skips the fallback or its verdict',
    () async {
      OtelFlutterErrorHooks.configure(
        frameworkErrorListener: (_) => throw StateError('listener boom'),
        platformErrorListener: (_) => throw StateError('listener boom'),
      );
      var frameworkFallbackCalls = 0;
      var platformFallbackCalls = 0;

      expect(
        () => recordFlutterFrameworkError(
          FlutterErrorDetails(
            exception: _ToStringThrows(),
            stack: StackTrace.current,
            informationCollector: () => throw StateError('collector boom'),
          ),
          fallback: (_) => frameworkFallbackCalls += 1,
        ),
        returnsNormally,
      );
      expect(frameworkFallbackCalls, 1);

      late bool handled;
      expect(
        () => handled = recordFlutterPlatformError(
          _ToStringThrows(),
          StackTrace.current,
          fallback: (error, stackTrace) {
            platformFallbackCalls += 1;
            return true;
          },
        ),
        returnsNormally,
      );
      expect(platformFallbackCalls, 1);
      expect(handled, isTrue);

      // Same guarantee with the hooks healthy but the attribute building
      // (exception.toString) failing.
      OtelFlutterErrorHooks.clear();
      expect(
        recordFlutterPlatformError(
          _ToStringThrows(),
          StackTrace.current,
          fallback: (error, stackTrace) {
            platformFallbackCalls += 1;
            return true;
          },
        ),
        isTrue,
      );
      expect(platformFallbackCalls, 2);
    },
  );

  test(
    'platform error handled flag reflects only the fallback, never Otel state',
    () async {
      expect(Otel.isInitialized, isTrue);

      expect(
        recordFlutterPlatformError(
          StateError('no fallback'),
          StackTrace.current,
        ),
        isFalse,
        reason: 'without a fallback the engine must keep its default handling',
      );
      expect(
        recordFlutterPlatformError(
          StateError('unhandled by fallback'),
          StackTrace.current,
          fallback: (error, stackTrace) => false,
        ),
        isFalse,
      );
      expect(
        recordFlutterPlatformError(
          StateError('handled by fallback'),
          StackTrace.current,
          fallback: (error, stackTrace) => true,
        ),
        isTrue,
      );
    },
  );

  test('platform errors include grouping and route context', () async {
    OtelFlutterRouteContext.update(
      routeName: '/profile',
      routeRuntimeType: 'MaterialPageRoute<dynamic>',
      previousRouteName: '/home',
    );

    recordFlutterPlatformError(
      ArgumentError('platform grouped boom'),
      StackTrace.current,
      fallback: (error, stackTrace) => false,
    );
    await Otel.forceFlush();

    final errorSpan = spanExporter.spans.singleWhere(
      (span) => span.name == 'flutter.platform_error',
    );
    final errorLog = logExporter.logs.singleWhere(
      (log) => log.body == 'flutter.platform_error',
    );

    expect(
      errorSpan.attributes['error.group.name'],
      contains('platform_dispatcher:ArgumentError'),
    );
    expect(errorSpan.attributes['flutter.route.name'], '/profile');
    expect(errorSpan.attributes['screen.previous.name'], '/home');
    expect(
      errorLog.attributes[SemanticAttributes.exceptionMessage],
      contains('platform grouped boom'),
    );
  });

  group('error telemetry never carries a URL path or query', () {
    test('framework error: message, context, diagnostics, breadcrumbs, '
        'status, event and log', () async {
      OtelFlutterBreadcrumbs.add(category: 'http', message: 'GET $_leakyUrl');

      recordFlutterFrameworkError(
        FlutterErrorDetails(
          exception: _UrlInMessageError(),
          stack: _stackWithUrl(),
          context: ErrorDescription('while fetching $_leakyUrl'),
          informationCollector: () sync* {
            yield DiagnosticsNode.message(
              'Image provider: NetworkImage("$_leakyUrl", scale: 1.0)',
            );
          },
        ),
        fallback: (_) {},
      );
      await Otel.forceFlush();

      final errorSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'flutter.error',
      );
      final errorLog = logExporter.logs.singleWhere(
        (log) => log.body == 'flutter.framework_error',
      );

      expect(
        errorSpan.attributes['flutter.error.diagnostics'],
        contains('NetworkImage("https://bucket.s3.amazonaws.com/…"'),
      );
      expect(errorSpan.statusDescription, isNotNull);
      expect(
        errorSpan.events.map((event) => event.name),
        contains('exception'),
      );
      _expectNoLeak(_flattenSpan(errorSpan));
      _expectNoLeak(_flattenLog(errorLog));
    });

    test('platform error: attributes, status, event and log', () async {
      recordFlutterPlatformError(
        _UrlInMessageError(),
        _stackWithUrl(),
        fallback: (error, stackTrace) => true,
      );
      await Otel.forceFlush();

      final errorSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'flutter.platform_error',
      );
      final errorLog = logExporter.logs.singleWhere(
        (log) => log.body == 'flutter.platform_error',
      );

      expect(
        errorLog.attributes[SemanticAttributes.exceptionMessage],
        contains('uri=https://bucket.s3.amazonaws.com/…'),
      );
      _expectNoLeak(_flattenSpan(errorSpan));
      _expectNoLeak(_flattenLog(errorLog));
    });

    test('error hooks receive scrubbed attributes', () async {
      OtelFlutterErrorSnapshot? captured;
      OtelFlutterErrorHooks.configure(
        platformErrorListener: (snapshot) => captured = snapshot,
      );

      recordFlutterPlatformError(
        _UrlInMessageError(),
        _stackWithUrl(),
        fallback: (error, stackTrace) => true,
      );

      expect(captured, isNotNull);
      _expectNoLeak(captured!.attributes.values.join(' '));
    });

    test('startup trackPhase error: status and event', () async {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
          markFirstFrame: false,
        ),
      );

      await expectLater(
        instrumentation.startupTracker!.trackPhase<void>(
          'upload',
          () async =>
              Error.throwWithStackTrace(_UrlInMessageError(), _stackWithUrl()),
        ),
        throwsA(isA<_UrlInMessageError>()),
      );
      await Otel.forceFlush();

      final phaseSpan = spanExporter.spans.singleWhere(
        (span) => span.name == 'app.startup.upload',
      );
      expect(phaseSpan.status, SpanStatus.error);
      _expectNoLeak(_flattenSpan(phaseSpan));

      instrumentation.dispose();
    });
  });

  test('interaction helpers trace tap callbacks with route context', () async {
    OtelFlutterRouteContext.update(
      routeName: '/checkout',
      routeRuntimeType: 'MaterialPageRoute<dynamic>',
      previousRouteName: '/cart',
    );

    var tapped = false;
    final callback = OtelFlutterInteractions.wrapTap(
      targetName: 'checkout_button',
      attributes: const <String, Object>{'feature.flag': 'new_checkout'},
      onTap: () {
        tapped = true;
      },
    );

    callback();
    await Otel.forceFlush();

    expect(tapped, isTrue);
    final span = spanExporter.spans.singleWhere(
      (span) => span.name == 'flutter.interaction tap checkout_button',
    );
    expect(span.status, SpanStatus.ok);
    expect(span.attributes['flutter.interaction.type'], 'tap');
    expect(span.attributes['flutter.target.name'], 'checkout_button');
    expect(span.attributes['flutter.route.name'], '/checkout');
    expect(span.attributes['screen.previous.name'], '/cart');
    expect(span.attributes['feature.flag'], 'new_checkout');

    final breadcrumbs = OtelFlutterBreadcrumbs.serialize();
    expect(breadcrumbs, contains('tap checkout_button'));
  });

  test('screen span processor stamps active screen onto spans', () async {
    final exporter = InMemorySpanExporter();
    await Otel.shutdown();
    await Otel.init(
      serviceName: 'stamp-test',
      spanProcessors: <SpanProcessor>[
        OtelFlutterScreenSpanProcessor(),
        SimpleSpanProcessor(exporter),
      ],
      metricReaders: const <MetricReader>[],
      logProcessors: const <LogProcessor>[],
    );

    OtelFlutterRouteContext.update(
      routeName: '/checkout',
      routeRuntimeType: 'CheckoutRoute',
    );

    await Otel.instance.tracer.traceAsync('http-call', fn: () async {});
    await Otel.forceFlush();

    final span = exporter.lastSpanNamed('http-call');
    expect(span, isNotNull);
    expect(span!.attributes['screen.name'], '/checkout');
    expect(span.attributes['flutter.route.name'], '/checkout');

    OtelFlutterRouteContext.clear();
    await Otel.shutdown();
  });

  test(
    'screen span processor never overwrites an explicit screen.name',
    () async {
      final exporter = InMemorySpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'stamp-guard-test',
        spanProcessors: <SpanProcessor>[
          OtelFlutterScreenSpanProcessor(),
          SimpleSpanProcessor(exporter),
        ],
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      OtelFlutterRouteContext.update(
        routeName: '/checkout',
        routeRuntimeType: 'CheckoutRoute',
      );

      // The span is born with an explicit screen.name; onStart must not clobber
      // it with the active route.
      await Otel.instance.tracer.traceAsync(
        'http-call',
        attributes: const <String, Object>{'screen.name': '/explicit'},
        fn: () async {},
      );
      await Otel.forceFlush();

      final span = exporter.lastSpanNamed('http-call');
      expect(span, isNotNull);
      expect(span!.attributes['screen.name'], '/explicit');
      // flutter.route.name was not set explicitly, so it is still stamped.
      expect(span.attributes['flutter.route.name'], '/checkout');

      OtelFlutterRouteContext.clear();
      await Otel.shutdown();
    },
  );

  test(
    'screen span processor stamps nothing when no route is active',
    () async {
      final exporter = InMemorySpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'stamp-empty-test',
        spanProcessors: <SpanProcessor>[
          OtelFlutterScreenSpanProcessor(),
          SimpleSpanProcessor(exporter),
        ],
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      OtelFlutterRouteContext.clear();

      // With no active route context, onStart must early-return without
      // throwing and leave the span unstamped.
      await Otel.instance.tracer.traceAsync('http-call', fn: () async {});
      await Otel.forceFlush();

      final span = exporter.lastSpanNamed('http-call');
      expect(span, isNotNull);
      expect(span!.attributes.containsKey('screen.name'), isFalse);
      expect(span.attributes.containsKey('flutter.route.name'), isFalse);

      OtelFlutterRouteContext.clear();
      await Otel.shutdown();
    },
  );

  test(
    'interaction helpers trace async form submissions and failures',
    () async {
      OtelFlutterRouteContext.update(
        routeName: '/payment',
        routeRuntimeType: 'MaterialPageRoute<dynamic>',
      );

      await expectLater(
        OtelFlutterInteractions.traceFormSubmit<void>(
          formName: 'payment_form',
          attributes: const <String, Object>{'flutter.form.step': 'confirm'},
          action: () async {
            throw StateError('submit boom');
          },
        ),
        throwsA(isA<StateError>()),
      );
      await Otel.forceFlush();

      final span = spanExporter.spans.singleWhere(
        (span) => span.name == 'flutter.interaction form_submit payment_form',
      );
      expect(span.status, SpanStatus.error);
      expect(span.attributes['flutter.form.name'], 'payment_form');
      expect(span.attributes['flutter.form.step'], 'confirm');
      expect(span.attributes['flutter.route.name'], '/payment');
      expect(
        span.events.any(
          (event) =>
              event.name == 'exception' &&
              event.attributes[SemanticAttributes.exceptionMessage]
                  .toString()
                  .contains('submit boom'),
        ),
        isTrue,
      );
    },
  );

  group('OtelNavigatorObserver.sanitizeRouteName', () {
    test('collapses numeric and uuid segments to :id', () {
      expect(
        OtelNavigatorObserver.sanitizeRouteName('/order/12345'),
        '/order/:id',
      );
      expect(
        OtelNavigatorObserver.sanitizeRouteName(
          '/u/3fa85f64-5717-4562-b3fc-2c963f66afa6',
        ),
        '/u/:id',
      );
    });

    test('strips query string and fragment before sanitizing', () {
      expect(
        OtelNavigatorObserver.sanitizeRouteName('/order/12345?from=push'),
        '/order/:id',
      );
      expect(
        OtelNavigatorObserver.sanitizeRouteName('/order/12345#section'),
        '/order/:id',
      );
    });

    test('sanitizes relative names without a leading slash', () {
      expect(
        OtelNavigatorObserver.sanitizeRouteName('profile/42'),
        'profile/:id',
      );
    });
  });

  test('iosResourceValuesFrom reads systemName, never the PII device name', () {
    const piiDeviceName = 'iPhone de João';
    final ios = IosDeviceInfo.setMockInitialValues(
      name: piiDeviceName, // PII — must NOT appear in any extracted value
      systemName: 'iOS',
      systemVersion: '17.4',
      model: 'iPhone',
      modelName: 'iPhone 15 Pro',
      localizedModel: 'iPhone',
      identifierForVendor: 'FAKE-UUID',
      isPhysicalDevice: true,
      isiOSAppOnMac: false,
      isiOSAppOnVision: false,
      freeDiskSize: 1,
      totalDiskSize: 2,
      physicalRamSize: 1,
      availableRamSize: 1,
      utsname: IosUtsname.setMockInitialValues(
        sysname: 'Darwin',
        nodename: 'iPhone',
        release: '23.0.0',
        version: 'x',
        machine: 'iPhone15,2',
      ),
    );

    final values = iosResourceValuesFrom(ios);

    expect(values.osName, 'iOS');
    expect(values.osVersion, '17.4');
    expect(values.modelId, 'iPhone15,2');
    expect(values.manufacturer, 'Apple');
    expect(<String>[
      values.osName,
      values.osVersion,
      values.modelId,
      values.manufacturer,
    ], isNot(contains(piiDeviceName)));
  });
}

final class _ToStringThrows {
  @override
  String toString() => throw StateError('toString boom');
}

/// URL whose path carries a CPF and whose query carries an S3 signature.
const String _leakyUrl =
    'https://bucket.s3.amazonaws.com/colaboradores/12345678900/foto.jpg'
    '?X-Amz-Signature=deadbeefcafe&X-Amz-Credential=AKIA#frag';

/// Fragments of [_leakyUrl] that must not survive scrubbing.
const List<String> _leakyFragments = <String>[
  '12345678900',
  'colaboradores',
  'foto.jpg',
  'X-Amz-Signature',
  'deadbeefcafe',
  'AKIA',
  '#frag',
];

final class _UrlInMessageError implements Exception {
  @override
  String toString() => 'ClientException: Connection closed, uri=$_leakyUrl';
}

StackTrace _stackWithUrl() => StackTrace.fromString(
  <String>[
    '#0      Uploader.put (package:app/uploader.dart:10:3)',
    '#1      request $_leakyUrl',
    '#2      main (package:app/main.dart:5:1)',
  ].join(String.fromCharCode(10)),
);

/// Flattens every exported string of a span (attributes, events, status).
String _flattenSpan(SpanData span) {
  final buffer = StringBuffer()
    ..writeln(span.name)
    ..writeln(span.statusDescription ?? '');
  for (final value in span.attributes.values) {
    buffer.writeln(value);
  }
  for (final event in span.events) {
    buffer.writeln(event.name);
    for (final value in event.attributes.values) {
      buffer.writeln(value);
    }
  }
  return buffer.toString();
}

/// Flattens every exported string of a log record (body and attributes).
String _flattenLog(LogRecord log) {
  final buffer = StringBuffer()..writeln(log.body);
  for (final value in log.attributes.values) {
    buffer.writeln(value);
  }
  return buffer.toString();
}

void _expectNoLeak(String flattened) {
  for (final fragment in _leakyFragments) {
    expect(flattened, isNot(contains(fragment)), reason: flattened);
  }
}
