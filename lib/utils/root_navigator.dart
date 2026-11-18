// utils/root_navigator.dart
import 'package:flutter/widgets.dart';

/// The main app's root Navigator (MaterialApp.navigatorKey in main.dart).
///
/// For UI raised from outside the page tree — e.g. a toast's button: toasts
/// sit above the Navigator, so their own context cannot open a dialog.
/// `currentContext` is null in the other app flavours and in tests.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
