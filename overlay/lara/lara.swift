//
//  lara.swift
//  lara
//
//  Created by ruter on 23.03.26.
//

import SwiftUI
import UniformTypeIdentifiers

enum taboptions {
    case applying, tweaks, rpc, files, logs
}

let g_isunsupported: Bool = isunsupported()
var weonadebugbuild_pjbweouttahereexclamationmark: Bool = false

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
        // 第一件事就先起看门狗，早于任何可能阻塞的初始化。
        // 白屏时整个 RPC 服务都不响应，只有它能告诉我主线程到底卡在哪一步
        // （独立线程应答 + 主线程心跳，见 RpcServer.swift 里的 BootServer）。
        BootServer.shared.startAndBeat()

        #if DEBUG
        weonadebugbuild_pjbweouttahereexclamationmark = true
        #endif
        
        // fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)
        
        if keepalive {
            toggleka()
        }
        
        globallogger.capture()
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
                BootServer.shared.mark("view onAppear")
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
