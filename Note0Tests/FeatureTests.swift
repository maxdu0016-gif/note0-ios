import CoreGraphics
import UIKit
import XCTest
@testable import Note0

final class AIPromptTests: XCTestCase {
    func testStreamLinesOnlyYieldDeltas() {
        XCTAssertEqual(AIPrompt.deltaText(fromLine: #"{"type":"delta","text":"你好"}"#), "你好")
        XCTAssertNil(AIPrompt.deltaText(fromLine: #"{"type":"reasoning","text":"..."}"#))
        XCTAssertNil(AIPrompt.deltaText(fromLine: #"{"type":"final","message":{}}"#))
        XCTAssertNil(AIPrompt.deltaText(fromLine: "not json"))
    }

    func testBaseURLNormalisation() {
        XCTAssertEqual(AIConfig.normalizedBaseURL("api.example.com/"), "https://api.example.com")
        XCTAssertEqual(AIConfig.normalizedBaseURL("192.168.1.20:8081"), "http://192.168.1.20:8081")
        XCTAssertEqual(AIConfig.normalizedBaseURL("http://localhost:8081//"), "http://localhost:8081")
        XCTAssertEqual(AIConfig.normalizedBaseURL("  "), "")
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(AIClient.formEncoded(["username": "a+b@x.com", "password": "p&w=1"]),
                       "password=p%26w%3D1&username=a%2Bb%40x.com")
    }

    func testTokenParsingAcceptsStandardResponse() throws {
        let body = #"{"status":"success","data":{"token":{"access_token":"A","token_type":"bearer","refresh_token":"R"}}}"#
        let ok = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let tokens = try AIClient.parseTokens(from: Data(body.utf8), response: ok, fallbackMessage: "")
        XCTAssertEqual(tokens.access, "A")
        XCTAssertEqual(tokens.refresh, "R")

        let denied = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let failure = #"{"detail":"Incorrect username or password"}"#
        XCTAssertThrowsError(try AIClient.parseTokens(from: Data(failure.utf8), response: denied, fallbackMessage: "x")) { error in
            XCTAssertEqual(error.localizedDescription, "邮箱或密码不正确。")
        }
    }

    func testServerErrorDetailIsShown() {
        let message = AIClient.errorMessage(from: Data(#"{"detail":"Model 'x' is not available on your plan"}"#.utf8), status: 403)
        XCTAssertEqual(message, "当前账号的套餐不能使用这个 AI 模型。")
        XCTAssertEqual(AIClient.errorMessage(from: Data(), status: 429), "请求太频繁或额度已用完，请稍后再试。")
    }
}

final class CardTests: XCTestCase {
    func testLongerTextMakesTallerCard() {
        let short = CardRenderer.height(for: "一句话", width: 280)
        let long = CardRenderer.height(for: String(repeating: "这是很长的一段解释。", count: 30), width: 280)
        XCTAssertGreaterThan(long, short)
    }

    func testCardGoesBelowRegionInsidePage() {
        let page = PageGeometry.a4
        let frame = CardPlacement.frame(for: "答案", below: CGRect(x: 500, y: 100, width: 50, height: 40), pageSize: page)
        XCTAssertEqual(frame.minY, 148, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.width, 260)
        XCTAssertLessThanOrEqual(frame.maxX, page.width - CardPlacement.margin + 0.001)
    }

    func testCardMovesAboveWhenNoRoomBelow() {
        let page = PageGeometry.a4
        let region = CGRect(x: 40, y: 700, width: 300, height: 120)
        let frame = CardPlacement.frame(for: "答案", below: region, pageSize: page)
        XCTAssertLessThanOrEqual(frame.maxY, region.minY)
    }

    func testSelectionRectIsNormalised() {
        let rect = RegionSelectionView.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 40, height: 60))
    }
}

final class OpenNotebookRegistryTests: XCTestCase {
    func testSameNotebookCannotBeClaimedByTwoWindows() {
        let registry = OpenNotebookRegistry()
        let notebook = UUID(), windowA = UUID(), windowB = UUID()
        XCTAssertTrue(registry.claim(notebook, by: windowA))
        XCTAssertTrue(registry.claim(notebook, by: windowA))
        XCTAssertFalse(registry.claim(notebook, by: windowB))
        registry.release(notebook, by: windowB)
        XCTAssertTrue(registry.isOpen(notebook))
        registry.release(notebook, by: windowA)
        XCTAssertFalse(registry.isOpen(notebook))
        XCTAssertTrue(registry.claim(notebook, by: windowB))
    }
}

final class AccountTextTests: XCTestCase {
    func testBackendMessagesAreTranslated() {
        XCTAssertEqual(AIClient.friendly("Error when creating user"), "这个邮箱可能已经注册过了，可以直接登录。")
        XCTAssertEqual(AIClient.friendly("Invalid token signature"), "登录已过期，请重新登录。")
        XCTAssertEqual(AIClient.friendly("其他错误"), "其他错误")
    }

    func testNetworkErrorsArePlainChinese() {
        XCTAssertEqual(AIClient.describe(URLError(.notConnectedToInternet)), "没有网络连接，请检查网络后再试。")
        XCTAssertEqual(AIClient.describe(URLError(.cannotFindHost)), "暂时连不上 note0 服务器，请稍后再试。")
    }
}

final class ServerDefaultTests: XCTestCase {
    func testSignInNeverNeedsATypedServer() {
        let saved = AIConfig.customBaseURL
        defer { AIConfig.customBaseURL = saved }

        AIConfig.customBaseURL = ""
        XCTAssertFalse(AIConfig.baseURL.isEmpty)
        XCTAssertEqual(AIConfig.baseURL, AIConfig.defaultBaseURL)

        // An old value saved by builds 23–24 is ignored.
        UserDefaults.standard.set("https://typo", forKey: "note0.ai.baseURL")
        XCTAssertEqual(AIConfig.baseURL, AIConfig.defaultBaseURL)
        UserDefaults.standard.removeObject(forKey: "note0.ai.baseURL")

        AIConfig.customBaseURL = "my-server.example.com"
        XCTAssertEqual(AIConfig.baseURL, "https://my-server.example.com")

        AIConfig.customBaseURL = AIConfig.defaultBaseURL
        XCTAssertEqual(AIConfig.customBaseURL, "")
    }
}

final class ShapeRecognizerTests: XCTestCase {
    /// Hand-drawn-ish points: dense along the corners with a small wobble.
    private func wobbly(_ corners: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        var i = 0
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(1, Int(ShapeRecognizer.distance(a, b) / 2))
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                i += 1
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + 1.5 * sin(CGFloat(i) * 0.15),
                                      y: a.y + (b.y - a.y) * t + 1.5 * cos(CGFloat(i) * 0.11)))
            }
        }
        return points
    }

    func testStraightLine() {
        guard case .line = ShapeRecognizer.recognize(wobbly([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 30)])) else {
            return XCTFail("expected a line")
        }
    }

    func testRectangleBecomesUpright() {
        let shape = ShapeRecognizer.recognize(wobbly([
            CGPoint(x: 50, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 120),
            CGPoint(x: 0, y: 120), CGPoint(x: 0, y: 0), CGPoint(x: 45, y: 2),
        ]))
        guard case .polygon(let corners) = shape else { return XCTFail("expected a rectangle") }
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(Set(corners.map { Int($0.y.rounded()) }).count, 2)
    }

    func testTriangle() {
        let shape = ShapeRecognizer.recognize(wobbly([
            CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 10), CGPoint(x: 60, y: 130), CGPoint(x: 3, y: 4),
        ]))
        guard case .polygon(let corners) = shape else { return XCTFail("expected a triangle") }
        XCTAssertEqual(corners.count, 3)
    }

