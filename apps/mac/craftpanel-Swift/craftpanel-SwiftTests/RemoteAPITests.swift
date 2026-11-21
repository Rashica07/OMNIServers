import XCTest
@testable import craftpanel_Swift

final class RemoteAPITests: XCTestCase {
    func testParsesCompleteRequestWithBody() {
        let raw = "POST /api/servers/abc/console?x=1 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\nContent-Length: 15\r\n\r\n{\"line\":\"list\"}"
        guard case .done(let r) = MiniHTTP.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/api/servers/abc/console")
        XCTAssertEqual(r.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"line\":\"list\"}")
    }

    func testIncompleteAndOversizedRequests() {
        XCTAssertEqual(MiniHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
        XCTAssertEqual(MiniHTTP.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), .incomplete)
        XCTAssertEqual(MiniHTTP.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)), .tooLarge)
        XCTAssertEqual(MiniHTTP.parse(Data(repeating: 65, count: MiniHTTP.maxHeaderBytes + 1)), .tooLarge)
        XCTAssertEqual(MiniHTTP.parse(Data("garbage\r\n\r\n".utf8)), .bad)
    }

    func testTokenComparison() {
        XCTAssertTrue(MiniHTTP.tokenMatches("Bearer cp_abc", token: "cp_abc"))
        XCTAssertFalse(MiniHTTP.tokenMatches("Bearer cp_abd", token: "cp_abc"))
        XCTAssertFalse(MiniHTTP.tokenMatches("cp_abc", token: "cp_abc"))
        XCTAssertFalse(MiniHTTP.tokenMatches(nil, token: "cp_abc"))
        XCTAssertFalse(MiniHTTP.tokenMatches("Bearer ", token: ""))
    }

    @MainActor
    func testUnauthorizedRequestsAreRejected() async {
        let req = MiniHTTP.Request(method: "GET", path: "/api/servers", headers: ["authorization": "Bearer nope"], body: Data())
        let resp = String(decoding: await RemoteAPIServer.shared.handle(req), as: UTF8.self)
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 401"))
        let pre = MiniHTTP.Request(method: "OPTIONS", path: "/api/servers", headers: [:], body: Data())
        let preResp = String(decoding: await RemoteAPIServer.shared.handle(pre), as: UTF8.self)
        XCTAssertTrue(preResp.hasPrefix("HTTP/1.1 204"))
    }

    func testDecodesTauriConfigWithoutSwiftOnlyKeys() throws {
        let c = try JSONDecoder().decode(RemoteAPIConfig.self, from: Data(#"{"enabled":true,"token":"cp_x","port":9000}"#.utf8))
        XCTAssertEqual(c.token, "cp_x")
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.port, 9000)
        XCTAssertFalse(c.allowRemote)
    }

    func testTokensAreFreshAndPrefixed() {
        let a = RemoteAPIConfig.newToken(), b = RemoteAPIConfig.newToken()
        XCTAssertTrue(a.hasPrefix("cp_"))
        XCTAssertEqual(a.count, 35)
        XCTAssertNotEqual(a, b)
    }
}

final class UPnPTests: XCTestCase {
    func testParsesSSDPLocation() {
        let r = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/rootDesc.xml\r\nST: urn:x\r\n\r\n"
        XCTAssertEqual(UPnP.parseSSDPLocation(r), "http://192.168.1.1:5000/rootDesc.xml")
        XCTAssertNil(UPnP.parseSSDPLocation("HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n"))
    }

    func testFindsWANIPControlURLRelativeToLocation() {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><deviceList><device>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>
        """
        let gw = UPnP.parseDescription(Data(xml.utf8), location: URL(string: "http://192.168.1.1:5000/rootDesc.xml")!)
        XCTAssertEqual(gw?.controlURL.absoluteString, "http://192.168.1.1:5000/ctl/IPConn")
        XCTAssertEqual(gw?.serviceType, "urn:schemas-upnp-org:service:WANIPConnection:1")
    }

    func testEnvelopeEscapesArguments() {
        let e = UPnP.envelope(action: "AddPortMapping", serviceType: "urn:s", args: [("NewPortMappingDescription", "a<b&c")])
        XCTAssertTrue(e.contains("<NewPortMappingDescription>a&lt;b&amp;c</NewPortMappingDescription>"))
        XCTAssertTrue(e.contains("<u:AddPortMapping xmlns:u=\"urn:s\">"))
    }
}
