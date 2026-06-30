import SwiftUI
import SwiftData

struct ListConditionsView: View {
    @Query(sort: \CachedSetList.name) private var setLists: [CachedSetList]

    var body: some View {
        Group {
            if setLists.isEmpty {
                ContentUnavailableView(
                    "Aucune liste",
                    systemImage: "list.bullet",
                    description: Text("Synchronisez votre collection depuis l'accueil pour voir vos listes Rebrickable ici.")
                )
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sélectionner le type de liste")
                                .font(.title2.bold())
                            Text("Le type détermine la source de prix utilisée pour estimer la valeur de votre collection. Choisissez « Neuf » pour les sets encore scellés (lego.com en priorité) et « Occasion » pour les sets ouverts ou d'occasion (BrickLink occasion).")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 4)
                    }

                    ForEach(setLists) { list in
                        ListConditionRow(list: list)
                    }
                }
            }
        }
        .navigationTitle("Listes")
    }
}

struct ListConditionRow: View {
    let list: CachedSetList
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Picker(list.name, selection: Binding(
            get: { list.condition },
            set: {
                list.condition = $0
                try? modelContext.save()
            }
        )) {
            ForEach(ListCondition.allCases) { condition in
                Text(condition.displayName).tag(condition)
            }
        }
    }
}
