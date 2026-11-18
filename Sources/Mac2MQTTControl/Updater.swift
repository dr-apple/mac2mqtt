import AppKit
import Foundation

/// Neueste Version aus den GitHub-Releases.
struct ReleaseInfo: Sendable {
    let version: String
    let zipURL: URL
    let pageURL: URL
    let notes: String
}

enum UpdateError: LocalizedError {
    case noZip
    case badResponse(Int)
    case invalidBundle(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noZip: return "Im Release fehlt Mac2MQTT.zip."
        case .badResponse(let code): return "GitHub antwortet mit Status \(code)."
        case .invalidBundle(let why): return "Heruntergeladene App ist ungültig: \(why)"
        case .installFailed(let why): return "Installation fehlgeschlagen: \(why)"
        }
    }
}

/// Sucht auf GitHub nach neuen Versionen und tauscht die App aus.
/// Ablauf: Release-Zip laden -> entpacken -> Bundle prüfen -> kleines Skript wartet, bis diese App
/// beendet ist, ersetzt das Bundle und startet es neu. Die neue App bringt beim Start den Dienst
/// (mac2mqttd + Now-Playing-Helfer) selbst auf ihren Stand (siehe syncRuntimeIfBundleChanged).
enum Updater {
    static let repo = "dr-apple/mac2mqtt"
    static let assetName = "Mac2MQTT.zip"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "0.13" > "0.12", "0.12.1" > "0.12"; ein führendes "v" wird ignoriert.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mac2MQTT-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let tag = json["tag_name"] as? String ?? "0"
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = zip["browser_download_url"] as? String,
              let url = URL(string: urlString) else { throw UpdateError.noZip }
        let page = URL(string: json["html_url"] as? String ?? "https://github.com/\(repo)/releases")!
        return ReleaseInfo(version: tag, zipURL: url, pageURL: page, notes: json["body"] as? String ?? "")
    }

    /// Lädt, prüft und installiert die Version. Beendet bei Erfolg diese App (das Skript startet die neue).
    @MainActor
    static func install(_ release: ReleaseInfo) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mac2mqtt-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let zip = work.appendingPathComponent(assetName)
        try fm.moveItem(at: downloaded, to: zip)

        let unpacked = work.appendingPathComponent("neu")
        let (code, out) = run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard code == 0 else { throw UpdateError.installFailed("Entpacken: \(out)") }
        let newApp = unpacked.appendingPathComponent("Mac2MQTT.app")

        // Prüfen: gleiche App, neuere Version, Dienst und Helfer enthalten
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("Info.plist fehlt")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("andere Bundle-ID")
        }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(newVersion, than: currentVersion) else {
            throw UpdateError.invalidBundle("Version \(newVersion) ist nicht neuer als \(currentVersion)")
        }
        for file in ["Contents/MacOS/mac2mqtt-ui", "Contents/Resources/mac2mqttd"] {
            guard fm.fileExists(atPath: newApp.appendingPathComponent(file).path) else {
                throw UpdateError.invalidBundle("\(file) fehlt")
            }
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.installFailed("Keine Schreibrechte für \(target.deletingLastPathComponent().path)")
        }

        // Austausch erst, wenn diese App beendet ist; bei Fehler alte App zurücklegen.
        let script = """
        APP="$1"; NEW="$2"; PID="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$APP.alt"
        if mv "$APP" "$APP.alt" && mv "$NEW" "$APP"; then
          rm -rf "$APP.alt"
        else
          [ -d "$APP" ] || mv "$APP.alt" "$APP"
        fi
        rm -rf "$WORK"
        open "$APP"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "mac2mqtt-update", target.path, newApp.path,
                       String(ProcessInfo.processInfo.processIdentifier), work.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
    }
}

/// Nach einem Update (oder wenn die App von Hand ersetzt wurde): Dienst und Helfer aus dem Bundle
/// installieren und den Dienst neu starten – aber nur, wenn er schon eingerichtet ist.
@MainActor
func syncRuntimeIfBundleChanged() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: Paths.plistPath),
          let bundledDaemon = bundledResourcePath("mac2mqttd"), fm.fileExists(atPath: bundledDaemon) else { return }
    var changed = filesDiffer(bundledDaemon, Paths.daemonPath)
    if let lib = bundledResourcePath(Paths.nowPlayingLibName), fm.fileExists(atPath: lib) {
        changed = changed || filesDiffer(lib, "\(Paths.appDir)/\(Paths.nowPlayingLibName)")
    }
    guard changed else { return }
    if installBundledRuntimeIfNeeded() == nil {
        let uid = String(getuid())
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.example.mac2mqttd"])
    }
}
