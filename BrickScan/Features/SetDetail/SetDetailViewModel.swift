import Foundation
import Observation

@Observable
final class SetDetailViewModel {
    let legoSet: LegoSet
    var collectionStatus: CollectionStatus
    var collectionListName: String?
    var isLoading = false
    var errorMessage: String?
    var toastMessage: String?

    private let repository: RebrickableRepositoryProtocol

    init(legoSet: LegoSet, collectionStatus: CollectionStatus, repository: RebrickableRepositoryProtocol = RebrickableRepository()) {
        self.legoSet = legoSet
        self.collectionStatus = collectionStatus
        self.repository = repository
    }

    var isInCollection: Bool {
        if case .inCollection = collectionStatus { return true }
        return false
    }

    var statusIsUnknown: Bool {
        if case .unknown = collectionStatus { return true }
        return false
    }

    @MainActor
    func addToList(listId: Int, listName: String) async {
        await perform {
            try await self.repository.addSetToList(setNum: self.legoSet.setNum, listId: listId)
            self.toastMessage = "Set ajouté à \(listName)"
            await self.refreshCollectionStatus()
        }
    }

    @MainActor
    func removeFromCollection() async {
        await perform {
            try await self.repository.removeSetFromCollection(setNum: self.legoSet.setNum)
            self.collectionStatus = .notInCollection
            self.collectionListName = nil
            self.toastMessage = "Set retiré de la collection"
        }
    }

    @MainActor
    func retryCollectionStatus() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await refreshCollectionStatus()
    }

    @MainActor
    private func refreshCollectionStatus() async {
        do {
            let userSet = try await repository.fetchUserSet(setNum: legoSet.setNum)
            collectionStatus = userSet.map(CollectionStatus.inCollection) ?? .notInCollection
            await refreshCollectionListName()
        } catch let error as APIError {
            collectionStatus = .unknown(error.errorDescription ?? "Statut de collection inconnu")
            collectionListName = nil
        } catch {
            collectionStatus = .unknown("Statut de collection inconnu")
            collectionListName = nil
        }
    }

    @MainActor
    private func refreshCollectionListName() async {
        guard case .inCollection(let userSet) = collectionStatus, let listId = userSet.listId else {
            collectionListName = nil
            return
        }
        let lists = (try? await repository.fetchUserSetLists()) ?? []
        collectionListName = lists.first(where: { $0.id == listId })?.name
    }

    @MainActor
    private func perform(_ operation: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Une erreur est survenue"
        }
    }
}
