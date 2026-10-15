import Foundation

enum ImportSources {
    static let extensions: Set<String> = ["cer", "p12", "p8", "mobileprovision", "provisionprofile"]
    static func collect(_ roots: [URL]) throws -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        var visited = 0
        func add(_ url: URL) throws {
            guard extensions.contains(url.pathExtension.lowercased()), seen.insert(url.standardizedFileURL.path).inserted else { return }
            files.append(url)
            guard files.count <= 200 else { throw ImportSourceError.limit }
        }
        for root in roots {
            let value = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard value.isSymbolicLink != true else { throw ImportSourceError.symlink }
            if value.isDirectory == true {
                var failure: Error?
                guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else { throw ValidationError.invalidFile }
                for case let child as URL in walker {
                    visited += 1
                    guard visited <= 10000 else { throw ImportSourceError.limit }
                    let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    if info.isSymbolicLink == true { walker.skipDescendants(); continue }
                    if info.isRegularFile == true { try add(child) }
                }
                if let failure { throw failure }
            } else if value.isRegularFile == true { try add(root) }
        }
        guard !files.isEmpty else { throw ImportSourceError.empty }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

enum ImportSourceError: LocalizedError {
    case limit, symlink, empty
    var errorDescription: String? {
        switch self {
        case .limit: "一度に200ファイル・フォルダ内の探索は10,000項目までです。対象を分けてください。"
        case .symlink: "シンボリックリンクは取り込めません。元のファイルまたはフォルダを選んでください。"
        case .empty: "対応するファイルが見つかりませんでした。"
        }
    }
}
