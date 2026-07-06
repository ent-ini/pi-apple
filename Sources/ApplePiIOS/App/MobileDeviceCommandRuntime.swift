import Foundation
import JavaScriptCore
#if canImport(UIKit)
import UIKit
#endif
import ApplePiRemote
import ApplePiCore

struct MobileDeviceScriptExecutionResult: Sendable {
    let ok: Bool
    let resultJSON: String?
    let error: String?
    let logs: [String]
}

final class MobileDeviceCommandRuntime: @unchecked Sendable {
    private let host: PiHostConfiguration
    private let token: String?
    private let onStatus: @MainActor @Sendable (String) -> Void
    private let deviceID: String
    private let deviceName: String
    private var streamTask: Task<Void, Never>?

    static let capabilities = [
        "js.fullBridge",
        "pi.device.info",
        "pi.app.info",
        "pi.net.httpText",
        "pi.clipboard.readWrite",
        "pi.log"
    ]

    @MainActor
    init(host: PiHostConfiguration, token: String?, onStatus: @escaping @MainActor @Sendable (String) -> Void) {
        self.host = host
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.onStatus = onStatus
        let storedIDKey = "ApplePiIOS.deviceCommandRuntime.deviceID"
        if let existing = UserDefaults.standard.string(forKey: storedIDKey)?.nilIfBlank {
            deviceID = existing
        } else {
            let fresh = "ios-\(Self.platformDeviceIdentifier())"
            UserDefaults.standard.set(fresh, forKey: storedIDKey)
            deviceID = fresh
        }
        deviceName = Self.platformDeviceName
    }

    deinit {
        stop()
    }

    func start() {
        guard streamTask == nil else { return }
        let host = host
        let token = token
        let deviceID = deviceID
        let deviceName = deviceName
        let onStatus = onStatus
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await RemoteDaemonClient().registerDevice(
                        host: host,
                        id: deviceID,
                        name: deviceName,
                        platform: "ios",
                        capabilities: Self.capabilities,
                        tokenOverride: token
                    )
                    await MainActor.run { onStatus("iPhone JS executor connected.") }
                    for try await job in RemoteDaemonClient().streamDeviceJobs(host: host, deviceID: deviceID, tokenOverride: token) {
                        guard !Task.isCancelled else { return }
                        await MainActor.run { onStatus("Running iPhone JS job \(job.id)…") }
                        let execution = await self?.execute(job: job) ?? MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: "runtime stopped", logs: [])
                        do {
                            _ = try await RemoteDaemonClient().submitDeviceJobResult(
                                host: host,
                                jobID: job.id,
                                ok: execution.ok,
                                resultJSON: execution.resultJSON,
                                error: execution.error,
                                logs: execution.logs,
                                tokenOverride: token
                            )
                            await MainActor.run { onStatus(execution.ok ? "iPhone JS job finished." : "iPhone JS job failed: \(execution.error ?? "unknown error")") }
                        } catch {
                            await MainActor.run { onStatus("Could not submit iPhone JS result: \(error.localizedDescription)") }
                        }
                    }
                } catch {
                    await MainActor.run { onStatus("iPhone JS executor disconnected: \(error.localizedDescription)") }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    @MainActor
    private static var platformDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    @MainActor
    private static func platformDeviceIdentifier() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }

    private func execute(job: RemoteDeviceJobRecord) async -> MobileDeviceScriptExecutionResult {
        await Task.detached(priority: .userInitiated) {
            MobileJavaScriptExecutor().run(script: job.script, timeoutSeconds: job.timeoutSeconds ?? 30)
        }.value
    }
}

@objc protocol MobilePiJSBridgeExports: JSExport {
    func log(_ message: String)
    func deviceInfo() -> NSDictionary
    func appInfo() -> NSDictionary
    func httpText(_ url: String) -> NSDictionary
    func clipboardText() -> String?
    func setClipboardText(_ text: String)
}

private final class MobilePiJSBridge: NSObject, MobilePiJSBridgeExports {
    private(set) var logs: [String] = []

    func log(_ message: String) {
        logs.append(String(message.prefix(4_000)))
    }

