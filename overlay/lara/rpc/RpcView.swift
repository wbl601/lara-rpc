//
//  RpcView.swift
//  lara
//
//  独立页签：把当前的 lara 会话变成一个可被 PC 驱动的微信节点。
//  刻意不塞进 ContentView —— 那文件上游改得最勤，我们少改一行，
//  以后 rebase 到新版 lara 时冲突面就小一行。
//

import SwiftUI

struct RpcView: View {
    @EnvironmentObject private var mgr: laramgr

    @AppStorage("rpcProcess") private var procname: String = "WeChat"
    @AppStorage("rpcPort") private var portstring: String = "8080"

    @State private var status: String = ""
    @State private var logtext: String = ""
    @State private var timer: Timer?
    @State private var injectline: String = "-"
    @State private var injectcolor: Color = .secondary

    private var server: RpcServer { RpcServer.shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("kernel r/w") {
                        Text(mgr.dsready ? "ready" : "not ready")
                            .foregroundColor(mgr.dsready ? .green : .red)
                    }
                    LabeledContent("sandbox escape") {
                        Text(mgr.sbxready ? "ready" : "not ready")
                            .foregroundColor(mgr.sbxready ? .green : .orange)
                    }
                    LabeledContent("target") {
                        Text(server.targetDescription)
                            .font(.system(.footnote, design: .monospaced))
                    }
                    LabeledContent("inject") {
                        Text(injectline)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(injectcolor)
                    }
                } header: {
                    Text("Prerequisites")
                } footer: {
                    Text("RemoteCall 必须先初始化成功才能注入第三方进程。若 kernel r/w 未就绪，回到主页点 Run Exploit 和 Initialize System。")
                }

                Section {
                    TextField("process name", text: $procname)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Inject RemoteCall") {
                        // 立刻返回，注入在后台线程做。上一版这里是同步调用，
                        // 微信处于挂起态时会把主线程钉死 → watchdog → 整机重启。
                        status = server.beginInject(procname.trimmingCharacters(in: .whitespaces))
                        refresh()
                    }
                    .disabled(!mgr.dsready)
                } header: {
                    Text("Target process")
                } footer: {
                    Text("微信的可执行文件名通常是 WeChat。Injectable 之后 /c /s /str /msg 这些原语才有意义。")
                }

                Section {
                    TextField("port", text: $portstring)
                        .keyboardType(.numberPad)
                    HStack {
                        Text("state")
                        Spacer()
                        Text(server.isRunning ? "listening" : "stopped")
                            .foregroundColor(server.isRunning ? .green : .secondary)
                    }
                    if server.isRunning {
                        Button("Stop Server", role: .destructive) {
                            server.stop()
                            refresh()
                        }
                    } else {
                        Button("Start Server") {
                            let p = UInt16(portstring) ?? 8080
                            status = server.start(port: p)
                            refresh()
                        }
                        .disabled(!mgr.dsready)
                    }
                } header: {
                    Text("HTTP endpoint")
                } footer: {
                    Text("启动时会同时打开静音保活并禁止自动锁屏。生效后 PC 上执行 curl http://<手机IP>:\(portstring)/health 。")
                }

                if !status.isEmpty {
                    Section {
                        Text(status)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text("Last result")
                    }
                }

                Section {
                    ScrollView {
                        Text(logtext.isEmpty ? "—" : logtext)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 220)
                } header: {
                    Text("RPC log")
                }
            }
            .navigationTitle("WeChat RPC")
            .onAppear {
                refresh()
                timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    refresh()
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private func refresh() {
        logtext = (server.tailLog(40)).joined(separator: "\n")

        let st = server.injectStatus()
        let state = (st["state"] as? String) ?? "idle"
        let msg = (st["message"] as? String) ?? ""
        let elapsed = (st["elapsed"] as? Int) ?? 0

        switch state {
        case "ready":
            injectline = "ready \(msg)"
            injectcolor = .green
        case "injecting":
            // 超过 45 秒基本可以判定目标进程没在跑，不需要继续等
            injectline = elapsed > 45 ? "stuck \(elapsed)s — target 可能已挂起" : "injecting… \(elapsed)s"
            injectcolor = elapsed > 45 ? .orange : .blue
        case "failed":
            injectline = "failed \(msg)"
            injectcolor = .red
        default:
            injectline = "idle"
            injectcolor = .secondary
        }
    }
}
