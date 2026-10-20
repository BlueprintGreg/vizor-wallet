@Tags(['mobile'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_navigation_scope.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_page_viewport.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';

void main() {
  for (final height in [369.0, 0.0]) {
    testWidgets(
      'branch content respects keyboard constraints ($height) and retains pane metrics',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 900);
        addTearDown(tester.view.reset);
        const probe = ValueKey('content');
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: AppTheme(
              data: AppThemeData.light,
              child: MediaQuery(
                data: const MediaQueryData(size: Size(663, 669)),
                child: MobileNavigationScope(
                  mode: MobileNavigationMode.sidebar,
                  navigation: MobileBranchNavigation(),
                  contentRect: const Rect.fromLTWH(61.5, 40, 440, 629),
                  child: Center(
                    child: SizedBox(
                      width: 663,
                      height: height,
                      child: const MobilePageViewport(
                        child: SizedBox.expand(key: probe),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byKey(probe)),
          Size(440, height == 0 ? 0 : 329),
        );
        expect(
          MediaQuery.sizeOf(tester.element(find.byKey(probe))),
          const Size(440, 629),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
