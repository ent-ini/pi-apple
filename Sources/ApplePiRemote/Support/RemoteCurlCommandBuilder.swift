import Foundation
import ApplePiCore

/// Builds the curl command shown in the Remote API section of the
/// settings view. The redacted form is always safe to render in the
/// UI; the full form embeds the user's stored bearer token and is
/// only ever copied to the clipboard after a confirm dialog.
package enum RemoteCurlCommandBuilder {
    /// The shell variable name used as the bearer-token placeholder
    /// in the redacted form. Keeping it as a constant makes it easy
    /// to detect in tests and to update in one place.
    package static let redactionToken = "$APPLEPI_TOKEN"

    /// Health-check path appended to the configured base URL.
    package static let healthzPath = "healthz"

    /// Returns the redacted curl command for `host`. The bearer
    /// token is replaced with `redactionToken`, so the result is safe
    /// to render in the UI or copy to the clipboard without leaking
    /// a secret. Returns `nil` when the host has no usable base URL.
    package static func redacted(host: PiHostConfiguration) -> String? {
        guard let url = healthzURL(for: host) else { return nil }
        return "curl -H \"Authorization: Bearer \(redactionToken)\" \(url.absoluteString.shellQuoted)"
    }

    /// Returns the full curl command for `host`, embedding `token`
    /// verbatim in the `Authorization` header. The caller is
    /// responsible for confirming with the user before copying this
    /// string to the clipboard. Returns `nil` when the host has no
    /// usable base URL.
    package static func full(host: PiHostConfiguration, token: String) -> String? {
        guard let url = healthzURL(for: host) else { return nil }
        return "curl -H \"Authorization: Bearer \(token.shellQuoted)\" \(url.absoluteString.shellQuoted)"
    }

    /// Whether `command` embeds a bearer token in plain text. Used
    /// by the test suite (and any future audit tooling) to assert
    /// that no UI surface renders the secret form by default.
    package static func containsPlaintextToken(_ command: String) -> Bool {
        // The redacted form always references the redaction token;
        // any other `Bearer …` header is a plaintext secret and
        // should never reach the UI.
        guard let range = command.range(of: "Authorization: Bearer ") else { return false }
        let suffix = String(command[range.upperBound...])
        return !suffix.hasPrefix(redactionToken)
    }

    private static func healthzURL(for host: PiHostConfiguration) -> URL? {
        host.remoteDaemonBaseURL?.appending(path: healthzPath)
    }
}
