import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import OnnxRuntimeBindings

// MARK: - Public detection types live in ANClient.swift.

/// On-device NudeNet detector. Owns the ORT session, runs preprocessing /
/// inference / postprocessing exactly as specified in
/// `an-model/PREPROCESSING.md`. Behavior must match `an-model/inference.py`
/// within the golden tolerance there.
///
/// Single instance is safe to reuse across scans. Sessions are not safe to
/// use from multiple threads simultaneously — call `detect` serially.
final class Detector {

    static let modelVersion = "nudenet-320n-v3.4"
    static let inputSize = 320

    /// Class names in the model's class-index order. Do NOT reorder.
    static let classNames: [String] = [
        "FEMALE_GENITALIA_COVERED",
        "FACE_FEMALE",
        "BUTTOCKS_EXPOSED",
        "FEMALE_BREAST_EXPOSED",
        "FEMALE_GENITALIA_EXPOSED",
        "MALE_BREAST_EXPOSED",
        "ANUS_EXPOSED",
        "FEET_EXPOSED",
        "BELLY_COVERED",
        "FEET_COVERED",
        "ARMPITS_COVERED",
        "ARMPITS_EXPOSED",
        "FACE_MALE",
        "BELLY_EXPOSED",
        "MALE_GENITALIA_EXPOSED",
        "ANUS_COVERED",
        "FEMALE_BREAST_COVERED",
        "BUTTOCKS_COVERED",
    ]

    // Thresholds — keep in sync with an-model/inference.py.
    static let preNMSConfidence: Float = 0.20
    static let nmsScoreThreshold: Float = 0.25
    static let nmsIoUThreshold: Float = 0.45
    static let unsafeScoreThreshold: Double = 0.50
    static let unsafeClasses: Set<String> = [
        "FEMALE_BREAST_EXPOSED",
        "FEMALE_GENITALIA_EXPOSED",
        "MALE_GENITALIA_EXPOSED",
        "BUTTOCKS_EXPOSED",
        "ANUS_EXPOSED",
    ]

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String

    init(modelURL: URL) throws {
        do {
            env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            session = try ORTSession(
                env: env,
                modelPath: modelURL.path,
                sessionOptions: nil
            )
            let names = try session.inputNames()
            guard let first = names.first else {
                throw ANError(code: .modelLoadFailed, message: "model has no inputs")
            }
            inputName = first
        } catch let e as ANError {
            throw e
        } catch {
            throw ANError(code: .modelLoadFailed, message: error.localizedDescription)
        }
    }

    // MARK: - Public entry point

    /// Decode `data`, run the full pipeline, return detections in bbox
    /// coordinates normalized to `[0, 1]` of the original image.
    func detect(imageData data: Data) throws -> [Detection] {
        guard let cgImage = makeCGImage(from: data) else {
            throw ANError(code: .unsupportedFormat, message: "could not decode image")
        }
        let origW = cgImage.width
        let origH = cgImage.height
        if origW == 0 || origH == 0 {
            throw ANError(code: .unsupportedFormat, message: "image has zero dimensions")
        }

        let (tensorData, s) = try preprocess(cgImage: cgImage)

        let inputShape: [NSNumber] = [1, 3, NSNumber(value: Self.inputSize), NSNumber(value: Self.inputSize)]
        let inputValue: ORTValue
        let outputs: [String: ORTValue]
        do {
            inputValue = try ORTValue(
                tensorData: NSMutableData(data: tensorData),
                elementType: ORTTensorElementDataType.float,
                shape: inputShape
            )
            outputs = try session.run(
                withInputs: [inputName: inputValue],
                outputNames: ["output0"],
                runOptions: nil
            )
        } catch {
            throw ANError(code: .inferenceFailed, message: error.localizedDescription)
        }
        guard let outValue = outputs["output0"] else {
            throw ANError(code: .inferenceFailed, message: "model produced no output0")
        }

        let raw: Data
        let shape: [Int]
        do {
            raw = try outValue.tensorData() as Data
            shape = (try outValue.tensorTypeAndShapeInfo().shape).map { $0.intValue }
        } catch {
            throw ANError(code: .inferenceFailed, message: error.localizedDescription)
        }
        // Expect [1, 22, N].
        guard shape.count == 3, shape[0] == 1, shape[1] == 22 else {
            throw ANError(code: .inferenceFailed, message: "unexpected output shape \(shape)")
        }
        let anchors = shape[2]

        return postprocess(
            raw: raw,
            anchors: anchors,
            origW: origW,
            origH: origH,
            s: s
        )
    }