    func testCircle() {
        let ring = (0...60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * 2 * .pi * 1.03
            return CGPoint(x: 100 + 80 * cos(t), y: 100 + 80 * sin(t))
        }
        guard case .ellipse(_, let rx, let ry, _) = ShapeRecognizer.recognize(wobbly(ring)) else {
            return XCTFail("expected a circle")
        }
        XCTAssertEqual(rx, ry, accuracy: 0.01)
        XCTAssertEqual(rx, 80, accuracy: 6)
    }

    private func regularPolygon(_ sides: Int) -> [CGPoint] {
        let corners = (0..<sides).map { k -> CGPoint in
            let t = 0.3 + 2 * CGFloat.pi * CGFloat(k) / CGFloat(sides)
            return CGPoint(x: 100 + 80 * cos(t), y: 100 + 80 * sin(t))
        }
        // Start mid-edge, like a hand would.
        let start = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        return [start] + corners.dropFirst() + [corners[0], CGPoint(x: start.x + 2, y: start.y + 1)]
    }

    func testPentagonAndHexagon() {
        for sides in [5, 6] {
            guard case .polygon(let corners) = ShapeRecognizer.recognize(wobbly(regularPolygon(sides))) else {
                return XCTFail("expected a polygon with \(sides) corners")
            }
            XCTAssertEqual(corners.count, sides)
        }
    }

    func testArrow() {
        let drawn = wobbly([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 40), CGPoint(x: 170, y: 15),
                            CGPoint(x: 200, y: 40), CGPoint(x: 175, y: 65)])
        guard case .arrow(let from, let to, _) = ShapeRecognizer.recognize(drawn) else {
            return XCTFail("expected an arrow")
        }
        XCTAssertLessThan(ShapeRecognizer.distance(from, CGPoint(x: 0, y: 0)), 6)
        XCTAssertLessThan(ShapeRecognizer.distance(to, CGPoint(x: 200, y: 40)), 6)
    }

    func testAngleIsNotMistakenForArrow() {
        let drawn = wobbly([CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 120), CGPoint(x: 120, y: 0)])
        guard case .polyline = ShapeRecognizer.recognize(drawn) else { return XCTFail("expected a V") }
    }

    func testWavyHandwritingIsLeftAlone() {
        let wave = (0..<100).map { CGPoint(x: CGFloat($0) * 2, y: 10 * sin(CGFloat($0) / 3)) }
        XCTAssertNil(ShapeRecognizer.recognize(wobbly(wave)))
    }
}

