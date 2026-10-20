import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import 'mobile_navigation_scope.dart';
import 'mobile_window_layout.dart';

/// Keeps the page background and its margins inside the route transition,
/// while foreground content retains the mobile pane's geometry and metrics.
class MobilePageViewport extends StatelessWidget {
  const MobilePageViewport({
    required this.child,
    this.constrainContent = true,
    super.key,
  });

  final Widget child;

  /// Tab shells retain a wide branch Navigator; their leaf pages constrain
  /// content individually so branch transitions also include the margins.
  final bool constrainContent;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final full = Offset.zero & media.size;
    final content = constrainContent
        ? MobileNavigationScope.maybeOf(context)?.contentRect ?? full
        : full;
    // Keep this tree stable across window modes to preserve screen state.
    return LayoutBuilder(
      builder: (context, constraints) => ColoredBox(
        color: context.colors.background.window,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              // The tab shell may already have resized its branch Navigator
              // for the keyboard. Respect those constraints while keeping the
              // original pane metrics, as a normal Scaffold body would.
              rect: Rect.fromLTRB(
                content.left.clamp(0, constraints.maxWidth),
                content.top.clamp(0, constraints.maxHeight),
                content.right.clamp(0, constraints.maxWidth),
                content.bottom.clamp(0, constraints.maxHeight),
              ),
              child: MediaQuery(
                data: mobilePaneMedia(media, content),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
