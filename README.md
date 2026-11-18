# lara-rpc

给 [lara](https://github.com/rooootdev/lara)（iOS 17.0–18.7.1 的 DarkSword 内核读写工具）加一层
**HTTP RPC**，目的是把一台不能完整越狱的 iPhone 上的微信，变成一个可被 PC 远程驱动的消息节点。

配合 `wechat-hub` 的 `drivers/iosrpc.py` 使用。

## 为什么需要它

iOS 18.5 + A14 没有完整越狱，挂不了 frida gadget，所以拿不到 TK9 那套接入方式。
但 lara 能拿到内核读写，而它内置的 `RemoteCall` 已经能把 `objc_msgSend` 打到别的进程里。
缺的只是一个「从 PC 侧调用」的入口 —— 这个仓库就是那个入口。

## 为什么只给原语

暴露的是六个最小原语，不是封装好的 `/send_text`：

| 端点 | 作用 |
|---|---|
| `GET /health` | 内核读写状态、内核基址、注入目标 |
| `GET /inject?proc=WeChat` | 在目标进程建立 RemoteCall 会话 |
| `GET /c?n=<类名>` | `NSClassFromString`，返回类地址 |
| `GET /s?n=<选择子>` | `sel_registerName`，返回 SEL 地址 |
| `GET /str?t=<文本>` | 在远程进程分配 NSString，返回地址 |
| `GET /msg?o=&s=&a0=&a1=&a2=&a3=` | `objc_msgSend`，参数可用 `str:文本` 简写 |
| `GET /rd?p=<地址>` | 读回远程 NSString 的值 |
| `GET /rd64?p=<地址>` | 读 8 字节 |

微信 8.0.79 的类名和选择子没有权威文档，封装成高层接口等于把猜测固化进二进制，
试错一次就要重编、重签、重装。原语式接口可以一次装机、无限次实验。

## 编译

仓库本身不含 lara 源码，CI 在 `macos-26` 上 clone 上游再贴 `overlay/` 里的补丁：

```
on push → clone rooootdev/lara@main → cp -R overlay/. src/ → xcodebuild → ldid → zip
        → 发布 Release（IPA 可直接匿名下载）
```

失败时会把完整 `xcodebuild.log` 提交回 `logs/`，因为在 Actions 网页之外没有别的读日志途径。

换上游版本：改 `UPSTREAM_REF`（workflow_dispatch 里有输入框）。

> 注意：不要 pin 到 `tag 0.2`。那个 tag 的树里 `RemoteCall` 只有 `destroyRemoteCall`，
> 而调用方写的是 `destroy()`，与 `main` 不一致；`main` 的 HEAD 有 CI 成功记录，`0.2` 没有。

## 装机后

1. lara 主页点 `Run Exploit` → `Initialize System`
2. 切到 `WeChat RPC` 页签 → `Inject RemoteCall`（目标 `WeChat`）
3. `Start Server`（默认 8080）
4. PC 上 `curl http://<手机IP>:8080/health`

`Start Server` 会同时打开静音保活（利用 `UIBackgroundModes: audio`）并禁止自动锁屏，
并让 `handlebg()` 不再销毁 RemoteCall 会话 —— 上游默认锁屏就销毁，对常驻节点是致命的。

## 已知限制

- 整个 HTTP 服务是单线程串行处理，因为 `RemoteCall` 本身不是线程安全的。轮询级别的频率够用。
- `RemoteCall` 上游自述「relatively unstable」；会话是内存态，App 被杀即失效。
- 免费证书 7 天过期，过期后需要重签重装，会话全部重建。
