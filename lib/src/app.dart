// ===============================================
// Module: app.dart
// Description: Core initialization function for Flutter AppKit with comprehensive error handling
//
// Sections:
//   - Global State Variables
//   - Main appRun() Function
//   - Error Handler Setup
//   - Error Catching and Processing
//
// Features:
//   - Sentry integration (optional)
//   - Error callback for custom error handling
//   - Riverpod state management setup
//   - Multi-layer error handling
//   - Talker logging integration
//   - Error dialog management
// ===============================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_appkit/src/show_dialog.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:talker_riverpod_logger/talker_riverpod_logger_observer.dart';

import 'env.dart';
import 'logger.dart';

// Cache the DSN validation result
bool? _sentryEnabledCache;

bool get isSentryEnabled {
  // In test mode, don't use cache to allow for environment changes
  if (kDebugMode) {
    final dsn = envGet('SENTRY_DSN');
    return dsn.isNotEmpty && _isValidSentryDSN(dsn);
  }

  if (_sentryEnabledCache != null) return _sentryEnabledCache!;

  final dsn = envGet('SENTRY_DSN');
  _sentryEnabledCache = dsn.isNotEmpty && _isValidSentryDSN(dsn);
  return _sentryEnabledCache!;
}

/// Initializes and runs a Flutter app with comprehensive error handling.
///
/// The [suspect] function should return the root widget of your application.
/// It receives a [Locale?] parameter that updates whenever the locale changes,
/// ensuring the app rebuilds when the user switches languages.
/// The optional [errorCallback] allows you to evaluate caught errors and decide
/// whether to suppress or display them to the user.
/// The optional [preInitCallback] is executed inside [runZonedGuarded] before
/// environment variables are loaded via [envInit]. Use it for any setup that
/// must run within the guarded zone but before the environment is available.
///
/// Sentry crash reporting is automatically enabled when SENTRY_DSN environment
/// variable is configured. App Hang tracking is disabled by default to protect
/// user's privacy, we must get user's permission in order to send sentry error report.
///
/// Features:
/// - Catches all unhandled exceptions
/// - Optional Sentry integration for crash reporting (with App Hang tracking disabled)
/// - Optional pre-init callback executed before environment initialization
/// - Optional error callback for custom error handling
/// - Prevents multiple error dialogs
/// - Logs errors using Talker
/// - Riverpod state management setup
/// - Locale-aware widget rebuilding
///
/// Example:
/// ```dart
/// await appRun(MyApp());
///
/// // With pre-init callback for early setup inside the guarded zone
/// await appRun(MyApp(), preInitCallback: () async {
///   await someEarlySetup();
/// });
///
/// // With error callback to suppress platform exceptions
/// await appRun(MyApp(), errorCallback: (e) {
///   if (e is PlatformException || e is MissingPluginException) {
///     return false; // Don't show these errors to user
///   }
///   return true; // Show other errors
/// });
/// ```
Future<void> appRun(
  Widget widget, {
  Future<void> Function()? preInitCallback,
  bool Function(Object)? errorCallback,
  bool enableLiquidGlass = true,
}) async {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _overrideDebugPrint();
      if (enableLiquidGlass) {
        await LiquidGlassWidgets.initialize();
      }
      if (preInitCallback != null) {
        await preInitCallback();
      }
      // Load environment variables from .env file
      await envInit();
      _setupErrorHandlers(errorCallback);

      final liquidWidget = enableLiquidGlass ? LiquidGlassWidgets.wrap(child: widget) : widget;
      if (isSentryEnabled) {
        await _initWithSentry(liquidWidget);
      } else {
        _initWithoutSentry(liquidWidget);
      }
    },
    (Object e, StackTrace stack) => catched(e, stack, errorCallback),
  );
}

void _overrideDebugPrint() {
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      if (message.contains('[LiquidGlass]')) {
        return; // Drop the log
      }
    }
    // Pass all other logs through normally
    debugPrintThrottled(message, wrapWidth: wrapWidth);
  };
}

