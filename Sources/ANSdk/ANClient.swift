import Foundation

public struct ScanResult: Sendable, Equatable {
    public let verdict: String
    public let topCategory: String?
    public let topScore: Double?
    public let latencyMs: Int
    public let modelVersion: String
    public let requestId: String?
}

public struct ANError: Error, CustomStringConvertible {
    public let statusCode: Int
    public let message: String
    public var description: String { "AN SDK error \(statusCode): \(message)" }
}

/// AntiNude SDK client.
///
/// Privacy model: the NSFW classifier runs **fully on-device**. No image bytes
/// ever leave the device. After local inference, the SDK reports only the
/// resulting verdict (and minimal metadata) to the AntiNude backend so the
/// developer can see usage in the dashboard.
///
/// v0.2.x ships a mock on-device model — verdicts are randomized. A real
/// CoreML model will replace `runLocalModel` in a future version without
/// changing the public API.
public final class ANClient {

    private let apiKey: String
    private let baseURL: URL
    private let reportToServer: Bool
    private let session: URLSession
    private let modelVersion = "mock-v0.2.0"

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://antinude.site")!,
        reportToServer: Bool = true,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.reportToServer = reportToServer
        self.session = session
    }

    /// Scan an image on device and (by default) report the verdict.
    public func scanImage(_ data: Data) async throws -> ScanResult {
        guard !data.isEmpty else {
            throw ANError(statusCode: 0, message: "empty image")
        }

        let started = Date()
        let local = runLocalModel(data)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let result = ScanResult(
            verdict: local.verdict,
            topCategory: local.topCategory,
            topScore: local.topScore,
            latencyMs: latencyMs,
            modelVersion: modelVersion,
            requestId: nil
        )

        guard reportToServer else { return result }

        let requestId = try? await reportVerdict(result)
        return ScanResult(
            verdict: result.verdict,
            topCategory: result.topCategory,
            topScore: result.topScore,
            latencyMs: result.latencyMs,
            modelVersion: result.modelVersion,
            requestId: requestId
        )
    }

    // MARK: - On-device inference (mock)

    private struct LocalOutput {
        let verdict: String
        let topCategory: String?
        let topScore: Double?
    }

    private func runLocalModel(_ data: Data) -> LocalOutput {
        // Pretend the model takes 30–80 ms to run.
        Thread.sleep(forTimeInterval: Double.random(in: 0.03...0.08))
        let unsafe = Double.random(in: 0...1) < 0.15
        let unsafeCats = ["nudity", "suggestive", "sexual_violence", "gore"]
        let safeCats = ["nudity", "suggestive"]
        let category = (unsafe ? unsafeCats : safeCats).randomElement()
        let score = unsafe
            ? 0.70 + Double.random(in: 0...0.30)
            : Double.random(in: 0...0.30)
        return LocalOutput(
            verdict: unsafe ? "unsafe" : "safe",
            topCategory: category,
            topScore: (score * 10000).rounded() / 10000
        )
    }

    // MARK: - Telemetry (verdict only, no bytes)

    private func reportVerdict(_ r: ScanResult) async throws -> String? {
        var payload: [String: Any] = [
            "verdict": r.verdict,
            "latency_ms": r.latencyMs,
            "model_version": r.modelVersion,
        ]
        if let c = r.topCategory { payload["top_category"] = c }
        if let s = r.topScore { payload["top_score"] = s }
        let body = try JSONSerialization.data(withJSONObject: payload)

        var req = URLRequest(url: baseURL.appendingPathComponent("/api/v1/scan"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("an-sdk-ios/0.2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ANError(statusCode: 0, message: "no_http_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ANError(statusCode: http.statusCode, message: msg)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["request_id"] as? String
    }
}
