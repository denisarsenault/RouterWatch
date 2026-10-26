//
//  ExportService.swift
//  RouterWatch
//

import Foundation

/// Turns the log into something that can be handed to an ISP.
enum ExportService {

    static func csv(from results: [ProbeResult], networkName: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines = [
            "timestamp,network,endpoint,interface,download_mbps,upload_mbps,latency_ms,jitter_ms,bytes_down,bytes_up,duration_s,error_kind,error_detail,note"
        ]

        for result in results {
            let fields: [String] = [
                formatter.string(from: result.timestamp),
                networkName,
                result.endpointName,
                result.interface.title,
                result.downloadMbps.map { String(format: "%.2f", $0) } ?? "",
                result.uploadMbps.map { String(format: "%.2f", $0) } ?? "",
                result.latencyMs.map { String(format: "%.1f", $0) } ?? "",
                result.jitterMs.map { String(format: "%.1f", $0) } ?? "",
                String(result.bytesDownloaded),
                String(result.bytesUploaded),
                String(format: "%.2f", result.duration),
                result.errorKind?.title ?? "",
                result.errorDetail ?? "",
                result.note ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    static func json(from results: [ProbeResult]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(results)
    }

    /// Quotes a CSV field only when it needs it, doubling any embedded quotes.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func suggestedFilename(networkName: String, extension ext: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        // Keep names readable but safe on every filesystem a CSV might land on.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let slug = networkName.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return "RouterWatch-\(slug.isEmpty ? "network" : slug)-\(formatter.string(from: now)).\(ext)"
    }

    /// Writes an export into the temporary directory and returns its URL, ready
    /// for a share sheet or a save panel.
    static func writeTemporaryFile(named name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }
}
