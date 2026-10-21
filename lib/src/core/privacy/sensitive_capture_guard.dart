import 'package:flutter/widgets.dart';

import 'native_sensitive_content_bridge.dart';

/// Excludes native window captures while this screen displays a secret.
/// Background/app-switcher privacy is owned by the native app lifecycle,
/// independently of this guard and of whether any secret is on screen.
class SensitiveCaptureGuard extends StatefulWidget {
  const SensitiveCaptureGuard({
    required this.sensitiveContentVisible,
    required this.child,
    super.key,
  });

  final bool sensitiveContentVisible;
  final Widget child;

  @override
  State<SensitiveCaptureGuard> createState() => _SensitiveCaptureGuardState();
}

class _SensitiveCaptureGuardState extends State<SensitiveCaptureGuard> {
  final _token = NativeSensitiveContentBridge.createToken();

  @override
  void initState() {
    super.initState();
    _syncVisibility();
  }

  @override
  void didUpdateWidget(covariant SensitiveCaptureGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sensitiveContentVisible != widget.sensitiveContentVisible) {
      _syncVisibility();
    }
  }

  void _syncVisibility() => NativeSensitiveContentBridge.updateToken(
    _token,
    widget.sensitiveContentVisible,
  );

  @override
  void dispose() {
    NativeSensitiveContentBridge.clearToken(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
