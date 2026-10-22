import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
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
      onSetSource: (source) => notifier.setSource(source),
    );
  }
}

/// Renders a [WalletPirServerState]. Free of providers, so Widgetbook and
/// tests drive it directly.
class WalletPirServerSettingsView extends StatefulWidget {
  const WalletPirServerSettingsView({
    required this.state,
    required this.onSelect,
    required this.onRefresh,
    required this.onSetSource,
    super.key,
  }) : _message = null;

  const WalletPirServerSettingsView.message(String message, {super.key})
    : state = null,
      onSelect = null,
      onRefresh = null,
      onSetSource = null,
      _message = message;

  final WalletPirServerState? state;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onRefresh;
  final Future<void> Function(String? source)? onSetSource;
  final String? _message;

  @override
  State<WalletPirServerSettingsView> createState() =>
      _WalletPirServerSettingsViewState();
}

class _WalletPirServerSettingsViewState
    extends State<WalletPirServerSettingsView> {
  final _sourceController = TextEditingController();
  bool _editingSource = false;
  bool _savingSource = false;

  @override
  void dispose() {
    _sourceController.dispose();
    super.dispose();
  }

  Future<void> _saveSource(String? source) async {
    setState(() => _savingSource = true);
    try {
      await widget.onSetSource?.call(source);
      if (mounted) setState(() => _editingSource = false);
    } finally {
      if (mounted) setState(() => _savingSource = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = widget.state;
    final bodyStyle = AppTypography.bodyMedium.copyWith(
      color: colors.text.muted,
    );
    if (state == null) {
      return Text(widget._message ?? '', style: bodyStyle);
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
              ? 'Server list: not set up'
              : state.sourceIsDefault
              ? 'Server list: default (${_host(state.source!)})'
              : 'Server list: custom (${_host(state.source!)})',
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
              onTap: widget.onSelect == null
                  ? null
                  : () => widget.onSelect!(server.baseUrl),
            ),
            const SizedBox(height: AppSpacing.xxs),
          ],
        ],
        const SizedBox(height: AppSpacing.xs),
        if (_editingSource)
          _SourceEditor(
            controller: _sourceController,
            saving: _savingSource,
            onSave: () => _saveSource(_sourceController.text),
            onUseDefault: () => _saveSource(null),
            onCancel: () => setState(() => _editingSource = false),
          )
        else
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              AppButton(
                key: const ValueKey('wallet_pir_server_refresh'),
                onPressed: state.source == null || state.refreshing
                    ? null
                    : widget.onRefresh,
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                child: const Text('Check for updates'),
              ),
              AppButton(
                key: const ValueKey('wallet_pir_server_change_source'),
                onPressed: () => setState(() {
                  _sourceController.text = state.sourceIsDefault
                      ? ''
                      : state.source ?? '';
                  _editingSource = true;
                }),
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                child: const Text('Change server list'),
              ),
            ],
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
      text: 'Private queries can\'t run until a server list is set up.',
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

class _SourceEditor extends StatelessWidget {
  const _SourceEditor({
    required this.controller,
    required this.saving,
    required this.onSave,
    required this.onUseDefault,
    required this.onCancel,
  });

  final TextEditingController controller;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onUseDefault;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 66,
          child: AppTextField(
            key: const ValueKey('wallet_pir_server_source_field'),
            label: 'Server list link',
            hintText: 'https://…?checksum=sha256:…',
            controller: controller,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSave(),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            AppButton(
              onPressed: saving ? null : onCancel,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              child: const Text('Cancel'),
            ),
            AppButton(
              onPressed: saving ? null : onUseDefault,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              child: const Text('Use default'),
            ),
            AppButton(
              key: const ValueKey('wallet_pir_server_source_save'),
              onPressed: saving ? null : onSave,
              size: AppButtonSize.small,
              child: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }
}
