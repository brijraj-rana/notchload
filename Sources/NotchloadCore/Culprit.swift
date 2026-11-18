import Foundation

/// Decides when the tab should name the process behind a long stretch of high CPU.
///
/// Feed it total CPU once a second. It reports sustained load only after CPU has been high for a while, and
/// lets go only after it has been clearly lower for a few seconds, so a spike or a dip does not flip the tab.
public struct CulpritTracker {
    public struct Config: Equatable {
        public var enter: Double = 0.85         // CPU at or above this counts toward sustained load
        public var exit: Double = 0.70          // CPU below this counts toward letting go
        public var enterSeconds: Int = 30
        public var exitSeconds: Int = 5
        public var minProcessCPU: Double = 50   // percent of one core; below this nobody is to blame
        public var confirmSamples: Int = 2      // process samples in a row before the name changes

        public init() {}
    }

    public let config: Config
    /// True while the process list should be sampled and the tab may show a name.
    public private(set) var sustained = false
    /// The process to name, if one stands out.
    public private(set) var culprit: String?

    private var hot = 0
    private var cool = 0
    private var candidate: String?
    private var candidateCount = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Takes one CPU reading (0...1) and returns whether load is sustained.
    @discardableResult
    public mutating func feed(cpu: Double) -> Bool {
        if sustained {
            cool = cpu < config.exit ? cool + 1 : 0
            if cool >= config.exitSeconds { reset() }
        } else {
            // Readings between the two thresholds neither add to the run nor break it.
            if cpu >= config.enter {
                hot += 1
            } else if cpu < config.exit {
                hot = 0
            }
            if hot >= config.enterSeconds {
                sustained = true
                cool = 0
            }
        }
        return sustained
    }

    /// Takes the busiest process from a fresh sample and returns the name to show, if any.
    @discardableResult
    public mutating func observe(top: ProcRow?) -> String? {
        guard sustained else { return nil }
        var name: String?
        if let top, top.cpu >= config.minProcessCPU { name = top.name }

        if name == culprit {
            candidate = nil
            candidateCount = 0
        } else if culprit == nil {
            culprit = name      // the first name shows straight away
        } else {
            // A different name, or none at all, has to hold for a few samples before it replaces the current one.
            if name == candidate {
                candidateCount += 1
            } else {
                candidate = name
                candidateCount = 1
            }
            if candidateCount >= config.confirmSamples {
                culprit = name
                candidate = nil
                candidateCount = 0
            }
        }
        return culprit
    }

    private mutating func reset() {
        sustained = false
        culprit = nil
        hot = 0
        cool = 0
        candidate = nil
        candidateCount = 0
    }

    /// A process name short enough for the tab: "Google Chrome Helper (Renderer)" becomes "Google Chrome".
    public static func displayName(_ name: String) -> String {
        var short = name
        if let range = short.range(of: " Helper", options: .backwards), range.lowerBound != short.startIndex {
            let tail = short[range.upperBound...]
            if tail.isEmpty || (tail.hasPrefix(" (") && tail.hasSuffix(")")) {
                short = String(short[..<range.lowerBound])
            }
        }
        return short
    }
}
