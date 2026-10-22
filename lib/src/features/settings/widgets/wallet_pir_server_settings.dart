import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../providers/wallet_pir_server_provider.dart';
import '../../../services/wallet_pir/wallet_pir_config.dart';

/// Server list source and server picker for Private queries, shared by the
/// desktop Privacy block and the mobile network privacy card.
class WalletPirServerSettings extends ConsumerWidget {
  const WalletPirServerSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(walletPirServerProvider);
    final notifier = ref.read(walletPirServerProvider.notifier);
    final state = async.value;
    if (state == null) {
      return async.hasError
          ? WalletPirServerSettingsView.message(
              'Couldn\'t read the private query server settings.',
            )
          : const SizedBox.shrink();
    }
    return WalletPirServerSettingsView(
      state: state,
      onSelect: (baseUrl) => unawaited(notifier.selectServer(baseUrl)),
      onRefresh: () => unawaited(notifier.refresh()),
    );
  }
}

/// Renders a [WalletPirServerState]. Free of providers, so Widgetbook and
/// tests drive it directly.
class WalletPirServerSettingsView extends StatelessWidget {
  const WalletPirServerSettingsView({
    required this.state,
    required this.onSelect,
    required this.onRefresh,
    super.key,
  }) : _message = null;

  const WalletPirServerSettingsView.message(String message, {super.key})
    : state = null,
      onSelect = null,
      onRefresh = null,
      _message = message;

  final WalletPirServerState? state;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onRefresh;
  final String? _message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = this.state;
    final bodyStyle = AppTypography.bodyMedium.copyWith(
      color: colors.text.muted,
    );
    if (state == null) {
      return Text(_message ?? '', style: bodyStyle);
    }
    final status = walletPirServerStatusText(state);
    return Column(
      key: const ValueKey('wallet_pir_server_settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Private query server',
          style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          state.source == null
              ? 'Server list: unavailable on this network'
              : 'Server list: ${_host(state.source!)}',
          key: const ValueKey('wallet_pir_server_source'),
          style: bodyStyle,
        ),
        if (status != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            status.text,
            key: const ValueKey('wallet_pir_server_status'),
            style: bodyStyle.copyWith(
              color: status.warning ? colors.text.destructive : null,
            ),
          ),
        ],
        if (state.servers.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          for (final server in state.servers) ...[
            _ServerRow(
              server: server,
              selected: server.baseUrl == state.selectedBaseUrl,
              onTap: onSelect == null ? null : () => onSelect!(server.baseUrl),
            ),
            const SizedBox(height: AppSpacing.xxs),
          ],
        ],
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            key: const ValueKey('wallet_pir_server_refresh'),
            onPressed: state.source == null || state.refreshing
                ? null
                : onRefresh,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.small,
            child: const Text('Check for updates'),
          ),
        ),
      ],
    );
  }
}

/// The one status line under the source, in everyday words. `null` when
/// everything is in order.
({String text, bool warning})? walletPirServerStatusText(
  WalletPirServerState state,
) {
  if (state.source == null) {
    return (
      text: 'Private queries are unavailable on this network.',
      warning: true,
    );
  }
  if (state.refreshing && state.config == null) {
    return (text: 'Loading the server list…', warning: false);
  }
  final error = state.refreshError;
  if (state.config == null) {
    return error == null
        ? (text: 'Loading the server list…', warning: false)
        : (
            text:
                'Couldn\'t load the server list. Private queries are paused '
                'until it loads.',
            warning: true,
          );
  }
  if (state.needsSelection) {
    return (
      text:
          'The server you chose is no longer offered. Choose another to '
          'resume private queries.',
      warning: true,
    );
  }
  if (state.hasNoServers) {
    return (
      text: 'No servers are offered yet. Private queries are paused.',
      warning: true,
    );
  }
  if (error != null) {
    return (
      text: 'Couldn\'t update the server list. Using the last list loaded.',
      warning: true,
    );
  }
  if (state.refreshing) {
    return (text: 'Checking for updates…', warning: false);
  }
  return null;
}

String _host(String url) {
  final uri = Uri.tryParse(url);
  return uri == null || uri.host.isEmpty ? url : uri.host;
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.selected,
    required this.onTap,
  });

  final WalletPirServerOption server;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final address = server.baseUrl.replaceFirst('https://', '');
    return Semantics(
      button: true,
      selected: selected,
      label: server.label,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('wallet_pir_server_option_${server.baseUrl}'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? colors.background.raised : colors.surface.card,
              borderRadius: BorderRadius.circular(AppRadii.small),
              border: Border.all(
                color: selected ? colors.border.medium : colors.border.subtle,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Row(
                children: [
                  _SelectionDot(selected: selected),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.labelLarge.copyWith(
                            color: colors.text.accent,
                          ),
                        ),
                        Text(
                          address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodySmall.copyWith(
                            color: colors.text.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionDot extends StatelessWidget {
  const _SelectionDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? colors.icon.brandCrimson : colors.background.ground,
        border: Border.all(
          color: selected ? colors.icon.brandCrimson : colors.border.medium,
        ),
      ),
      child: SizedBox.square(
        dimension: 20,
        child: Center(
          child: selected
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.background.ground,
                  ),
                  child: const SizedBox.square(dimension: 8),
                )
              : null,
        ),
      ),
    );
  }
}
