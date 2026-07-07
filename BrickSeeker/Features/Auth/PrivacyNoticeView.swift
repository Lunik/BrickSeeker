import SwiftUI

struct PrivacyNoticeView: View {
    @State private var showDetail = false

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

            HStack {
                Spacer()
                Button {
                    showDetail = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .sheet(isPresented: $showDetail) {
            PrivacyDetailView()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}
