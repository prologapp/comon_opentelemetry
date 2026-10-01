import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:comon_otel_flutter/comon_otel_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryMetricExporter metricExporter;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    metricExporter = InMemoryMetricExporter();

    await Otel.shutdown();
    await Otel.init(
      serviceName: 'flutter-test-app',
      metricReaders: <MetricReader>[
        ExportingMetricReader(exporter: metricExporter),
      ],
    );
  });

  tearDown(() async {
    await Otel.shutdown();
  });

  group('all toggles off (AC1)', () {
    test('install exposes no resourceObserver when every toggle is off', () {
      final instrumentation = ComonOtelFlutter.install(
        config: const ComonOtelFlutterConfig(
          observeAppLifecycle: false,
          trackNavigatorRoutes: false,
        ),
      );

      expect(instrumentation.resourceObserver, isNull);

      instrumentation.dispose();
    });

    test('disabled signals never subscribe, record, or emit', () async {
      var thermalStreamCalled = false;
      var storageGetterCalled = false;
      var batteryLevelGetterCalled = false;
      final observer = OtelFlutterResourceObserver(
        storageFreeBytesGetter: () async {
          storageGetterCalled = true;
          return 123;
        },
        thermalStateStreamGetter: () {
          thermalStreamCalled = true;
          return const Stream<String>.empty();
        },
        batteryLevelGetter: () async {
          batteryLevelGetterCalled = true;
          return 50;
        },
        batteryStateStreamGetter: () => const Stream<String>.empty(),
      );

      observer.start();
      await observer.recordStorageMilestone('startup');
      await observer.recordBatteryMoment('startup');
      await Otel.forceFlush();

      expect(thermalStreamCalled, isFalse);
      expect(storageGetterCalled, isFalse);
      expect(batteryLevelGetterCalled, isFalse);
      expect(metricExporter.lastMetricNamed('app.device.storage.free'), isNull);
      expect(
        metricExporter.lastMetricNamed('app.device.battery.level'),
        isNull,
      );
      expect(
        metricExporter.lastMetricNamed('app.device.battery.state'),
        isNull,
      );
      expect(
        metricExporter.lastMetricNamed('app.device.thermal.count'),
        isNull,
      );
      expect(metricExporter.lastMetricNamed('app.process.memory.rss'), isNull);

      observer.dispose();
    });
  });

  group('battery (AC2)', () {
    test(
      'level metric never carries the numeric level as an attribute',
      () async {
        final observer = OtelFlutterResourceObserver(
          trackBatteryMetrics: true,
          batteryLevelGetter: () async => 42,
          batteryStateStreamGetter: () => const Stream<String>.empty(),
        );

        observer.start();
        await observer.recordBatteryMoment('startup');
        await Otel.forceFlush();

        final metric = metricExporter.lastMetricNamed(
          'app.device.battery.level',
        );
        expect(metric, isNotNull);
        final point = metric!.points.single;
        expect(point.value, 42.0);
        expect(point.attributes['moment'], 'startup');
        expect(point.attributes.containsKey('level'), isFalse);
        expect(
          point.attributes.values.any((value) => value == 42 || value == 42.0),
          isFalse,
        );

        observer.dispose();
      },
    );

    test('state gauge exposes only the current state label', () async {
      final controller = StreamController<String>();
      final observer = OtelFlutterResourceObserver(
        trackBatteryMetrics: true,
        batteryLevelGetter: () async => 10,
        batteryStateStreamGetter: () => controller.stream,
      );

      observer.start();
      controller.add('charging');
      await Future<void>.delayed(Duration.zero);
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.battery.state');
      expect(metric, isNotNull);
      final point = metric!.points.single;
      expect(point.value, 1.0);
      expect(point.attributes['state'], 'charging');
      expect(point.attributes.keys.toSet(), <String>{'state'});

      observer.dispose();
      await controller.close();
    });

    test('state gauge merges staticAttributes with the state label', () async {
      final controller = StreamController<String>();
      final observer = OtelFlutterResourceObserver(
        trackBatteryMetrics: true,
        batteryLevelGetter: () async => 10,
        batteryStateStreamGetter: () => controller.stream,
        staticAttributes: const <String, Object>{'device.tier': 'low'},
      );

      observer.start();
      controller.add('discharging');
      await Future<void>.delayed(Duration.zero);
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.battery.state');
      expect(metric, isNotNull);
      final point = metric!.points.single;
      expect(point.attributes.keys.toSet(), <String>{'state', 'device.tier'});
      expect(point.attributes['state'], 'discharging');
      expect(point.attributes['device.tier'], 'low');

      observer.dispose();
      await controller.close();
    });

    test(
      'a throwing level getter does not crash and records no point',
      () async {
        final observer = OtelFlutterResourceObserver(
          trackBatteryMetrics: true,
          batteryLevelGetter: () async => throw StateError('boom'),
          batteryStateStreamGetter: () => const Stream<String>.empty(),
        );

        observer.start();
        await observer.recordBatteryMoment('startup');
        await Otel.forceFlush();

        expect(
          metricExporter.lastMetricNamed('app.device.battery.level'),
          isNull,
        );

        observer.dispose();
      },
    );

    test(
      'a battery-state stream error does not crash start()/dispose()',
      () async {
        final observer = OtelFlutterResourceObserver(
          trackBatteryMetrics: true,
          batteryLevelGetter: () async => 10,
          batteryStateStreamGetter: () =>
              Stream<String>.error(StateError('battery stream boom')),
        );

        await runZonedGuarded(
          () async {
            observer.start();
            await Future<void>.delayed(Duration.zero);
            await Otel.forceFlush();
            observer.dispose();
          },
          (error, stackTrace) {
            fail('unhandled error escaped the observer: $error');
          },
        );
      },
    );
  });

  group('thermal (AC3)', () {
    test('counts only real transitions, not repeats', () async {
      final controller = StreamController<String>();
      final observer = OtelFlutterResourceObserver(
        trackThermalMetrics: true,
        thermalStateStreamGetter: () => controller.stream,
      );

      observer.start();
      for (final state in <String>[
        'nominal',
        'fair',
        'fair',
        'serious',
        'critical',
      ]) {
        controller.add(state);
        await Future<void>.delayed(Duration.zero);
      }
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.thermal.count');
      expect(metric, isNotNull);
      final countByState = <Object?, num>{};
      for (final point in metric!.points) {
        final state = point.attributes['state'];
        countByState[state] = (countByState[state] ?? 0) + (point.value ?? 0);
      }
      // 'nominal' is the initial reading (baseline), not a transition.
      expect(countByState, <String, num>{
        'fair': 1,
        'serious': 1,
        'critical': 1,
      });

      observer.dispose();
      await controller.close();
    });

    test('the initial state is a baseline, not a transition', () async {
      final controller = StreamController<String>();
      final observer = OtelFlutterResourceObserver(
        trackThermalMetrics: true,
        thermalStateStreamGetter: () => controller.stream,
      );

      observer.start();
      controller.add('nominal');
      await Future<void>.delayed(Duration.zero);
      await Otel.forceFlush();

      expect(
        metricExporter.lastMetricNamed('app.device.thermal.count'),
        isNull,
      );

      observer.dispose();
      await controller.close();
    });

    test('a stream that never emits leaves the counter empty', () async {
      final observer = OtelFlutterResourceObserver(
        trackThermalMetrics: true,
        thermalStateStreamGetter: () => const Stream<String>.empty(),
      );

      observer.start();
      await Otel.forceFlush();

      expect(
        metricExporter.lastMetricNamed('app.device.thermal.count'),
        isNull,
      );

      observer.dispose();
    });

    test('dispose cancels the subscription', () async {
      final controller = StreamController<String>();
      final observer = OtelFlutterResourceObserver(
        trackThermalMetrics: true,
        thermalStateStreamGetter: () => controller.stream,
      );

      observer.start();
      expect(controller.hasListener, isTrue);
      controller.add('nominal');
      controller.add('fair');
      await Future<void>.delayed(Duration.zero);
      observer.dispose();
      expect(controller.hasListener, isFalse);

      controller.add('serious');
      await Future<void>.delayed(Duration.zero);
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.thermal.count');
      // nominal -> fair is the one transition; the post-dispose 'serious'
      // must not add a second count.
      expect(metric, isNotNull);
      final totalCount = metric!.points.fold<num>(
        0,
        (total, point) => total + (point.value ?? 0),
      );
      expect(totalCount, 1);

      await controller.close();
    });

    test(
      'an error mid-stream does not crash and later events still count',
      () async {
        final controller = StreamController<String>();
        final observer = OtelFlutterResourceObserver(
          trackThermalMetrics: true,
          thermalStateStreamGetter: () => controller.stream,
        );

        await runZonedGuarded(
          () async {
            observer.start();
            controller.add('nominal');
            await Future<void>.delayed(Duration.zero);
            controller.addError(StateError('thermal stream boom'));
            await Future<void>.delayed(Duration.zero);
            controller.add('fair');
            await Future<void>.delayed(Duration.zero);
            await Otel.forceFlush();
          },
          (error, stackTrace) {
            fail('unhandled error escaped the observer: $error');
          },
        );

        final metric = metricExporter.lastMetricNamed(
          'app.device.thermal.count',
        );
        expect(metric, isNotNull);
        final totalCount = metric!.points.fold<num>(
          0,
          (total, point) => total + (point.value ?? 0),
        );
        // 'nominal' is the baseline; 'fair' (real transition) still counts
        // after the error in between, and the error itself never counts.
        expect(totalCount, 1);

        observer.dispose();
        await controller.close();
      },
    );

    test('double start() does not leak/duplicate the subscription', () async {
      final controllers = <StreamController<String>>[];
      final observer = OtelFlutterResourceObserver(
        trackThermalMetrics: true,
        thermalStateStreamGetter: () {
          final controller = StreamController<String>();
          controllers.add(controller);
          return controller.stream;
        },
      );

      observer.start();
      observer.start();
      await Future<void>.delayed(Duration.zero);

      // Only the latest subscription stays alive.
      expect(controllers, hasLength(2));
      expect(controllers.first.hasListener, isFalse);
      expect(controllers.last.hasListener, isTrue);

      observer.dispose();
      expect(controllers.last.hasListener, isFalse);
      for (final controller in controllers) {
        await controller.close();
      }
    });
  });

  group('storage (AC4)', () {
    test('emits one gauge point per milestone with no path/filename', () async {
      // A single mutable "current reading" lets one observer instance
      // record three different milestones with three different byte values,
      // so the gauge accumulates all of them for one collection cycle.
      var currentBytes = 1000;
      final observer = OtelFlutterResourceObserver(
        trackStorageMetrics: true,
        storageFreeBytesGetter: () async => currentBytes,
      );

      await observer.recordStorageMilestone('before_photo_write');
      currentBytes = 2000;
      await observer.recordStorageMilestone('before_sync');
      currentBytes = 3000;
      await observer.recordStorageMilestone('startup');

      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.storage.free');
      expect(metric, isNotNull);
      expect(metric!.points, hasLength(3));
      final bytesByMilestone = <Object?, Object?>{
        for (final point in metric.points)
          point.attributes['milestone']: point.value,
      };
      expect(bytesByMilestone, <String, num>{
        'before_photo_write': 1000,
        'before_sync': 2000,
        'startup': 3000,
      });
      for (final point in metric.points) {
        expect(point.attributes.containsKey('path'), isFalse);
        expect(point.attributes.containsKey('filename'), isFalse);
      }

      observer.dispose();
    });

    test('null getter result records no point and does not crash', () async {
      final observer = OtelFlutterResourceObserver(
        trackStorageMetrics: true,
        storageFreeBytesGetter: () async => null,
      );

      await observer.recordStorageMilestone('startup');
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.device.storage.free');
      expect(metric, isNull);

      observer.dispose();
    });

    test('a throwing getter does not crash the observer', () async {
      final observer = OtelFlutterResourceObserver(
        trackStorageMetrics: true,
        storageFreeBytesGetter: () async => throw StateError('boom'),
      );

      await observer.recordStorageMilestone('startup');
      await Otel.forceFlush();

      expect(metricExporter.lastMetricNamed('app.device.storage.free'), isNull);

      observer.dispose();
    });
  });

  group('RSS', () {
    test('records a positive value when enabled', () async {
      final observer = OtelFlutterResourceObserver(trackRssMetrics: true);

      observer.start();
      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('app.process.memory.rss');
      expect(metric, isNotNull);
      expect(metric!.points.single.value, greaterThan(0));

      observer.dispose();
    });
  });

  group('dispose', () {
    test(
      'a disposed observer stops emitting its gauges (reinstall never duplicates series)',
      () async {
        OtelFlutterResourceObserver build() => OtelFlutterResourceObserver(
          trackStorageMetrics: true,
          trackBatteryMetrics: true,
          trackRssMetrics: true,
          storageFreeBytesGetter: () async => 1000,
          batteryStateStreamGetter: () => Stream<String>.value('charging'),
        );

        final first = build()..start();
        await first.recordStorageMilestone('startup');
        await Future<void>.delayed(Duration.zero);
        first.dispose();

        final second = build()..start();
        await second.recordStorageMilestone('startup');
        await Future<void>.delayed(Duration.zero);

        metricExporter.clear();
        await Otel.forceFlush();

        for (final name in <String>[
          'app.process.memory.rss',
          'app.device.storage.free',
          'app.device.battery.state',
        ]) {
          final metrics = metricExporter.metrics
              .where((metric) => metric.name == name)
              .toList();
          expect(
            metrics,
            hasLength(1),
            reason: '$name must be exported by the live observer only',
          );
          // One series, too: a muted callback that still observed would
          // show up as extra points on the surviving MetricData.
          expect(
            metrics.single.points,
            hasLength(1),
            reason: '$name must carry exactly one point (one series)',
          );
        }

        second.dispose();
        metricExporter.clear();
        await Otel.forceFlush();
        expect(
          metricExporter.metrics.where(
            (metric) => metric.name == 'app.process.memory.rss',
          ),
          isEmpty,
        );
      },
    );
  });

  group('edges', () {
    test('Otel not initialized does not crash', () async {
      await Otel.shutdown();

      final observer = OtelFlutterResourceObserver(
        trackStorageMetrics: true,
        trackBatteryMetrics: true,
        trackThermalMetrics: true,
        trackRssMetrics: true,
        storageFreeBytesGetter: () async => 100,
        thermalStateStreamGetter: () => const Stream<String>.empty(),
      );

      observer.start();
      await observer.recordStorageMilestone('startup');
      await observer.recordBatteryMoment('startup');

      observer.dispose();
    });
  });
}
