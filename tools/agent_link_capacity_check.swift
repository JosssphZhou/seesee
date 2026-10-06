import Darwin
import Foundation

/// 真实socketpair、生产读取函数和现有时限；不放松4连接与2秒保护。
@main
struct AgentLinkCapacityCheck {
    struct Failed: Error { let message: String }
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        guard AgentLinkServer.readTimeout == 2, AgentLinkServer.maxConnections == 4 else {
            throw Failed(message: "原连接数或读取时限被放松")
        }
        for megabytes in [4, 16] {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw Failed(message: "socketpair失败") }
            let reader = fds[0], writer = fds[1], size = megabytes * 1024 * 1024
            let done = DispatchSemaphore(value: 0)
            Thread {
                defer { close(writer); done.signal() }
                var payload = Data(repeating: 0x61, count: size); payload.append(0x0A)
                _ = AgentLinkSocket.writeAll(writer, payload, timeout: AgentLinkServer.readTimeout)
            }.start()
            let start = Date()
            let result = AgentLinkSocket.readLine(reader, limit: AgentLinkServer.maxRequestBytes, timeout: AgentLinkServer.readTimeout)
            let elapsed = Date().timeIntervalSince(start)
            close(reader)
            guard done.wait(timeout: .now() + 3) == .success else { throw Failed(message: "本轮发送线程未退出") }
            let count: Int
            if case .line(let data) = result { count = data.count } else { count = -1 }
            print(String(format: "readline size=%dMB elapsed=%.4fs bytes=%d limit=%.1fs", megabytes, elapsed, count, AgentLinkServer.readTimeout))
            fflush(stdout)
            guard count == size, elapsed < AgentLinkServer.readTimeout else { throw Failed(message: "\(megabytes)MB未在原2秒时限内读完") }
        }
        print("agent_link_capacity_check=passed")
    }
}
