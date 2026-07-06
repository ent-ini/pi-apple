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
    private let deviceInfoSnapshot: [String: String]
    private var streamTask: Task<Void, Never>?

    static let runtimeVersion = "device-js.v6-polling-jobs"

    static let capabilities = [
        runtimeVersion,
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
        deviceInfoSnapshot = Self.platformDeviceInfoSnapshot()
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
            var handledJobIDs = Set<String>()
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
                    while !Task.isCancelled {
                        let jobs = try await RemoteDaemonClient().loadDeviceJobs(host: host, deviceID: deviceID, tokenOverride: token)
                        for job in jobs where !handledJobIDs.contains(job.id) {
                            handledJobIDs.insert(job.id)
                            guard !Task.isCancelled else { return }
                            await MainActor.run { onStatus("Running iPhone JS job \(job.id)…") }
                            let execution = await self?.execute(job: job) ?? MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: "runtime stopped", logs: [])
                            await MainActor.run { onStatus("Finished iPhone JS job \(job.id), submitting result…") }
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
                        try await Task.sleep(for: .seconds(2))
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
        platformDeviceInfoSnapshot()["name"] ?? "iPhone"
    }

    @MainActor
    private static func platformDeviceIdentifier() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }

    @MainActor
    private static func platformDeviceInfoSnapshot() -> [String: String] {
        #if canImport(UIKit)
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
        #else
        return [
            "name": ProcessInfo.processInfo.hostName,
            "systemName": "macOS",
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": "ApplePiIOS SwiftPM host"
        ]
        #endif
    }

    private func execute(job: RemoteDeviceJobRecord) async -> MobileDeviceScriptExecutionResult {
        let timeoutSeconds = job.timeoutSeconds ?? 30
        if let direct = MobileJavaScriptExecutor.directReturnResultIfPossible(job.script) {
            return MobileDeviceScriptExecutionResult(
                ok: true,
                resultJSON: direct,
                error: nil,
                logs: ["timeoutSeconds=\(timeoutSeconds)", "directReturnFallback=true"]
            )
        }
        // JavaScriptCore on iOS should be driven from the app's main actor.
        // Jobs are trusted and short-lived, so blocking the UI briefly is an
        // acceptable MVP trade-off and avoids background-executor hangs.
        return await MainActor.run {
            MobileJavaScriptExecutor(deviceInfo: deviceInfoSnapshot).run(
                script: job.script,
                timeoutSeconds: timeoutSeconds
            )
        }
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
    private let deviceInfoSnapshot: [String: String]

    init(deviceInfo: [String: String]) {
        deviceInfoSnapshot = deviceInfo
        super.init()
    }

    func log(_ message: String) {
        logs.append(String(message.prefix(4_000)))
    }

    func deviceInfo() -> NSDictionary {
        deviceInfoSnapshot as NSDictionary
    }

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
    private let deviceInfo: [String: String]

    init(deviceInfo: [String: String]) {
        self.deviceInfo = deviceInfo
    }

    func run(script: String, timeoutSeconds: Int) -> MobileDeviceScriptExecutionResult {
        var logs = ["timeoutSeconds=\(timeoutSeconds)"]
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            return MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: "Could not create JavaScript context", logs: logs)
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        context.evaluateScript(Self.bootstrapScript(deviceInfo: deviceInfo, appInfo: Self.currentAppInfo()))

        let wrapped = """
        (function() {
        \(script)
        })()
        """
        let started = Date()
        let value = context.evaluateScript(wrapped)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        logs.append("durationMs=\(durationMs)")
        if let jsLogs = context.objectForKeyedSubscript("__piLogs")?.toArray() as? [Any] {
            logs.append(contentsOf: jsLogs.map { String(describing: $0).prefixString(4_000) })
        }

        if let exceptionMessage {
            return MobileDeviceScriptExecutionResult(ok: false, resultJSON: nil, error: exceptionMessage, logs: logs)
        }
        let resultJSON = Self.jsonString(from: value)
        return MobileDeviceScriptExecutionResult(ok: true, resultJSON: resultJSON, error: nil, logs: logs)
    }

    private static func bootstrapScript(deviceInfo: [String: String], appInfo: [String: String]) -> String {
        let deviceJSON = jsonLiteral(deviceInfo)
        let appJSON = jsonLiteral(appInfo)
        return """
        var __piLogs = [];
        var pi = {
          log: function(message) { __piLogs.push(String(message)); },
          device: {
            info: function() { return \(deviceJSON); }
          },
          app: {
            info: function() { return \(appJSON); }
          },
          net: {
            httpText: function(url) { throw new Error("pi.net.httpText is not available in this MVP build yet"); }
          },
          clipboard: {
            text: function() { return null; },
            setText: function(text) { throw new Error("pi.clipboard.setText is not available in this MVP build yet"); }
          }
        };
        """
    }

    private static func currentAppInfo() -> [String: String] {
        let bundle = Bundle.main
        return [
            "bundleIdentifier": bundle.bundleIdentifier ?? "",
            "version": String(describing: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""),
            "build": String(describing: bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""),
            "documentsDirectory": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "",
            "temporaryDirectory": FileManager.default.temporaryDirectory.path
        ]
    }

    private static func jsonLiteral(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func directReturnResultIfPossible(_ script: String) -> String? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("return "), trimmed.hasSuffix(";") else { return nil }
        let expression = String(trimmed.dropFirst("return ".count).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if Double(expression) != nil { return expression }
        if expression == "true" || expression == "false" || expression == "null" { return expression }
        if (expression.hasPrefix("\"") && expression.hasSuffix("\"")) || (expression.hasPrefix("'") && expression.hasSuffix("'")) {
            let unquoted = String(expression.dropFirst().dropLast())
            if let data = try? JSONEncoder().encode(unquoted) {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

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

private extension StringProtocol {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
