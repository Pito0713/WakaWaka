import Foundation

/// Reads the last few kilobytes of an agent transcript.
///
/// Transcripts grow to megabytes while the panel refreshes every second, so
/// nothing here may read a whole file, and the caller is expected to skip the
/// read entirely when `stamp(of:)` is unchanged — see `ContextUsageService`.
enum TranscriptTailReader {
    /// First window tried. A usage record is a few hundred bytes, so this
    /// covers many turns of an ordinary transcript.
    static let maximumTailBytes = 64 * 1024

    /// Windows tried in order until a line decodes. One assistant line carries
    /// a whole message, so a single long code block can exceed any fixed
    /// window — and since a truncated first line has to be dropped, a window
    /// smaller than the last line yields *nothing at all*. Widening beats
    /// guessing a size: the common case still costs one 64KB read.
    private static let tailWindows = [maximumTailBytes, 512 * 1024, 4 * 1024 * 1024]

    /// Cheap identity for "has this file changed". Size alone is not enough:
    /// an edit that replaces a line leaves it identical.
    struct Stamp: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

    static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true,
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return Stamp(size: UInt64(size), modifiedAt: modified)
    }

    /// The newest line that `decode` accepts, searching backwards.
    ///
    /// Escalates through `tailWindows` because a transcript's last line has no
    /// bounded size. Each attempt re-reads from the end rather than continuing
    /// the previous one — simpler, and only a pathological file pays for it.
    static func newest<T>(of url: URL, decode: (String) -> T?) -> T? {
        for window in tailWindows {
            let (lines, reachedStart) = tail(of: url, limitBytes: window)
            if let match = lines.reversed().lazy.compactMap(decode).first { return match }
            // The whole file has been searched; a bigger window finds nothing.
            if reachedStart { return nil }
        }
        return nil
    }

    /// Complete lines from the end of the file, oldest first.
    static func tailLines(of url: URL, limitBytes: Int = maximumTailBytes) -> [String] {
        tail(of: url, limitBytes: limitBytes).lines
    }

    /// - Returns: the lines, and whether the window reached the start of the
    ///   file (so the caller knows there is nothing left to widen into).
    private static func tail(of url: URL, limitBytes: Int) -> (lines: [String], reachedStart: Bool) {
        guard let handle = openRegularFile(at: url) else { return ([], true) }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let readCount = min(size, UInt64(max(limitBytes, 0)))
            let reachedStart = readCount == size
            try handle.seek(toOffset: size - readCount)
            let data = try handle.read(upToCount: Int(readCount)) ?? Data()
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // A read that started mid-file begins inside a line. Half a JSON
            // object is not a record, and keeping it would make every large
            // transcript look corrupt.
            if !reachedStart, !lines.isEmpty { lines.removeFirst() }
            return (lines.compactMap { String(data: Data($0), encoding: .utf8) }, reachedStart)
        } catch {
            return ([], true)
        }
    }

    /// Opens the file only if it is still a regular file *after* it is open.
    ///
    /// Checking the path and then opening it are two moments, and between them
    /// the name can be pointed at something else. `O_NONBLOCK` means a fifo
    /// swapped in cannot block this thread on `open` — one stuck thread per
    /// five-second tick would accumulate — and `fstat` on the descriptor we
    /// actually hold rejects it, rather than trusting what the path meant a
    /// moment ago.
    private static func openRegularFile(at url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
