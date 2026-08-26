import Foundation

/// Reads the last few kilobytes of an agent transcript.
///
/// Transcripts grow to megabytes while the panel refreshes every second, so
/// nothing here may read a whole file, and the caller is expected to skip the
/// read entirely when `stamp(of:)` is unchanged — see `ContextUsageService`.
enum TranscriptTailReader {
    /// Matches the registry reader's own ceiling. A token-usage record is a few
    /// hundred bytes, so this covers many turns' worth of history.
    static let maximumTailBytes = 64 * 1024

    /// Cheap identity for "has this file changed". Size alone is not enough:
    /// an edit that replaces a line leaves it identical.
    struct Stamp: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

    static func stamp(of url: URL) -> Stamp? {
        // Regular files only. The registry reader learned this the hard way:
        // a fifo in the scanned directory blocks the reader forever, and this
        // path is one background hop away from the UI.
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true,
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return Stamp(size: UInt64(size), modifiedAt: modified)
    }

    /// Complete lines from the end of the file, oldest first.
    ///
    /// When the read starts mid-file the first line is a fragment, so it is
    /// dropped: half a JSON object parses as nothing useful, and keeping it
    /// would make every truncated read look like a corrupt transcript.
    static func tailLines(of url: URL, limitBytes: Int = maximumTailBytes) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let readCount = min(size, UInt64(max(limitBytes, 0)))
            try handle.seek(toOffset: size - readCount)
            let data = try handle.read(upToCount: Int(readCount)) ?? Data()
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if readCount < size, !lines.isEmpty { lines.removeFirst() }
            return lines.compactMap { String(data: Data($0), encoding: .utf8) }
        } catch {
            return []
        }
    }
}
