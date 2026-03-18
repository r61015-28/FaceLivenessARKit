import Foundation
import Combine

/// 自動同步本地 CSV 資料到 Mac server
/// - 成功傳送後清空本地 CSV（只留 header）
/// - 失敗時不動本地資料，下次再補傳
/// - Server 端用 timestamp 去重，不會重複
/// - 分批上傳，回報即時進度
@MainActor
final class DataSyncManager: ObservableObject {

    static let shared = DataSyncManager()

    // MARK: - Published 狀態（UI 用）

    @Published var isSyncing = false
    @Published var totalRows = 0
    @Published var sentRows = 0
    @Published var syncResult: SyncResult?

    enum SyncResult {
        case success(accepted: Int)
        case failure(String)
    }

    var progress: Double {
        guard totalRows > 0 else { return 0 }
        return Double(sentRows) / Double(totalRows)
    }

    /// 與 LivenessAPIClient 共用同一個 baseURL
    private var baseURL: String {
        return "http://100.79.179.62:8002"
    }

    private let batchSize = 10

    // MARK: - 同步（帶進度）

    func sync(mode: String) {
        guard !isSyncing else { return }

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
        guard lines.count >= 2 else { return }

        let header = lines[0]
        let dataRows = Array(lines.dropFirst())
        guard !dataRows.isEmpty else { return }

        // 開始同步
        isSyncing = true
        totalRows = dataRows.count
        sentRows = 0
        syncResult = nil

        Task {
            await uploadBatches(mode: mode, header: header, dataRows: dataRows, logFile: logFile)
        }
    }

    private func uploadBatches(mode: String, header: String, dataRows: [String], logFile: URL) async {
        guard let url = URL(string: "\(baseURL)/api/collect") else {
            syncResult = .failure("URL 錯誤")
            isSyncing = false
            return
        }

        // 分批上傳
        var offset = 0
        var totalAccepted = 0

        while offset < dataRows.count {
            let end = min(offset + batchSize, dataRows.count)
            let batch = Array(dataRows[offset..<end])

            let payload: [String: Any] = [
                "mode": mode,
                "header": header,
                "rows": batch
            ]

            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                syncResult = .failure("資料編碼錯誤")
                isSyncing = false
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accepted = json["accepted"] as? Int
                else {
                    syncResult = .failure("Server 回應異常")
                    isSyncing = false
                    return
                }

                totalAccepted += accepted
                offset = end
                sentRows = offset

            } catch {
                // 網路失敗，資料留在本地
                syncResult = .failure("連線失敗")
                isSyncing = false
                return
            }
        }

        // 全部上傳成功 → 清空本地 CSV
        let headerLine = header + "\n"
        try? headerLine.write(to: logFile, atomically: true, encoding: .utf8)

        syncResult = .success(accepted: totalAccepted)
        print("[DataSync] mode=\(mode) sent=\(dataRows.count) accepted=\(totalAccepted)")

        // 1.5 秒後自動關閉 overlay
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        isSyncing = false
        syncResult = nil
    }

    /// 靜默同步（App 啟動時用，不顯示 UI）
    func syncAllSilently() {
        let modes = ["perspective", "arkit"]
        for mode in modes {
            silentSync(mode: mode)
        }
    }

    /// 靜默模式：不更新 UI 狀態，背景上傳
    private func silentSync(mode: String) {
        let filename = mode == "perspective" ? "perspective_log.csv" : "liveness_log.csv"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent(filename)

        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return }

        let header = lines[0]
        let dataRows = Array(lines.dropFirst())
        guard !dataRows.isEmpty else { return }

        let payload: [String: Any] = [
            "mode": mode,
            "header": header,
            "rows": dataRows
        ]

        guard let url = URL(string: "\(baseURL)/api/collect"),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return }

            let headerLine = header + "\n"
            try? headerLine.write(to: logFile, atomically: true, encoding: .utf8)
            print("[DataSync] silent mode=\(mode) sent=\(dataRows.count)")
        }.resume()
    }
}
