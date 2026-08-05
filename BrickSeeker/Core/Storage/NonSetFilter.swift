import Foundation
import Observation

/// Hides the entries of Rebrickable's catalog that aren't sets of bricks — merchandise, books,
/// LEGO's own internal exclusives — from the screens that *suggest* sets to the user (issue #224),
/// plus the catalog's own bookkeeping rows, which are hidden unconditionally. Together that's
/// 7 795 of the dump's 27 940 entries (28 %), measured on the real `sets.csv`/`themes.csv` dumps
/// rather than estimated.
///
/// **Discovery only.** Everything the user actually owns or scanned — Collection, Historique,
/// Liste cadeaux, Statistiques — is left alone on purpose: a LEGO cap you own is still yours, and
/// a set count or an estimated value that silently drops because of a Réglages toggle reads as a
/// bug. The surfaces this applies to are the ones proposing sets the user hasn't chosen:
/// `NewSetsView`, the scan disambiguator, "Sets contenant cette minifig". Deliberately scanning a
/// cap still opens its sheet, flagged with a badge rather than refused — hiding a result the user
/// just pointed the camera at would be the confusing outcome, not the helpful one.
///
/// **Identification is structural, never a list of ids or a number pattern.** Each `Kind` below is
/// one named theme sub-tree, resolved through `ThemeNameStore`'s `parent_id` hierarchy, so a
/// sub-theme Rebrickable adds later is hidden with no code change. Two shapes of signal were
/// measured against the dumps and rejected:
///
/// - **`num_parts == 0`** — legitimate sets carry no part count either (see
///   `RebrickableRepository.fetchSimilarSets`, which already works around exactly that), and
///   conversely 541 of the 1 440 Books entries *do* ship parts. It would hide real sets and miss
///   real books.
/// - **"a non-numeric set number is never a real product"** — proposed on #224 from screenshots of
///   `SLIZER`/`DOSSIER`/`AUTOSHOW`. 2 554 entries match it, including 80 Star Wars, 76 Promotional
///   and 75 FIRST LEGO League ones; `AUTOSHOW-1` is a genuine 28-part Chevrolet Silverado promo
///   set. The real signal behind those screenshots is the "Database Sets" theme, which catches
///   `SLIZER-1`/`SLIZER-5`/`DOSSIER-1` exactly and leaves `AUTOSHOW-1` alone.
///
/// Until the theme table has been downloaded no name resolves, so nothing is hidden — the safe
/// direction: showing a cap is a nuisance, hiding a real set the user is looking for isn't.
@MainActor
@Observable
final class NonSetFilter {
    static let shared = NonSetFilter()

    /// Why a catalog entry isn't a set. Each case is a theme sub-tree matched by name, never by id.
    enum Kind: Hashable {
        /// Rebrickable's "Gear" root (6 139 entries): clothing, bags, watches, key chains, plush,
        /// houseware, stationery.
        case merchandise
        /// The "Books" root (1 440 entries): story, activity, ideas and non-fiction books. Kept
        /// whole rather than sparing the "Activity Books with LEGO Parts" sub-theme — carving out
        /// one id is the hardcoded exception this design exists to avoid, and someone who collects
        /// Klutz books can turn the toggle off.
        case book
        /// The "LEGO Exclusive" root (83 entries): LEGO Inside Tour sets, moulding machines,
        /// employee Christmas gifts, the 14-karat gold brick — real products, but never sold.
        case exclusive
        /// The "Database Sets" theme (133 entries, all literally named "Database Set for …"):
        /// Rebrickable's own bookkeeping rows for print variants, not products at all. Hidden
        /// whatever the toggle says — see `shouldHide(themeId:)`.
        case catalogArtifact
    }

    /// The theme name each `Kind` is resolved from, and whether only a *root* may match. Roots-only
    /// is the stricter rule and the default: a nested theme can share a name with an unrelated
    /// branch — "Gears" (a Universal Building Set sub-theme, about actual cogs) must never resolve
    /// to the "Gear" merchandise root. "Database Sets" can't use it because it legitimately sits
    /// under "Other"; its name is distinctive enough that matching at any depth is safe.
    private static let subtrees: [(kind: Kind, themeName: String, rootsOnly: Bool)] = [
        (.catalogArtifact, "Database Sets", false),
        (.merchandise, "Gear", true),
        (.book, "Books", true),
        (.exclusive, "LEGO Exclusive", true),
    ]

