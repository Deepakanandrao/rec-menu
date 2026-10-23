// Rec Menu: a menu bar controller for the rec inference server.
import AppKit
import ServiceManagement
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser
let recBinary = home.appendingPathComponent(".local/bin/rec").path
let recData = home.appendingPathComponent(".local/share/rec")
let modelsLink = recData.appendingPathComponent("models")

struct RecStatus: Decodable {
    let ready: Bool
    let model: String
    let endpoint: String
}

enum ServerState: Equatable {
    case stopped, starting, running, stopping
}

@discardableResult
func runRec(_ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: recBinary)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@MainActor
final class RecController: ObservableObject {
    @Published var state: ServerState = .stopped
    @Published var endpoint = ""
    @Published var model = "flint"
    @Published var message = ""
    @Published var modelsPath = ""
    @Published var moving = false
    @Published var portText: String

    var port: Int {
        get { UserDefaults.standard.object(forKey: "port") as? Int ?? 11500 }
        set { UserDefaults.standard.set(newValue, forKey: "port") }
    }

    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    init() {
        portText = String(UserDefaults.standard.object(forKey: "port") as? Int ?? 11500)
        // Register as a login item once, the first time the installed app runs.
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            setOpenAtLogin(true)
        }
        refreshModelsPath()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    var displayURL: String { endpoint.isEmpty ? "http://127.0.0.1:\(port)/v1" : endpoint }

    var recInstalled: Bool { FileManager.default.isExecutableFile(atPath: recBinary) }
    static let recMissing = "rec isn't installed. Install it from github.com/recursive-oss/rec"

    func refresh() {
        guard recInstalled else {
            state = .stopped
            message = Self.recMissing
            return
        }
        Task.detached {
            let r = runRec(["status"])
            let status = r.code == 0 ? try? JSONDecoder().decode(RecStatus.self, from: Data(r.out.utf8)) : nil
            await MainActor.run {
                if let s = status {
                    self.endpoint = s.endpoint
                    self.model = s.model
                    if self.state != .stopping { self.state = s.ready ? .running : .starting }
                    if s.ready { self.message = "" }
                } else if self.state != .starting || self.message.hasPrefix("Failed") {
                    self.endpoint = ""
                    self.state = .stopped
                }
            }
        }
    }

