//
//  RpcServer.swift
//  lara
//
//  给 lara 加一层 HTTP RPC，用来把 iOS 微信当成一个可远程驱动的事件源。
//  配合 PC 侧 wechat-hub 的 drivers/iosrpc.py 使用。
//
//  设计上刻意只暴露最原始的六个原语（/c /s /str /msg /rd /rd64），
//  而不是预先封装好 /send_text。原因：微信 8.0.79 的类名和选择子没人有权威文档，
//  封装成高层接口等于把猜测固化进二进制里，试错一次就要重新编译、重新签名、重新装。
//  原语式接口可以让我在 PC 上用 curl 组合出任意调用链，一次装机无限次实验。
//
//  另一个刻意的决定：**整个服务单线程**（accept 之后同步处理再关连接）。
//  因为 RemoteCall 内部操作目标进程的线程和异常端口，本身不是线程安全的；
//  串行化掉所有远程调用比加锁更简单也更可靠。hub 的轮询频率是秒级，性能完全够。
//

import Foundation
import Darwin
import UIKit

final class RpcServer {
    static let shared = RpcServer()

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var rc: RemoteCall?
    private var targetName: String = ""
    private var currentPort: UInt16 = 8080
    private let lock = NSLock()
    private var logs: [String] = []

    private(set) var isRunning = false

    var targetDescription: String {
        if let r = rc { return "\(targetName) (pid \(r.pid))" }
        return "none"
    }

    // MARK: - 日志

    func log(_ s: String) {
        lock.lock()
        logs.append(s)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
        lock.unlock()
        globallogger.log("(rpc) \(s)")
    }

