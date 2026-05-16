import Foundation

/// A single object the on-device model detected in the image.
///
/// `bbox` is normalized to `[0, 1]` in `[x, y, width, height]` form relative to
/// the original image dimensions. It stays on-device — only `category` and
/// `score` are reported to the AntiNude backend.
public struct Detection: Sendable, Equatable {
    public let category: String
    public let score: Double
    public let bbox: [Double]?

    public init(category: String, score: Double, bbox: [Double]? = nil) {
        self.category = category
        self.score = score
        self.bbox = bbox
    }
}

public struct ScanResult: Sendable, Equatable {
    public let verdict: String
    public let topCategory: String?
    public let topScore: Double?
    public let latencyMs: Int
    public let modelVersion: String
    public let requestId: String?
    /// Detailed per-object detections from the on-device model. `nil` for
    /// classifier-only models; non-empty array for detector models such as
    /// NudeNet.
    public let detections: [Detection]?
}

/// Stable error codes returned by the SDK.
///
/// Server-side codes mirror the `error` field in `/api/v1/scan` responses.
/// Local codes (those starting with `local_*` semantics) are raised before
/// any network call — e.g. when the supplied image bytes are invalid.
///
/// Adding a new case is non-breaking; renaming or removing one is breaking.
/// `unknown` is the fallback for codes a newer server may introduce.
public enum ANErrorCode: String, Sendable, Equatable {
    // --- Server-reported ---
    case unauthorized
    case keyRevoked = "key_revoked"
    case featureNotAllowed = "feature_not_allowed"
    case quotaExceeded = "quota_exceeded"
    case rateLimited = "rate_limited"
    case invalidBody = "invalid_body"
    case expectedApplicationJson = "expected_application_json"
    case invalidVerdict = "invalid_verdict"
    case invalidDetections = "invalid_detections"
    case serviceUnavailable = "service_unavailable"
    case internalError = "internal_error"

    // --- Local-only (no network involved) ---
    case emptyImage = "empty_image"
    case unsupportedFormat = "unsupported_format"
    case imageTooLarge = "image_too_large"
    case modelLoadFailed = "model_load_failed"
    case inferenceFailed = "inference_failed"
    case network = "network"

    case unknown = "unknown"

    init(rawOrUnknown: String?) {
        self = ANErrorCode(rawValue: rawOrUnknown ?? "") ?? .unknown
    }
}

public struct ANError: Error, CustomStringConvertible, Sendable {
    public let code: ANErrorCode
    /// HTTP status code if the error came from the server, `0` for local errors.
    public let statusCode: Int
    public let message: String

    public init(code: ANErrorCode, statusCode: Int = 0, message: String) {
        self.code = code
        self.statusCode = statusCode
        self.message = message
    }

    /// `true` if the caller can reasonably retry the same request later.
    public var isRetryable: Bool {
        switch code {
        case .rateLimited, .serviceUnavailable, .network: return true
        default: return false
        }
    }

    public var description: String {
        statusCode == 0
            ? "AN SDK error \(code.rawValue): \(message)"
            : "AN SDK error \(code.rawValue) (HTTP \(statusCode)): \(message)"
    }
}

/// AntiNude SDK client.
///
/// Privacy model: the NSFW classifier runs **fully on-device**. No image bytes
/// ever leave the device. After local inference, the SDK reports only the
/// resulting verdict (and minimal metadata) to the AntiNude backend so the
/// developer can see usage in the dashboard.
///
/// v0.3.x ships a mock on-device model — verdicts and detections are
/// randomized. A real CoreML/ONNX model will replace `runLocalModel` in a
/// future version without changing the public API.
public final class ANClient {

    private let apiKey: String
    private let baseURL: URL
    private let reportToServer: Bool
    private let session: URLSession
    private let modelVersion = "mock-v0.3.0"

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
            throw ANError(code: .emptyImage, message: "empty image")
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
            requestId: nil,
            detections: local.detections
        )

        guard reportToServer else { return result }

        let requestId = try? await reportVerdict(result)
        return ScanResult(
            verdict: result.verdict,
            topCategory: result.topCategory,
            topScore: result.topScore,
            latencyMs: result.latencyMs,
            modelVersion: result.modelVersion,
            requestId: requestId,
            detections: result.detections
        )
    }

    // MARK: - On-device inference (mock)

    private struct LocalOutput {
        let verdict: String
        let topCategory: String?
        let topScore: Double?
        let detections: [Detection]?
    }

    private static let mockUnsafeClasses = [
        "FEMALE_BREAST_EXPOSED",
        "FEMALE_GENITALIA_EXPOSED",
        "MALE_GENITALIA_EXPOSED",
        "BUTTOCKS_EXPOSED",
    ]
    private static let mockSafeClasses = [
        "FEMALE_BREAST_COVERED",
        "FACE_FEMALE",
        "FACE_MALE",
        "FEET_EXPOSED",
    ]

    private func runLocalModel(_ data: Data) -> LocalOutput {
        // Pretend the model takes 30–80 ms to run.
        Thread.sleep(forTimeInterval: Double.random(in: 0.03...0.08))
        let unsafe = Double.random(in: 0...1) < 0.15

        let count = Int.random(in: 1...3)
        let pool = unsafe ? Self.mockUnsafeClasses : Self.mockSafeClasses
        var detections: [Detection] = []
        for _ in 0..<count {
            let cat = pool.randomElement()!
            let score = unsafe
                ? 0.70 + Double.random(in: 0...0.30)
                : Double.random(in: 0...0.30)
            let x = Double.random(in: 0...0.7)
            let y = Double.random(in: 0...0.7)
            let w = Double.random(in: 0.1...min(0.3, 1 - x))
            let h = Double.random(in: 0.1...min(0.3, 1 - y))
            detections.append(Detection(
                category: cat,
                score: (score * 10000).rounded() / 10000,
                bbox: [x, y, w, h].map { ($0 * 10000).rounded() / 10000 }
            ))
        }
        let top = detections.max(by: { $0.score < $1.score })

        return LocalOutput(
            verdict: unsafe ? "unsafe" : "safe",
            topCategory: top?.category,
            topScore: top?.score,
            detections: detections
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
        if let ds = r.detections, !ds.isEmpty {
            // bbox stays on-device; telemetry only ships category + score.
            payload["detections"] = ds.map { ["category": $0.category, "score": $0.score] }
        }
        let body = try JSONSerialization.data(withJSONObject: payload)

        var req = URLRequest(url: baseURL.appendingPathComponent("/api/v1/scan"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("an-sdk-ios/0.3.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ANError(code: .network, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ANError(code: .network, message: "no_http_response")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let serverCode = json?["error"] as? String
            let serverMsg = (json?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw ANError(
                code: ANErrorCode(rawOrUnknown: serverCode),
                statusCode: http.statusCode,
                message: serverMsg
            )
        }
        return json?["request_id"] as? String
    }
}
