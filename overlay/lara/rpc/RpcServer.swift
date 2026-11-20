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

/// 编译期构建标识。
///
/// 之前完全没法确认手机上跑的是不是刚编出来的包：Info.plist 里的版本号是上游的
/// （0.2 / Release），装十个包看到的值都一样，出问题只能靠猜和重启。
/// 现在 RPC 页顶部和 /health 都会显示它，装完瞄一眼就知道。
let LARA_RPC_BUILD = "v20-2026-11-20T1400"

final class RpcServer {
    static let shared = RpcServer()

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var rc: RemoteCall?
    private var targetName: String = ""
    private var currentPort: UInt16 = 8080
    private let lock = NSLock()
    // 所有会碰 RemoteCall 的接口走这把锁。RemoteCall 的会话是单份的：
    // 两个线程同时驱动同一个 trojan 线程必然互相踩。用递归锁是因为
    // route 里可能间接再进一次（例如 /relaunch 内部调 launch）。
    private let opLock = NSRecursiveLock()
    private var logs: [String] = []

    // /pool 的 autorelease pool 栈，按「跑在哪个线程上」分开存。
    // trojan 线程和被征用的主线程是两条独立的线程，各自的 pool 栈也独立，
    // 混在一起 pop 会 drain 错线程的池（等于什么都没做，还丢了一个 pool 引用）。
    private let poolLock = NSLock()
    private var poolStack: [String: [UInt64]] = [:]

    // 注入状态机。为什么必须有这个：
    // RemoteCall 进一个「已被系统挂起」的进程时，那个远程线程永远不会被调度，
    // 调用就一直不返回。如果这件事发生在主线程上，SwiftUI 卡死 → 20 秒后
    // iOS 的用户态 watchdog 判定 SpringBoard 无响应 → 整机 panic 重启。
    // 所以注入必须跑在后台线程，主线程只读状态。
    private var injectState: String = "idle"   // idle / injecting / ready / failed
    private var injectMessage: String = ""
    private var injectStarted: TimeInterval = 0
    private var injectProc: String = ""

    private(set) var isRunning = false

    /// stdout 被重定向到一个文件，/stdout 接口读它。
    private var stdoutPath: String?

    /// RemoteCall.m 里 printf 直写的那份诊断日志（自己 fopen，不经过 lara Logger）。
    private var diagPath: String?

    /// 定位 lara 自己那份日志。
    ///
    /// 为什么不是自己 freopen：lara 的 Logger.capture() 在启动时就用
    /// `dup2(pipe, STDOUT_FILENO)` 把 stdout/stderr 全接管了，RemoteCall 里那些
    /// printf（signState 的 pc_raw/pc_signed、异常的 exc/code、每次远程调用的 pcAddr）
    /// 都流进它的 pipe，再由 appendtofile 落到 Documents/lara.log。
    /// 我一开始在 start() 里 freopen，结果是建了一个空文件 —— printf 早就不走那条路了。
    /// 直接读 lara 的成品日志最省事，也不用抢它的 fd。
    private func documentsPath(_ name: String) -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (dir ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(name).path
    }

