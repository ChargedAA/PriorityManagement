import Cocoa

// MARK: - Helpers

/// Green (low value) to red (high value). Dynamic, so it stays readable in light and dark mode.
func priorityColor(_ ui: Int) -> NSColor {
    let t = CGFloat(max(0, min(40, ui))) / 40
    return NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(hue: (1 - t) * 0.36, saturation: 0.8, brightness: dark ? 0.95 : 0.68, alpha: 1)
    }
}

/// Rotate (counter clockwise, about the centre) and optionally mirror horizontally. Safe off the main thread.
func transformImage(_ img: NSImage, degrees: Int, mirror: Bool) -> NSImage? {
    var rect = NSRect(origin: .zero, size: img.size)
    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    if mirror { ctx.scaleBy(x: -1, y: 1) }
    ctx.rotate(by: CGFloat(degrees) * .pi / 180)
    ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage() else { return nil }
    return NSImage(cgImage: out, size: img.size)
}

func pick<T>(_ items: [(T, Int)]) -> T {
    let total = items.reduce(0) { $0 + $1.1 }
    var r = Int.random(in: 0..<total)
    for (item, w) in items { r -= w; if r < 0 { return item } }
    return items[0].0
}

func cpuSeconds(pid: pid_t) -> Double? {
    var r = rusage_info_v2()
    let ok = withUnsafeMutablePointer(to: &r) { ptr -> Int32 in
        proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard ok == 0 else { return nil }
    return hostSeconds(fromTicks: r.ri_user_time + r.ri_system_time)
}

// MARK: - Model

final class AppProcess {
    let name: String
    let key: String
    let pid: pid_t
    let isUserApp: Bool
    let app: NSRunningApplication
    var nice: Int
    var cpuPercent: Double   // percent of one core
    init(name: String, key: String, pid: pid_t, isUserApp: Bool, app: NSRunningApplication, nice: Int, cpuPercent: Double) {
        self.name = name; self.key = key; self.pid = pid; self.isUserApp = isUserApp
        self.app = app; self.nice = nice; self.cpuPercent = cpuPercent
    }
    var tier: Int { cpuPercent >= 500 ? 2 : (cpuPercent >= 200 ? 1 : 0) }
}

enum Row {
    case header(String)
    case process(AppProcess)
}

struct Candidate {
    let name: String; let key: String; let pid: pid_t; let isUser: Bool; let app: NSRunningApplication
}

// MARK: - Views

final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    convenience init(symbol: String, tooltip: String, tint: NSColor = .secondaryLabelColor) {
        self.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        toolTip = tooltip
        contentTintColor = tint
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

final class HeaderCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Priority is shown as a percentage. 50% is the normal priority (nice 0), 0% is the lowest, 100% the highest.
// Internally it is 41 steps (0...40), so one step is 2.5%.
func percentText(_ ui: Int) -> String {
    let p = Double(ui) * 2.5
    return p == p.rounded() ? String(Int(p)) : String(format: "%.1f", p)
}

func uiFromPercent(_ p: Double) -> Int { max(0, min(40, Int((p / 2.5).rounded()))) }

/// A gradient track with a round knob that takes the colour of the current value.
/// Drag it, click on it, use the arrow keys, or double-click to reset to 50%.
final class PrioritySlider: NSControl {
    var ui: Int = 20 {
        didSet {
            guard ui != oldValue else { return }
            needsDisplay = true
        }
    }
    /// Called while dragging (final is false) and when a drag ends or a key is pressed (final is true)
    var onChange: ((Int, Bool) -> Void)?
    private(set) var isDragging = false

    private let trackHeight: CGFloat = 6
    private let knobSize: CGFloat = 18

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackRect: NSRect {
        NSRect(x: knobSize / 2, y: bounds.midY - trackHeight / 2, width: bounds.width - knobSize, height: trackHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = trackRect
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGradient(colors: (0...4).map { priorityColor($0 * 10) })?.draw(in: track, angle: 0)
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        track.lineWidth = 0.5
        track.stroke()

        let cx = r.minX + r.width * CGFloat(ui) / 40
        let knob = NSRect(x: cx - knobSize / 2, y: bounds.midY - knobSize / 2, width: knobSize, height: knobSize)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()

        priorityColor(ui).setFill()
        NSBezierPath(ovalIn: knob.insetBy(dx: 3.5, dy: 3.5)).fill()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)          // also ends any edit in a number field
        if event.clickCount >= 2 {
            set(20, final: true)                  // back to 50%
            return
        }
        isDragging = true
        move(to: event, final: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        move(to: event, final: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        move(to: event, final: true)
        isDragging = false
    }

    private func move(to event: NSEvent, final: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        let t = (x - trackRect.minX) / trackRect.width
        set(max(0, min(40, Int((t * 40).rounded()))), final: final)
    }

    private func set(_ value: Int, final: Bool) {
        let changed = value != ui
        ui = value
        if changed || final { onChange?(ui, final) }
    }

    // MARK: Keyboard and accessibility

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: set(max(0, ui - 1), final: true)      // left, down
        case 124, 126: set(min(40, ui + 1), final: true)     // right, up
        default: super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { Double(ui) * 2.5 }
    override func accessibilityPerformIncrement() -> Bool { set(min(40, ui + 1), final: true); return true }
    override func accessibilityPerformDecrement() -> Bool { set(max(0, ui - 1), final: true); return true }
}

final class ProcessCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let percentSign = NSTextField(labelWithString: "%")
    private let slider = PrioritySlider()
    private let quit = HoverButton(symbol: "xmark", tooltip: "Quit")
    private let force = HoverButton(symbol: "xmark.octagon.fill", tooltip: "Force Quit", tint: .systemRed)

    private(set) var pid: pid_t = 0
    private weak var handler: AppDelegate?

    /// True while the user is dragging the slider or typing in the number field
    var isBusy: Bool { slider.isDragging || field.currentEditor() != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.usesSingleLineMode = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.masksToBounds = true
        field.toolTip = "Type a priority from 0 to 100 percent"
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false

        percentSign.font = .systemFont(ofSize: 12)
        percentSign.textColor = .secondaryLabelColor

        slider.toolTip = "Drag to set priority, double-click to reset to 50%"
        slider.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [field, percentSign, slider, quit, force])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.setCustomSpacing(14, after: percentSign)
        stack.setCustomSpacing(10, after: slider)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView); addSubview(nameLabel); addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -10),
            field.widthAnchor.constraint(equalToConstant: 46),
            field.heightAnchor.constraint(equalToConstant: 22),
            slider.widthAnchor.constraint(equalToConstant: 150),
            slider.heightAnchor.constraint(equalToConstant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: AppProcess, handler: AppDelegate, icon: NSImage?) {
        pid = p.pid
        self.handler = handler
        iconView.image = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        for b in [quit, force] { b.tag = Int(p.pid); b.target = handler }
        quit.action = #selector(AppDelegate.quitApp(_:))
        force.action = #selector(AppDelegate.forceQuitApp(_:))
        slider.onChange = { [weak self] ui, final in
            guard let self = self else { return }
            self.show(ui)
            self.handler?.sliderChanged(pid: self.pid, ui: ui, final: final)
        }
        refresh(p)
    }

    /// Update the shown values in place, without disturbing a drag or an edit
    func refresh(_ p: AppProcess) {
        let prefix = p.tier == 2 ? "🔋 " : (p.tier == 1 ? "🪫 " : "")
        nameLabel.stringValue = prefix + p.name
        if !isBusy {
            slider.ui = max(0, min(40, 20 - p.nice))
            show(slider.ui)
        }
    }

    private func show(_ ui: Int) {
        if field.currentEditor() == nil { field.stringValue = percentText(ui) }
        field.textColor = priorityColor(ui)
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        let cleaned = sender.stringValue
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned) {
            let ui = uiFromPercent(v)
            slider.ui = ui
            handler?.sliderChanged(pid: pid, ui: ui, final: true)
        }
        // Leave the field so the list can update normally again, then show the (possibly corrected) value
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(nil)
            self.show(self.slider.ui)
        }
    }
}

