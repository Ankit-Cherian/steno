import Foundation

/// Removes temporary files a previous run of Steno left behind, for example
/// after a crash or a force quit. Only regular files named exactly
/// `<prefix><UUID>.<extension>`, and older than `minimumAge`, are removed.
enum StaleTemporaryFileSweep {
    static func remove(
        in directory: URL,
        prefix: String,
        extensions: Set<String>,
        olderThan minimumAge: TimeInterval,
        now: Date
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var removed: [URL] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix),
                  extensions.contains(url.pathExtension),
                  UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > minimumAge
            else {
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url)
            }
        }
        return removed
    }
}
