import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:comon_otel/comon_otel.dart';
import 'package:comon_otel/src/core/otel_session.dart';
import 'package:comon_otel/src/exporters/otlp/common/exporter_headers.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show formatHttpDate;
import 'package:test/test.dart';

part 'common/test_support.dart';
part 'src/trace_core_tests.dart';
part 'src/signals_pipeline_tests.dart';
part 'src/propagation_testing_tests.dart';
part 'src/config_resource_tests.dart';
part 'src/http_transport_tests.dart';
part 'src/batch_processor_health_tests.dart';
part 'src/session_tests.dart';
part 'src/metric_aggregation_tests.dart';
part 'src/export_resilience_tests.dart';
part 'src/id_generation_tests.dart';

late InMemorySpanExporter exporter;
late InMemoryMetricExporter metricExporter;
late InMemoryLogExporter logExporter;

Future<void> _setUpDefaultSdk() async {
  OtelEnvConfig.resetEnvSource();
  exporter = InMemorySpanExporter();
  metricExporter = InMemoryMetricExporter();
  logExporter = InMemoryLogExporter();
  await Otel.init(
    serviceName: 'test-service',
    spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
    metricReaders: <MetricReader>[
      ExportingMetricReader(exporter: metricExporter),
    ],
    logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
  );
}

Future<void> _tearDownDefaultSdk() async {
  await Otel.shutdown();
  OtelEnvConfig.resetEnvSource();
}

void main() {
  group('comon_otel unit', () {
    setUp(_setUpDefaultSdk);
    tearDown(_tearDownDefaultSdk);

    defineTraceCoreTests();
    defineSignalsPipelineTests();
    definePropagationAndTestingTests();
    defineConfigAndResourceTests();
    defineHttpTransportTests();
    defineBatchProcessorHealthTests();
    defineSessionTests();
    defineMetricAggregationTests();
    defineExportResilienceTests();
    defineIdGenerationTests();
  });
}
