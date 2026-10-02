import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/foundation.dart';

import '../errors/otel_flutter_breadcrumbs.dart';
import '../navigation/otel_flutter_route_context.dart';

/// Helpers for tracing user interactions in Flutter widgets.
final class OtelFlutterInteractions {
  static const String _defaultTracerName = 'comon_otel.flutter';
  static const String _defaultSpanPrefix = 'flutter.interaction';

  /// Wraps a synchronous tap callback with tracing.
  static VoidCallback wrapTap({
    required String targetName,
    required VoidCallback onTap,
    String interactionType = 'tap',
    String tracerName = _defaultTracerName,
    String spanPrefix = _defaultSpanPrefix,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return () {
      traceAction<void>(
        targetName: targetName,
        interactionType: interactionType,
        tracerName: tracerName,
        spanPrefix: spanPrefix,
        attributes: attributes,
        action: onTap,
      );
    };
  }

  /// Wraps an asynchronous tap callback with tracing.
  static VoidCallback wrapAsyncTap({
    required String targetName,
    required Future<void> Function() onTap,
    String interactionType = 'tap',
    String tracerName = _defaultTracerName,
    String spanPrefix = _defaultSpanPrefix,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return () {
      unawaited(
        traceAsyncAction<void>(
          targetName: targetName,
          interactionType: interactionType,
          tracerName: tracerName,
          spanPrefix: spanPrefix,
          attributes: attributes,
          action: onTap,
        ),
      );
    };
  }

  /// Traces a synchronous interaction.
  static T traceAction<T>({
    required String targetName,
    required String interactionType,
    required T Function() action,
    String tracerName = _defaultTracerName,
    String spanPrefix = _defaultSpanPrefix,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    if (!Otel.isInitialized) {
      return action();
    }

    final resolvedAttributes = _baseAttributes(
      targetName: targetName,
      interactionType: interactionType,
      attributes: attributes,
    );
    _recordBreadcrumb(
      interactionType: interactionType,
      targetName: targetName,
      attributes: resolvedAttributes,
    );

    return Otel.instance.tracerProvider
        .getTracer(tracerName, version: '0.1.1')
        .trace(
          '$spanPrefix $interactionType $targetName',
          attributes: resolvedAttributes,
          fn: action,
        );
  }

  /// Traces an asynchronous interaction.
  static Future<T> traceAsyncAction<T>({
    required String targetName,
    required String interactionType,
    required Future<T> Function() action,
    String tracerName = _defaultTracerName,
    String spanPrefix = _defaultSpanPrefix,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    if (!Otel.isInitialized) {
      return action();
    }

    final resolvedAttributes = _baseAttributes(
      targetName: targetName,
      interactionType: interactionType,
      attributes: attributes,
    );
    _recordBreadcrumb(
      interactionType: interactionType,
      targetName: targetName,
      attributes: resolvedAttributes,
    );

    return Otel.instance.tracerProvider
        .getTracer(tracerName, version: '0.1.1')
        .traceAsync(
          '$spanPrefix $interactionType $targetName',
          attributes: resolvedAttributes,
          fn: action,
        );
  }

  /// Traces a form submission flow.
  static Future<T> traceFormSubmit<T>({
    required String formName,
    required Future<T> Function() action,
    String tracerName = _defaultTracerName,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return traceAsyncAction<T>(
      targetName: formName,
      interactionType: 'form_submit',
      tracerName: tracerName,
      attributes: <String, Object>{
        'flutter.form.name': formName,
        ...attributes,
      },
      action: action,
    );
  }

  /// Traces a widget-level user flow.
  static Future<T> traceWidgetFlow<T>({
    required String widgetName,
    required Future<T> Function() action,
    String flowName = 'flow',
    String tracerName = _defaultTracerName,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return traceAsyncAction<T>(
      targetName: widgetName,
      interactionType: 'widget_$flowName',
      tracerName: tracerName,
      attributes: <String, Object>{
        'flutter.widget.name': widgetName,
        'flutter.widget.flow': flowName,
        ...attributes,
      },
      action: action,
    );
  }

  static Map<String, Object> _baseAttributes({
    required String targetName,
    required String interactionType,
    required Map<String, Object> attributes,
  }) {
    final routeContext = OtelFlutterRouteContext.current;
    return <String, Object>{
      'flutter.interaction.type': interactionType,
      'flutter.target.name': targetName,
      if (routeContext.routeName != null)
        'flutter.route.name': routeContext.routeName!,
      if (routeContext.routeName != null)
        'screen.name': routeContext.routeName!,
      if (routeContext.routeRuntimeType != null)
        'flutter.route.runtime_type': routeContext.routeRuntimeType!,
      if (routeContext.previousRouteName != null)
        'screen.previous.name': routeContext.previousRouteName!,
      ...attributes,
    };
  }

  static void _recordBreadcrumb({
    required String interactionType,
    required String targetName,
    required Map<String, Object> attributes,
  }) {
    OtelFlutterBreadcrumbs.add(
      category: 'interaction',
      message: '$interactionType $targetName',
      attributes: attributes,
    );
  }
}