// MARK: - App Delegate

enum Speed { case half, normal, double, quad }

/// Off: no parrot. Dancing: animates by itself, no audio. Music sync: follows the beat and needs audio capture.
enum ParrotMode: Int { case off, dancing, sync }

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    // UI
    var window: NSWindow!
    var tableView: NSTableView!
    let modeSlider = NSSlider(value: 2, minValue: 0, maxValue: 2, target: nil, action: nil)
    let modeLabel = NSTextField(labelWithString: "")
    let deprioritizeButton = NSButton(title: "Deprioritize Background", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset All", target: nil, action: nil)
    let spinner = NSProgressIndicator()

    // Data
    var rows: [Row] = []
    var known: [pid_t: AppProcess] = [:]
    var lastSignature = ""
    var userCount = 0, systemCount = 0
    var scanBusy = false
    var lastScanned: [(Candidate, Int, Double)] = []
    var query = ""
    let searchField = NSSearchField()
    let trashButton = NSButton()
    var sudoReady = true
    var promptingSudo = false
    var sudoOfferedThisSession = false
    var inFlight = Set<pid_t>()
    var iconCache: [String: NSImage] = [:]
    var engineNote = ""
    let scanQueue = DispatchQueue(label: "priority.scan", qos: .utility)
    let reniceQueue = DispatchQueue(label: "priority.renice", qos: .userInitiated)
    var lastCPU: [pid_t: (cpu: Double, wall: Double)] = [:]   // scanQueue only
    var refreshTimer: Timer?

    // Parrot
    let idleInterval: TimeInterval = 0.04
    var baseFrames: [NSImage] = []
    var parrotSets: [Int: [Bool: [NSImage]]] = [:]
    var currentFrames: [NSImage] = []
    var parrotIndex = 0
    var parrotTimer: Timer?
    var speed: Speed = .normal
    var beatLocked = false
    var currentPeriod: Double = 0.5
    var lastTrack = ""
    var downbeatsSinceChange = 0
    var barsPerChange = 4
    var parrotMode: ParrotMode = .sync
    var parrotEnabled: Bool { parrotMode != .off }
    var syncEnabled: Bool { parrotMode == .sync }
    var engineRunning = false
    var intensity: Double = 0.5     // how loud the song is right now compared with its own range (0 to 1)
    var riser: Double = 0           // 0 to 1, a build up is in progress

    // Beat engine
    let engine = BeatEngine()

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "parrotMode") as? Int, let m = ParrotMode(rawValue: raw) {
            parrotMode = m
        } else if let old = defaults.object(forKey: "parrotEnabled") as? Bool {
            parrotMode = old ? .sync : .off          // from the earlier on/off switch
        }
        buildMenu()
        buildWindow()
        refreshProcesses()
        refreshTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshProcesses() }
        RunLoop.main.add(refreshTimer!, forMode: .common)
        if parrotEnabled { loadParrot() }
        if syncEnabled { startEngine() }
        observePlayers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.checkSudoSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { engine.stop() }

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Priority Management", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem(); mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Priority Management"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 320)
        window.isReleasedWhenClosed = false

        // Translucent material that follows the system light/dark setting
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        window.contentView = bg

        tableView = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scroll)

        // Bottom bar
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(bar)
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sep)

        let parrotCaption = NSTextField(labelWithString: "Parrot")
        parrotCaption.font = .systemFont(ofSize: 12)
        parrotCaption.textColor = .secondaryLabelColor
        parrotCaption.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(parrotCaption)

        modeSlider.numberOfTickMarks = 3
        modeSlider.allowsTickMarkValuesOnly = true
        modeSlider.tickMarkPosition = .below
        modeSlider.controlSize = .small
        modeSlider.integerValue = parrotMode.rawValue
        modeSlider.target = self
        modeSlider.action = #selector(modeChanged(_:))
        modeSlider.toolTip = "Off, Dancing (no audio needed), or Music sync"
        modeSlider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(modeSlider)

        modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .labelColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(modeLabel)
        updateModeLabel()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(spinner)

        deprioritizeButton.target = self
        deprioritizeButton.action = #selector(deprioritizeBackground)
        deprioritizeButton.bezelStyle = .rounded
        deprioritizeButton.controlSize = .large
        deprioritizeButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        deprioritizeButton.imagePosition = .imageLeading
        deprioritizeButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(deprioritizeButton)

        resetButton.target = self
        resetButton.action = #selector(resetAll)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .large
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        resetButton.imagePosition = .imageLeading
        resetButton.toolTip = "Set every app back to 50%"
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(resetButton)

        searchField.placeholderString = "Search apps"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.controlSize = .large
        searchField.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(searchField)

        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove permission")
        trashButton.bezelStyle = .rounded
        trashButton.controlSize = .large
        trashButton.target = self
        trashButton.action = #selector(trashClicked)
        trashButton.toolTip = "Remove the password-free priority permission"
        trashButton.isHidden = true
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(trashButton)

        let topAnchor: NSLayoutYAxisAnchor = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? bg.topAnchor
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),

            sep.topAnchor.constraint(equalTo: bar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            parrotCaption.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            parrotCaption.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            modeSlider.leadingAnchor.constraint(equalTo: parrotCaption.trailingAnchor, constant: 10),
            modeSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            modeSlider.widthAnchor.constraint(equalToConstant: 84),
            modeLabel.leadingAnchor.constraint(equalTo: modeSlider.trailingAnchor, constant: 10),
            modeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            modeLabel.widthAnchor.constraint(equalToConstant: 84),

            deprioritizeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            deprioritizeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            resetButton.trailingAnchor.constraint(equalTo: deprioritizeButton.leadingAnchor, constant: -8),
            resetButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            trashButton.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -8),
            trashButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        window.center()
        window.setFrameAutosaveName("PriorityManagementWindow")
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Process scanning (heavy work off the main thread)

    func refreshProcesses() {
        guard !scanBusy else { return }
        scanBusy = true

        // Cheap: just reads a few properties
        var cands: [Candidate] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, app.processIdentifier > 0 else { continue }   // -1 means launching or already quit
            let key = app.bundleIdentifier ?? name
            if seen.contains(key) { continue }
            seen.insert(key)
            cands.append(Candidate(name: name, key: key, pid: app.processIdentifier,
                                   isUser: app.activationPolicy == .regular, app: app))
        }

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let now = hostSecondsNow()
            var out: [(Candidate, Int, Double)] = []
            var alive = Set<pid_t>()
            for c in cands {
                let nice = Int(getpriority(PRIO_PROCESS, id_t(truncatingIfNeeded: c.pid)))
                var pct = 0.0
                if let cpu = cpuSeconds(pid: c.pid) {
                    alive.insert(c.pid)
                    if let last = self.lastCPU[c.pid], now > last.wall {
                        pct = max(0, (cpu - last.cpu) / (now - last.wall) * 100)
                    }
                    self.lastCPU[c.pid] = (cpu, now)
                }
                out.append((c, nice, pct))
            }
            self.lastCPU = self.lastCPU.filter { alive.contains($0.key) }
            DispatchQueue.main.async { self.applyScan(out) }
        }
    }

    func applyScan(_ scanned: [(Candidate, Int, Double)]) {
        scanBusy = false
        lastScanned = scanned
        render(scanned)
    }

    func render(_ scanned: [(Candidate, Int, Double)]) {
        var user: [AppProcess] = [], system: [AppProcess] = []
        var newKnown: [pid_t: AppProcess] = [:]
        let busy = busyPids()
        for (c, nice, pct) in scanned {
            // Keep the shown value while a renice is running or the user is dragging or typing in that row
            let n = (inFlight.contains(c.pid) || busy.contains(c.pid)) ? (known[c.pid]?.nice ?? nice) : nice
            let p = AppProcess(name: c.name, key: c.key, pid: c.pid, isUserApp: c.isUser, app: c.app, nice: n, cpuPercent: pct)
            newKnown[c.pid] = p
            if !query.isEmpty && !c.name.localizedCaseInsensitiveContains(query) { continue }
            if c.isUser { user.append(p) } else { system.append(p) }
        }
        user.sort { $0.name.lowercased() < $1.name.lowercased() }
        system.sort { $0.name.lowercased() < $1.name.lowercased() }

        var newRows: [Row] = []
        var structure = ""
        if !user.isEmpty { newRows.append(.header("Apps")); structure += "H1|" }
        for p in user { newRows.append(.process(p)); structure += "\(p.pid)|" }
        if !system.isEmpty { newRows.append(.header("Background Processes")); structure += "H2|" }
        for p in system { newRows.append(.process(p)); structure += "\(p.pid)|" }

        known = newKnown
        userCount = user.count; systemCount = system.count
        updateCounts()

        if structure == lastSignature {
            // Same apps in the same order: refresh the visible values in place, so nothing is rebuilt under the mouse
            rows = newRows
            refreshVisibleCells()
        } else if !userIsInteracting() {
            lastSignature = structure
            rows = newRows
            tableView.reloadData()
        }
        // otherwise wait for the next scan, once the user has let go
    }

    func updateCounts() {
        var s = "\(userCount) apps  \u{00B7}  \(systemCount) background"
        if !engineNote.isEmpty { s += "  \u{00B7}  \(engineNote)" }
        window.subtitle = s
    }

    // MARK: In place updates

    /// True while the mouse is down or a number field is being edited
    func userIsInteracting() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor, !(editor.delegate is NSSearchField) { return true }
        return false
    }

    func visibleCells() -> [(Int, ProcessCellView)] {
        var out: [(Int, ProcessCellView)] = []
        tableView.enumerateAvailableRowViews { rowView, row in
            if let c = rowView.view(atColumn: 0) as? ProcessCellView { out.append((row, c)) }
        }
        return out
    }

    func busyPids() -> Set<pid_t> {
        var s = Set<pid_t>()
        for (_, c) in visibleCells() where c.isBusy { s.insert(c.pid) }
        return s
    }

    func refreshVisibleCells() {
        for (row, cell) in visibleCells() {
            guard row < rows.count, case .process(let p) = rows[row], p.pid == cell.pid else { continue }
            cell.refresh(p)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 38
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HeaderCellView) ?? HeaderCellView()
            cell.identifier = id
            cell.label.stringValue = title.uppercased()
            return cell
        case .process(let p):
            let id = NSUserInterfaceItemIdentifier("process")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ProcessCellView) ?? ProcessCellView()
            cell.identifier = id
            cell.configure(p, handler: self, icon: icon(for: p))
            return cell
        }
    }

    /// Icons load lazily, only for rows that are actually shown
    func icon(for p: AppProcess) -> NSImage? {
        if let i = iconCache[p.key] { return i }
        guard let i = p.app.icon else { return nil }
        iconCache[p.key] = i
        return i
    }

    func process(for pid: pid_t) -> AppProcess? { known[pid] }

    func reloadRow(for pid: pid_t) {
        for (i, r) in rows.enumerated() {
            if case .process(let p) = r, p.pid == pid {
                tableView.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
                return
            }
        }
    }

    // MARK: Actions

    /// Called by a row's slider or number field. While dragging only the model changes, the system call happens on release.
    func sliderChanged(pid: pid_t, ui: Int, final: Bool) {
        guard let p = known[pid] else { return }
        p.nice = 20 - ui
        guard final else { return }
        inFlight.insert(pid)
        runRenice(pids: [pid], nice: 20 - ui) { [weak self] ok in
            self?.inFlight.remove(pid)
            if !ok { self?.refreshProcesses() }
        }
    }

    @objc func quitApp(_ sender: NSButton) {
        guard let p = process(for: pid_t(sender.tag)) else { return }
        p.app.terminate()
        scheduleRefreshes()
    }

    @objc func forceQuitApp(_ sender: NSButton) {
        guard let p = process(for: pid_t(sender.tag)) else { return }
        p.app.forceTerminate()
        scheduleRefreshes()
    }

    func scheduleRefreshes() {
        for d in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.refreshProcesses() }
        }
    }

    @objc func deprioritizeBackground() {
        var targets: [AppProcess] = []
        targets = known.values.filter { !$0.isUserApp }
        guard !targets.isEmpty else { return }
        setBusy(true)
        for p in targets { p.nice = 20 }       // 0 percent, shown immediately
        refreshVisibleCells()
        let pids = targets.map { $0.pid }
        pids.forEach { inFlight.insert($0) }
        runRenice(pids: pids, nice: 20) { [weak self] _ in
            guard let self = self else { return }
            pids.forEach { self.inFlight.remove($0) }
            self.setBusy(false)
            self.refreshProcesses()
        }
    }

    @objc func resetAll() {
        var targets: [AppProcess] = []
        targets = known.values.filter { $0.nice != 0 }
        guard !targets.isEmpty else { return }
        setBusy(true)
        for p in targets { p.nice = 0 }        // 50 percent
        refreshVisibleCells()
        let pids = targets.map { $0.pid }
        pids.forEach { inFlight.insert($0) }
        runRenice(pids: pids, nice: 0) { [weak self] _ in
            guard let self = self else { return }
            pids.forEach { self.inFlight.remove($0) }
            self.setBusy(false)
            self.refreshProcesses()
        }
    }

    func setBusy(_ busy: Bool) {
        deprioritizeButton.isEnabled = !busy
        resetButton.isEnabled = !busy
        deprioritizeButton.title = busy ? "Working\u{2026}" : "Deprioritize Background"
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// One sudo call for any number of processes, on a serial background queue
    func runRenice(pids: [pid_t], nice: Int, completion: @escaping (Bool) -> Void) {
        reniceQueue.async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            t.arguments = ["-n", "/usr/bin/renice", "\(nice)", "-p"] + pids.map { "\($0)" }
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            var ok = false
            do { try t.run(); t.waitUntilExit(); ok = (t.terminationStatus == 0) } catch {}
            DispatchQueue.main.async {
                if !ok { (NSApp.delegate as? AppDelegate)?.sudoFailed() }
                completion(ok)
            }
        }
    }

    // MARK: Permission setup (password-free renice)

    static let sudoersPath = "/etc/sudoers.d/prioritymanagement"

    static func sudoRuleWorks() -> Bool {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        t.arguments = ["-n", "-l", "/usr/bin/renice"]
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        do { try t.run(); t.waitUntilExit(); return t.terminationStatus == 0 } catch { return false }
    }

    func setSudoReady(_ ok: Bool) {
        sudoReady = ok
        trashButton.isHidden = !ok
    }

    func checkSudoSetup() {
        reniceQueue.async { [weak self] in
            let ok = AppDelegate.sudoRuleWorks()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setSudoReady(ok)
                if !ok && !UserDefaults.standard.bool(forKey: "sudoPromptDismissed") && !self.sudoOfferedThisSession {
                    self.sudoOfferedThisSession = true
                    self.offerSudoSetup()
                }
            }
        }
    }

    /// Called when a renice fails: if the permission rule is the cause, offer setup once per launch
    func sudoFailed() {
        guard !promptingSudo, !sudoOfferedThisSession else { return }
        reniceQueue.async { [weak self] in
            let ok = AppDelegate.sudoRuleWorks()
            DispatchQueue.main.async {
                guard let self = self, !ok, !self.sudoOfferedThisSession else { return }
                self.sudoOfferedThisSession = true
                self.setSudoReady(false)
                self.offerSudoSetup()
            }
        }
    }

    func offerSudoSetup() {
        guard !promptingSudo else { return }
        promptingSudo = true
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Allow Priority Management to change priorities?"
        a.informativeText = "To change how much CPU an app gets, this app uses the built-in renice command with administrator rights. Without setup, macOS would ask for your password every time.\n\nSetup adds one rule to your Mac that lets your account run /usr/bin/renice without a password. It cannot be used to run anything else. You will be asked for your password once, now.\n\nYou can remove the rule at any time with the trash button in the bottom bar."
        a.addButton(withTitle: "Set Up")
        a.addButton(withTitle: "Not Now")
        let r = a.runModal()
        promptingSudo = false
        if r == .alertFirstButtonReturn { installSudoRule() }
        else { UserDefaults.standard.set(true, forKey: "sudoPromptDismissed") }
    }

    /// Runs a shell command with the standard macOS administrator password prompt
    func runAdmin(_ shell: String, done: @escaping (Bool, String) -> Void) {
        precondition(!shell.contains("\"") && !shell.contains("\\"))
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            t.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
            let err = Pipe()
            t.standardError = err
            t.standardOutput = FileHandle.nullDevice
            var ok = false
            do { try t.run(); t.waitUntilExit(); ok = (t.terminationStatus == 0) } catch {}
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { done(ok, msg) }
        }
    }

    func installSudoRule() {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9_][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            showSetupProblem("Your account name has characters this setup does not support, so nothing was changed.")
            return
        }
        let cmd = "set -e; T=$(/usr/bin/mktemp /tmp/pmsudo.XXXXXX); trap '/bin/rm -f $T' EXIT; "
            + "echo '\(user) ALL=(root) NOPASSWD: /usr/bin/renice' > $T; /usr/sbin/visudo -cf $T; "
            + "/usr/sbin/chown root:wheel $T; /bin/chmod 0440 $T; /bin/mv $T \(AppDelegate.sudoersPath)"
        runAdmin(cmd) { [weak self] ok, msg in
            guard let self = self else { return }
            if !ok && !msg.contains("-128") { self.showSetupProblem("The permission rule was not installed. Nothing on your Mac was changed.") }
            self.recheckSudo()
        }
    }

    @objc func trashClicked() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Remove the priority permission?"
        a.informativeText = "This deletes the rule that lets Priority Management run renice without a password. Priority changes will stop working until you set it up again. You will be asked for your password."
        let remove = a.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runAdmin("/bin/rm -f \(AppDelegate.sudoersPath)") { [weak self] ok, msg in
            guard let self = self else { return }
            if ok { UserDefaults.standard.set(true, forKey: "sudoPromptDismissed") }
            else if !msg.contains("-128") { self.showSetupProblem("The permission rule could not be removed.") }
            self.recheckSudo()
        }
    }

    func recheckSudo() {
        reniceQueue.async { [weak self] in
            let ok = AppDelegate.sudoRuleWorks()
            DispatchQueue.main.async { self?.setSudoReady(ok) }
        }
    }

    func showSetupProblem(_ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Setup did not finish"
        a.informativeText = text
        a.runModal()
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        render(lastScanned)
    }

    // MARK: Parrot

    func loadParrot() {
        let dir = (Bundle.main.resourcePath ?? "") + "/parrot_frames"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames: [NSImage] = (0..<10).compactMap { NSImage(contentsOfFile: String(format: "%@/frame_%02d.png", dir, $0)) }
            guard !frames.isEmpty else { return }
            var sets: [Int: [Bool: [NSImage]]] = [:]
            for rot in [0, 90, 180, 270] {
                let plain = rot == 0 ? frames : frames.map { transformImage($0, degrees: rot, mirror: false) ?? $0 }
                let mirrored = frames.map { transformImage($0, degrees: rot, mirror: true) ?? $0 }
                sets[rot] = [false: plain, true: mirrored]
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.baseFrames = frames
                self.parrotSets = sets
                self.currentFrames = frames
                self.startIdle()
            }
        }
    }

    func showFrame() {
        guard !currentFrames.isEmpty else { return }
        NSApp.applicationIconImage = currentFrames[parrotIndex % currentFrames.count]
    }

    func startIdle() {
        guard parrotEnabled, !baseFrames.isEmpty else { return }
        beatLocked = false
        currentFrames = baseFrames
        speed = .normal
        parrotIndex = 0
        parrotTimer?.invalidate()
        let t = Timer(timeInterval: idleInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.currentFrames.isEmpty else { return }
            self.parrotIndex = (self.parrotIndex + 1) % self.currentFrames.count
            self.showFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        parrotTimer = t
        showFrame()
    }

    /// Start the animation cycle exactly on a beat, with one cycle per beat (or half or double)
    func restartParrot(period: Double) {
        guard !currentFrames.isEmpty else { return }
        parrotTimer?.invalidate()
        var interval = period / Double(currentFrames.count)
        switch speed {
        case .half: interval *= 2
        case .double: interval /= 2
        case .quad: interval /= 4
        case .normal: break
        }
        // Timers faster than about 50 fps are wasteful, so skip frames instead
        var step = 1
        while interval < 0.02 && step < 4 { interval *= 2; step *= 2 }
        let stepNow = step
        parrotIndex = 0
        showFrame()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, !self.currentFrames.isEmpty else { return }
            self.parrotIndex = (self.parrotIndex + stepNow) % self.currentFrames.count
            self.showFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        parrotTimer = t
    }

    /// Three independent random choices: rotation, direction, speed
    func applyVariation(period: Double) {
        guard !baseFrames.isEmpty else { return }
        let rotation = pick([(0, 55), (90, 15), (180, 15), (270, 15)])
        let direction = pick([("forward", 60), ("reverse", 20), ("mirror", 20)])
        speed = desiredSpeed()

        let mirrored = direction == "mirror"
        var frames = parrotSets[rotation]?[mirrored] ?? baseFrames
        if direction == "reverse" { frames = frames.reversed() }
        currentFrames = frames
        restartParrot(period: period)
    }

    // MARK: Speed from energy

    /// Speed follows how intense the song is right now compared with its own range, and speeds up
    /// further during a riser. Thresholds differ going up and down so it does not flutter.
    func desiredSpeed() -> Speed {
        let i = intensity, r = riser
        switch speed {
        case .half:
            return (i > 0.30 || r > 0.3) ? .normal : .half
        case .normal:
            if i < 0.18 && r < 0.2 { return .half }
            if i > 0.72 || r > 0.5 { return .double }
            return .normal
        case .double:
            if r > 0.85 { return .quad }
            if i < 0.55 && r < 0.3 { return .normal }
            return .double
        case .quad:
            return r < 0.6 ? .double : .quad
        }
    }

    // MARK: Parrot mode (off, dancing, music sync)

    @objc func modeChanged(_ sender: NSSlider) {
        setParrotMode(ParrotMode(rawValue: sender.integerValue) ?? .sync)
    }

    func updateModeLabel() {
        switch parrotMode {
        case .off: modeLabel.stringValue = "Off"
        case .dancing: modeLabel.stringValue = "Dancing"
        case .sync: modeLabel.stringValue = "Music sync"
        }
    }

    func setParrotMode(_ mode: ParrotMode) {
        guard mode != parrotMode else { return }
        parrotMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "parrotMode")
        updateModeLabel()

        // Audio capture only runs in music sync mode
        if mode != .sync && engineRunning {
            engine.stop()
            engineRunning = false
            engineNote = ""
            updateCounts()
        }
        switch mode {
        case .off:
            parrotTimer?.invalidate(); parrotTimer = nil
            beatLocked = false
            NSApp.applicationIconImage = nil        // back to the normal app icon
        case .dancing:
            beatLocked = false
            if baseFrames.isEmpty { loadParrot() } else { startIdle() }
        case .sync:
            if baseFrames.isEmpty { loadParrot() } else { startIdle() }
            startEngine()
        }
    }

    // MARK: Beat engine

    func startEngine() {
        engineRunning = true
        let offsetMs = UserDefaults.standard.double(forKey: "visualOffsetMs")
        engine.visualOffset = offsetMs / 1000
        let bars = UserDefaults.standard.integer(forKey: "barsPerChange")
        barsPerChange = bars > 0 ? bars : 4

        engine.onBeat = { [weak self] period, number, beatInBar, meter in
            guard let self = self else { return }
            self.beatLocked = true
            self.currentPeriod = period

            // Changes land on beat one of a bar once the meter is known, otherwise every 16 beats
            var change = false
            if number == 1 {
                change = true
            } else if meter > 0 {
                if beatInBar == 0 {
                    self.downbeatsSinceChange += 1
                    if self.downbeatsSinceChange >= self.barsPerChange { change = true }
                }
            } else if number % 16 == 0 {
                change = true
            }

            self.speed = self.desiredSpeed()
            if change {
                self.downbeatsSinceChange = 0
                self.applyVariation(period: period)
            } else if self.speed != .half || number % 2 == 0 {
                self.restartParrot(period: period)
            }
        }
        engine.onDrop = { [weak self] in
            guard let self = self, self.beatLocked else { return }
            self.applyVariation(period: self.currentPeriod)
        }
        engine.onSection = { [weak self] in
            guard let self = self, self.beatLocked else { return }
            self.applyVariation(period: self.currentPeriod)
        }
        engine.onLost = { [weak self] in self?.startIdle() }
        engine.onEnergy = { [weak self] intensity, riser in
            self?.intensity = intensity
            self?.riser = riser
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.engine.start()
            DispatchQueue.main.async {
                self.engineNote = ok ? "" : "beat sync unavailable"
                self.updateCounts()
            }
        }
    }

    // Spotify and Apple Music announce track and play state changes, which lets the detector start fresh instantly
    func observePlayers() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] note in
                self?.playerChanged(note)
            }
        }
    }

    func playerChanged(_ note: Notification) {
        guard syncEnabled, let info = note.userInfo else { return }
        let state = (info["Player State"] as? String) ?? ""
        var track = (info["Track ID"] as? String) ?? ""
        if track.isEmpty, let n = info["Persistent ID"] as? NSNumber { track = n.stringValue }
        if track.isEmpty { track = (info["Name"] as? String) ?? "" }

        if !state.isEmpty && state != "Playing" {
            engine.reset()
            startIdle()
        } else if !track.isEmpty && track != lastTrack {
            engine.beginTrack(track)      // starts fresh and loads this song's remembered loudness range
        }
        if !track.isEmpty { lastTrack = track }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