    func start() {
        guard recInstalled else {
            message = Self.recMissing
            return
        }
        guard let p = Int(portText), (1...65535).contains(p) else {
            message = "Port must be between 1 and 65535"
            return
        }
        port = p
        state = .starting
        message = "Loading model…"
        // Same detached start that `rec launch` uses, so the server outlives this app.
        let logURL = recData.appendingPathComponent("state/recmenu.log")
        Task.detached {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "nohup \"$0\" _background --port \"$1\" >\"$2\" 2>&1 &", recBinary, String(p), logURL.path]
            try? proc.run()
            proc.waitUntilExit()
            // Surface early failures such as a busy port.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if let line = log.split(separator: "\n").last(where: { $0.contains("rec:") || $0.contains("Error") }) {
                await MainActor.run {
                    self.message = "Failed: " + line.replacingOccurrences(of: "rec: ", with: "")
                    self.state = .stopped
                }
            }
        }
    }

    func stop() {
        state = .stopping
        message = ""
        Task.detached {
            runRec(["stop"])
            for _ in 0..<50 {
                if runRec(["status"]).code != 0 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run {
                self.state = .stopped
                self.refresh()
            }
        }
    }

    func applyPort() {
        guard let p = Int(portText), (1...65535).contains(p) else {
            message = "Port must be between 1 and 65535"
            return
        }
        let wasRunning = state == .running || state == .starting
        port = p
        message = ""
        guard wasRunning, !displayURL.contains(":\(p)/") else { return }
        state = .stopping
        Task.detached {
            runRec(["stop"])
            for _ in 0..<50 {
                if runRec(["status"]).code != 0 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run { self.start() }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAPIKey() {
        let r = runRec(["auth", "token"])
        if r.code == 0 {
            copy(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
            message = "API key copied"
        } else {
            message = "No API key yet; start the server once"
        }
    }

    func refreshModelsPath() {
        modelsPath = modelsLink.resolvingSymlinksInPath().path
    }

    func revealModels() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: modelsPath)])
    }

    // rec has no model-directory setting, so move the folder and leave a symlink
    // at the path rec expects.
    func chooseModelsLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose a folder for rec's models. A \"rec-models\" folder will be created inside it."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let dest = parent.appendingPathComponent("rec-models")
        let current = URL(fileURLWithPath: modelsPath)
        if dest.standardizedFileURL.path == current.standardizedFileURL.path { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            message = "\(dest.path) already exists"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move models to \(dest.path)?"
        alert.informativeText = "The server will be stopped first. Moving to another drive copies the files and can take several minutes."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        moving = true
        message = "Moving models…"
        let wasLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: modelsLink.path)) != nil
        Task.detached {
            if runRec(["status"]).code == 0 {
                runRec(["stop"])
                for _ in 0..<50 {
                    if runRec(["status"]).code != 0 { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let fm = FileManager.default
            var error: String?
            do {
                try fm.moveItem(at: current, to: dest)
                if wasLink { try fm.removeItem(at: modelsLink) }
                if dest.standardizedFileURL.path == modelsLink.standardizedFileURL.path {
                    // Moving back to the default location: no link needed.
                } else {
                    try fm.createSymbolicLink(at: modelsLink, withDestinationURL: dest)
                }
            } catch let e {
                error = e.localizedDescription
            }
            let failure = error
            await MainActor.run {
                self.moving = false
                self.message = failure.map { "Move failed: \($0)" } ?? "Models moved"
                self.refreshModelsPath()
                self.refresh()
            }
        }
    }

    func resetModelsLocation() {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: modelsLink.path)) != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Move models back to \(modelsLink.path)?"
        alert.addButton(withTitle: "Move Back")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let current = URL(fileURLWithPath: modelsPath)
        moving = true
        message = "Moving models…"
        Task.detached {
            if runRec(["status"]).code == 0 { runRec(["stop"]) }
            let fm = FileManager.default
            var error: String?
            do {
                try fm.removeItem(at: modelsLink)
                try fm.moveItem(at: current, to: modelsLink)
            } catch let e {
                error = e.localizedDescription
            }
            let failure = error
            await MainActor.run {
                self.moving = false
                self.message = failure.map { "Move failed: \($0)" } ?? "Models moved back"
                self.refreshModelsPath()
                self.refresh()
            }
        }
    }

    var isCustomLocation: Bool { modelsPath != modelsLink.path }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Login item: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct MenuView: View {
    @ObservedObject var rec: RecController

    var statusText: String {
        switch rec.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        }
    }

    var statusColor: Color {
        switch rec.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text("\(rec.model.capitalized) · \(statusText)").font(.headline)
                Spacer()
                if rec.state == .running || rec.state == .starting {
                    Button("Stop") { rec.stop() }
                } else {
                    Button("Start") { rec.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(rec.state == .stopping || rec.moving)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("API URL").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(rec.displayURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button { rec.copy(rec.displayURL); rec.message = "URL copied" } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy URL")
                }
                Button("Copy API key") { rec.copyAPIKey() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Port").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("11500", text: $rec.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { rec.applyPort() }
                    Button(rec.state == .running ? "Apply & Restart" : "Apply") { rec.applyPort() }
                        .disabled(rec.portText == String(rec.port))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model location").font(.caption).foregroundStyle(.secondary)
                Text(rec.modelsPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button("Show in Finder") { rec.revealModels() }
                    Button("Change…") { rec.chooseModelsLocation() }
                    if rec.isCustomLocation {
                        Button("Reset") { rec.resetModelsLocation() }
                    }
                }
                .disabled(rec.moving)
            }

            if !rec.message.isEmpty {
                Text(rec.message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Toggle("Open at login", isOn: Binding(get: { rec.openAtLogin }, set: { rec.setOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("Quit Rec Menu") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

@main
struct RecMenuApp: App {
    @StateObject private var rec = RecController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(rec: rec)
        } label: {
            Image(systemName: rec.state == .running ? "brain.head.profile.fill" : "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}
