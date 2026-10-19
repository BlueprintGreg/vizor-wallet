import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../services/native_modal_corners.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_modal_shape.dart';

typedef _PanelGeometry = ({Rect rect, Size viewSize, double scale});

/// Owns one shared outline for the panel fill and clipping. Only iOS asks
/// UIKit to resolve container-concentric corners at the panel's actual frame.
class MobileSidebarSurface extends StatefulWidget {
  const MobileSidebarSurface({required this.child, super.key});
  final Widget child;

  @override
  State<MobileSidebarSurface> createState() => _MobileSidebarSurfaceState();
}

class _MobileSidebarSurfaceState extends State<MobileSidebarSurface>
    with WidgetsBindingObserver {
  static const _fallback = BorderRadius.all(Radius.circular(AppRadii.large));
  final _key = GlobalKey();
  BorderRadius _radius = _fallback;
  _PanelGeometry? _request;
  int _epoch = 0;
  bool _scheduled = false;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _schedule() {
    if (_scheduled || !_active || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _active) _resolve();
    });
  }

  @override
  void didChangeMetrics() {
    _epoch++;
    _request = null;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _epoch++;
    _request = null;
    if (_active) {
      _schedule();
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Future<void> _resolve() async {
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final view = View.of(context);
    final geometry = (
      rect: box.localToGlobal(Offset.zero) & box.size,
      viewSize: view.physicalSize / view.devicePixelRatio,
      scale: view.devicePixelRatio,
    );
    if (_request == geometry) return;
    _request = geometry;
    final epoch = ++_epoch;
    // Do not keep the old posture's radius while awaiting a new geometry.
    if (_radius != _fallback) setState(() => _radius = _fallback);
    final radius = await NativeModalCorners.resolveSidebar(
      rect: geometry.rect,
      viewSize: geometry.viewSize,
      scale: geometry.scale,
    );
    if (!mounted || !_active || epoch != _epoch) return;
    final target = radius ?? _fallback;
    if (_radius != target) setState(() => _radius = target);
  }

  @override
  Widget build(BuildContext context) {
    // Parent positioning can change without resizing the panel itself.
    _schedule();
    final shape = appModalShape(_radius);
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _schedule();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: DecoratedBox(
          key: _key,
          decoration: ShapeDecoration(
            color: context.colors.background.raised,
            shape: shape,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: widget.child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
