import Foundation

/// /metrics 接口的数据模型。
/// 所有字段都可缺失（缺字段、多字段、null 都不导致解码失败）。
/// 接口定义见 docs/design.md「指标接口」。
public struct Metrics: Decodable, Sendable {
    public var version: Int?
    public var state: String?
    public var engineReady: Bool?
    public var model: String?
    public var tensorfoldVersion: String?
    public var contextMax: Int?
    public var hooks: Hooks?
    public var current: Current?
    public var last: Last?
    public var totals: Totals?
    public var round: Round?

    public struct Hooks: Decodable, Sendable {
        public var chat: String?

        public init(chat: String? = nil) {
            self.chat = chat
        }
    }

    public struct Current: Decodable, Sendable {
        public var elapsedS: Double?
        public var ttftS: Double?
        public var outputTokens: Int?
        public var decodeTps: Double?
        public var decodeTpsPeak: Double?
        public var decodeTpsAvg: Double?
        /// 本次提示 token 数（精确，拿不到时为 nil）
        public var promptTokens: Int?
        /// 预填充开始时的缓存命中 token 数（拿不到时为 nil）
        public var prefillCached: Int?
        /// 预计纯预填充秒数（拿不到时为 nil）
        public var prefillEstS: Double?
        /// 是否判定为缓存未命中
        public var cacheMiss: Bool?

        public init(
            elapsedS: Double? = nil,
            ttftS: Double? = nil,
            outputTokens: Int? = nil,
            decodeTps: Double? = nil,
            decodeTpsPeak: Double? = nil,
            decodeTpsAvg: Double? = nil,
            promptTokens: Int? = nil,
            prefillCached: Int? = nil,
            prefillEstS: Double? = nil,
            cacheMiss: Bool? = nil
        ) {
            self.elapsedS = elapsedS
            self.ttftS = ttftS
            self.outputTokens = outputTokens
            self.decodeTps = decodeTps
            self.decodeTpsPeak = decodeTpsPeak
            self.decodeTpsAvg = decodeTpsAvg
            self.promptTokens = promptTokens
            self.prefillCached = prefillCached
            self.prefillEstS = prefillEstS
            self.cacheMiss = cacheMiss
        }

        private enum CodingKeys: String, CodingKey {
            case elapsedS = "elapsed_s"
            case ttftS = "ttft_s"
            case outputTokens = "output_tokens"
            case decodeTps = "decode_tps"
            case decodeTpsPeak = "decode_tps_peak"
            case decodeTpsAvg = "decode_tps_avg"
            case promptTokens = "prompt_tokens"
            case prefillCached = "prefill_cached"
            case prefillEstS = "prefill_est_s"
            case cacheMiss = "cache_miss"
        }
    }

    public struct Last: Decodable, Sendable {
        public var promptTokens: Int?
        public var cachedTokens: Int?
        public var completionTokens: Int?
        public var decodeTps: Double?
        public var ttftS: Double?
        public var acceptanceRate: Double?
        public var contextUsed: Int?
        public var finishReason: String?

        public init(
            promptTokens: Int? = nil,
            cachedTokens: Int? = nil,
            completionTokens: Int? = nil,
            decodeTps: Double? = nil,
            ttftS: Double? = nil,
            acceptanceRate: Double? = nil,
            contextUsed: Int? = nil,
            finishReason: String? = nil
        ) {
            self.promptTokens = promptTokens
            self.cachedTokens = cachedTokens
            self.completionTokens = completionTokens
            self.decodeTps = decodeTps
            self.ttftS = ttftS
            self.acceptanceRate = acceptanceRate
            self.contextUsed = contextUsed
            self.finishReason = finishReason
        }

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case cachedTokens = "cached_tokens"
            case completionTokens = "completion_tokens"
            case decodeTps = "decode_tps"
            case ttftS = "ttft_s"
            case acceptanceRate = "acceptance_rate"
            case contextUsed = "context_used"
            case finishReason = "finish_reason"
        }
    }

    public struct Totals: Decodable, Sendable {
        public var requests: Int?
        public var peakTps: Double?
        public var uptimeS: Int?

        public init(requests: Int? = nil, peakTps: Double? = nil, uptimeS: Int? = nil) {
            self.requests = requests
            self.peakTps = peakTps
            self.uptimeS = uptimeS
        }

        private enum CodingKeys: String, CodingKey {
            case requests
            case peakTps = "peak_tps"
            case uptimeS = "uptime_s"
        }
    }

    /// 当前这一轮（连续请求）；还没有任何请求时为 null
    public struct Round: Decodable, Sendable {
        public var requests: Int?
        public var outputTokens: Int?
        public var decodeTpsAvg: Double?
        public var elapsedS: Double?
        public var active: Bool?

        public init(
            requests: Int? = nil,
            outputTokens: Int? = nil,
            decodeTpsAvg: Double? = nil,
            elapsedS: Double? = nil,
            active: Bool? = nil
        ) {
            self.requests = requests
            self.outputTokens = outputTokens
            self.decodeTpsAvg = decodeTpsAvg
            self.elapsedS = elapsedS
            self.active = active
        }

        private enum CodingKeys: String, CodingKey {
            case requests
            case outputTokens = "output_tokens"
            case decodeTpsAvg = "decode_tps_avg"
            case elapsedS = "elapsed_s"
            case active
        }
    }

    // 接口字段为蛇形命名，统一映射成驼峰属性
    private enum CodingKeys: String, CodingKey {
        case version
        case state
        case engineReady = "engine_ready"
        case model
        case tensorfoldVersion = "tensorfold_version"
        case contextMax = "context_max"
        case hooks
        case current
        case last
        case totals
        case round
    }

    public init(
        version: Int? = nil,
        state: String? = nil,
        engineReady: Bool? = nil,
        model: String? = nil,
        tensorfoldVersion: String? = nil,
        contextMax: Int? = nil,
        hooks: Hooks? = nil,
        current: Current? = nil,
        last: Last? = nil,
        totals: Totals? = nil,
        round: Round? = nil
    ) {
        self.version = version
        self.state = state
        self.engineReady = engineReady
        self.model = model
        self.tensorfoldVersion = tensorfoldVersion
        self.contextMax = contextMax
        self.hooks = hooks
        self.current = current
        self.last = last
        self.totals = totals
        self.round = round
    }
}
