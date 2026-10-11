import Foundation
import Network

/// 最小化的「仅回环」静态文件 HTTP 服务。
///
/// 为什么要它：解包出来的游戏是一套纯静态网页（Egret H5），它用
/// `fetch('/data/xxx.json')` 和 `XMLHttpRequest` 同源取数据，并用
/// `localStorage` 存档。在 WKWebView 里用 `file://` 打开会被 CORS / 同源策略
/// 直接挡死（origin 为 null，fetch 一律失败），所以必须给它一个**真正的
/// HTTP 源**。
///
/// 这正是 Android 端 `MainActivity$AssetServer` 做的事（那边用的是
/// `https://appassets.worldol.local` 虚拟主机 + `shouldInterceptRequest`）。
/// iOS 上等价且兼容性最好的做法，就是在 127.0.0.1 上起一个真实的 HTTP 服务。
final class LocalHTTPServer {

    private let root: URL
    private let queue = DispatchQueue(label: "com.worldol.httpserver", qos: .userInitiated)
    private var listener: NWListener?

    /// 实际监听到的端口。
    private(set) var port: UInt16 = 0

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm":  "text/html; charset=utf-8",
        "js":   "text/javascript; charset=utf-8",
        "mjs":  "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "css":  "text/css; charset=utf-8",
        "txt":  "text/plain; charset=utf-8",
        "md":   "text/plain; charset=utf-8",
        "b64":  "text/plain; charset=utf-8",
        "xml":  "application/xml; charset=utf-8",
        "exml": "text/xml; charset=utf-8",
        "png":  "image/png",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "gif":  "image/gif",
        "webp": "image/webp",
        "svg":  "image/svg+xml",
        "ico":  "image/x-icon",
        "mp3":  "audio/mpeg",
        "ogg":  "audio/ogg",
        "wav":  "audio/wav",
        "mp4":  "video/mp4",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf":  "font/ttf",
        "otf":  "font/otf",
        "wasm": "application/wasm",
        "bin":  "application/octet-stream",
        "zip":  "application/zip",
        "atlas": "text/plain; charset=utf-8",
        "fnt":  "text/plain; charset=utf-8",
    ]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - 生命周期

    func start(preferredPort: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        // 只绑定回环地址，避免把 307MB 的游戏资源暴露到局域网上。
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: preferredPort) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            // 回退：个别系统版本不允许为 listener 指定 requiredLocalEndpoint。
            // 退化成普通监听，respond() 里用 Host 头挡掉非本机请求。
            let fallback = NWParameters.tcp
            fallback.allowLocalEndpointReuse = true
            fallback.includePeerToPeer = false
            listener = try NWListener(using: fallback, on: .any)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?

        // listener 持有 stateUpdateHandler，闭包又引用 listener，会成环；
        // 这里弱引用打破它，避免 stop() 之后 listener 无法释放。
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.port = listener?.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 8)

        if let failure = failure {
            listener.cancel()
            self.listener = nil
            throw failure
        }
        if port == 0 {
            listener.cancel()
            self.listener = nil
            throw NSError(domain: "WorldOL.HTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本地资源服务启动失败：未获得可用端口"])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(on: connection, buffer: Data())
    }

    /// 只处理 GET/HEAD：这个游戏的所有请求都是无 body 的静态资源请求。
    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }

            var accumulated = buffer
            if let chunk = chunk { accumulated.append(chunk) }

            let terminator = Data("\r\n\r\n".utf8)
            if let range = accumulated.range(of: terminator) {
                let headerData = accumulated.subdata(in: 0..<range.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                self.respond(on: connection, requestHeader: headerText)
                return
            }

            // 头部异常长 / 连接中断，直接放弃。
            if isComplete || error != nil || accumulated.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receiveHeader(on: connection, buffer: accumulated)
        }
    }

    private func respond(on connection: NWConnection, requestHeader: String) {
        let lines = requestHeader.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { connection.cancel(); return }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(connection, status: 405, reason: "Method Not Allowed",
                 contentType: "text/plain; charset=utf-8", body: Data("405".utf8))
            return
        }

        // 拒绝非本机 Host，双保险（listener 本身已只绑回环）。
        if let hostLine = lines.first(where: { $0.lowercased().hasPrefix("host:") }) {
            let host = hostLine.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            let allowed = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") || host.hasPrefix("[::1]")
            if !allowed {
                send(connection, status: 403, reason: "Forbidden",
                     contentType: "text/plain; charset=utf-8", body: Data("403".utf8))
                return
            }
        }

        var rawPath = String(parts[1])
        if let queryIndex = rawPath.firstIndex(of: "?") {
            rawPath = String(rawPath[rawPath.startIndex..<queryIndex])
        }
        if let fragmentIndex = rawPath.firstIndex(of: "#") {
            rawPath = String(rawPath[rawPath.startIndex..<fragmentIndex])
        }
        let decoded = rawPath.removingPercentEncoding ?? rawPath

        guard let fileURL = resolve(path: decoded) else {
            send(connection, status: 404, reason: "Not Found",
                 contentType: "text/plain; charset=utf-8", body: Data("404 Not Found: \(decoded)".utf8))
            return
        }

        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            send(connection, status: 500, reason: "Internal Server Error",
                 contentType: "text/plain; charset=utf-8", body: Data("500".utf8))
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        let contentType = LocalHTTPServer.mimeTypes[ext] ?? "application/octet-stream"

        if method == "HEAD" {
            send(connection, status: 200, reason: "OK", contentType: contentType, body: Data())
        } else {
            send(connection, status: 200, reason: "OK", contentType: contentType, body: data)
        }
    }

    /// 把 URL 路径映射到 bundle 内的真实文件，并挡住目录穿越。
    private func resolve(path: String) -> URL? {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "client/standalone.html" }
        relative = relative.replacingOccurrences(of: "\\", with: "/")

        let rootPath = root.path
        var candidate = root
        for component in relative.split(separator: "/") {
            let name = String(component)
            if name.isEmpty || name == "." { continue }
            if name == ".." { return nil }
            candidate.appendPathComponent(name)
        }
        candidate = candidate.standardizedFileURL

        // 最终路径必须仍在 root 之内。
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) { return index }
            return nil
        }
        return candidate
    }

    // MARK: - 响应写出

    private func send(_ connection: NWConnection,
                      status: Int,
                      reason: String,
                      contentType: String,
                      body: Data) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        write(connection, payload)
    }

    /// 分块写出，避免一次把 30MB 的 JSON 全塞进 send。
    private func write(_ connection: NWConnection, _ data: Data) {
        let chunkSize = 1 << 20
        var offset = 0

        func sendNextChunk() {
            guard offset < data.count else {
                connection.cancel()
                return
            }
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            offset = end
            let isLast = offset >= data.count
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { connection.cancel(); return }
                if isLast { connection.cancel(); return }
                sendNextChunk()
            })
        }

        if data.isEmpty {
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        sendNextChunk()
    }
}