    private func resolveLogPath() -> String? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let p = dir.appendingPathComponent("lara.log").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    private func readFileTail(_ path: String?, _ n: Int) -> [String] {
        guard let p = path, let h = FileHandle(forReadingAtPath: p) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 524288 ? size - 524288 : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), let s = String(data: d, encoding: .utf8) else { return [] }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.count > n ? Array(lines.suffix(n)) : lines
    }

    private func readStdoutTail(_ n: Int) -> [String] {
        guard let p = stdoutPath ?? resolveLogPath(),
              let h = FileHandle(forReadingAtPath: p) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 131072 ? size - 131072 : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), let s = String(data: d, encoding: .utf8) else { return [] }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.count > n ? Array(lines.suffix(n)) : lines
    }

    /// 会话作废：进程没了 / 远程线程坏了，都必须从这里走一遍，
    /// 否则注入状态还写着 ready，外部会以为还能用。
    private func invalidateRC(_ reason: String) {
        lock.lock()
        rc = nil
        targetName = ""
        if injectState != "injecting" {
            injectState = "failed"
            injectMessage = reason
        }
        lock.unlock()
        log(reason + "，会话已作废")
        rc_diag_line("[rpc] session invalidated: \(reason)\n")
    }

    /// rc 会被注入线程改写，路由线程也会读，统一从锁里取。
    private func currentRC() -> RemoteCall? {
        lock.lock()
        defer { lock.unlock() }
        return rc
    }

    private func targetDescLocked() -> String {
        if let r = rc { return "\(targetName) (pid \(r.pid))" }
        return "none"
    }

    var targetDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return targetDescLocked()
    }

    // MARK: - 日志

    /// 日志用**独立的锁**。
    /// 之前和主 lock 共用：任何在持 lock 期间调用 log() 的路径（route 的某个
    /// case、注入线程、UI 的 refresh）都会自己把自己锁死 —— NSLock 不可重入，
    /// 表现就是主线程卡住、界面动不了。日志和状态本来也没有互斥关系。
    private let logLock = NSLock()

    func log(_ s: String) {
        logLock.lock()
        logs.append(s)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
        logLock.unlock()
        globallogger.log("(rpc) \(s)")
    }

    private func snapshotLogs() -> [String] {
        logLock.lock()
        defer { logLock.unlock() }
        return logs
    }

    // MARK: - 生命周期

    @discardableResult
    func start(port: UInt16) -> String {
        if isRunning { return "already running on port \(listenFD)" }
        // 冗余启动：init 阶段如果 BootServer 没起来（端口被占、启动过早），
        // 用户点 Start Server 时再试一次，此时 app 已完全启动、环境更正常。
        BootServer.shared.startAndBeat()
        BootServer.shared.mark("rpc start port=\(port)")

        stdoutPath = resolveLogPath()

        // printf 写管道默认是 4KB 全缓冲，RemoteCall 大段调试信息会滞留在缓冲区里，
        // 于是「注入成功」之后的日志永远看不到 —— 排查注入稳定性时等于瞎的。
        // 这里改成行缓冲/无缓冲，代价可忽略。
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        // 真正可靠的诊断落盘：RemoteCall.m 里所有 printf 已被重定向到 rc_diagf，
        // 它自己 fopen 一个文件并每条 fflush。lara 的 Logger 会丢行（过滤 + 管道），
        // 靠 /applog 排查注入问题已经踩过坑了。
        let diag = documentsPath("rc-diag.log")
        diagPath = diag
        rc_set_diag_path(diag)
        rc_diag_line("\n===== lara-rpc server start \(ISO8601DateFormatter().string(from: Date())) =====\n")
        // 探测期把单次等待从 10s 压到 3s：会话一旦坏了立刻报错，不用干等 20s。
        rc_set_wait_ms(5000)

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

        // iOS 的「本地网络」权限只在 app **主动发起**局域网访问时才弹窗，纯 listen 不触发。
        // 后果很隐蔽：服务起得来、手机自己访问 127.0.0.1 正常、lara 页面上 state 就是
        // listening，但电脑连上来时内核把 SYN 静默丢掉 —— 外部看到的是 timeout 而不是
        // refused，极易被误判成「服务没起」。这里主动打一发 UDP 广播把询问逼出来。
        Thread { [weak self] in
            self?.requestLocalNetworkPermission()
            self?.selfCheck(port: port)
        }.start()

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "lara-rpc-http"
        t.stackSize = 1 << 20
        t.start()
        thread = t

        log("listening on 0.0.0.0:\(port)")
        BootServer.shared.mark("rpc listening \(port)")
        return "ok"
    }

    /// 主动触发 iOS 本地网络权限询问。
    /// 原理：向广播地址发一包 UDP。系统在放行这个 sendto 之前会要求 app 拿到
    /// Local Network 权限，于是弹窗出现。只 listen 是等不到这个弹窗的。
    private func requestLocalNetworkPermission() {
        let u = socket(AF_INET, SOCK_DGRAM, 0)
        guard u >= 0 else { log("权限触发：socket() 失败，跳过"); return }
        var bc: Int32 = 1
        setsockopt(u, SOL_SOCKET, SO_BROADCAST, &bc, socklen_t(MemoryLayout<Int32>.size))

        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(9).bigEndian
        a.sin_addr.s_addr = inet_addr("255.255.255.255")

        let payload = Array("lara-rpc".utf8)
        let n = withUnsafePointer(to: &a) { p -> Int in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                payload.withUnsafeBufferPointer { buf in
                    sendto(u, buf.baseAddress, buf.count, 0, sp,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        close(u)
        if n > 0 {
            log("权限触发：UDP 广播已发出。若弹出「本地网络」询问请点允许")
        } else {
            log("权限触发：广播 sendto 失败 errno=\(errno)（多半是权限已被拒，去设置里手动打开）")
        }
    }

    /// listen 到底生效没有。走 127.0.0.1，这条路径不受本地网络权限影响：
    /// 连得上 → 服务本身没问题，外部连不上就一定是权限/网络；连不上 → 代码或端口问题。
    /// 连上后立刻 close，acceptLoop 那边 read 返回 0 自然结束，不会卡住串行处理。
    private func selfCheck(port: UInt16) {
        Thread.sleep(forTimeInterval: 0.4)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let e = errno
        close(s)
        log(r == 0 ? "自检 127.0.0.1:\(port) 连接成功 → listen 正常"
                   : "自检 127.0.0.1:\(port) 失败 errno=\(e) → 端口没起来")
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

    /// 供 UI / HTTP 查询当前注入状态，附带已耗时（秒），超时可以据此判断。
    func injectStatus() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var d: [String: Any] = [
            "state": injectState,
            "proc": injectProc,
            "message": injectMessage,
            "target": targetDescLocked(),
        ]
        if injectStarted > 0 {
            d["elapsed"] = Int(Date().timeIntervalSince1970 - injectStarted)
        }
        return d
    }

    /// 立刻返回，真正的注入在后台线程做。UI 不会因此卡住。
    @discardableResult
    func beginInject(_ proc: String, mig: Bool = false, sign: Int = 1) -> String {
        lock.lock()
        if injectState == "injecting" {
            let s = "already injecting \(injectProc)"
            lock.unlock()
            return s
        }
        injectState = "injecting"
        injectMessage = ""
        injectProc = proc
        injectStarted = Date().timeIntervalSince1970
        lock.unlock()

        // 传递「怎么写线程状态里的 pc/lr」这一策略给 ObjC 侧的 signState。
        // 走 UserDefaults 而不是加头文件属性：RemoteCall.h 是上游文件，
        // 为了一个 int 去 overlay 整个头文件会让以后同步上游更麻烦。
        UserDefaults.standard.set(sign, forKey: "rcSignMode")

        log("开始注入 \(proc)（后台线程，migBypass=\(mig) signMode=\(sign)）")

        let t = Thread { [weak self] in self?.doInject(proc, mig: mig) }
        t.name = "lara-rpc-inject"
        t.stackSize = 1 << 21
        t.start()
        return "injecting"
    }

    private func doInject(_ proc: String, mig: Bool) {
        if currentRC() != nil { detach() }

        guard laramgr.shared.dsready else {
            finishInject("failed", "kernel r/w not ready (tap Run Exploit first)")
            return
        }

        // 先确认目标真的在跑。pid=0 说明进程不存在（被系统回收或从没启动过），
        // 此时注入只会无限等一个永远不会被调度的远程线程 —— 这就是上一版
        // 「点一下整机卡死重启」的成因。这里直接拒绝，代价为零。
        let pid = proc.withCString { find_process_pid($0) }
        guard pid > 0 else {
            finishInject("failed", "进程 \(proc) 未运行（pid=0），先 GET /launch?b=<bundleid> 再注入")
            return
        }
        log("目标 \(proc) 在运行，pid=\(pid)，开始建会话")

        // 与 laramgr 里同样的调用方式：init 失败时返回 nil，错误原因用类方法取
        // useMigFilterBypass 对微信有实际意义：它开了 MIG 消息过滤，
        // 设异常端口这一步可能被拦。lara 自己注 SpringBoard 用 false 就够，
        // 但第三方 App 防护更重，留成可切换。
        let inst: RemoteCall? = RemoteCall(process: proc, useMigFilterBypass: mig)
        guard let inst = inst else {
            finishInject("failed", RemoteCall.lastInitError() ?? "unknown")
            return
        }

        lock.lock()
        rc = inst
        targetName = proc
        injectState = "ready"
        injectMessage = "pid \(inst.pid)"
        lock.unlock()
        log("注入成功 \(proc) pid \(inst.pid)")
    }

    private func finishInject(_ state: String, _ message: String) {
        lock.lock()
        injectState = state
        injectMessage = message
        lock.unlock()
        log("注入未成功 [\(state)] \(message)")
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
        lock.lock()
        let r = rc
        rc = nil
        targetName = ""
        lock.unlock()
        _ = r?.destroy()
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
            // 每条连接一个线程。单线程 accept+handle 的模型有两个致命后果：
            // 1) 一个只连不发的客户端（探测、超时的 HTTP 客户端）就能让 accept 停摆；
            // 2) 更常见的是远程调用卡死（目标进程死了、注入到一半），整个 HTTP 服务
            //    跟着一起哑，连 /health 都返回不了，只能重启 app 才能恢复。
            // 真正需要串行的只有远程调用本身，那个用 opLock 单独把关。
            Thread { [weak self] in
                autoreleasepool {
                    var tv = timeval(tv_sec: 10, tv_usec: 0)
                    let tvl = socklen_t(MemoryLayout<timeval>.size)
                    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvl)
                    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvl)
                    self?.handle(cfd)
                    close(cfd)
                }
            }.start()
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

        // 廉价只读接口不参与串行：远程调用一旦卡死（目标进程没了、注入到一半），
        // 它会把 opLock 占住几十秒，而这些接口必须随时能答 —— 否则连
        // 「到底卡在哪」都问不出来。连接线程已经是每连接一个，这里只管互斥。
        let cheap: Set<String> = ["/boot", "/health", "/log", "/stdout", "/diag",
                                  "/applog", "/inject_status", "/pid"]
        // 注意 defer 必须挂在函数作用域上。写在 if 块里会在块结束时立刻执行，
        // 锁刚加上就放掉，等于没加。
        let needsOpLock = !cheap.contains(path)
        if needsOpLock { opLock.lock() }
        defer { if needsOpLock { opLock.unlock() } }

        switch path {
        case "/boot":
            // 从 8080 也能看启动看门狗。8081 起不来时（端口被占、启动过早）
            // 这是唯一的观测口：能读到 8081 到底绑没绑上、失败原因是什么。
            return (200, BootServer.shared.snapshot())
        case "/health":
            return (200, [
                "ok": true,
                "service": "lara-rpc",
                "build": LARA_RPC_BUILD,
                "port": Int(currentPort),
                "ds_ready": mgr.dsready,
                "vfs_ready": mgr.vfsready,
                "sbx_ready": mgr.sbxready,
                "kernbase": String(format: "0x%llx", mgr.kernbase),
                "kernslide": String(format: "0x%llx", mgr.kernslide),
                "target": targetDescription,
                "inject": injectStatus(),
                "ts": Int(Date().timeIntervalSince1970),
            ])

        case "/inject":
            let proc = params["proc"] ?? "WeChat"
            let mig = (params["mig"] ?? "0") == "1"
            // 默认 0（上游 remotepac 签名路径）。实测 iOS 18.5 / A14：
            // 裸指针那几条岔路（1/2/3）会把线程状态里的 diversifier 标志一起清掉，
            // 内核改用错误的密钥重签，pc 变成非规范地址，线程连第一条指令都取不到
            // （faulted at getpid: code=[0x1 0x20000001f06e0f9c]）。
            // 0 路径按目标线程自己的 diversifier 签名，SpringBoard 上实测 memset 成功。
            let sign = Int(params["sign"] ?? "0") ?? 0
            let r = beginInject(proc, mig: mig, sign: sign)
            return (200, ["result": r, "inject": injectStatus()])

        // C 层 printf 的尾巴。注入排查完全靠它：异常类型 exc、code、fault 时真实的 pc。
        // （lara 的 lastError 在格式化前把 threadState.__pc 改成了 lr 标记，
        //   所以外面看到的 "pc=0x201" 是假的，真值只在这份日志里。）
        case "/stdout":
            let n = Int(params["n"] ?? "150") ?? 150
            return (200, ["path": stdoutPath ?? "(未重定向)", "lines": readStdoutTail(n)])

        // RemoteCall.m 里 printf 直写的那份日志（rc_diagf → rc-diag.log）。
        // 和 /stdout、/applog 的区别：这条路径完全不经过 lara 的 Logger，
        // 不会因为它的行过滤或落盘时机丢内容，崩之前写的一定在。
        case "/diag":
            if params["clear"] == "1" {
                try? FileManager.default.removeItem(atPath: diagPath ?? "")
                rc_set_diag_path(diagPath)
                return (200, ["cleared": true, "path": diagPath ?? ""])
            }
            let n = Int(params["n"] ?? "200") ?? 200
            return (200, ["path": diagPath ?? "(未设置)", "lines": readFileTail(diagPath, n)])

        // 单次等待异常的毫秒数。探测时调小，会话坏了能秒级发现而不是干等 20s。
        case "/timeout":
            let ms = Int(params["ms"] ?? "0") ?? 0
            rc_set_wait_ms(Int32(ms))
            return (200, ["wait_ms": ms])

        // lara 自己的内存日志（globallogger.logs）。它才是 printf 的真正归宿：
        // Logger 启动时 dup2 抢走 stdout，但在「注入进行中」它并不及时落盘，
        // 所以文件里永远缺最关键的那几行。内存里是全的。
        case "/applog":
            let n = Int(params["n"] ?? "200") ?? 200
            var all: [String] = []
            if Thread.isMainThread {
                all = globallogger.logs
            } else {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    all = globallogger.logs
                    sem.signal()
                }
                // 主线程万一被卡住也不能把 RPC 请求线程永久拖死，3 秒后放弃。
                if sem.wait(timeout: .now() + 3) == .timedOut {
                    return (200, ["count": -1, "lines": ["(applog) main thread busy"]])
                }
            }
            let tail = all.count > n ? Array(all.suffix(n)) : all
            return (200, ["count": all.count, "lines": tail])

        // 清掉卡死的 injecting 状态。改成后台线程注入之后，进程被挂起时状态会
        // 永远停在 injecting，没有这个接口就只能重启 app（还得重跑 exploit）。
        case "/reset":
            lock.lock()
            var s = injectState
            if injectState != "injecting" {
                injectState = "idle"
                injectMessage = ""
                injectProc = ""
                s = "idle"
            }
            lock.unlock()
            return (200, ["ok": true, "state": s])

        case "/inject_status":
            return (200, injectStatus())

        // 注入前的体检：目标进程在不在。微信被系统回收/从未启动时 pid 为 0，
        // 这时候强行注入必然长时间不返回（远程线程永远等不到调度）。
        case "/pid":
            guard let n = params["n"], !n.isEmpty else { return (400, ["error": "missing n"]) }
            let pid = n.withCString { find_process_pid($0) }
            return (200, ["proc": n, "pid": Int(pid), "running": pid > 0])

        // 把目标 App 拉到前台。挂起的进程没法被 RemoteCall 驱动，
        // 先 launch 再注入，命中率高得多。
        case "/launch":
            guard let b = params["b"], !b.isEmpty else { return (400, ["error": "missing b"]) }
            let ret = b.withCString { launch_app($0) }
            return (200, ["bundle": b, "ret": Int(ret)])

        // RemoteCall 一旦把目标线程用到「卡死」，那个进程就是废的：后续每次远程调用
        // 都只能等满超时。没有这个接口就只能去手机上手动上滑杀 App，而注入一旦
        // 卡住，微信界面本身就是冻的，连上滑都可能不灵。
        case "/kill":
            let name = params["n"] ?? "WeChat"
            let pid = name.withCString { find_process_pid($0) }
            guard pid > 0 else { return (200, ["proc": name, "pid": 0, "killed": false]) }
            let r = kill(pid, SIGKILL)
            log("kill \(name) pid=\(pid) ret=\(r)")
            return (200, ["proc": name, "pid": Int(pid), "killed": r == 0])

        // 杀干净再拉起来，给它一个全新的进程和全新的线程池。
        case "/relaunch":
            guard let b = params["b"], !b.isEmpty else { return (400, ["error": "missing b"]) }
            let name = params["n"] ?? "WeChat"
            let pid = name.withCString { find_process_pid($0) }
            if pid > 0 { _ = kill(pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 1.5)
            let ret = b.withCString { launch_app($0) }
            log("relaunch \(name): killed pid=\(pid) launch ret=\(ret)")
            return (200, ["bundle": b, "killedPid": Int(pid), "ret": Int(ret)])

        case "/log":
            let n = Int(params["n"] ?? "80") ?? 80
            let all = snapshotLogs()
            let tail = all.count > n ? Array(all.suffix(n)) : all
            return (200, ["lines": tail])

        case "/stop":
            stop()
            return (200, ["ok": true])

        // ---- 以下都是远程原语，必须先注入成功 ----

        case "/c", "/s", "/str", "/msg", "/msg_main", "/ui", "/rd", "/rd64":
            guard let r = currentRC() else {
                return (409, ["error": "not injected, POST /inject?proc=WeChat first",
                              "inject": injectStatus()])
            }

            // 目标进程死了就立刻作废会话。
            // 为什么必须判：远程调用把目标弄崩一次之后，_pid 还留着，所有原语都会
            // 白等 rc_wait_ms*2 才返回 0，外部看起来像"调用次数用完了"。
            //
            // 坑：不能拿 kill() 的返回值直接判。iOS 沙箱里向别的 app 发信号会被拒，
            // 返回 -1 但 errno=EPERM —— 进程明明活着。只有 ESRCH 才是"确实没有这个
            // 进程"。第一版没区分，把正常会话全废了（实测见 rc-diag.log）。
            if r.pid > 0 {
                errno = 0
                let kr = kill(r.pid, 0)
                let ke = errno
                if kr != 0 && ke == ESRCH {
                    invalidateRC("目标进程 \(r.pid) 已退出")
                    return (410, ["error": "target process gone",
                                  "pid": Int(r.pid),
                                  "hint": "POST /inject?proc=WeChat&sign=1 重新注入",
                                  "inject": injectStatus()])
                }
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

            // 带类型解读的远程调用。
            //
            // 为什么不能用 /msg：微信的字段大量返回标量（GetSessionCount 是 NSUInteger，
            // m_n64MesSvrID 是 int64，m_uiMessageType 是 uint32），而 /msg 只会把 x0
            // 当指针打出来。arm64 上这些值都在 x0 里，所以一次调用就能同时给出
            // hex / u32 / i32 / u64 / i64 五种视图，PC 侧按字段类型自取，省掉一半往返。
            // rt=s 表示返回值是 NSString，顺便读回来。
            case "/call":
                let obj = hex(params["o"])
                let sel = hex(params["s"])
                if sel == 0 { return (400, ["error": "missing s (selector address)"]) }
                let a0 = argValue(params["a0"], r)
                let a1 = argValue(params["a1"], r)
                let a2 = argValue(params["a2"], r)
                let a3 = argValue(params["a3"], r)
                let onMain = (params["main"] ?? "0") != "0"
                let ret = onMain
                    ? remote_msg_main(r, obj, sel, a0, a1, a2, a3)
                    : remote_msg(r, obj, sel, a0, a1, a2, a3)
                var out: [String: Any] = [
                    "ret": hexString(ret),
                    "u32": String(UInt32(truncatingIfNeeded: ret)),
                    "i32": String(Int32(bitPattern: UInt32(truncatingIfNeeded: ret))),
                    "u64": String(ret),
                    "i64": String(Int64(bitPattern: ret)),
                    "errno": Int(remote_errno(r)),
                ]
                if (params["rt"] ?? "") == "s" {
                    out["s"] = readNSString(ret, r) ?? ""
                }
                return (200, out)

            // 手动管理 autorelease pool。
            //
            // 这是接微信业务层的前提：我们的 trojan 线程和「被征用的主线程」都不是
            // WeChat 自己的线程，没有外层 pool。WeChat 内部大量对象以 autorelease
            // 返回，没有 pool 兜着就会一路堆到 per-process 上限被 jetsam 打死
            // （原厂 frida agent 里写着实测：poll 每次 +3.3MB，sessions 每次 +5.2MB）。
            //
            // 规矩和原厂一样：pool 里能带出来的只有 JS/PC 侧的原生值（字符串、数字），
            // 需要长期持有的对象必须先 -retain 再 pop，否则就是野指针。
            case "/pool":
                let op = params["op"] ?? "push"
                let onMain = (params["main"] ?? "0") != "0"
                let key = onMain ? "main" : "trojan"
                poolLock.lock()
                let stack = poolStack[key] ?? []
                poolLock.unlock()

                if op == "push" {
                    let cls = "NSAutoreleasePool".withCString { remote_getClass(r, $0) }
                    let selAlloc = "alloc".withCString { remote_sel(r, $0) }
                    let selInit = "init".withCString { remote_sel(r, $0) }
                    let raw = onMain
                        ? remote_msg_main(r, cls, selAlloc, 0, 0, 0, 0)
                        : remote_msg(r, cls, selAlloc, 0, 0, 0, 0)
                    let pool = onMain
                        ? remote_msg_main(r, raw, selInit, 0, 0, 0, 0)
                        : remote_msg(r, raw, selInit, 0, 0, 0, 0)
                    poolLock.lock()
                    poolStack[key] = stack + [pool]
                    let depth = stack.count + 1
                    poolLock.unlock()
                    return (200, ["ok": true, "depth": depth, "pool": hexString(pool)])
                }

                guard let pool = stack.last else {
                    return (200, ["ok": false, "error": "pool stack empty"])
                }
                let selDrain = "drain".withCString { remote_sel(r, $0) }
                poolLock.lock()
                poolStack[key] = Array(stack.dropLast())
                poolLock.unlock()
                _ = onMain
                    ? remote_msg_main(r, pool, selDrain, 0, 0, 0, 0)
                    : remote_msg(r, pool, selDrain, 0, 0, 0, 0)
                return (200, ["ok": true, "depth": stack.count - 1])

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

            // 主线程版本：UIKit 的 windows / applicationState / 视图树这些东西在
            // trojan 线程上调用会让微信进程直接消失，必须派回主线程。
            case "/msg_main":
                let obj = hex(params["o"])
                let sel = hex(params["s"])
                if sel == 0 { return (400, ["error": "missing s (selector address)"]) }
                let a0 = argValue(params["a0"], r)
                let a1 = argValue(params["a1"], r)
                let a2 = argValue(params["a2"], r)
                let a3 = argValue(params["a3"], r)
                let ret = remote_msg_main(r, obj, sel, a0, a1, a2, a3)
                return (200, ["ret": hexString(ret)])

            // 一次征用主线程拿整棵 UI 树。逐层 /msg_main 追问每次 ~0.4s，
            // 几十个节点就几十秒，没法用。详见 RemoteCall.m 里 remote_ui_dump 的说明。
            case "/ui":
                let depth = Int32(params["depth"] ?? "6") ?? 6
                let maxNodes = Int32(params["max"] ?? "200") ?? 200
                let dump = remote_ui_dump(r, depth, maxNodes) ?? ""
                let lines = dump.split(separator: "\n").count
                return (200, ["dump": dump, "lines": lines,
                              "depth": Int(depth), "max": Int(maxNodes)])

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
            return (404, ["error": "unknown path", "paths": ["/health", "/inject", "/inject_status",
                                                           "/reset", "/stdout", "/applog", "/diag", "/timeout",
                                                           "/pid", "/launch", "/log", "/stop",
                                                           "/c", "/s", "/str", "/msg", "/msg_main", "/ui", "/rd", "/rd64",
                                                           "/call", "/pool"]])
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
        // i: 前缀 = 十进制整数。必须显式标出来：不带前缀的一律按十六进制解析，
        // 所以 "10" 是 0x10。`GetSessionAtIndex:` 这类收 NSUInteger 的方法如果把
        // 十进制当十六进制传进去，就会去取第 16 个会话 —— 越界读，微信直接崩。
        if raw.hasPrefix("i:") {
            return UInt64(String(raw.dropFirst(2))) ?? 0
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

// MARK: - 启动看门狗

/// 专门用来诊断「白屏」的最小 HTTP 服务，默认 8081。
///
/// 白屏有两种完全不同的成因，在 PC 侧看起来一模一样（HTTP 超时、设备侧 socket
/// 仍在内核里 listen、三次握手还能成功），只能靠猜和重启手机：
///   A. 主线程被卡住（内核偏移解析、同步 UIKit 操作）——进程是健康的，只是 UI 死
///   B. 整个进程被系统冻结（后台挂起 / 内存压力）——SIGSTOP，什么都不会跑
///
/// 区分办法就是这里的 `/boot`：它由**独立线程**应答，同时记录主线程心跳。
/// 主线程卡住时它可以正常响应，且 `beat_age` 会持续增大（A）；
/// 进程被冻结时连它都连不上（B）。B 是系统层的事，改代码没用，只能避免触发。
///
/// 所以它在 `App.init()` 的第一行启动：不碰 UIKit、不碰 offsets、不碰 RpcServer，
/// 只依赖 Foundation 和 BSD socket。主线程再怎么卡都影响不到它。
final class BootServer {
    static let shared = BootServer()

    private var listenFD: Int32 = -1
    private var booting = false
    private var marks: [String] = []
    private let lock = NSLock()
    private var lastBeat: TimeInterval = 0
    private var bootAt: TimeInterval = 0
    private var logPath = ""
    private var actualPort: UInt16 = 0
    private var bindNote = ""

    // 下面这一整块刻意只用 POSIX，不碰 FileManager / DateFormatter / Bundle。
    //
    // v13 的实测教训：`App.init()` 里调 `FileManager.default.urls(for:.documentDirectory)`
    // 会把主线程整个卡死 —— 症状是白屏、boot.log 一次都没被创建、App.init 之后
    // 再没执行过一行代码（lara.log 停在上一次运行的 17:16 不动）。
    // getenv("HOME") 是 dyld 在进程启动时设好的，没有任何沙箱依赖，安全。
    private var bootT0: time_t = 0

    private func now() -> TimeInterval { Double(time(nil)) }

    private func ticks() -> String {
        if bootT0 == 0 { bootT0 = time(nil) }
        return "+\(Int(time(nil) - bootT0))s"
    }

    private func docPath(_ n: String) -> String {
        guard let h = getenv("HOME") else { return n }
        return String(cString: h) + "/Documents/" + n
    }

    /// 打点。同时落盘：进程万一被冻结甚至被杀，HTTP 就什么都读不到了，
    /// 只有 boot.log 能在下一次启动时告诉我上次停在哪一步。
    func mark(_ s: String) {
        let line = "[\(ticks())] \(s)"
        lock.lock()
        marks.append(line)
        if marks.count > 300 { marks.removeFirst(marks.count - 300) }
        let p = logPath
        lock.unlock()
        guard !p.isEmpty else { return }
        // 用 open/write 而不是 FileHandle：后者走 Foundation，正是要避开的东西。
        let fd = p.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        var out = line + "\n"
        out.withUTF8 { buf in
            if let base = buf.baseAddress {
                _ = Darwin.write(fd, base, buf.count)
            }
        }
        Darwin.close(fd)
    }

    /// 主线程心跳：只在主线程执行。主线程一卡心跳就停，`beat_age` 会一直涨。
    private func beat() {
        lock.lock()
        lastBeat = now()
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.beat()
        }
    }

    func startAndBeat() {
        lock.lock()
        // 已经成功监听就直接返回；上一次尝试失败（没绑上端口）时允许重试 ——
        // init 阶段环境可能还不完整，用户点 Start Server 时再起一次往往就成了。
        if booting && listenFD >= 0 { lock.unlock(); return }
        booting = true
        bootAt = now()
        logPath = docPath("boot.log")
        lock.unlock()

        mark("--- app launch ---")
        mark("build \(LARA_RPC_BUILD)")

        let t = Thread { [weak self] in self?.listenLoop() }
        t.name = "lara-boot"
        t.stackSize = 512 * 1024
        t.start()

        beat()
    }

    private func listenLoop() {
        // 8081 在个别环境下会被占（实测 v13 在这台机器上就完全没绑上），
        // 所以按顺序找一个能绑的端口，并把最终端口写进 marks / boot.log，
        // 让外部知道该连哪个。
        let candidates: [UInt16] = [8081, 18081, 9500, 9600]
        var lastErr = ""
        for p in candidates {
            if let fd = bindListen(p) {
                listenFD = fd
                actualPort = p
                bindNote = "listening \(p)"
                mark("boot: listening \(p)")
                break
            }
            lastErr = "bind \(p) errno=\(errno)"
            mark("boot: \(lastErr)")
        }
        if listenFD < 0 {
            bindNote = lastErr.isEmpty ? "no port" : lastErr
            mark("boot: 全部端口失败 \(bindNote)")
            return
        }

        let fd = listenFD
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                usleep(50_000)
                continue
            }
            autoreleasepool {
                // 同样要带超时：这个服务是诊断用的，不能因为一个挂空连接
                // 就变成新的"不响应"现场。
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                let tvl = socklen_t(MemoryLayout<timeval>.size)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, tvl)
                setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, tvl)
                serve(c)
            }
            close(c)
        }
    }

    private func bindListen(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

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
        if bound != 0 || listen(fd, 16) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// 状态快照，给 8080 的 /boot 用。
    func snapshot() -> [String: Any] {
        lock.lock()
        let ms = marks
        let b = bootAt
        let lb = lastBeat
        let p = actualPort
        let note = bindNote
        lock.unlock()
        let n = now()
        return [
            "boot_age": b > 0 ? Int(n - b) : -1,
            "beat_age": lb > 0 ? Int(n - lb) : -1,
            "port": Int(p),
            "listen": note,
            "marks": ms,
        ]
    }

    private func serve(_ c: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while total < buf.count {
            let n = read(c, &buf[total], buf.count - total)
            if n <= 0 { break }
            total += n
            if total > 4, String(decoding: buf[0..<total], as: UTF8.self).contains("\r\n\r\n") { break }
        }
        guard total > 0 else { return }

        let head = String(decoding: buf[0..<total], as: UTF8.self)
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        var path = String(parts[1])
        var query = ""
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[path.startIndex..<q])
        }
        let p = parseQuery(query)

        var out: [String: Any] = [:]
        switch path {
        case "/boot":
            lock.lock()
            let ms = marks
            let b = bootAt
            let lb = lastBeat
            lock.unlock()
            let n = now()
            out = [
                "boot_age": Int(n - b),
                "beat_age": lb > 0 ? Int(n - lb) : -1,
                "marks": ms,
            ]
        case "/log":
            let n = Int(p["n"] ?? "80") ?? 80
            out = [
                "boot": tailText(logPath, n),
                "rc_diag": tailText(docPath("rc-diag.log"), n),
                "lara": tailText(docPath("lara.log"), n),
            ]
        case "/ls":
            let d = p["p"] ?? "/"
            let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
            out = ["p": d, "items": items.sorted()]
        case "/file":
            let f = p["p"] ?? ""
            if f.isEmpty {
                out = ["error": "missing p"]
            } else {
                out = ["p": f, "lines": tailText(f, Int(p["n"] ?? "200") ?? 200)]
            }
        default:
            out = ["error": "unknown",
                   "paths": ["/boot", "/log", "/ls?p=", "/file?p=&n="]]
        }

        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var head2 = "HTTP/1.1 200 OK\r\n"
        head2 += "Content-Type: application/json; charset=utf-8\r\n"
        head2 += "Content-Length: \(data.count)\r\n"
        head2 += "Connection: close\r\n\r\n"
        var blob = Data(head2.utf8)
        blob.append(data)
        let bytes = [UInt8](blob)
        var off = 0
        while off < bytes.count {
            let w = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(c, raw.baseAddress!.advanced(by: off), bytes.count - off)
            }
            if w <= 0 { break }
            off += w
        }
    }

    private func tailText(_ path: String, _ n: Int) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 262144 ? size - 262144 : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), let s = String(data: d, encoding: .utf8) else { return [] }
        let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.count > n ? Array(lines.suffix(n)) : lines
    }

    private func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, let k = String(kv[0]).removingPercentEncoding else { continue }
            out[k] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return out
    }
}
