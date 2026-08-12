import Foundation
import Combine

/// Loads `parser/phase-usage.ts` off the main thread and caches the result for
/// 60 s, so switching tabs or flipping the metric toggle doesn't pay the
/// `npx tsx` cold-start cost every time. Mirrors `DailyUsageService`.
final class PhaseUsageService: ObservableObject {
    enum State {
        case loading
        case loaded(PhaseUsage)
        case error(String)
    }

    @Published private(set) var state: State = .loading
    /// Currently-selected window length in days (7 / 14 / 30).
    @Published private(set) var days: Int = 7

    /// Nothing has been requested yet — lets the dashboard defer the first
    /// (slow) load until the user actually opens this tab.
    private(set) var hasLoaded = false

    private let cacheTTL: TimeInterval = 60
    private var cached: PhaseUsage?
    private var cachedDays = 0
    private var cachedAt: Date = .distantPast

    /// Identifies the newest in-flight request. A 30-day load can take a minute
    /// and would otherwise land after the user switched back to 7 days,
    /// replacing the content while the picker still reads 7.
    private var generation = 0

    /// Injection point for tests; production always runs the real parser.
    private let loader: (Int) -> PhaseUsage?

    init(loader: @escaping (Int) -> PhaseUsage? = { ParserRunner.runPhaseUsage(days: $0) }) {
        self.loader = loader
    }

    /// Loads the given window. Serves cache when it's fresh and for the same
    /// window length, unless `force` is set (manual refresh).
    func load(days: Int, force: Bool = false) {
        self.days = days
        hasLoaded = true

        if !force,
           let cached,
           cachedDays == days,
           Date().timeIntervalSince(cachedAt) < cacheTTL {
            state = .loaded(cached)
            return
        }

        generation += 1
        let requested = generation
        state = .loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self, loader] in
            let result = loader(days)
            DispatchQueue.main.async {
                guard let self else { return }
                // A superseded request must not overwrite newer content.
                guard requested == self.generation else { return }
                if let result {
                    self.cached = result
                    self.cachedDays = days
                    self.cachedAt = Date()
                    self.state = .loaded(result)
                } else {
                    self.state = .error("無法讀取活動分佈（parser 執行失敗）")
                }
            }
        }
    }
}
