import SwiftUI

/// Static info blurb only — no button of its own. It used to have a "?" that opened
/// `PrivacyDetailView`, right next to `SettingsView`'s own "Confidentialité & données" row that
/// opens the exact same sheet (#153); the row is the one real entry point now.
struct PrivacyNoticeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("Vos données restent sur votre appareil")
                    .font(.subheadline.bold())
            }

            bullet("Vos clés API et identifiants sont conservés dans le Keychain iOS chiffré par Apple ; votre historique de scans et votre collection restent sur l'appareil.")
            bullet("Vous pouvez révoquer l'accès à tout moment depuis vos paramètres Rebrickable, Brickset ou BrickLink.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}
