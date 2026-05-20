import XCTest
@testable import sakura_mcp

final class MCPServerTests: XCTestCase {
    func testInitializeRoundtrip() throws {
        let request = """
        {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        """

        let data = request.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)

        guard case .request(let id, let method, _) = message else {
            XCTFail("Expected request")
            return
        }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "initialize")
    }

    func testToolsListRoundtrip() throws {
        let request = """
        {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
        """

        let data = request.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)

        guard case .request(let id, let method, _) = message else {
            XCTFail("Expected request")
            return
        }
        XCTAssertEqual(id, "2")
        XCTAssertEqual(method, "tools/list")
    }

    func testJSONRPCValueRoundtrip() throws {
        let original: JSONRPCValue = .object([
            "name": .string("test"),
            "count": .number(42),
            "active": .bool(true),
            "items": .array([.string("a"), .string("b")])
        ])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONRPCValue.self, from: encoded)

        // Compare JSON strings since Equatable on JSONRPCValue handles this
        let originalJSON = String(data: try JSONEncoder().encode(original), encoding: .utf8)!
        let decodedJSON = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        XCTAssertEqual(originalJSON, decodedJSON)
    }

    func testResponseEncoding() throws {
        let response = JSONRPCMessage.response(
            id: "1",
            result: .object([
                "screens": .array([.string("screen_1")])
            ])
        )

        let encoded = try JSONEncoder().encode(response)
        let json = String(data: encoded, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(json.contains("\"id\":\"1\""))
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertTrue(json.contains("screen_1"))
    }

    func testErrorEncoding() throws {
        let error = JSONRPCMessage.error(id: "3", code: -32600, message: "Invalid Request")

        let encoded = try JSONEncoder().encode(error)
        let json = String(data: encoded, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"code\":-32600"))
        XCTAssertTrue(json.contains("Invalid Request"))
    }

    func testNotificationDecoding() throws {
        let notification = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """

        let data = notification.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)

        guard case .notification(let method, _) = message else {
            XCTFail("Expected notification")
            return
        }
        XCTAssertEqual(method, "notifications/initialized")
    }
}