    func deviceInfo() -> NSDictionary {
        #if canImport(UIKit)
        let info: [String: String]
        if Thread.isMainThread {
            info = MainActor.assumeIsolated { Self.currentDeviceInfo() }
        } else {
            info = DispatchQueue.main.sync {
                MainActor.assumeIsolated { Self.currentDeviceInfo() }
            }
        }
        return info as NSDictionary
        #else
        return [
            "name": ProcessInfo.processInfo.hostName,
            "systemName": "macOS",
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": "ApplePiIOS SwiftPM host"
        ] as NSDictionary
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    private static func currentDeviceInfo() -> [String: String] {
        let device = UIDevice.current
        return [
            "name": device.name,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "model": device.model,
            "localizedModel": device.localizedModel,
            "batteryLevel": String(device.batteryLevel),
            "batteryState": String(device.batteryState.rawValue),
            "identifierForVendor": device.identifierForVendor?.uuidString ?? ""
        ]
    }
    #endif

    func appInfo() -> NSDictionary {
        let bundle = Bundle.main
        return [
            "bundleIdentifier": bundle.bundleIdentifier as Any,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as Any,
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as Any,
            "documentsDirectory": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path as Any,
            "temporaryDirectory": FileManager.default.temporaryDirectory.path
        ] as NSDictionary
    }

    func httpText(_ url: String) -> NSDictionary {
        guard let requestURL = URL(string: url) else {
            return ["ok": false, "error": "invalid URL"] as NSDictionary
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 30
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = MobileHTTPTextResponseBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            responseBox.store(data: data, response: response, error: error)
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return ["ok": false, "error": "timeout"] as NSDictionary
        }
        let snapshot = responseBox.snapshot()
        if let errorMessage = snapshot.errorMessage {
            return ["ok": false, "status": snapshot.status, "headers": snapshot.headers, "error": errorMessage] as NSDictionary
        }
        return ["ok": true, "status": snapshot.status, "headers": snapshot.headers, "text": snapshot.body] as NSDictionary
    }

    func clipboardText() -> String? {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return UIPasteboard.general.string
        }
        return DispatchQueue.main.sync { UIPasteboard.general.string }
        #else
        return nil
        #endif
    }

    func setClipboardText(_ text: String) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            UIPasteboard.general.string = text
        } else {
            DispatchQueue.main.sync { UIPasteboard.general.string = text }
        }
        #endif
    }
}

private final class MobileHTTPTextResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 0
    private var headers: [String: String] = [:]
    private var body = ""
    private var errorMessage: String?

    func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { key, value in
                (String(describing: key), String(describing: value))
            })
        }
        if let data {
            body = String(data: data.prefix(512_000), encoding: .utf8) ?? ""
        }
        if let error {
            errorMessage = error.localizedDescription
        }
    }

    func snapshot() -> (status: Int, headers: [String: String], body: String, errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (status, headers, body, errorMessage)
    }
}

private final class MobileJavaScriptExecutor {
    func run(script: String, timeoutSeconds: Int) -> MobileDeviceScriptExecutionResult {
        let bridge = MobilePiJSBridge()
        guard let context = JSContext() else {
            return MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: "Could not create JavaScript context", logs: [])
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        context.setObject(bridge, forKeyedSubscript: "__piBridge" as NSString)
        context.evaluateScript(Self.bootstrapScript)
        bridge.log("timeoutSeconds=\(timeoutSeconds)")

        let wrapped = """
        (function() {
        \(script)
        })()
        """
        let started = Date()
        let value = context.evaluateScript(wrapped)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        bridge.log("durationMs=\(durationMs)")

        if let exceptionMessage {
            return MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: exceptionMessage, logs: bridge.logs)
        }
        let resultJSON = Self.jsonString(from: value)
        return MobileDeviceScriptExecutionResult(ok: true, resultJSON: resultJSON, error: nil, logs: bridge.logs)
    }

    private static let bootstrapScript = """
    var pi = {
      log: function(message) { __piBridge.log(String(message)); },
      device: {
        info: function() { return __piBridge.deviceInfo(); }
      },
      app: {
        info: function() { return __piBridge.appInfo(); }
      },
      net: {
        httpText: function(url) { return __piBridge.httpText(String(url)); }
      },
      clipboard: {
        text: function() { return __piBridge.clipboardText(); },
        setText: function(text) { return __piBridge.setClipboardText(String(text)); }
      }
    };
    """

    private static func jsonString(from value: JSValue?) -> String {
        guard let value, !value.isUndefined else { return "null" }
        if value.isNull { return "null" }
        let object = value.toObject() ?? NSNull()
        let normalized = normalizeForJSON(object)
        if JSONSerialization.isValidJSONObject(normalized),
           let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = normalized as? String,
           let data = try? JSONEncoder().encode(string) {
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
        if let number = normalized as? NSNumber {
            return number.stringValue
        }
        return "null"
    }

    private static func normalizeForJSON(_ object: Any) -> Any {
        switch object {
        case is NSNull:
            return NSNull()
        case let value as String:
            return value
        case let value as NSNumber:
            return value
        case let value as [Any]:
            return value.map { normalizeForJSON($0) }
        case let value as NSDictionary:
            var result: [String: Any] = [:]
            for (key, rawValue) in value {
                result[String(describing: key)] = normalizeForJSON(rawValue)
            }
            return result
        case let value as [String: Any]:
            return value.mapValues { normalizeForJSON($0) }
        default:
            return String(describing: object)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