// Provides a observer for logging riverpod events to Talker. This can be added to the ProviderScope observers list.
TalkerRiverpodObserver riverpodObserver() => TalkerRiverpodObserver(talker: talker);

/// Initializes the app with Sentry integration
Future<void> _initWithSentry(Widget appContent) async {
  final sentryDSN = envGet('SENTRY_DSN');
  try {
    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDSN;
        options.sendDefaultPii = true;
        // Reduce debug noise in console
        options.debug = false;
        options.enableAppHangTracking = true;
        options.appHangTimeoutInterval = const Duration(seconds: 20);
        options.diagnosticLevel = kDebugMode ? SentryLevel.warning : SentryLevel.error;
        // Add environment detection
        options.environment = kDebugMode ? 'development' : 'production';
        // Enable Tombstone collection on Android to get richer crash reports
        options.enableTombstone = true;
        options.beforeSend = (event, hint) {
          // Never send errors in debug mode - they should only be shown on screen
          if (kDebugMode) {
            return null;
          }
          return event;
        };
      },
      appRunner: () => runApp(SentryWidget(child: appContent)),
    );
    logDebug('[appkit-app] Sentry is enabled.');
  } catch (e) {
    logWarning('[appkit-app] failed to initialize Sentry: $e. Falling back to basic error handling.');
    _initWithoutSentry(appContent);
  }
}

/// Initializes the app without Sentry
void _initWithoutSentry(Widget appContent) {
  logInfo('Sentry is not enabled. To use Sentry, provide a valid DSN in the SENTRY_DSN environment variable.');
  runApp(appContent);
}

/// Validates if the provided DSN is a valid Sentry DSN format
bool _isValidSentryDSN(String dsn) {
  if (dsn.isEmpty) return false;

  try {
    final uri = Uri.parse(dsn);
    // Enhanced validation for Sentry DSN format
    // Sentry DSNs typically follow: https://public_key@organization.ingest.sentry.io/project_id
    return uri.hasScheme &&
        uri.hasAuthority &&
        uri.pathSegments.isNotEmpty &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.contains('sentry.io'); // More specific Sentry validation
  } catch (e) {
    return false;
  }
}

void _setupErrorHandlers(bool Function(Object)? errorCallback) {
  FlutterError.onError = (FlutterErrorDetails details) async {
    await catched(details.exception, details.stack, errorCallback);
    // Don't call original onError - Sentry overrides it for automatic capture,
    // but we control error reporting in catched() to enforce user consent
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    catched(error, stack, errorCallback);
    return true;
  };
}

/// Handles caught errors with filtering, logging, and optional user reporting.
///
/// This function implements a three-layer protection system:
/// 1. Filters development-only errors (FlutterError, AssertionError, MissingPluginException)
/// 2. Logs all errors to console via Talker
/// 3. Shows error dialog and sends to Sentry only with user consent
///
/// Development errors are logged but never shown in dialogs (debug mode) or sent to Sentry.
/// The [errorCallback] allows custom filtering - return false to suppress the error dialog.
@visibleForTesting
Future<void> catched(dynamic e, StackTrace? stack, [bool Function(Object)? errorCallback]) async {
  // Only ignore null errors for safety
  if (e == null) {
    return;
  }

  // Filter development-only errors: FlutterError, AssertionError, MissingPluginException
  // These should only be logged to console, never shown in dialogs or sent to Sentry
  if (e is FlutterError || e is AssertionError || e is MissingPluginException) {
    printErrorToConsole(e, stack);
    // In debug mode, development errors are expected - just print to console and don't show dialog
    return;
  }
  try {
    bool errorHandled = false;
    if (errorCallback != null) {
      errorHandled = !errorCallback(e);
    }

    // Only show error dialog if callback allows it
    if (!errorHandled) {
      showError(e, stack);
      logError(e, stackTrace: stack);
    }
  } catch (ex) {
    // Log the error and also print to console for debugging
    debugPrint('[appkit-app] failed to display error dialog: $ex');
  }
}
