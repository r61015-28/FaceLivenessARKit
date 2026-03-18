import Foundation

/// 自動同步本地 CSV 資料到 Mac server
/// - 成功傳送後清空本地 CSV（只留 header）
/// - 失敗時不動本地資料，下次再補傳
/// - Server 端用 timestamp 去重，不會重複
final class DataSyncManager {

    static let shared = DataSyncManager()

    /// 與 LivenessAPIClient 共用同一個 baseURL
    private var baseURL: String {
        // 讀取 LivenessAPIClient 的 baseURL（Tailscale IP）
        return "http://100.79.179.62:8002"
    }

    /// 同步指定模式的 CSV 到 server，成功後清空本地
    func sync(mode: String) {
        let filename: String
        switch mode {
        case "perspective": filename = "perspective_log.csv"
        case "arkit":       filename = "liveness_log.csv"
        default: return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent(filename)

        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return }  // 至少要有 header + 1 筆資料

        let header = lines[0]
        let dataRows = Array(lines.dropFirst())

        guard !dataRows.isEmpty else { return }

        // 組 JSON payload
        let payload: [String: Any] = [
            "mode": mode,
            "header": header,
            "rows": dataRows
        ]

        guard let url = URL(string: "\(baseURL)/api/collect") else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accepted = json["accepted"] as? Int,
                  let total = json["total"] as? Int
            else {
                // 同步失敗，資料留在本地，下次再試
                return
            }

            // 同步成功 → 清空本地 CSV，只留 header
            let headerLine = header + "\n"
            try? headerLine.write(to: logFile, atomically: true, encoding: .utf8)

            print("[DataSync] mode=\(mode) sent=\(dataRows.count) accepted=\(accepted) server_total=\(total)")
        }.resume()
    }

    /// 同步所有模式
    func syncAll() {
        sync(mode: "perspective")
        sync(mode: "arkit")
    }
}
