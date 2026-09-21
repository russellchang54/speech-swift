import XCTest
@testable import AudioServer
import AudioCommon

final class DiarizeEndpointTests: XCTestCase {
    // MARK: - Registry resolution

    func testDiarizeVariantsResolveForAllEngines() {
        for engine in ["pyannote", "community1", "sortformer"] {
            let variant = defaultVariant(forEngine: engine, kind: .diarize)
            XCTAssertEqual(variant.engine, engine)
            XCTAssertEqual(variant.kind, .diarize)
        }
    }

    func testCommunity1VariantResolvesByAlias() {
        for name in ["community1", "community-1", "community1-diarize",
                     "community1-diarization-coreml"] {
            let variant = resolveModelVariant(name)
            XCTAssertNotNil(variant, "alias \(name) should resolve")
            XCTAssertEqual(variant?.kind, .diarize)
        }
    }

    func testPyannoteDiarizeVariantDoesNotShadowVADVariant() {
        // "pyannote" must keep resolving to the segmentation (VAD) variant;
        // the diarization entry deliberately omits that alias.
        XCTAssertEqual(resolveModelVariant("pyannote")?.kind, .vad)
        XCTAssertEqual(resolveModelVariant("pyannote-diarization")?.kind, .diarize)
    }

    // MARK: - Response contract

    func testSegmentsMapToWireContract() {
        let segments = [
            DiarizedSegment(startTime: 0.4231, endTime: 3.8749, speakerId: 0),
            DiarizedSegment(startTime: 4.0, endTime: 7.5, speakerId: 1),
        ]

        let json = diarizeSegmentsJSON(segments)

        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["startTime"] as? Double, 0.423)
        XCTAssertEqual(json[0]["endTime"] as? Double, 3.875)
        XCTAssertEqual(json[0]["speakerId"] as? Int, 0)
        XCTAssertEqual(json[1]["startTime"] as? Double, 4.0)
        XCTAssertEqual(json[1]["speakerId"] as? Int, 1)
    }

    func testSegmentsJSONEncodesToContractShape() throws {
        let segments = [DiarizedSegment(startTime: 1.0, endTime: 2.0, speakerId: 0)]
        let data = try JSONSerialization.data(
            withJSONObject: diarizeSegmentsJSON(segments))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?[0]["startTime"] as? Double, 1.0)
        XCTAssertEqual(decoded?[0]["endTime"] as? Double, 2.0)
        XCTAssertEqual(decoded?[0]["speakerId"] as? Int, 0)
    }

    // MARK: - Request parsing

    func testNumSpeakersAcceptsSnakeAndCamelCase() throws {
        let snake = try RequestParams.parse(
            .init(data: JSONSerialization.data(withJSONObject: [
                "audio_base64": "", "num_speakers": 2,
            ])),
            contentType: "application/json")
        XCTAssertEqual(snake.int("num_speakers"), 2)

        let camel = try RequestParams.parse(
            .init(data: JSONSerialization.data(withJSONObject: [
                "audio_base64": "", "numSpeakers": 3,
            ])),
            contentType: "application/json")
        XCTAssertEqual(camel.int("numSpeakers"), 3)
    }
}
