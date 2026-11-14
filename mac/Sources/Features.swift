import AppKit
import Intents
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

// MARK: - Ver el celular en el Mac (scrcpy por el mismo canal cifrado de adb)

final class Mirror {
    private var process: Process?
    private var navBar: NavBar?
    var onChange: ((Bool) -> Void)?
    var running: Bool { process?.isRunning == true }

    static let path: String? = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func open(serial: String) {
        if let p = process, p.isRunning {
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
            return
        }
        guard let exe = Self.path else { Log.info("scrcpy no está instalado"); return }
        let wifi = serial.contains(":") || serial.contains("_adb-tls-connect")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-s", serial, "--window-title", UserDefaults.standard.string(forKey: "phoneName") ?? "Tu celular",
                       "--turn-screen-off",       // la pantalla del celular se apaga mientras lo usas desde el Mac
                       // …y sigue apagada: el celular no se bloquea por inactividad mientras la ventana está abierta
                       // (se restaura su tiempo de pantalla al cerrar) y queda apagado al cerrar la ventana
                       "--screen-off-timeout=86400", "--stay-awake", "--power-off-on-close",
                       "--disable-screensaver",   // el Mac no apaga la pantalla mientras ves el celular
                       "--keyboard=uhid",         // teclado del Mac como teclado físico (tildes, ñ, atajos)
                       // Mouse como en Enlace a Windows: clic = toque, arrastrar = deslizar, rueda = scroll, entra y sale libre.
                       // Clic derecho = Atrás, medio = Inicio, botón 4 = Recientes, botón 5 = notificaciones.
                       "--mouse=sdk", "--mouse-bind=bhsn:++++",
                       // H.265 rinde más imagen por el mismo ancho de banda; por Wi‑Fi se baja un poco para que vaya fluido
                       "--video-codec=h265", "--max-fps=60"]
            + (wifi ? ["--video-bit-rate=6M", "--max-size=1600"] : ["--video-bit-rate=16M"])
                       // el sonido del celular sale por el Mac mientras la ventana está abierta, como en el iPhone
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = Adb.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            self?.navBar?.close(); self?.navBar = nil
            self?.keepMacAwake(false)
            self?.onChange?(false)
        } }
        do { try p.run(); process = p; onChange?(true) } catch { Log.info("scrcpy: \(error)"); return }
        navBar = NavBar(pid: p.processIdentifier, serial: serial)
        keepMacAwake(true)
        // Traer la ventana al frente cuando aparezca
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
        }
    }

    func close() { navBar?.close(); navBar = nil; keepMacAwake(false); process?.terminate(); process = nil }

    /// Mientras la ventana del celular está abierta, el Mac no apaga la pantalla ni se duerme por inactividad,
    /// también con batería (como cuando reproduces un video). Se suelta al cerrar la ventana.
    private var awake: IOPMAssertionID = 0
    private func keepMacAwake(_ on: Bool) {
        if on, awake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Puente: viendo el celular en el Mac" as CFString, &awake)
        } else if !on, awake != 0 {
            IOPMAssertionRelease(awake); awake = 0
        }
    }
}

/// Barra Atrás · Inicio · Recientes pegada bajo la ventana del celular (como en Enlace a Windows).
/// Sigue a la ventana de scrcpy y solo se muestra mientras esa ventana está al frente.
final class NavBar {
    private let pid: pid_t
    private let serial: String
    private let panel: NSPanel
    private var timer: Timer?
    static let height: CGFloat = 40

