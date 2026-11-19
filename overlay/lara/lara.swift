//
//  lara.swift
//  lara
//
//  Created by ruter on 23.03.26.
//

import SwiftUI
import UniformTypeIdentifiers
import Darwin

enum taboptions {
    case applying, tweaks, rpc, files, logs
}

/// 启动进度打点：只依赖 POSIX，不碰 Foundation，也**不碰任何 class**。
///
/// 为什么不能直接用 BootServer.shared.mark()：v15 里 `init()` 第一行就是
/// `BootServer.shared.startAndBeat()`，结果 boot.log 一次都没被创建、进程被
/// 启动 watchdog 在 20.00s 处杀掉（0x8BADF00D process-launch）。这个现象有两种
/// 解释 —— 要么 init 压根没执行，要么卡在 `static let shared` 的初始化里 ——
/// 而类静态初始化本身就可能阻塞，用它当探针等于让嫌疑人给自己作证。
/// 这个函数连类都不用，只要 getenv("HOME") 能读就落盘，所以它是可信的。
@inline(never)
func laraBootMark(_ s: String) {
    // 先走 syslog。文件写不出来的情况下（沙箱没就绪、HOME 不对、open 被拦），
    // NSLog 仍然会进系统日志，而 syslog 是我们在 PC 上能 100% 抓到的通道 ——
    // 前面几轮的所有结论都卡在"到底有没有执行到 init"这一点上，不能再只靠文件。
    NSLog("[lara-boot] %@", s)

    guard let h = getenv("HOME") else { return }
    let path = String(cString: h) + "/Documents/boot.log"
    let fd = path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
    if fd < 0 { return }
    var line = "[\(Int(time(nil)))] \(s)\n"
    line.withUTF8 { buf in
        if let base = buf.baseAddress { _ = Darwin.write(fd, base, buf.count) }
    }
    Darwin.close(fd)
}

let g_isunsupported: Bool = isunsupported()

// 顶层 var 的初始化器在 **dyld 阶段**（main 之前）执行，这是唯一能在
// `App.init()` 之前落一笔的地方。有它才能把两种完全不同的死法分开：
//   syslog 里有 00 → 我们的二进制已被加载执行，问题在 main/init 里
//   连 00 都没有 → 卡在加载我们之前（Swift 运行时 / UIKit / 签名校验）
var weonadebugbuild_pjbweouttahereexclamationmark: Bool = {
    laraBootMark("00 dyld global init")
    return false
}()

@main
struct lara: App {
    @StateObject private var mgr = laramgr.shared
    @StateObject private var iconthememgr = IconThemeManager.shared
    @Environment(\.scenePhase) var scenephase
    @AppStorage("selectedMethod") private var selectedMethod: method = .hybrid
    @AppStorage("keepAlive") private var keepalive: Bool = false
    @AppStorage("showFMInTabs") private var showfmintabs: Bool = true
    @AppStorage("logsdisplaymode") private var logsdisplaymode: logsdisplaymode = .toolbar
    @State private var selectedtab: taboptions = .applying
    
