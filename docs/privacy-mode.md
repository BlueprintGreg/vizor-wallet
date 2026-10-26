# Privacy mode

Privacy mode ("Hide balance") replaces wallet amounts with `******`, so anyone
who can see the screen — nearby, over screen sharing, in a screenshot, or
through a screen reader — cannot learn how much the wallet holds or has moved.
Users toggle it with the eye button on home and in the desktop sidebar, and in
the mobile gift card list header.

It changes presentation only. Validation, Max, proposals, and signing keep
using real values, and network requests, storage, and native surfaces are
unaffected. The setting is one flag shared by every account
(`privacyModeProvider`, stored as `zcash_privacy_mode_enabled`).

## Which amounts to mask

Classify each amount by where it comes from, not by the screen it is on.

| Category | Privacy mode | What belongs here | Examples |
| --- | --- | --- | --- |
| Holdings | Mask | Any value derived from the wallet's balances, including a value from which a balance can be worked out | Home and sidebar balances and their fiat; spendable or available labels; `Max: X`, `Use max: X`; "X available" in error copy; a shortfall such as "Additional ZEC needed" (total minus balance); the transparent amount on shield screens; per-account balances in import discovery; migration amounts (Orchard balance, left to migrate, per-note, migrated); voting power and the amount left out of a vote |
| History | Mask | Amounts and fees of stored records | Activity rows; transaction receipts; swap and Pay detail and status pages, including the awaiting-deposit page; gift card lists and group detail |
| Current draft | Show | The amount the user is entering in this flow and what is computed from it, through the flow's own result screen | Composer amount, fiat conversion, quote, fee estimate, review; send status after submitting; the gift card ready screen; an incoming card being claimed; the amount in a payment request someone sent |
| Not wallet data | Show | Values that do not depend on this wallet | Prices and 24h change, swap rates, slippage, fee rates, round-wide vote tallies, protocol minimums |

Boundary rules:

- **Flow screen or record screen.** A screen that belongs to the composing
  flow shows the draft. A screen that displays a stored record masks, even when
  the app opens it right after a submit: swap and Pay continue to their
  activity detail page, which is a record screen.
- **Explicit actions carry real values.** Copy, CSV export, share, and the Max
  fill may use the real amount because the user chose where it goes. After
  tapping Max, the amount field shows the filled amount; the Max label stays
  masked. Nothing the app shows on its own may reveal a masked value.
- **Keep progress without amounts.** Where amounts are masked, keep
  percentages, counts, and step progress, such as migration progress and
  signing batches.
- **Zero is an amount.** Mask a zero balance too. Loading placeholders and
  fixed copy with no number ("Not enough ZEC") stay as they are.
- **Presence is out of scope.** UI that appears or is disabled because of the
  wallet's holdings, such as the transparent strip or a disabled Review button,
  is not masked.

## Every channel, both form factors

Mask the value in every channel that presents it: visible text, painted or
animated text, `Semantics` labels, tooltips, and status or error messages.
Desktop and mobile build most screens separately (`lib/src/app.dart` and
`buildMobileRoutes` in `lib/src/core/navigation/mobile_routes.dart`), so
masking a screen on one form factor requires checking its counterpart.

## Implementation

- Use the helpers in `lib/src/core/privacy/privacy_mask.dart`:
  `hideAmountIfPrivacyMode` for an amount with its denomination,
  `hideIfPrivacyMode` for a bare value, and `fixedPrivacyMask()` where the
  denomination or currency is drawn separately.
- Mask where the display string is built, and pass that same string to `Text`
  and `Semantics`. Keep raw values for logic.
- Read the flag with `ref.watch(privacyModeProvider)` in the build that
  produces the string, or pass it down as `privacyModeEnabled`, so a toggle
  updates the screen in place.
- Test each masked site with privacy mode on (the raw amount is absent from
  text and semantics) and off (it is shown). Mobile-UI tests carry
  `@Tags(['mobile'])`. Existing examples are
  `test/core/privacy/privacy_mask_test.dart`,
  `test/support/gift_card_privacy_checks.dart` (registered in both lanes), and
  `ZEC swap composer masks the max balance in privacy mode` in
  `test/features/swap/swap_screen_test.dart`.