    private func snapshotLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }

    // MARK: - 生命周期

    @discardableResult
    func start(port: UInt16) -> String {
        if isRunning { return "already running on port \(listenFD)" }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return "socket() failed errno=\(errno)" }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let e = errno
            close(fd)
            return "bind() failed errno=\(e)"
        }

        if listen(fd, 16) != 0 {
            let e = errno
            close(fd)
            return "listen() failed errno=\(e)"
        }

        listenFD = fd
        isRunning = true
        currentPort = port

        // 常驻的两个必要条件：
        // 1) 不让屏幕自动熄灭（灭屏进后台会让 RemoteCall 会话被上游逻辑销毁）
        // 2) 播放静音音频，利用 Info.plist 里的 audio 后台模式保持进程存活
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if !kaenabled { toggleka() }

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "lara-rpc-http"
        t.stackSize = 1 << 20
        t.start()
        thread = t

        log("listening on 0.0.0.0:\(port)")
        return "ok"
    }

    func stop() {
        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        log("stopped")
    }

    func setTarget(_ proc: String) -> String {
        if let existing = rc, targetName == proc {
            return "already injected into \(proc) pid \(existing.pid)"
        }
        if rc != nil { detach() }

        guard laramgr.shared.dsready else { return "kernel r/w not ready (tap Run Exploit first)" }

        // 与 laramgr 里同样的调用方式：init 失败时返回 nil，错误原因用类方法取
        let inst: RemoteCall? = RemoteCall(process: proc, useMigFilterBypass: false)
        guard let inst = inst else {
            let e = RemoteCall.lastInitError() ?? "unknown"
            log("inject \(proc) failed: \(e)")
            return "inject failed: \(e)"
        }
        rc = inst
        targetName = proc
        log("injected into \(proc) pid \(inst.pid)")
        return "ok pid \(inst.pid)"
    }

    /// 日志尾部，给 UI 轮询用。
    func tailLog(_ n: Int) -> [String] {
        let all = snapshotLogs()
        return all.count > n ? Array(all.suffix(n)) : all
    }

    private func detach() {
        // 头文件里写的是 -destroyRemoteCall，但它被标了 obsoleted，
        // Swift 侧只能用改名后的 destroy()。用旧名会直接编译不过：
        //   error: 'destroyRemoteCall()' has been renamed to 'destroy()'
        _ = rc?.destroy()
        rc = nil
        targetName = ""
    }

    // MARK: - 连接循环

    private func acceptLoop() {
        while isRunning {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                // 监听套接字已关闭（stop 被调用）或出现致命错误
                if !isRunning { break }
                usleep(50_000)
                continue
            }
            autoreleasepool {
                handle(cfd)
            }
            close(cfd)
        }
    }

    private func handle(_ cfd: Int32) {
        var buf = [UInt8](repeating: 0, count: 32768)
        var total = 0
        while total < buf.count {
            let n = read(cfd, &buf[total], buf.count - total)
            if n <= 0 { break }
            total += n
            if total > 4, let s = String(bytes: buf[0..<total], encoding: .utf8),
               s.contains("\r\n\r\n") {
                break
            }
        }
        guard total > 0 else { return }

        let head = String(decoding: buf[0..<total], as: UTF8.self)
        guard let firstLine = head.components(separatedBy: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(cfd, 400, ["error": "malformed request"])
            return
        }

        let method = String(parts[0])
        let target = String(parts[1])
        var path = target
        var query = ""
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            query = String(target[target.index(after: q)...])
        }

        let params = parseQuery(query)
        let (code, body) = route(method: method, path: path, params: params)
        respond(cfd, code, body)
    }

    private func respond(_ cfd: Int32, _ code: Int, _ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "ERROR")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(data)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(cfd, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // MARK: - 路由

    private func route(method: String, path: String, params: [String: String]) -> (Int, [String: Any]) {
        let mgr = laramgr.shared

        switch path {
        case "/health":
            return (200, [
                "ok": true,
                "service": "lara-rpc",
                "port": Int(currentPort),
                "ds_ready": mgr.dsready,
                "vfs_ready": mgr.vfsready,
                "sbx_ready": mgr.sbxready,
                "kernbase": String(format: "0x%llx", mgr.kernbase),
                "kernslide": String(format: "0x%llx", mgr.kernslide),
                "target": targetDescription,
                "ts": Int(Date().timeIntervalSince1970),
            ])

        case "/inject":
            let proc = params["proc"] ?? "WeChat"
            let r = setTarget(proc)
            return (r.hasPrefix("ok") || r.hasPrefix("already") ? 200 : 500, [
                "result": r,
                "target": targetDescription,
            ])

        case "/log":
            let n = Int(params["n"] ?? "80") ?? 80
            let all = snapshotLogs()
            let tail = all.count > n ? Array(all.suffix(n)) : all
            return (200, ["lines": tail])

        case "/stop":
            stop()
            return (200, ["ok": true])

        // ---- 以下都是远程原语，必须先注入成功 ----

        case "/c", "/s", "/str", "/msg", "/rd", "/rd64":
            guard let r = rc else {
                return (409, ["error": "not injected, POST /inject?proc=WeChat first"])
            }

            switch path {
            case "/c":
                guard let name = params["n"], !name.isEmpty else {
                    return (400, ["error": "missing n"])
                }
                let addr = name.withCString { remote_getClass(r, $0) }
                return (200, ["cls": name, "addr": hexString(addr)])

            case "/s":
                guard let name = params["n"], !name.isEmpty else {
                    return (400, ["error": "missing n"])
                }
                let addr = name.withCString { remote_sel(r, $0) }
                return (200, ["sel": name, "addr": hexString(addr)])

            case "/str":
                guard let text = params["t"] else { return (400, ["error": "missing t"]) }
                let addr = text.withCString { remote_NSString(r, $0) }
                return (200, ["addr": hexString(addr)])

            case "/msg":
                let obj = hex(params["o"])
                let sel = hex(params["s"])
                if sel == 0 { return (400, ["error": "missing s (selector address)"]) }
                let a0 = argValue(params["a0"], r)
                let a1 = argValue(params["a1"], r)
                let a2 = argValue(params["a2"], r)
                let a3 = argValue(params["a3"], r)
                let ret = remote_msg(r, obj, sel, a0, a1, a2, a3)
                return (200, [
                    "ret": hexString(ret),
                    "errno": Int(remote_errno(r)),
                ])

            case "/rd":
                let p = hex(params["p"])
                guard p != 0 else { return (400, ["error": "missing p"]) }
                guard let s = readNSString(p, r) else {
                    return (500, ["error": "read failed", "errno": Int(remote_errno(r))])
                }
                return (200, ["value": s])

            default: // /rd64
                let p = hex(params["p"])
                guard p != 0 else { return (400, ["error": "missing p"]) }
                let v = r.remoteRead64(from: p)
                return (200, ["value": hexString(v)])
            }

        default:
            return (404, ["error": "unknown path", "paths": ["/health", "/inject", "/log", "/stop",
                                                           "/c", "/s", "/str", "/msg", "/rd", "/rd64"]])
        }
    }

    // MARK: - 远程内存辅助

    /// 读回远程进程里的 NSString。不走 RemotePointer 的下标语法，
    /// 而是自己拆 length + UTF8String 两步，少一层 ARC 语义的不确定性。
    private func readNSString(_ addr: UInt64, _ r: RemoteCall) -> String? {
        let selLength = "length".withCString { remote_sel(r, $0) }
        let selUtf8 = "UTF8String".withCString { remote_sel(r, $0) }
        let len = remote_msg(r, addr, selLength, 0, 0, 0, 0)
        let ptr = remote_msg(r, addr, selUtf8, 0, 0, 0, 0)
        guard ptr != 0 else { return nil }

        let cap = Int(min(len, 1 << 20)) + 1
        var buf = [UInt8](repeating: 0, count: cap)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            r.remoteRead(ptr, to: raw.baseAddress, size: UInt64(cap))
        }
        guard ok else { return nil }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    /// 方法参数：支持 `str:文本` 简写（直接在远程进程分配 NSString），
    /// 或纯十六进制地址。这样一次 HTTP 请求就能把字符串参数带上，省一轮往返。
    private func argValue(_ raw: String?, _ r: RemoteCall) -> UInt64 {
        guard let raw = raw, !raw.isEmpty else { return 0 }
        if raw == "nil" || raw == "null" { return 0 }
        if raw.hasPrefix("str:") {
            let s = String(raw.dropFirst(4))
            return s.withCString { remote_NSString(r, $0) }
        }
        return hex(raw)
    }

    // MARK: - 小工具

    private func hexString(_ v: UInt64) -> String {
        String(format: "0x%llx", v)
    }

    private func hex(_ s: String?) -> UInt64 {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return 0 }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t.removeFirst(2) }
        return UInt64(t, radix: 16) ?? 0
    }

    private func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = percentDecode(String(kv[0]))
            let v = kv.count > 1 ? percentDecode(String(kv[1])) : ""
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    private func percentDecode(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "+" {
                out.append(" ")
                i = s.index(after: i)
            } else if c == "%", s.distance(from: i, to: s.endIndex) >= 3 {
                let hexPart = String(s[s.index(after: i)...].prefix(2))
                if let v = UInt8(hexPart, radix: 16) {
                    out.append(Character(UnicodeScalar(v)))
                    i = s.index(i, offsetBy: 3)
                } else {
                    out.append(c)
                    i = s.index(after: i)
                }
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
