import 'address_book_contact.dart';
import 'address_book_label_lookup.dart';

/// The recent recipients and saved contacts a recipient picker shows for the
/// current field text.
class RecipientSuggestions<R> {
  const RecipientSuggestions({required this.recents, required this.contacts});

  final List<R> recents;
  final List<AddressBookContact> contacts;

  bool get isNotEmpty => recents.isNotEmpty || contacts.isNotEmpty;
}

/// Characters an address fragment must match beyond its network prefix.
const kRecipientAddressFragmentLength = 4;

/// Matches the field text against [recents] and [contacts], shared by the
/// Send and Pay recipient steps.
///
/// Labels match by substring, including the name a recent row shows
/// ([recentLabel]). Addresses match by their start or end, the parts the app
/// shows: a fragment must cover [kRecipientAddressFragmentLength] characters
/// past the network prefix (`u1`, `t1`, `0x`, ...) that every address shares,
/// so a bare prefix lists nothing. A recent is left out when a matched contact
/// already shows its address.
RecipientSuggestions<R> matchRecipientSuggestions<R>({
  required String query,
  required AddressBookNetwork network,
  required List<R> recents,
  required String Function(R recent) recentAddress,
  String? Function(R recent)? recentLabel,
  required List<AddressBookContact> contacts,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return RecipientSuggestions(recents: recents, contacts: contacts);
  }
  final label = trimmed.toLowerCase();
  final matchedContacts = [
    for (final contact in contacts)
      if (contact.label.toLowerCase().contains(label) ||
          _addressMatches(contact.network, contact.address, trimmed))
        contact,
  ];
  final shownAddresses = {
    for (final contact in matchedContacts)
      normalizedAddressBookAddress(network, contact.address),
  };
  return RecipientSuggestions(
    recents: [
      for (final recent in recents)
        if ((_addressMatches(network, recentAddress(recent), trimmed) ||
                (recentLabel?.call(recent)?.toLowerCase().contains(label) ??
                    false)) &&
            !shownAddresses.contains(
              normalizedAddressBookAddress(network, recentAddress(recent)),
            ))
          recent,
    ],
    contacts: matchedContacts,
  );
}

bool _addressMatches(
  AddressBookNetwork network,
  String address,
  String fragment,
) {
  final candidate = normalizedAddressBookAddress(network, address);
  final needle = normalizedAddressBookAddress(network, fragment);
  if (needle.isEmpty) return false;
  if (candidate.startsWith(needle) &&
      needle.length - _networkPrefixLength(network, candidate) >=
          kRecipientAddressFragmentLength) {
    return true;
  }
  return needle.length >= kRecipientAddressFragmentLength &&
      candidate.endsWith(needle);
}

// `0x` for hex addresses, otherwise, on networks with bech32 addresses, an
// `hrp1` (`u1`, `zs1`, `tex1`, `bc1`; also the `t1` of a transparent address).
// Bech32 may also be written all uppercase, which a mixed-case base58 address
// never is.
final _hrpPrefix = RegExp(r'^[a-z]{1,16}1');
final _upperHrpPrefix = RegExp(r'^[A-Z]{1,16}1');

int _networkPrefixLength(AddressBookNetwork network, String address) {
  if (address.startsWith('0x')) return 2;
  if (!_hasBech32Addresses(network)) return 0;
  final hrp = address == address.toUpperCase() ? _upperHrpPrefix : _hrpPrefix;
  return hrp.firstMatch(address)?.end ?? 0;
}

// Elsewhere a `1` is part of the address itself, as in a NEAR account name.
bool _hasBech32Addresses(AddressBookNetwork network) => switch (network) {
  AddressBookNetwork.zcash ||
  AddressBookNetwork.bitcoin ||
  AddressBookNetwork.litecoin ||
  AddressBookNetwork.cardano ||
  AddressBookNetwork.aleo => true,
  _ => false,
};
