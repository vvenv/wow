import Foundation
import Network

// TCP connect 延迟探测。
//
// 用 NWConnection 连接目标端口（realmd 监听 3724），量从发起到 ready
// 状态的耗时，然后立刻关掉连接。
// 返回 ms；连接失败或超时返回 -1。
enum Pinger {
    static func tcpLatency(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Double {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            nonisolated(unsafe) var done = false
            let start = Date()

            @Sendable func finish(_ ms: Double) {
                guard !done else { return }
                done = true
                conn.cancel()
                continuation.resume(returning: ms)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish((Date().timeIntervalSince(start)) * 1000)
                case .failed, .cancelled:
                    finish(-1)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))

            // 超时兜底
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(-1)
            }
        }
    }
}
