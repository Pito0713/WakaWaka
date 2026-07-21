import AppKit

/// Loads an optional user-supplied menu-bar skin — a folder of PNG frames under
/// `~/.wakawaka/skins/<name>/`. Frames are authored at 2x (Retina); each is
/// interpreted so its point size is half its pixel size. Missing frames fall back
/// to the idle frame, and if no skin is active the app uses its built-in
/// procedural ghost, so a skin is purely additive.
///
/// Frame filenames (all optional except at least one idle frame). The `_0…_4`
/// suffix is the feet-glide phase (seamless conveyor); a missing phase falls back to
/// `_0`, then to idle. A `pending_` prefix is the yellow colour set shown while an
/// approval is waiting (falls back to the red base if absent):
///   idle_0…idle_4.png          → idle / looking right (also the default pose)
///   look_left_0…4.png          → eyes look left
///   look_up_0…4.png            → eyes look up
///   look_down_0…4.png          → eyes look down
///   blink_0…4.png              → eyes closed
///   pending_<any>.png          → yellow variant used while pending
///
/// Optional `skin.json`: { "template": true }  (template tints monochrome to the
/// menu-bar colour; set false for a full-colour skin). Defaults to template.
final class SkinManager {
    static let shared = SkinManager()

    /// Max icon height in points; taller frames are scaled down to fit the menu bar.
    private static let maxHeightPt: CGFloat = 18

    private let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".wakawaka/skins", isDirectory: true)

    private var imageCache: [String: NSImage] = [:]   // "skin/file" → image
    private var missing: Set<String> = []             // files known absent
    private(set) var activeSkin: String?
    private var isTemplate = true

    /// (Re)scan the skins directory and choose the active skin: an explicit
    /// UserDefaults["activeSkin"] if present, otherwise the sole skin folder.
    func reload() {
        imageCache.removeAll()
        missing.removeAll()
        activeSkin = nil
        isTemplate = true

        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let skins = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()

        if let chosen = UserDefaults.standard.string(forKey: "activeSkin"), skins.contains(chosen) {
            activeSkin = chosen
        } else if skins.count == 1 {
            activeSkin = skins.first
        }
        guard let skin = activeSkin else { return }

        // A skin must actually have a base frame, else treat it as absent.
        guard loadFrame(skin: skin, file: "idle_0") != nil
            || loadFrame(skin: skin, file: "idle_1") != nil else {
            activeSkin = nil
            return
        }

        let manifest = root.appendingPathComponent("\(skin)/skin.json")
        if let data = try? Data(contentsOf: manifest),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let template = obj["template"] as? Bool {
            isTemplate = template
        }
    }

    /// The frame image for the current animation state, or nil to use the built-in
    /// ghost (no skin active, or no usable frame found). `wave` selects the feet-bob
    /// phase; each pose falls back to its phase-0 frame, then to idle.
    func image(wave: Int, action: String, pending: Bool) -> NSImage? {
        guard let skin = activeSkin else { return nil }
        let base: [String]
        switch action {
        case "blink":    base = ["blink_\(wave)", "blink_0"]
        case "lookLeft": base = ["look_left_\(wave)", "look_left_0"]
        case "lookUp":   base = ["look_up_\(wave)", "look_up_0"]
        case "lookDown": base = ["look_down_\(wave)", "look_down_0"]
        default:         base = ["idle_\(wave)", "idle_0"]   // normal = looking right
        }
        // Pending swaps to the yellow ("pending_") colour set; fall back to the red
        // base (then idle) if a yellow frame is missing, so the swap is purely additive.
        var candidates = pending ? base.map { "pending_" + $0 } : []
        candidates += base
        candidates += ["idle_\(wave)", "idle_0"]
        for file in candidates {
            if let img = loadFrame(skin: skin, file: file) { return img }
        }
        return nil
    }

    private func loadFrame(skin: String, file: String) -> NSImage? {
        let key = "\(skin)/\(file)"
        if let cached = imageCache[key] { return cached }
        if missing.contains(key) { return nil }

        let url = root.appendingPathComponent("\(skin)/\(file).png")
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else {
            missing.insert(key)
            return nil
        }
        // Interpret pixels as 2x; clamp height to keep the icon menu-bar-sized.
        var pointW = CGFloat(rep.pixelsWide) / 2
        var pointH = CGFloat(rep.pixelsHigh) / 2
        if pointH > Self.maxHeightPt {
            let k = Self.maxHeightPt / pointH
            pointW *= k; pointH *= k
        }
        let size = NSSize(width: pointW, height: pointH)
        rep.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        img.isTemplate = isTemplate
        imageCache[key] = img
        return img
    }
}