    init() {
        // 每句都落盘。首帧之前只有这几行会跑，白屏时就靠 boot.log 判断停在哪。
        laraBootMark("01 init enter")

        #if DEBUG
        weonadebugbuild_pjbweouttahereexclamationmark = true
        #endif
        laraBootMark("02 debug flag")

        // fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)
        laraBootMark("03 filepicker hooked")

        if keepalive {
            // keepalive 的 toggleka() 会激活 AVAudioSession（setCategory + setActive）。
            // 这一步需要 app 已完成启动、能和 mediaserverd 通信，放在 init（main 之前）
            // 会一直阻塞到 process-launch watchdog 的 20 秒上限，然后被 kill(9) ——
            // 表现就是白屏、无任何日志、重启手机才恢复。
            // 现在改成首帧之后再做（见 body 里的 onAppear），启动路径上一个内核/音频
            // 操作都不留。
            laraBootMark("04 toggleka deferred")
        }

        globallogger.capture()
        laraBootMark("06 capture done")

        // 看门狗放到 init 最后：它要起线程 + 绑端口，万一这步有问题，
        // 前面 01~06 已经把"init 本身是活的"这件事证明掉了。
        laraBootMark("07 bootserver begin")
        BootServer.shared.startAndBeat()
        laraBootMark("08 init done")
    }
    
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedtab) {
                ContentView()
                    .tabItem {
                        Image(systemName: "wrench.and.screwdriver.fill")
                    }
                    .tag(taboptions.applying)
                
                // this has gotta fucking go
                TweaksView(mgr: mgr)
                    .tabItem {
                        Image(systemName: "ant.fill")
                    }
                    .tag(taboptions.tweaks)

                // WeChat RPC：把当前会话变成一个可被 PC 驱动的微信节点。
                // 单独开一个页签而不是塞进主页，是为了让上游文件的改动只有这三处，
                // 以后跟新版 lara 合并时冲突面最小。
                RpcView()
                    .tabItem {
                        Image(systemName: "network")
                    }
                    .tag(taboptions.rpc)

                
                
                // i'm gonna strangle you root (the weight of your actions will crush you)
                if showfmintabs {
                    SantanderView(startPath: "/")
                        .tabItem {
                            Image(systemName: "folder.fill")
                        }
                        .tag(taboptions.files)
                }
                
                // this too
                if logsdisplaymode == .tabs {
                    LogsView(logger: globallogger)
                        .tabItem {
                            Image(systemName: "terminal")
                        }
                        .tag(taboptions.logs)
                }
            }
            .environmentObject(mgr)
            .overlay {
                if mgr.showrespring {
                    respringview()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                }
            }
            .sheet(isPresented: Binding(
                get: { logsdisplaymode == .toolbar && mgr.showLogs },
                set: { mgr.showLogs = $0 }
            )) {
                LogsView(logger: globallogger)
            }
            .sheet(isPresented: $iconthememgr.showFixupSheet) {
                IconThemeFixupView()
            }
            .onAppear {
                laraBootMark("10 view onAppear")
                BootServer.shared.mark("view onAppear")

                // 保活音频推迟到首帧之后。启动阶段激活 AVAudioSession 会阻塞到
                // 20 秒 watchdog（见 init 里的注释），这里已经出了首帧，安全。
                if keepalive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        laraBootMark("11 toggleka begin")
                        toggleka()
                        laraBootMark("12 toggleka end")
                    }
                }
                if !isunsupported() {
                    // 内核偏移解析原来直接在主线程同步跑。它要扫 kernelcache 的符号表，
                    // 正常几百毫秒，异常时可能长时间不返回 —— 主线程一卡就是白屏：
                    // UI 停在最后一帧、RPC 也不响应，现象和「进程被系统冻结」一模一样，
                    // 只能靠重启手机恢复。挪到后台后，慢只是功能晚点可用，不会整屏白。
                    DispatchQueue.global(qos: .userInitiated).async {
                        BootServer.shared.mark("offsets begin")
                        init_offsets()
                        offsets_init()
                        BootServer.shared.mark("offsets done")
                        DispatchQueue.main.async {
                            BootServer.shared.mark("offsets applied")
                            iconthememgr.startPendingFixupIfPossible()
                            // beautiful name root
                            // thanks
                            mgr.hasOffsets = emergencyfixfunctiontobereplacedlateronquestionmark()
                            BootServer.shared.mark("hasOffsets=\(mgr.hasOffsets)")

                            // v18: 自动把 darksword exploit 跑起来，然后自己接管 RPC 监听。
                            //
                            // 为什么必须自动：上游把 ds_run() 只挂在 UI 按钮上，而 RPC 页的
                            // Start Server 又用 .disabled(!mgr.dsready) 卡着 —— 不点 exploit
                            // 就没有内核读写，没有 RPC 就没法远程去点那个按钮，直接死锁。
                            // 这台设备是要当常驻节点的，没人会守着屏幕点，所以只能自己爬。
                            //
                            // RPC 的启动放在 ok 判断之外：exploit 失败时 dsready 为 false，
                            // 注入类接口不能用，但 /health /boot 这类仍在进程内的接口照样
                            // 有价值（能远程看到它活着、卡在哪一步）。宁可用一半，也别全哑。
                            if mgr.hasOffsets && !mgr.dsattempted {
                                BootServer.shared.mark("auto exploit begin")
                                laraBootMark("13 auto exploit begin")
                                // 让 UI 先出首帧再动内核，避免和启动期的东西抢主线程。
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    mgr.run { ok in
                                        laraBootMark("14 exploit done ok=\(ok) dsready=\(mgr.dsready)")
                                        BootServer.shared.mark("auto exploit done ok=\(ok) dsready=\(mgr.dsready)")
                                        guard !RpcServer.shared.isRunning else { return }
                                        let s = RpcServer.shared.start(port: 8080)
                                        laraBootMark("15 rpc start: \(s)")
                                        BootServer.shared.mark("auto rpc: \(s)")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Alertinator.shared.alert(title: "This device is not supported!", body: "We apologize, but this device is currently not supported by Lara. Possible reasons: \n- You are on an unsupported iOS version (Supported: iOS 16.0 - iOS 18.7.1, iOS 26.0 - iOS 26.0.1) \n- Your device has MIE (A19+ or M5+) \n- A debugger is attached.", actionLabel: "Exit App", action: { exitinator() })
                }
            }
            .onChange(of: scenephase, perform: handleScenePhase)
            .onChange(of: mgr.sbxready) { ready in
                if ready {
                    iconthememgr.startPendingFixupIfPossible()
                }
            }
        }
    }
    
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            handlebg()
            globallogger.stopcapture()

        case .active:
            globallogger.capture()
            iconthememgr.startPendingFixupIfPossible()

        @unknown default:
            break
        }
    }

    private func handlebg() {
        guard mgr.rcready else { return }
        let keepSpringBoardRemoteCallAlive = UserDefaults.standard.bool(forKey: "keepSpringBoardRemoteCallAliveIOS16")
        if isIOS16() && keepSpringBoardRemoteCallAlive {
            return
        }

        // 上游默认行为是进后台就销毁会话。对常驻节点来说这是致命的：
        // 锁屏 = 会话没了 = 收不到消息。所以 HTTP 服务在跑时不做销毁，
        // 由 RpcServer 那边的静音保活 + 禁止自动锁屏来维持进程存活。
        if RpcServer.shared.isRunning {
            globallogger.log("(rpc) 常驻模式：跳过 RemoteCall 销毁")
            return
        }

        var bgTask: UIBackgroundTaskIdentifier = .invalid

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "RemoteCallCleanup") {
            endbgtask(&bgTask)
        }

        mgr.rcdestroy {
            self.endbgtask(&bgTask)
        }
    }

    private func endbgtask(_ task: inout UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

// file picker fixes
extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

// make strings compatiable with errors
extension String: @retroactive Error {}
