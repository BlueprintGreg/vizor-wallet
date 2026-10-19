import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';
import '../../formatting/sync_status_label.dart';
import '../../navigation/mobile_destinations.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_icon.dart';

/// A mobile component, intentionally independent of the desktop sidebar.
/// Data is injected so window/typography/accessibility states can be captured
/// without a wallet database, secure storage, network, or Rust.
class MobileWalletSidebar extends StatelessWidget {
  const MobileWalletSidebar({
    required this.accountName,
    required this.avatar,
    required this.status,
    required this.currentPath,
    required this.swapEnabled,
    required this.onSelect,
    required this.onAccountTap,
    super.key,
  });
  final String accountName;
  final Widget avatar;
  final SyncStatusLabel status;
  final String currentPath;
  final bool swapEnabled;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onAccountTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final syncColor = switch (status.kind) {
      SyncStatusKind.failed => colors.sync.textError,
      SyncStatusKind.synced => colors.sync.text,
      SyncStatusKind.syncing => colors.sync.textSyncing,
    };
    final items = [
      for (final item in mobileDestinations)
        if (swapEnabled || item.path != '/swap') item,
    ];
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.macosUtility.navPanel,
        borderRadius: BorderRadius.circular(AppRadii.large),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Footer stays at the bottom when space permits. At large text sizes
            // or on a short window the whole sidebar scrolls, never clips controls.
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppButton(
                        variant: AppButtonVariant.ghost,
                        onPressed: onAccountTap,
                        height: 72,
                        growWithContent: true,
                        constrainContent: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          children: [
                            avatar,
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              accountName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: AppTypography.bodyMediumStrong,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      for (final destination in items) ...[
                        Semantics(
                          selected: _selected(destination.path),
                          child: AppButton(
                            variant: AppButtonVariant.ghost,
                            height: 52,
                            growWithContent: true,
                            expand: true,
                            constrainContent: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            enabledBackgroundColor: _selected(destination.path)
                                ? colors.navPanel.activeBg
                                : null,
                            enabledLabelColor: _selected(destination.path)
                                ? colors.navPanel.activeIcon
                                : null,
                            onPressed: onSelect == null
                                ? null
                                : () => onSelect!(destination.path),
                            child: Row(
                              children: [
                                AppIcon(
                                  destination.item.iconName,
                                  size: 24,
                                  color: _selected(destination.path)
                                      ? colors.navPanel.activeIcon
                                      : colors.icon.muted,
                                ),
                                const SizedBox(width: AppSpacing.s),
                                Expanded(
                                  child: Text(
                                    destination.item.label,
                                    style: AppTypography.bodyMediumStrong,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                      ],
                      const Spacer(),
                      const SizedBox(height: AppSpacing.md),
                      Semantics(
                        liveRegion: status.kind == SyncStatusKind.failed,
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              height: 32,
                              decoration: BoxDecoration(
                                color: syncColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s),
                            Expanded(
                              child: Text(
                                status.label,
                                style: AppTypography.bodySmall.copyWith(
                                  color: syncColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    // This surface also lives above the Router, outside its Material widgets.
    // Establish a complete mobile text style instead of inheriting the
    // MaterialApp fallback's yellow double underline.
    return Material(
      type: MaterialType.transparency,
      textStyle: AppTypography.bodyMedium.copyWith(
        color: colors.text.accent,
        decoration: TextDecoration.none,
      ),
      child: panel,
    );
  }

  bool _selected(String path) =>
      currentPath == path ||
      currentPath.startsWith('$path/') ||
      (path == '/home' &&
          (currentPath == '/accounts' ||
              currentPath.startsWith('/send') ||
              currentPath.startsWith('/receive') ||
              currentPath.startsWith('/migration')));
}
