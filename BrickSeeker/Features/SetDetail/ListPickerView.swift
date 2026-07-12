import SwiftUI

struct ListPickerView: View {
    @State private var setLists: [SetList] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var newListName = ""
    @State private var showNewListField = false
    @State private var selectedListId: Int?
    @Environment(\.dismiss) private var dismiss

    private let repository: RebrickableRepositoryProtocol
    private let excludeListId: Int?
    let onConfirm: (Int, String) -> Void

    init(
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        excludeListId: Int? = nil,
        onConfirm: @escaping (Int, String) -> Void
    ) {
        self.repository = repository
        self.excludeListId = excludeListId
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                } else if setLists.isEmpty && errorMessage == nil {
                    // A successful load that just came back empty looked identical to a stuck
                    // spinner or a silently-failed fetch, with nothing explaining there's simply
                    // no list yet (#147).
                    Text("Aucune liste sur votre compte. Créez-en une ci-dessous.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(setLists.filter { $0.id != excludeListId }) { list in
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

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Choisir une liste")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await confirm() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Enregistrer")
                        }
                    }
                    // Also disabled while saving — a second tap during createSetList used to
                    // fire a second creation (#81).
                    .disabled(isSaving || (selectedListId == nil && (newListName.isEmpty || !showNewListField)))
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
        errorMessage = nil
        do {
            setLists = try await repository.fetchUserSetLists()
        } catch {
            // Surface why the list is empty (e.g. missingCredentials when no account is linked)
            // instead of an indistinguishable blank list (#81).
            setLists = []
            errorMessage = (error as? APIError)?.errorDescription ?? String(localized: "Impossible de charger vos listes. Vérifiez votre réseau.")
        }
        isLoading = false
    }

    private func confirm() async {
        errorMessage = nil
        if showNewListField, !newListName.isEmpty {
            isSaving = true
            defer { isSaving = false }
            do {
                let created = try await repository.createSetList(name: newListName)
                onConfirm(created.id, created.name)
                dismiss()
            } catch {
                // Réseau, 403, nom refusé… — before this, a failed creation was a silent no-op
                // and the button just "didn't work" (#81).
                errorMessage = (error as? APIError)?.errorDescription ?? String(localized: "Impossible de créer la liste. Vérifiez votre réseau.")
            }
        } else if let selectedListId, let list = setLists.first(where: { $0.id == selectedListId }) {
            onConfirm(list.id, list.name)
            dismiss()
        }
    }
}
