import XCTest
@testable import AudioServer

/// End-to-end tests for POST /diarize.
/// Loads real diarization models; skipped in CI via the `--skip E2E`
/// filter; runs locally as part of the isolated E2E runner.
final class E2EDiarizeEndpointTests: XCTestCase {
    static var serverTask: Task<Void, Error>?
    static let port = 19387

    override class func setUp() {
        super.setUp()
        serverTask = Task {
            let server = AudioServer(host: "127.0.0.1", port: port)
            try await server.run()
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    override class func tearDown() {
        serverTask?.cancel()
        Thread.sleep(forTimeInterval: 0.5)
        super.tearDown()
    }

    // MARK: - Helpers

    private func testAudioData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "test_audio", withExtension: "wav") else {
            throw XCTSkip("test_audio.wav resource missing from AudioServerTests bundle")
        }
        return try Data(contentsOf: url)
    }

    private func multipartBody(
        file: Data,
        filename: String = "audio.wav",
        boundary: String = "----diarize-e2e-\(UUID().uuidString)",
        fields: [String: String]
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n".utf8))
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private func post(
        path: String,
        body: Data,
        contentType: String
    ) async throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(Self.port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func assertSegmentsContract(_ data: Data) throws -> [[String: Any]] {
        let decoded = try JSONSerialization.jsonObject(with: data)
        let segments = try XCTUnwrap(decoded as? [[String: Any]], "expected a JSON array of segments")
        for (index, seg) in segments.enumerated() {
            let start = try XCTUnwrap(seg["startTime"] as? Double, "segment \(index) missing startTime")
            let end = try XCTUnwrap(seg["endTime"] as? Double, "segment \(index) missing endTime")
            let speaker = try XCTUnwrap(seg["speakerId"] as? Int, "segment \(index) missing speakerId")
            XCTAssertGreaterThanOrEqual(start, 0)
            XCTAssertGreaterThanOrEqual(end, start)
            XCTAssertGreaterThanOrEqual(speaker, 0)
        }
        return segments
    }

    // MARK: - Tests

    func testCommunity1ReturnsContractSegments() async throws {
        let boundary = "----diarize-e2e-\(UUID().uuidString)"
        let (status, data) = try await post(
            path: "/diarize",
            body: multipartBody(
                file: try testAudioData(), boundary: boundary,
                fields: ["engine": "community1"]),
            contentType: "multipart/form-data; boundary=\(boundary)")

        XCTAssertEqual(status, 200, String(data: data, encoding: .utf8) ?? "")
        let segments = try assertSegmentsContract(data)
        XCTAssertFalse(segments.isEmpty, "expected at least one diarized segment")
    }

    func testDefaultEngineIsPyannote() async throws {
        // No engine field — the route must fall back to pyannote.
        let boundary = "----diarize-e2e-\(UUID().uuidString)"
        let (status, data) = try await post(
            path: "/diarize",
            body: multipartBody(file: try testAudioData(), boundary: boundary, fields: [:]),
            contentType: "multipart/form-data; boundary=\(boundary)")

        XCTAssertEqual(status, 200, String(data: data, encoding: .utf8) ?? "")
        let segments = try assertSegmentsContract(data)
        XCTAssertFalse(segments.isEmpty, "expected at least one diarized segment")
    }

    func testUnknownEngineReturns400() async throws {
        let boundary = "----diarize-e2e-\(UUID().uuidString)"
        let (status, data) = try await post(
            path: "/diarize",
            body: multipartBody(
                file: try testAudioData(), boundary: boundary, fields: ["engine": "nope"]),
            contentType: "multipart/form-data; boundary=\(boundary)")

        XCTAssertEqual(status, 400)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["error"])
    }

    func testMissingAudioReturns400() async throws {
        let boundary = "----diarize-e2e-\(UUID().uuidString)"
        let (status, _) = try await post(
            path: "/diarize",
            body: multipartBody(file: Data(), boundary: boundary, fields: [:]),
            contentType: "multipart/form-data; boundary=\(boundary)")

        XCTAssertEqual(status, 400)
    }
}
