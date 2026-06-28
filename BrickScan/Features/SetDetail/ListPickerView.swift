import SwiftUI

struct ListPickerView: View {
    @State private var setLists: [SetList] = []
    @State private var isLoading = true
    @State private var newListName = ""
    @State private var showNewListField = false
    @State private var selectedListId: Int?
    @Environment(\.dismiss) private var dismiss

    private let repository: RebrickableRepositoryProtocol
    let onConfirm: (Int, String) -> Void

    init(repository: RebrickableRepositoryProtocol = RebrickableRepository(), onConfirm: @escaping (Int, String) -> Void) {
        self.repository = repository
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                } else {
                    ForEach(setLists) { list in
                        Button {
                            selectedListId = list.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(list.name)
                                    Text("\(list.numSets) sets")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedListId == list.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.shared.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section {
                    if showNewListField {
                        TextField("Nom de la nouvelle liste", text: $newListName)
                    } else {
                        Button("Créer une nouvelle liste") {
                            showNewListField = true
                        }
                    }
                }
            }
            .navigationTitle("Choisir une liste")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") {
                        Task { await confirm() }
                    }
                    .disabled(selectedListId == nil && (newListName.isEmpty || !showNewListField))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .task { await loadLists() }
        }
    }

    private func loadLists() async {
        isLoading = true
        setLists = (try? await repository.fetchUserSetLists()) ?? []
        isLoading = false
    }

    private func confirm() async {
        if showNewListField, !newListName.isEmpty {
            if let created = try? await repository.createSetList(name: newListName) {
                onConfirm(created.id, created.name)
                dismiss()
            }
        } else if let selectedListId, let list = setLists.first(where: { $0.id == selectedListId }) {
            onConfirm(list.id, list.name)
            dismiss()
        }
    }
}
