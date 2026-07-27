import Foundation
import Combine

/// Loads `parser/daily-usage.ts` off the main thread and caches the result for
/// 60 s so re-opening the dashboard (or flipping the metric toggle) doesn't pay
/// the `npx tsx` cold-start cost every time.
final class DailyUsageService: ObservableObject {
    enum State {
        case loading
        case loaded(DailyUsage)
        case error(String)
    }

    @Published private(set) var state: State = .loading
    /// Currently-selected window length in days (7 / 14 / 30).
    @Published private(set) var days: Int = 7

    private let cacheTTL: TimeInterval = 60
    private var cached: DailyUsage?
    private var cachedDays = 0
    private var cachedAt: Date = .distantPast

    /// Loads the given window. Serves cache when it's fresh and for the same
    /// window length, unless `force` is set (manual refresh).
    func load(days: Int, force: Bool = false) {
        self.days = days

        if !force,
           let cached,
           cachedDays == days,
           Date().timeIntervalSince(cachedAt) < cacheTTL {
            state = .loaded(cached)
            return
        }

        state = .loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ParserRunner.runDailyUsage(days: days)
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.cached = result
                    self.cachedDays = days
                    self.cachedAt = Date()
                    self.state = .loaded(result)
                } else {
                    self.state = .error("無法讀取用量資料（parser 執行失敗）")
                }
            }
        }
    }
}
