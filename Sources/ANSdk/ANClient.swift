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
/// Privacy model: the NSFW detector runs **fully on-device**. No image bytes
/// ever leave the device. After local inference, the SDK reports only the
/// resulting verdict (and minimal metadata) to the AntiNude backend so the
/// developer can see usage in the dashboard.
///
/// v0.3 ships NudeNet 320n bundled inside the SDK; the model file is also
/// addressable as `Bundle.module.url(forResource: "320n", withExtension:
/// "onnx")` if you want to manage it yourself. Init is throwing because
/// model load can fail (bundle corrupted, unknown ORT version).
public final class ANClient {

    private let apiKey: String
    private let baseURL: URL
    private let reportToServer: Bool
    private let session: URLSession
    private let detector: Detector
    private let modelVersion: String

    /// Designated initializer.
    /// - Parameter modelURL: path to a NudeNet 320n `.onnx`. Defaults to the
    ///   model bundled with the SDK. Pass an explicit URL when integrating a
    ///   hot-updated or alternative model.
    public init(
        apiKey: String,
        modelURL: URL? = nil,
        baseURL: URL = URL(string: "https://antinude.site")!,
        reportToServer: Bool = true,
        session: URLSession = .shared
    ) throws {
        let resolvedModelURL: URL
        if let modelURL {
            resolvedModelURL = modelURL
        } else if let bundled = Bundle.module.url(forResource: "320n", withExtension: "onnx") {
            resolvedModelURL = bundled
        } else {
            throw ANError(
                code: .modelLoadFailed,
                message: "SDK bundle is missing 320n.onnx; pass an explicit modelURL"
            )
        }
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.reportToServer = reportToServer
        self.session = session
        self.detector = try Detector(modelURL: resolvedModelURL)
        self.modelVersion = Detector.modelVersion
    }

    /// Scan an image on device and (by default) report the verdict.
    public func scanImage(_ data: Data) async throws -> ScanResult {
        guard !data.isEmpty else {
            throw ANError(code: .emptyImage, message: "empty image")
        }

        let started = Date()
        let detections = try detector.detect(imageData: data)
        let (verdict, top) = Detector.computeVerdict(detections: detections)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let result = ScanResult(
            verdict: verdict,
            topCategory: top?.category,
            topScore: top?.score,
            latencyMs: latencyMs,
            modelVersion: modelVersion,
            requestId: nil,
            detections: detections
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