    // MARK: - Preprocessing

    /// Letterbox-pad to square (right/bottom black), resize to 320, normalize
    /// to [0,1], CHW float32 RGB. Returns the tensor blob and `S = max(W, H)`
    /// for postprocessing scale-back.
    private func preprocess(cgImage: CGImage) throws -> (Data, Int) {
        let origW = cgImage.width
        let origH = cgImage.height
        let s = max(origW, origH)
        let size = Self.inputSize
        let scale = CGFloat(size) / CGFloat(s)

        // Allocate a `size × size` RGBA8 context filled with black. Drawing
        // straight into the final size (no intermediate `S × S` step) is
        // equivalent and avoids a large allocation for big inputs.
        let bytesPerRow = size * 4
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ANError(code: .inferenceFailed, message: "failed to allocate CGContext")
        }
        // Fill black (default for noneSkipLast is undefined — be explicit).
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // CG coords are bottom-left. We want the image at the TOP-LEFT of the
        // canvas (right/bottom padding in image-space). So in CG terms place
        // it at y = size - scaledH.
        let scaledW = CGFloat(origW) * scale
        let scaledH = CGFloat(origH) * scale
        // `.medium` is bilinear on Core Graphics, matching `cv2.dnn.blobFromImage`
        // which uses bilinear interpolation. `.high` is Lanczos and shifts
        // model scores enough to diverge from the Python golden.
        ctx.interpolationQuality = .medium
        ctx.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: CGFloat(size) - scaledH,
                width: scaledW,
                height: scaledH
            )
        )

        guard let pixels = ctx.data else {
            throw ANError(code: .inferenceFailed, message: "CGContext returned no pixel data")
        }
        let pixelBuf = pixels.assumingMemoryBound(to: UInt8.self)

        // Convert HWC RGBA u8 → CHW RGB float32 normalized to [0,1].
        // BUT: CG draws with origin bottom-left, so row 0 in the buffer is the
        // BOTTOM of the image. The model expects top-down rows. We must flip
        // vertically while reading.
        let plane = size * size
        var tensor = [Float](repeating: 0, count: 3 * plane)
        let inv: Float = 1.0 / 255.0
        for y in 0..<size {
            let srcRow = (size - 1 - y) * bytesPerRow  // vertical flip
            let dstRow = y * size
            for x in 0..<size {
                let p = srcRow + x * 4
                let dst = dstRow + x
                tensor[0 * plane + dst] = Float(pixelBuf[p + 0]) * inv  // R
                tensor[1 * plane + dst] = Float(pixelBuf[p + 1]) * inv  // G
                tensor[2 * plane + dst] = Float(pixelBuf[p + 2]) * inv  // B
            }
        }

        let data = tensor.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        return (data, s)
    }

    // MARK: - Postprocessing

    /// Decode the `[1, 22, N]` output, filter, NMS, scale to original image
    /// coordinates, normalize bbox to `[0, 1]`.
    private func postprocess(
        raw: Data,
        anchors: Int,
        origW: Int,
        origH: Int,
        s: Int
    ) -> [Detection] {
        let scale = Float(s) / Float(Self.inputSize)
        let fW = Float(origW)
        let fH = Float(origH)

        // Memory layout: row-major [22, N], read as raw little-endian float32.
        // out[c, i] corresponds to channel c, anchor i.
        var boxes: [[Float]] = []        // [x, y, w, h] in pixel coords
        var scores: [Float] = []
        var classIds: [Int] = []
        boxes.reserveCapacity(anchors / 4)
        scores.reserveCapacity(anchors / 4)
        classIds.reserveCapacity(anchors / 4)

        raw.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let floats = ptr.bindMemory(to: Float.self)
            // helper to access out[c, i]
            @inline(__always) func at(_ c: Int, _ i: Int) -> Float {
                return floats[c * anchors + i]
            }
            for i in 0..<anchors {
                var maxScore: Float = 0
                var maxId: Int = 0
                for c in 0..<18 {
                    let v = at(4 + c, i)
                    if v > maxScore {
                        maxScore = v
                        maxId = c
                    }
                }
                if maxScore < Self.preNMSConfidence { continue }
                let cx = at(0, i)
                let cy = at(1, i)
                let w = at(2, i)
                let h = at(3, i)
                var x = (cx - w / 2) * scale
                var y = (cy - h / 2) * scale
                var bw = w * scale
                var bh = h * scale
                if x < 0 { x = 0 }
                if y < 0 { y = 0 }
                if x > fW { x = fW }
                if y > fH { y = fH }
                if bw > fW - x { bw = fW - x }
                if bh > fH - y { bh = fH - y }
                boxes.append([x, y, bw, bh])
                scores.append(maxScore)
                classIds.append(maxId)
            }
        }

        let kept = nms(
            boxes: boxes,
            scores: scores,
            scoreThreshold: Self.nmsScoreThreshold,
            iouThreshold: Self.nmsIoUThreshold
        )

        var detections: [Detection] = []
        detections.reserveCapacity(kept.count)
        for idx in kept {
            let b = boxes[idx]
            // Normalize bbox to [0, 1] of original image.
            let nx = Double(b[0]) / Double(origW)
            let ny = Double(b[1]) / Double(origH)
            let nw = Double(b[2]) / Double(origW)
            let nh = Double(b[3]) / Double(origH)
            detections.append(
                Detection(
                    category: Self.classNames[classIds[idx]],
                    score: round4(Double(scores[idx])),
                    bbox: [round4(nx), round4(ny), round4(nw), round4(nh)]
                )
            )
        }
        detections.sort { $0.score > $1.score }
        return detections
    }

    // MARK: - NMS

    /// Greedy class-agnostic NMS. Matches `cv2.dnn.NMSBoxes(scoreThreshold,
    /// iouThreshold)` behavior closely enough for the golden tolerance.
    private func nms(
        boxes: [[Float]],
        scores: [Float],
        scoreThreshold: Float,
        iouThreshold: Float
    ) -> [Int] {
        let eligible = scores.indices.filter { scores[$0] >= scoreThreshold }
        let order = eligible.sorted { scores[$0] > scores[$1] }
        var kept: [Int] = []
        var suppressed = Set<Int>()
        for i in order {
            if suppressed.contains(i) { continue }
            kept.append(i)
            for j in order where j != i && !suppressed.contains(j) {
                if iou(boxes[i], boxes[j]) > iouThreshold {
                    suppressed.insert(j)
                }
            }
        }
        return kept
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let ax2 = a[0] + a[2], ay2 = a[1] + a[3]
        let bx2 = b[0] + b[2], by2 = b[1] + b[3]
        let ix1 = max(a[0], b[0]), iy1 = max(a[1], b[1])
        let ix2 = min(ax2, bx2), iy2 = min(ay2, by2)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        let union = a[2] * a[3] + b[2] * b[3] - inter
        return union > 0 ? inter / union : 0
    }

    private func round4(_ v: Double) -> Double {
        return (v * 10000).rounded() / 10000
    }

    // MARK: - Image decode

    /// Decode arbitrary image bytes (JPEG/PNG/HEIC/WebP — anything ImageIO
    /// supports on the current OS) to a CGImage.
    private func makeCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Verdict policy (kept here so callers stay decoupled)

    /// Apply verdict policy. Mirrors `compute_verdict` in inference.py.
    static func computeVerdict(detections: [Detection]) -> (verdict: String, top: Detection?) {
        let unsafe = detections.filter {
            unsafeClasses.contains($0.category) && $0.score >= unsafeScoreThreshold
        }
        guard let top = unsafe.max(by: { $0.score < $1.score }) else {
            return ("safe", detections.max(by: { $0.score < $1.score }))
        }
        return ("unsafe", top)
    }
}
