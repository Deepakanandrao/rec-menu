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

    // rec creates the key the first time the server starts.
    func apiKey() -> String? {
        let r = runRec(["auth", "token"])
        guard r.code == 0 else {
            message = "No API key yet; start the server once"
            return nil
        }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
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

// The logo is a black-on-transparent PNG, so it works as a template image.
let logo: NSImage = {
    let image = Bundle.main.image(forResource: "logo") ?? NSImage(systemSymbolName: "triangle", accessibilityDescription: nil)!
    image.isTemplate = true
    return image
}()

func menuBarIcon(_ state: ServerState) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let tint: NSColor? = switch state {
    case .running: .systemGreen
    case .starting, .stopping: .systemOrange
    case .stopped: nil
    }
    // Stopped uses the plain template icon so it matches the other menu bar icons.
    let icon = NSImage(size: size, flipped: false) { rect in
        // The logo's strokes are thin at 18pt; drawing it slightly offset thickens them.
        for (dx, dy) in [(-0.3, 0.0), (0.3, 0.0), (0.0, -0.3), (0.0, 0.3)] {
            logo.draw(in: rect.offsetBy(dx: dx, dy: dy))
        }
        if let tint {
            tint.set()
            rect.fill(using: .sourceAtop)
        }
        return true
    }
    icon.isTemplate = tint == nil
    icon.accessibilityDescription = "Rec Menu"
    return icon
}

struct MenuView: View {
    @ObservedObject var rec: RecController
    @State private var key: String?
    @State private var keyVisible = false
    @State private var copied: String?

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

    var isBusy: Bool { rec.state == .starting || rec.state == .stopping }
    var isUp: Bool { rec.state == .running || rec.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            powerButton
            PanelSection(title: "Connection") {
                endpointRow
                Divider()
                keyRow
                Divider()
                portRow
            }
            PanelSection(title: "Model") { modelRow }
            if !rec.message.isEmpty { banner }
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 380)
        .animation(.easeOut(duration: 0.15), value: rec.state)
        .animation(.easeOut(duration: 0.15), value: rec.message)
    }

    // MARK: Sections

    var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: logo)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rec Menu")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText)
                    Text("·").foregroundStyle(.tertiary)
                    Text(rec.model.capitalized)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var powerButton: some View {
        Button {
            isUp ? rec.stop() : rec.start()
        } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isUp ? "stop.fill" : "play.fill")
                }
                Text(isBusy ? (rec.state == .starting ? "Loading model…" : "Stopping…") : (isUp ? "Stop Server" : "Start Server"))
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .modifier(PowerButtonStyle(prominent: !isUp))
        .disabled(rec.state == .stopping || rec.moving)
    }

    var endpointRow: some View {
        Row(icon: "link", label: "Endpoint") {
            Text(rec.displayURL.replacingOccurrences(of: "http://", with: ""))
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            copyButton(id: "url") { rec.displayURL }
        }
    }

    var keyRow: some View {
        Row(icon: "key", label: "API key") {
            Group {
                if keyVisible, let key {
                    Text(key)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(String(repeating: "•", count: 14)).foregroundStyle(.secondary)
                }
            }
            .font(.body.monospaced())
            Spacer(minLength: 4)
            IconButton(systemName: keyVisible ? "eye.slash" : "eye", help: keyVisible ? "Hide key" : "Show key") {
                if !keyVisible, key == nil { key = rec.apiKey() }
                if key != nil { keyVisible.toggle() }
            }
            copyButton(id: "key") { key ?? rec.apiKey() }
        }
    }

    var portRow: some View {
        Row(icon: "number", label: "Port") {
            TextField("11500", text: $rec.portText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 80)
                .onSubmit { rec.applyPort() }
            Spacer(minLength: 4)
            if rec.portText != String(rec.port) {
                Button(rec.state == .running ? "Apply & Restart" : "Apply") { rec.applyPort() }
                    .transition(.opacity)
            }
        }
    }

    var modelRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(rec.modelsPath.replacingOccurrences(of: home.path, with: "~"))
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(rec.modelsPath)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { rec.revealModels() }
                Button("Move…") { rec.chooseModelsLocation() }
                if rec.isCustomLocation {
                    Button("Reset") { rec.resetModelsLocation() }
                }
                Spacer()
                if rec.moving { ProgressView().controlSize(.small) }
            }
            .disabled(rec.moving)
        }
    }

    var banner: some View {
        let isError = rec.message.hasPrefix("Failed") || rec.message.contains("failed") || rec.message.hasPrefix("rec isn't") || rec.message.hasPrefix("No API")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? .orange : .secondary)
            Text(rec.message)
                .font(.callout)
                .foregroundStyle(isError ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { rec.openAtLogin }, set: { rec.setOpenAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.callout)
    }

    // MARK: Helpers

    func copyButton(id: String, value: @escaping () -> String?) -> some View {
        IconButton(systemName: copied == id ? "checkmark" : "doc.on.doc", help: "Copy", tint: copied == id ? .green : nil) {
            guard let text = value() else { return }
            rec.copy(text)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if copied == id { copied = nil }
            }
        }
    }
}

// Start is the primary action; Stop stays a plain button.
struct PowerButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
    }
}

struct Row<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            content
        }
        .font(.body)
        .frame(minHeight: 24)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint ?? (hovering ? .primary : .secondary))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

@main
struct RecMenuApp: App {
    @StateObject private var rec = RecController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(rec: rec)
        } label: {
            Image(nsImage: menuBarIcon(rec.state))
        }
        .menuBarExtraStyle(.window)
    }
}
