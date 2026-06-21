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

            bullet("Seule votre API Key est conservée, dans le Keychain iOS chiffré par Apple.")
            bullet("Vous pouvez révoquer l'accès à tout moment depuis vos paramètres Rebrickable.")

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
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
