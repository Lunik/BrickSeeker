import XCTest
@testable import BrickScan

final class RebrickableRepositoryTests: XCTestCase {
    private var repository: RebrickableRepository!

    override func setUp() {
        super.setUp()
        let session = MockURLProtocol.makeSession()
        let client = NetworkClient(session: session)
        repository = RebrickableRepository(client: client)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func response(status: Int, json: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://rebrickable.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (response, data)
    }

    func testResolveSetFirstAttemptSucceeds() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("42143-1"))
            return self.response(status: 200, json: [
                "set_num": "42143-1", "name": "Ferrari", "year": 2022,
                "theme_id": 1, "num_parts": 3778, "set_img_url": NSNull(), "set_url": NSNull()
            ])
        }

        let resolution = try await repository.resolveSet(setNum: "42143")
        guard case .found(let set) = resolution else {
            return XCTFail("Expected found")
        }
        XCTAssertEqual(set.setNum, "42143-1")
    }

    func testResolveSetSecondAttemptSucceeds() async throws {
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if request.url!.absoluteString.contains("42143-1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            return self.response(status: 200, json: [
                "set_num": "42143", "name": "Ferrari", "year": 2022,
                "theme_id": 1, "num_parts": 3778, "set_img_url": NSNull(), "set_url": NSNull()
            ])
        }

        let resolution = try await repository.resolveSet(setNum: "42143")
        guard case .found(let set) = resolution else {
            return XCTFail("Expected found")
        }
        XCTAssertEqual(set.setNum, "42143")
        XCTAssertEqual(callCount, 2)
    }

    func testResolveSetThirdAttemptSearch() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url!.absoluteString.contains("/lego/sets/?") {
                let json: [String: Any] = [
                    "count": 1,
                    "next": NSNull(),
                    "previous": NSNull(),
                    "results": [[
                        "set_num": "42143-1", "name": "Ferrari", "year": 2022,
                        "theme_id": 1, "num_parts": 3778, "set_img_url": NSNull(), "set_url": NSNull()
                    ]]
                ]
                return self.response(status: 200, json: json)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let resolution = try await repository.resolveSet(setNum: "42143")
        guard case .found = resolution else {
            return XCTFail("Expected found via search")
        }
    }

    func testResolveSetNotFound() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url!.absoluteString.contains("/lego/sets/?") {
                return self.response(status: 200, json: ["count": 0, "next": NSNull(), "previous": NSNull(), "results": []])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let resolution = try await repository.resolveSet(setNum: "99999999")
        guard case .notFound = resolution else {
            return XCTFail("Expected notFound")
        }
    }

    func testAuthenticateUnauthorized() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await repository.authenticate(apiKey: "bad", username: "user", password: "pass")
            XCTFail("Expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, APIError.unauthorized.errorDescription)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testAuthenticateForbidden() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await repository.authenticate(apiKey: "key", username: "user", password: "wrong")
            XCTFail("Expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, APIError.forbidden.errorDescription)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testFetchUserSetNotFoundReturnsNil() async throws {
        KeychainService.shared.save(key: .userToken, value: "test_token")
        defer { KeychainService.shared.delete(key: .userToken) }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let userSet = try await repository.fetchUserSet(setNum: "42143-1")
        XCTAssertNil(userSet)
    }

    func testFetchUserSetFoundDecodesNestedSet() async throws {
        KeychainService.shared.save(key: .userToken, value: "test_token")
        defer { KeychainService.shared.delete(key: .userToken) }

        MockURLProtocol.requestHandler = { request in
            self.response(status: 200, json: [
                "set": [
                    "set_num": "42143-1", "name": "Ferrari", "year": 2022,
                    "theme_id": 1, "num_parts": 3778, "set_img_url": NSNull(), "set_url": NSNull()
                ],
                "quantity": 1,
                "include_spares": false,
                "list_id": 7
            ])
        }

        let userSet = try await repository.fetchUserSet(setNum: "42143-1")
        XCTAssertEqual(userSet?.setNum, "42143-1")
        XCTAssertEqual(userSet?.listId, 7)
    }

    func testForbiddenWithoutStoredPasswordPropagatesError() async {
        KeychainService.shared.save(key: .userToken, value: "expired_token")
        defer { KeychainService.shared.delete(key: .userToken) }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await repository.fetchUserSetLists()
            XCTFail("Expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, APIError.forbidden.errorDescription)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testMissingCredentialsThrows() async {
        KeychainService.shared.delete(key: .userToken)

        do {
            _ = try await repository.fetchUserSetLists()
            XCTFail("Expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, APIError.missingCredentials.errorDescription)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testAddSetToListPostsToSetListSetsEndpointWithoutDecodingBody() async throws {
        KeychainService.shared.save(key: .userToken, value: "test_token")
        defer { KeychainService.shared.delete(key: .userToken) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/users/test_token/setlists/7/sets/"))
            // Rebrickable's real response shape for this endpoint is not
            // reliably documented; returning an arbitrary body must not
            // cause a decoding error since the repository ignores it.
            return self.response(status: 201, json: ["unexpected": "shape"])
        }

        try await repository.addSetToList(setNum: "42143-1", listId: 7)
    }

    func testMoveSetToListDeletesFromOldListThenAddsToNewList() async throws {
        KeychainService.shared.save(key: .userToken, value: "test_token")
        defer { KeychainService.shared.delete(key: .userToken) }

        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestedPaths.append("\(request.httpMethod ?? "") \(request.url!.absoluteString)")
            if request.httpMethod == "DELETE" {
                XCTAssertTrue(request.url!.absoluteString.contains("/users/test_token/setlists/3/sets/42143-1/"))
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertTrue(request.url!.absoluteString.contains("/users/test_token/setlists/9/sets/"))
            return self.response(status: 201, json: ["unexpected": "shape"])
        }

        try await repository.moveSetToList(setNum: "42143-1", fromListId: 3, toListId: 9)
        XCTAssertEqual(requestedPaths.count, 2)
        XCTAssertTrue(requestedPaths[0].hasPrefix("DELETE"))
        XCTAssertTrue(requestedPaths[1].hasPrefix("POST"))
    }
}