    /// Kept as `hide_wearables_enabled` even though the feature outgrew "wearables": renaming the
    /// key would silently reset the preference of everyone who already turned it off.
    private static let enabledKey = "hide_wearables_enabled"

    /// On by default: hiding non-sets is the point of the feature, and the screens it affects only
    /// ever *suggest* sets — nothing the user owns disappears either way. Stored (not computed from
    /// `UserDefaults`) so `@Observable` notifies SwiftUI, per the same rule as
    /// `ScanLocationService.isEnabled`.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            // Only `shouldHide` depends on the toggle; `kind(themeId:)` doesn't, and the theme
            // tree hasn't moved. Nothing to invalidate — noted so nobody adds a needless flush.
        }
    }

    private let themeNameStore: ThemeNameStore

    init(themeNameStore: ThemeNameStore = .shared) {
        self.themeNameStore = themeNameStore
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Why this theme isn't a set, or `nil` if it is one. Independent of `isEnabled`, so
    /// `SetDetailView` can badge a scanned cap even while the toggle is off.
    func kind(themeId: Int) -> Kind? {
        let generation = themeNameStore.generation
        if cachedKinds.generation != generation {
            cachedKinds = (generation, [:])
        }
        if let known = cachedKinds.byThemeId[themeId] { return known }
        let resolved = resolveKind(themeId: themeId, generation: generation)
        cachedKinds.byThemeId[themeId] = resolved
        return resolved
    }

    /// The predicate discovery screens filter on. Catalog artifacts go whatever the preference
    /// says — they're not products, so there's no reading of the toggle under which someone wants
    /// "Database Set for 1307-1" proposed to them. Everything else is the user's choice.
    func shouldHide(themeId: Int) -> Bool {
        switch kind(themeId: themeId) {
        case .catalogArtifact: true
        case .merchandise, .book, .exclusive: isEnabled
        case nil: false
        }
    }

    private func resolveKind(themeId: Int, generation: Int) -> Kind? {
        for subtree in rootIds(generation: generation)
        where themeNameStore.isDescendant(themeId, of: subtree.id) {
            return subtree.kind
        }
        return nil
    }

    /// Resolves each sub-tree's name to theme ids, memoized against `ThemeNameStore.generation` —
    /// every lookup scans the whole theme table, and this runs once per set on screens listing
    /// thousands of them.
    private func rootIds(generation: Int) -> [(kind: Kind, id: Int)] {
        if let cachedRoots, cachedRoots.generation == generation { return cachedRoots.ids }
        let ids = Self.subtrees.flatMap { subtree -> [(kind: Kind, id: Int)] in
            let matches = subtree.rootsOnly
                ? [themeNameStore.rootThemeId(named: subtree.themeName)].compactMap { $0 }
                : themeNameStore.themeIds(named: subtree.themeName)
            return matches.map { (subtree.kind, $0) }
        }
        cachedRoots = (generation, ids)
        return ids
    }

    /// `@ObservationIgnored` on both caches: they're derived state, and writing an observed
    /// property while a SwiftUI body is evaluating is exactly the "modifying state during view
    /// update" trap. The read of `generation` in `kind(themeId:)` still registers the dependency
    /// that re-renders when the table lands.
    ///
    /// `byThemeId` stores `Kind?` (hence the double optional on lookup) so a theme that resolved to
    /// "this is a real set" is remembered as such instead of being walked again on every row.
    /// Bounded by the theme table's ~500 rows, not by the catalogue's 28 000 sets.
    @ObservationIgnored private var cachedRoots: (generation: Int, ids: [(kind: Kind, id: Int)])?
    @ObservationIgnored private var cachedKinds: (generation: Int, byThemeId: [Int: Kind?]) = (-1, [:])
}
