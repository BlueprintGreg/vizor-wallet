import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';
import '../../formatting/sync_status_label.dart';
import '../../navigation/mobile_destinations.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_icon.dart';
import 'mobile_sync_status.dart';
import 'mobile_sidebar_surface.dart';

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
    this.inputBlocked = false,
    super.key,
  });
  final String accountName;
  final Widget avatar;
  final SyncStatusLabel status;
  final String currentPath;
  final bool swapEnabled;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onAccountTap;

  /// A temporary navigation lock preserves paint while blocking pointer,
  /// keyboard focus, and pointer-related accessibility actions. Null callbacks
  /// still represent actual route restrictions and retain disabled styling.
  final bool inputBlocked;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final items = [
      for (final item in mobileDestinations)
        if (swapEnabled || item.path != '/swap') item,
    ];
    final panel = MobileSidebarSurface.builder(
      builder: (context, corners) => Padding(
        padding: EdgeInsets.only(
          top: 16,
          // The bar hugs the leading edge. Keep its lower glow above the same
          // native corner used to paint and clip the panel, without stacking
          // the remaining pane safe-area inset on top of that clearance.
          bottom: MediaQuery.paddingOf(
            context,
          ).bottom.clamp(corners.bottomLeft.y + AppSpacing.sm, double.infinity),
        ),
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: AppButton(
                          variant: AppButtonVariant.ghost,
                          onPressed: onAccountTap,
                          height: 72,
                          growWithContent: true,
                          constrainContent: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              avatar,
                              const SizedBox(width: AppSpacing.s),
                              Expanded(
                                child: Text(
                                  accountName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.bodyMediumStrong,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      for (final destination in items) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Semantics(
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
                              enabledBackgroundColor:
                                  _selected(destination.path)
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
                        ),
                        const SizedBox(height: AppSpacing.xs),
                      ],
                      const Spacer(),
                      const SizedBox(height: AppSpacing.md),
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: MobileSyncStatus.fromStatus(
                          context: context,
                          status: status,
                          leading: true,
                          wrapLabel: true,
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
    // Establish text defaults independently of surrounding route Material widgets.
    // Establish a complete mobile text style instead of inheriting the
    // MaterialApp fallback's yellow double underline.
    return ExcludeFocus(
      excluding: inputBlocked,
      child: AbsorbPointer(
        absorbing: inputBlocked,
        child: Material(
          type: MaterialType.transparency,
          textStyle: AppTypography.bodyMedium.copyWith(
            color: colors.text.accent,
            decoration: TextDecoration.none,
          ),
          child: panel,
        ),
      ),
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
