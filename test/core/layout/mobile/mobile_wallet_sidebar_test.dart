@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/formatting/sync_status_label.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_shell.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_navigation_scope.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_wallet_sidebar.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';

const status = SyncStatusLabel(
  kind: SyncStatusKind.syncing,
  label: '4% Syncing...',
  semanticsLabel: '4% Syncing',
);
Widget harness(Widget child, {double scale = 1}) => MaterialApp(
  builder: (_, navigator) => AppTheme(
    data: AppThemeData.light,
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: navigator!,
    ),
  ),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets(
    'sidebar shows mobile destinations and sync, respects flag and disabled state',
    (tester) async {
      final visits = <String>[];
      Widget sidebar({bool enabled = true}) => SizedBox(
        width: 200,
        height: 600,
        child: MobileWalletSidebar(
          accountName: 'Windborne Trailguard',
          avatar: const SizedBox(width: 40, height: 40),
          status: status,
          currentPath: '/activity',
          swapEnabled: false,
          onAccountTap: enabled ? () {} : null,
          onSelect: enabled ? visits.add : null,
        ),
      );
      await tester.pumpWidget(harness(sidebar()));
      expect(find.text('Swap'), findsNothing);
      expect(find.text('4% Syncing...'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      expect(visits, ['/settings']);
      await tester.pumpWidget(harness(sidebar(enabled: false)));
      await tester.tap(find.text('Home'));
      expect(visits, ['/settings']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'short sidebar scrolls all controls at large accessibility text size',
    (tester) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 200,
            height: 260,
            child: MobileWalletSidebar(
              accountName: 'A long account name that should wrap',
              avatar: const SizedBox(width: 40, height: 40),
              status: status,
              currentPath: '/home',
              swapEnabled: true,
              onAccountTap: () {},
              onSelect: (_) {},
            ),
          ),
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('4% Syncing...'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'side tabs retain upright icons and every destination scrolls into view',
    (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 492,
            height: 720,
            child: MobileNavigationScope(
              mode: MobileNavigationMode.systemSideTabs,
              navigation: MobileBranchNavigation(),
              railRect: const Rect.fromLTWH(416, 200, 64, 100),
              child: AppMobileShell(
                body: const SizedBox.expand(),
                tabBar: AppMobileTabBar(
                  axis: Axis.vertical,
                  items: const [
                    AppMobileTabItem(iconName: AppIcons.home, label: 'Home'),
                    AppMobileTabItem(iconName: AppIcons.cog, label: 'Settings'),
                  ],
                  currentIndex: 0,
                  onSelect: selected.add,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.bySemanticsLabel('Settings'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Settings'));
      expect(selected, [1]);
      expect(tester.takeException(), isNull);
    },
  );
}
