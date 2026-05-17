import ANSdk
import Foundation

@main
struct GoldenCheck {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: golden-check <images-dir> <golden.json>\n".utf8))
            exit(2)
        }
        let imagesDir = URL(fileURLWithPath: args[1])
        let goldenURL = URL(fileURLWithPath: args[2])

        let goldenData = try! Data(contentsOf: goldenURL)
        let golden = try! JSONSerialization.jsonObject(with: goldenData) as! [String: Any]
        let items = golden["items"] as! [[String: Any]]
        let goldenByName = Dictionary(uniqueKeysWithValues: items.map { ($0["image"] as! String, $0) })

        let client: ANClient
        do {
            client = try ANClient(apiKey: "test", reportToServer: false)
        } catch {
            print("init failed: \(error)")
            exit(1)
        }

        var mismatches = 0
        let files = (try! FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil))
            .filter { ["jpg","jpeg","png","webp","bmp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in files {
            let data = try! Data(contentsOf: url)
            let result: ScanResult
            do {
                result = try await client.scanImage(data)
            } catch {
                print("  \(url.lastPathComponent): SCAN ERROR \(error)")
                mismatches += 1
                continue
            }
            let expected = goldenByName[url.lastPathComponent]
            let expectedVerdict = (expected?["verdict"] as? String) ?? "?"
            let match = expectedVerdict == result.verdict ? "OK " : "FAIL"
            if expectedVerdict != result.verdict { mismatches += 1 }
            let top = result.topCategory.map { "[\($0) \(String(format: "%.2f", result.topScore ?? 0))]" } ?? ""
            print("  \(match) \(url.lastPathComponent): ios=\(result.verdict) golden=\(expectedVerdict)  (\(result.detections?.count ?? 0) det) \(top)  \(result.latencyMs)ms")
        }
        print("\n\(mismatches == 0 ? "ALL PASS" : "\(mismatches) MISMATCH(ES)")")
        exit(mismatches == 0 ? 0 : 1)
    }
}
