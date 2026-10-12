/// Where ERF-number lookups and their suggestions are allowed to come from.
///
/// ERF numbers repeat all over the country, so an unscoped lookup for "1234"
/// offers candidates from Gauteng, KZN and the Free State alongside the one
/// the user actually meant. Operations here are in Cape Town, so that is the
/// default and the widest net is opt-in.
enum ErfSearchScope {
  /// The Cape Town cadastral major region (MAJ_CODE C0160000) — Constantia,
  /// Langa, the CBD and the rest of the metro.
  capeTown,

  /// Everything in the Western Cape province.
  westernCape,

  /// No geographic restriction.
  southAfrica;

  String get label => switch (this) {
        ErfSearchScope.capeTown => 'Cape Town',
        ErfSearchScope.westernCape => 'Western Cape',
        ErfSearchScope.southAfrica => 'All of South Africa',
      };

  String get description => switch (this) {
        ErfSearchScope.capeTown =>
          'Only parcels in the Cape Town cadastral region',
        ErfSearchScope.westernCape => 'Any parcel in the Western Cape',
        ErfSearchScope.southAfrica =>
          'Anywhere — expect duplicate ERF numbers between provinces',
      };

  /// Cadastral major-region code to filter on, when this scope uses one.
  String? get majCode =>
      this == ErfSearchScope.capeTown ? 'C0160000' : null;

  /// Province name to filter on, when this scope uses one.
  String? get province =>
      this == ErfSearchScope.westernCape ? 'WESTERN CAPE' : null;

  bool get isRestricted => this != ErfSearchScope.southAfrica;

  /// Whether a parcel with these attributes falls inside this scope.
  ///
  /// Used to filter parcels already held in memory, where re-querying the
  /// register would be wasteful.
  bool allows({required String majCode, required String province}) {
    return switch (this) {
      ErfSearchScope.capeTown => majCode == 'C0160000',
      ErfSearchScope.westernCape =>
        province.toUpperCase() == 'WESTERN CAPE',
      ErfSearchScope.southAfrica => true,
    };
  }
}
