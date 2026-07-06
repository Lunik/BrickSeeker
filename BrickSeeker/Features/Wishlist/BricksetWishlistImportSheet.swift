import SwiftUI

/// Sheet wrapping `BricksetWishlistImportSection` (the file picker + progress + summary — it's
/// designed to live inside a `Form` `Section`, same convention as `CollectionPriceUpdateSection`)
/// for presentation from `WishlistView`'s import button.
struct BricksetWishlistImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BricksetWishlistImportSection()
                } footer: {
                    Text("Sur la page de ta custom list Rebrickable, onglet Sets, télécharge le CSV puis choisis-le ici pour ajouter tous ses sets à ta liste cadeaux Brickset.")
                }
            }
            .navigationTitle("Importer depuis Rebrickable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
