import 'platform_runtime.dart';

/// Detects resource attributes from the current runtime environment.
abstract interface class ResourceDetector {
  /// Returns detected resource attributes.
  Map<String, Object> detect();
}

/// Detects process-level resource attributes.
final class ProcessResourceDetector implements ResourceDetector {
  /// Creates a process resource detector.
  const ProcessResourceDetector();

  @override
  Map<String, Object> detect() {
    return detectProcessResourceAttributes();
  }
}

/// Detects host-level resource attributes.
final class HostResourceDetector implements ResourceDetector {
  /// Creates a host resource detector.
  const HostResourceDetector();

  @override
  Map<String, Object> detect() {
    return detectHostResourceAttributes();
  }
}

/// Detects OpenTelemetry SDK identity attributes (spec-mandatory).
final class TelemetrySdkResourceDetector implements ResourceDetector {
  /// Creates a telemetry SDK resource detector.
  const TelemetrySdkResourceDetector();

  @override
  Map<String, Object> detect() {
    // telemetry.sdk.version is hardcoded; keep it in sync with the package
    // version in pubspec.yaml on every release bump.
    return const <String, Object>{
      'telemetry.sdk.name': 'comon_otel',
      'telemetry.sdk.language': 'dart',
      'telemetry.sdk.version': '0.1.0',
    };
  }
}

/// OpenTelemetry resource describing the entity that emits telemetry.
final class Resource {
  /// Creates a resource from raw [attributes].
  Resource._(this.attributes, {this.schemaUrl});

  /// Resource attributes.
  final Map<String, Object> attributes;

  /// Optional schema URL describing the resource attribute schema.
  final String? schemaUrl;

  /// Default detectors used by [autoDetect].
  static const List<ResourceDetector> defaultDetectors = <ResourceDetector>[
    ProcessResourceDetector(),
    HostResourceDetector(),
    TelemetrySdkResourceDetector(),
  ];

  /// Platform-derived fallback service name.
  static String get defaultServiceName => platformDefaultServiceName();

  /// Creates an empty resource.
  factory Resource.empty() {
    return Resource._(const <String, Object>{});
  }

  /// Creates a resource from service metadata and extra attributes.
  factory Resource({
    required String serviceName,
    String? serviceVersion,
    String? serviceNamespace,
    String? environment,
    String? schemaUrl,
    Map<String, Object>? extra,
  }) {
    return Resource._(<String, Object>{
      'service.name': serviceName,
      ...?serviceVersion == null
          ? null
          : <String, Object>{'service.version': serviceVersion},
      ...?serviceNamespace == null
          ? null
          : <String, Object>{'service.namespace': serviceNamespace},
      ...?environment == null
          ? null
          : <String, Object>{'deployment.environment': environment},
      ...?extra,
    }, schemaUrl: schemaUrl);
  }

  /// Creates a resource by combining detector output with explicit attributes.
  factory Resource.autoDetect({
    required String serviceName,
    String? serviceVersion,
    String? environment,
    String? schemaUrl,
    Iterable<ResourceDetector>? detectors,
    Map<String, Object>? extra,
  }) {
    final detectedAttributes = <String, Object>{};
    for (final detector in detectors ?? defaultDetectors) {
      detectedAttributes.addAll(detector.detect());
    }
    detectedAttributes.remove('service.name');
    if (serviceVersion != null) {
      // An explicit serviceVersion must win over any detector that emits one.
      detectedAttributes.remove('service.version');
    }
    if (environment != null) {
      detectedAttributes.remove('deployment.environment');
    }

    return Resource(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      environment: environment,
      schemaUrl: schemaUrl,
      extra: <String, Object>{...detectedAttributes, ...?extra},
    );
  }

  /// Returns a merged resource where [other] overrides duplicate attributes.
  Resource merge(Resource other) {
    return Resource._(<String, Object>{
      ...attributes,
      ...other.attributes,
    }, schemaUrl: other.schemaUrl ?? schemaUrl);
  }
}
