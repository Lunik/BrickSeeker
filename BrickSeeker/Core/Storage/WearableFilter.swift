import Foundation
import Observation

/// Hides Rebrickable's non-set merchandise — caps, bags, watches, plush, stationery… — from the
/// screens that *suggest* sets to the user (issue #224). Rebrickable's catalog files them as real
/// catalog entries, so a search for "LEGO" comes back full of keychains and T-shirts that have
/// nothing to do with a collection of sets.
///
/// **Discovery only.** Everything the user actually owns or scanned — Collection, Historique,
/// Liste cadeaux, Statistiques — is left alone on purpose: a LEGO cap you own is still yours, and
/// a set count or an estimated value that silently drops because of a Réglages toggle reads as a
/// bug. The surfaces this applies to are the ones proposing sets the user hasn't chosen:
/// `NewSetsView`, the scan disambiguator, "Sets similaires", "Sets contenant cette minifig".
/// Deliberately scanning a cap still opens its sheet, flagged with a badge rather than refused —
/// hiding a result the user just pointed the camera at would be the confusing outcome, not the
/// helpful one.
///
/// **Identification is structural, never a list of ids.** These products live under Rebrickable's
/// top-level "Gear" theme (Clothing & Footwear, Bags/Totes/Luggage, Clocks and Watches, Key Chain,
/// Plush Toys…), so the predicate walks `ThemeNameStore`'s `parent_id` hierarchy from the set's
/// theme up to its root. A sub-theme Rebrickable adds later is hidden with no code change, and the
/// unrelated "Gears" theme (a Universal Building Set sub-theme about actual cogs) is unaffected
/// because only *root* themes are matched by name — see `ThemeNameStore.rootThemeId(named:)`.
/// `num_parts == 0` is deliberately **not** used, even as a secondary signal: legitimate sets carry
/// no part count too (see `RebrickableRepository.fetchSimilarSets`, which already works around
/// exactly that), so it would hide real sets.
///
/// Until the theme table has been downloaded the hierarchy is unknown and nothing is hidden — the
/// safe direction: showing a cap is a nuisance, hiding a real set the user is looking for isn't.
@MainActor
@Observable
final class WearableFilter {
    static let shared = WearableFilter()

    private static let enabledKey = "hide_wearables_enabled"
    /// Rebrickable's own name for the merchandise root, matched against top-level themes only.
    private static let gearRootThemeName = "Gear"

    /// On by default: hiding merchandise is the point of the feature, and the screens it affects
    /// only ever *suggest* sets — nothing the user owns disappears either way. Stored (not
    /// computed from `UserDefaults`) so `@Observable` notifies SwiftUI, per the same rule as
    /// `ScanLocationService.isEnabled`.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private let themeNameStore: ThemeNameStore

    init(themeNameStore: ThemeNameStore = .shared) {
        self.themeNameStore = themeNameStore
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Whether this theme is merchandise rather than a buildable set — independent of `isEnabled`,
    /// so `SetDetailView` can badge a scanned cap even while the toggle is off.
    func isWearable(themeId: Int) -> Bool {
        guard let gearRootId else { return false }
        return themeNameStore.isDescendant(themeId, of: gearRootId)
    }

    /// The predicate discovery screens filter on: `isWearable`, gated on the user's preference.
    /// Cheap enough to call per row — the expensive part (finding the "Gear" root, a scan of the
    /// whole theme table) is memoized below, and the tree walk itself is a handful of lookups.
    func shouldHide(themeId: Int) -> Bool {
        isEnabled && isWearable(themeId: themeId)
    }

    /// Memoized against `ThemeNameStore.generation` — resolving the root scans every theme, and
    /// this is called once per set on screens listing thousands of them. `@ObservationIgnored` on
    /// the cache: it's derived state, and writing an observed property while a SwiftUI body is
    /// evaluating is exactly the "modifying state during view update" trap. The read of
    /// `generation` still registers the dependency that re-renders when the table lands.
    private var gearRootId: Int? {
        let generation = themeNameStore.generation
        if let cachedGearRoot, cachedGearRoot.generation == generation { return cachedGearRoot.id }
        let resolved = themeNameStore.rootThemeId(named: Self.gearRootThemeName)
        cachedGearRoot = (generation, resolved)
        return resolved
    }

    @ObservationIgnored private var cachedGearRoot: (generation: Int, id: Int?)?
}