final class InkToolsTests: XCTestCase {
    func testColorRoundTrip() {
        let color = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let hex = InkTools.hex(color)
        XCTAssertEqual(hex, "336699FF")
        XCTAssertEqual(InkTools.hex(InkTools.color(hex)!), hex)
        XCTAssertNil(InkTools.color("nope"))
    }
}

final class DirectAITests: XCTestCase {
    func testStreamEventsYieldContent() {
        XCTAssertEqual(AIPrompt.sseDeltaText(fromLine: #"data: {"choices":[{"delta":{"content":"你好"}}]}"#), "你好")
        XCTAssertNil(AIPrompt.sseDeltaText(fromLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(AIPrompt.sseDeltaText(fromLine: "data: [DONE]"))
        XCTAssertNil(AIPrompt.sseDeltaText(fromLine: ": keep-alive"))
    }

    func testChatURLIsBuiltFromBase() {
        XCTAssertEqual(AIEndpoint(baseURL: "https://api.openai.com/v1/", apiKey: "k", model: "m").chatURL?.absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(AIEndpoint(baseURL: "x.workers.dev/v1/chat/completions", apiKey: "k", model: "m").chatURL?.absoluteString,
                       "https://x.workers.dev/v1/chat/completions")
        XCTAssertFalse(AIEndpoint(baseURL: "", apiKey: "k", model: "m").isComplete)
    }

    func testDirectErrorsArePlainChinese() {
        let body = Data(#"{"error":{"message":"You exceeded your current quota, please check your plan and billing details."}}"#.utf8)
        XCTAssertEqual(AIClient.directErrorMessage(from: body, status: 429), "额度已用完或还没开通付费（429），请到服务商后台充值。")
        XCTAssertTrue(AIClient.directErrorMessage(from: Data(), status: 401).hasPrefix("API Key 被服务商拒绝（401）"))
    }
}

final class ChatPromptTests: XCTestCase {
    func testOnlyRecentScreenshotsAreResent() throws {
        let turns = (0..<5).flatMap { i in [
            AIPrompt.Turn(isUser: true, text: "问题\(i)", imageJPEG: Data([UInt8(i)])),
            AIPrompt.Turn(isUser: false, text: "回答\(i)", imageJPEG: nil),
        ] }
        let messages = AIPrompt.chatMessages(turns, maxImages: 2)
        XCTAssertEqual(messages.count, 11)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        let withImages = messages.filter { $0["content"] is [[String: Any]] }
        XCTAssertEqual(withImages.count, 2)
        XCTAssertEqual(messages[1]["content"] as? String, "问题0\n（附图见前文）")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        let last = try XCTUnwrap(messages[9]["content"] as? [[String: Any]])
        XCTAssertEqual(last[0]["text"] as? String, "问题4")
    }
}

final class APIKeyCleaningTests: XCTestCase {
    func testPastedKeyLosesInvisibleCharactersAndQuotes() {
        XCTAssertEqual(AIDirect.cleanedKey(" sk-abc123\u{200B}\n"), "sk-abc123")
        XCTAssertEqual(AIDirect.cleanedKey("“sk-abc123”"), "sk-abc123")
        XCTAssertEqual(AIDirect.cleanedKey("Bearer sk-abc1234567"), "sk-abc1234567")
        XCTAssertEqual(AIDirect.cleanedKey("sk-or-v1-xyz"), "sk-or-v1-xyz")
    }

    func testObviouslyWrongKeysAreCaught() {
        XCTAssertNotNil(AIDirect.keyProblem("me@example.com", provider: .openAI))
        XCTAssertNotNil(AIDirect.keyProblem("sk-123", provider: .openAI))
        XCTAssertNotNil(AIDirect.keyProblem("mypassword1234567890abc", provider: .openAI))
        XCTAssertNil(AIDirect.keyProblem("sk-proj-" + String(repeating: "a", count: 40), provider: .openAI))
        XCTAssertNil(AIDirect.keyProblem(String(repeating: "b", count: 32), provider: .custom))
    }

    func testUnauthorizedExplainsLikelyCause() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-abc***xyz."}}"#.utf8)
        let message = AIClient.directErrorMessage(from: body, status: 401)
        XCTAssertTrue(message.hasPrefix("API Key 不正确（401）"))
        XCTAssertTrue(message.contains("Incorrect API key provided"))
    }
}

final class LocalizationTests: XCTestCase {
    func testEnglishStringsAreBundled() throws {
        let path = try XCTUnwrap(Bundle(for: InkTools.self).path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertGreaterThan(table.count, 200)
        XCTAssertEqual(table["未命名笔记本"], "Untitled Notebook")
        XCTAssertEqual(table["已选 %lld 本"], "%lld selected")
    }

    func testTestsRunInSourceLanguage() {
        XCTAssertEqual(L("未命名笔记本"), "未命名笔记本")
        XCTAssertEqual(L("已选 \(3) 本"), "已选 3 本")
    }
}
