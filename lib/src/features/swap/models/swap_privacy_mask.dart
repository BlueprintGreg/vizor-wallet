import '../../../core/privacy/privacy_mask.dart';

final _swapAmountTextPattern = RegExp(
  r'^[<>~+\-]?\s*\d[\d,]*(?:\.\d+)?(?:\s+(.+))?$',
);

/// Masks a swap amount such as `0.21 USDC` while keeping its own symbol
/// (`****** USDC`), because swap legs are often not ZEC. Text that is not an
/// amount (`Included in shown rate`, `Not reported`, `--`) is returned as is.
String swapAmountTextForPrivacy(
  String amountText, {
  required bool privacyModeEnabled,
  int maskLength = kDefaultPrivacyMaskLength,
}) {
  if (!privacyModeEnabled) return amountText;
  final match = _swapAmountTextPattern.firstMatch(amountText.trim());
  if (match == null) return amountText;
  return hideAmountIfPrivacyMode(
    amountText,
    privacyModeEnabled: true,
    maskLength: maskLength,
    denomination: match.group(1) ?? '',
  );
}

/// Masks a captured fiat value (`$12.34`) as a bare mask; the `$--`
/// placeholder has no value and stays visible.
String swapFiatTextForPrivacy(
  String fiatText, {
  required bool privacyModeEnabled,
}) {
  if (!privacyModeEnabled || !fiatText.contains(RegExp(r'\d'))) {
    return fiatText;
  }
  return fixedPrivacyMask();
}
