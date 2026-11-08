import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : 4
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."

    /// What this device is called and the chip it has, for a Mac that reports its host
    /// (MacSettingsView → About This Mac). Names fit the firmware's 23-character
    /// product-name slot, so generation-numbered devices use their chip instead
    /// ("iPad Pro 11-inch (M1)"). Anything newer than the table reports its identifier
    /// and keeps the guest's own chip. Sources: Apple's device lists, AppleDB.
    static var modelIdentifier: String { HengeLog.deviceModel }
    static var marketingName: String { hostIdentity?.name ?? modelIdentifier }
    static var chipName: String? { hostIdentity?.chip }

    private static let hostIdentity: (name: String, chip: String)? = {
        let table: [String: (name: String, chip: String)] = [
            "iPhone13,1": ("iPhone 12 mini", "Apple A14"),
            "iPhone13,2": ("iPhone 12", "Apple A14"),
            "iPhone13,3": ("iPhone 12 Pro", "Apple A14"),
            "iPhone13,4": ("iPhone 12 Pro Max", "Apple A14"),
            "iPhone14,2": ("iPhone 13 Pro", "Apple A15"),
            "iPhone14,3": ("iPhone 13 Pro Max", "Apple A15"),
            "iPhone14,4": ("iPhone 13 mini", "Apple A15"),
            "iPhone14,5": ("iPhone 13", "Apple A15"),
            "iPhone14,6": ("iPhone SE (A15)", "Apple A15"),
            "iPhone14,7": ("iPhone 14", "Apple A15"),
            "iPhone14,8": ("iPhone 14 Plus", "Apple A15"),
            "iPhone15,2": ("iPhone 14 Pro", "Apple A16"),
            "iPhone15,3": ("iPhone 14 Pro Max", "Apple A16"),
            "iPhone15,4": ("iPhone 15", "Apple A16"),
            "iPhone15,5": ("iPhone 15 Plus", "Apple A16"),
            "iPhone16,1": ("iPhone 15 Pro", "Apple A17 Pro"),
            "iPhone16,2": ("iPhone 15 Pro Max", "Apple A17 Pro"),
            "iPhone17,1": ("iPhone 16 Pro", "Apple A18 Pro"),
            "iPhone17,2": ("iPhone 16 Pro Max", "Apple A18 Pro"),
            "iPhone17,3": ("iPhone 16", "Apple A18"),
            "iPhone17,4": ("iPhone 16 Plus", "Apple A18"),
            "iPhone17,5": ("iPhone 16e", "Apple A18"),
            "iPhone18,1": ("iPhone 17 Pro", "Apple A19 Pro"),
            "iPhone18,2": ("iPhone 17 Pro Max", "Apple A19 Pro"),
            "iPhone18,3": ("iPhone 17", "Apple A19"),
            "iPhone18,4": ("iPhone Air", "Apple A19 Pro"),
            "iPhone18,5": ("iPhone 17e", "Apple A19"),
            "iPhone19,2": ("iPhone 18 Pro", "Apple A20 Pro"),
            "iPhone19,3": ("iPhone 18 Pro Max", "Apple A20 Pro"),
            "iPhone19,7": ("iPhone 18 Pro Max", "Apple A20 Pro"),
            "iPhone19,4": ("iPhone Duo", "Apple A20 Pro"),
            "iPad13,1": ("iPad Air (A14)", "Apple A14"),
            "iPad13,2": ("iPad Air (A14)", "Apple A14"),
            "iPad13,4": ("iPad Pro 11-inch (M1)", "Apple M1"),
            "iPad13,5": ("iPad Pro 11-inch (M1)", "Apple M1"),
            "iPad13,6": ("iPad Pro 11-inch (M1)", "Apple M1"),
            "iPad13,7": ("iPad Pro 11-inch (M1)", "Apple M1"),
            "iPad13,8": ("iPad Pro 12.9-inch (M1)", "Apple M1"),
            "iPad13,9": ("iPad Pro 12.9-inch (M1)", "Apple M1"),
            "iPad13,10": ("iPad Pro 12.9-inch (M1)", "Apple M1"),
            "iPad13,11": ("iPad Pro 12.9-inch (M1)", "Apple M1"),
            "iPad13,16": ("iPad Air (M1)", "Apple M1"),
            "iPad13,17": ("iPad Air (M1)", "Apple M1"),
            "iPad13,18": ("iPad (10th generation)", "Apple A14"),
            "iPad13,19": ("iPad (10th generation)", "Apple A14"),
            "iPad14,1": ("iPad mini (A15)", "Apple A15"),
            "iPad14,2": ("iPad mini (A15)", "Apple A15"),
            "iPad14,3": ("iPad Pro 11-inch (M2)", "Apple M2"),
            "iPad14,4": ("iPad Pro 11-inch (M2)", "Apple M2"),
            "iPad14,5": ("iPad Pro 12.9-inch (M2)", "Apple M2"),
            "iPad14,6": ("iPad Pro 12.9-inch (M2)", "Apple M2"),
            "iPad14,8": ("iPad Air 11-inch (M2)", "Apple M2"),
            "iPad14,9": ("iPad Air 11-inch (M2)", "Apple M2"),
            "iPad14,10": ("iPad Air 13-inch (M2)", "Apple M2"),
            "iPad14,11": ("iPad Air 13-inch (M2)", "Apple M2"),
            "iPad15,3": ("iPad Air 11-inch (M3)", "Apple M3"),
            "iPad15,4": ("iPad Air 11-inch (M3)", "Apple M3"),
            "iPad15,5": ("iPad Air 13-inch (M3)", "Apple M3"),
            "iPad15,6": ("iPad Air 13-inch (M3)", "Apple M3"),
            "iPad15,7": ("iPad (A16)", "Apple A16"),
            "iPad15,8": ("iPad (A16)", "Apple A16"),
            "iPad16,1": ("iPad mini (A17 Pro)", "Apple A17 Pro"),
            "iPad16,2": ("iPad mini (A17 Pro)", "Apple A17 Pro"),
            "iPad16,3": ("iPad Pro 11-inch (M4)", "Apple M4"),
            "iPad16,4": ("iPad Pro 11-inch (M4)", "Apple M4"),
            "iPad16,5": ("iPad Pro 13-inch (M4)", "Apple M4"),
            "iPad16,6": ("iPad Pro 13-inch (M4)", "Apple M4"),
        ]
        return table[modelIdentifier]
    }()
}

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            henge_vm_key_hid(usage, down ? 1 : 0)
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if down {
                held.insert(usage)
            } else {
                held.remove(usage)
                if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return !scenes.isEmpty && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttonsDown: Set<Int32> = []
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0

    func start() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        lastScrollFirst = 0
        lastScrollSecond = 0
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            let locked = (note.object as? UIScene)?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        for button in buttonsDown { henge_vm_mouse_button(button, 0) }
        buttonsDown.removeAll()
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ button: Int32, _ pressed: Bool) {
        henge_vm_mouse_button(button, pressed ? 1 : 0)
        if pressed {
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
            StickyKeys.shared.releaseAll()
        }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second.
    /// macOS accelerates wheel units roughly quadratically, so use a tunable square root
    /// and cap each event to keep a small pad gesture from jumping across a page.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; sending both values doubles the scroll and adds sideways drift.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        let mostlyVertical = abs(first) > 2 * abs(second)
        let mostlyHorizontal = abs(second) > 2 * abs(first)
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        let way: Int32 = reverse ? -1 : 1
        let horizontal = way * Self.wheelUnits(horizontalRaw, scale: scale)
        let vertical = way * Self.wheelUnits(verticalRaw, scale: scale)
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second); units: \(horizontal), \(vertical)")
        }
        if horizontal != 0 || vertical != 0 { henge_vm_mouse_scroll(horizontal, vertical) }
    }

    private static func wheelUnits(_ value: Float, scale: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let units = Int32(min(32, (22 * scale * abs(value).squareRoot()).rounded()))
        return value < 0 ? -units : units
    }
}