    init(pid: pid_t, serial: String) {
        self.pid = pid
        self.serial = serial
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NavBarView { [serial] key in
            DispatchQueue.global().async { _ = Adb.shell(serial, "input keyevent \(key)", timeout: 5) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.follow() }
    }

    func close() { timer?.invalidate(); timer = nil; panel.orderOut(nil) }

    /// Marco de la ventana de scrcpy (coordenadas de Quartz: origen arriba a la izquierda).
    private func scrcpyFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width > 100 { return r }
        }
        return nil
    }

    private func follow() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front == pid || front == ProcessInfo.processInfo.processIdentifier, let r = scrcpyFrame() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let width = max(180, min(r.width, 360))
        var y = screenH - r.maxY - Self.height - 6          // justo debajo de la ventana
        if let vis = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: screenH - r.midY)) })?.visibleFrame,
           y < vis.minY { y = screenH - r.maxY + 6 }       // si no cabe abajo, se monta sobre el borde inferior
        let frame = NSRect(x: r.midX - width / 2, y: y, width: width, height: Self.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private struct NavBarView: View {
    let send: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            button("chevron.backward", "Atrás (clic derecho)", "KEYCODE_BACK")
            button("circle", "Inicio (clic central)", "KEYCODE_HOME")
            button("square", "Recientes", "KEYCODE_APP_SWITCH")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
    }

    private func button(_ icon: String, _ help: String, _ key: String) -> some View {
        Button { send(key) } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - No molestar sincronizado

final class FocusSync {
    var onMacChange: ((Bool) -> Void)?
    private(set) var macOn: Bool?
    private var timer: Timer?

    func start() {
        INFocusStatusCenter.default.requestAuthorization { st in
            Log.info("concentración: permiso \(st.rawValue)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized,
              let on = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        if on != macOn {
            let first = macOn == nil
            macOn = on
            if !first { onMacChange?(on) }
        }
    }

    static let shortcutOn = "Puente No molestar sí"
    static let shortcutOff = "Puente No molestar no"

    static var shortcutsInstalled: Bool {
        let out = Self.runShortcuts(["list"])
        return out.contains(shortcutOn) && out.contains(shortcutOff)
    }

    /// Cambiar la concentración del Mac (macOS solo lo permite por Atajos).
    func setMac(_ on: Bool) {
        macOn = on
        // Atajos guarda el nombre con la tilde descompuesta (venía del nombre de archivo): hay que pedirlo igual
        let name = (on ? Self.shortcutOn : Self.shortcutOff).decomposedStringWithCanonicalMapping
        DispatchQueue.global().async { _ = Self.runShortcuts(["run", name]) }
    }

    /// Abre los dos atajos para que la persona los añada (una vez).
    static func installShortcuts() {
        guard let res = Bundle.main.resourceURL else { return }
        for (file, name) in [("on", shortcutOn), ("off", shortcutOff)] {
            let src = res.appendingPathComponent("\(file).shortcut")
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).shortcut")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            NSWorkspace.shared.open(dst)
        }
    }

    private static func runShortcuts(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Pestaña del navegador → celular

enum BrowserTab {
    private(set) static var lastApp: NSRunningApplication?

    static func track() {
        lastApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               a.bundleIdentifier != Bundle.main.bundleIdentifier { lastApp = a }
        }
    }

    /// URL de la pestaña activa del último navegador usado.
    static func current() -> (url: String?, error: String?) {
        let candidates = [lastApp, NSWorkspace.shared.frontmostApplication].compactMap { $0 }
        guard let app = candidates.first(where: { scriptFor($0.bundleIdentifier ?? "") != nil }),
              let src = scriptFor(app.bundleIdentifier ?? "") else {
            return (nil, "Abre la página en Chrome, Opera, Safari, Brave, Edge o Arc")
        }
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
        if let out, out.hasPrefix("http") { return (out, nil) }
        Log.info("pestaña: \(err ?? [:])")
        return (nil, "Permite que Puente controle \(app.localizedName ?? "el navegador") en Ajustes › Privacidad › Automatización")
    }

    private static func scriptFor(_ id: String) -> String? {
        switch id {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return "tell application id \"\(id)\" to get URL of front document"
        case "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
             "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser":
            return "tell application id \"\(id)\" to get URL of active tab of front window"
        default: return nil
        }
    }
}

// MARK: - Avisos breves del propio Puente

enum Toast {
    static func show(_ title: String, _ body: String = "", image: URL? = nil, info: [String: String] = [:]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = info.merging(["kind": "puente"]) { a, _ in a }
        if let image {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("puente-\(UUID().uuidString)." + image.pathExtension)
            if (try? FileManager.default.copyItem(at: image, to: tmp)) != nil,
               let a = try? UNNotificationAttachment(identifier: "img", url: tmp, options: nil) { c.attachments = [a] }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
