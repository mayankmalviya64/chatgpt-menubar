// ChatGPT Bar — a tiny menu bar app that shows chatgpt.com in a floating window
// (toggle with ⌥Space or the menu bar icon)
// and can pull in the text of the web page you are looking at in Safari/Chrome.
//
// Build:  ./build.sh      (no Xcode project, no paid developer account needed)

import Cocoa
import WebKit
import ServiceManagement
import PDFKit        // reads the text of PDFs open in Preview
import Carbon          // for the system-wide ⌥Space keyboard shortcut

// MARK: - Settings (saved between launches)

/// Small wrapper around UserDefaults so settings survive app restarts.
enum Settings {
    /// Privacy master switch. When false the app never looks at Safari/Chrome/Preview at all.
    static var readingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "readingEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "readingEnabled") }
    }
    /// Per-app switches (right-click menu): e.g. allow Safari but not Preview.
    static func isAppAllowed(_ bundleID: String) -> Bool {
        UserDefaults.standard.object(forKey: "allow." + bundleID) as? Bool ?? true
    }
    static func setAppAllowed(_ bundleID: String, _ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: "allow." + bundleID)
    }
    /// Open a ChatGPT Temporary Chat (not saved to history/memory) before inserting page context.
    static var useTemporaryChat: Bool {
        get { UserDefaults.standard.object(forKey: "useTemporaryChat") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useTemporaryChat") }
    }
    /// Mask emails / phone / card / ID numbers and strip link tokens in page text.
    static var redact: Bool {
        get { UserDefaults.standard.object(forKey: "redact") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "redact") }
    }
    static var autoContext: Bool {
        get { UserDefaults.standard.object(forKey: "autoContext") as? Bool ?? true }   // ON by default
        set { UserDefaults.standard.set(newValue, forKey: "autoContext") }
    }
    static var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: "pinned") }
        set { UserDefaults.standard.set(newValue, forKey: "pinned") }
    }
    static var large: Bool {
        get { UserDefaults.standard.bool(forKey: "large") }
        set { UserDefaults.standard.set(newValue, forKey: "large") }
    }
}

// MARK: - Reading the current browser page

/// What we learn about the page the user is viewing.
struct PageContext {
    var bundleID: String = ""
    var browserName: String
    var title: String
    var url: String
    var text: String?        // nil when we could not read the page text
    var error: String?       // explains why text could not be read
    var shield: Shield = .none   // set when we deliberately did NOT read (private window, blocked site)
}

/// The only apps ChatGPT Bar may read from (through AppleScript).
/// "safari", "chromium" and "preview" each need slightly different AppleScript words.
let knownBrowsers: [String: (appName: String, kind: String)] = [
    "com.apple.Safari":  ("Safari", "safari"),
    "com.google.Chrome": ("Google Chrome", "chromium"),
    "com.apple.Preview": ("Preview", "preview"),     // PDFs: text is read straight from the file
]
/// Order used in menus.
let knownAppOrder = ["com.apple.Safari", "com.google.Chrome", "com.apple.Preview"]

// MARK: - Privacy: private windows, blocked sites, hiding personal details

/// Why a page was deliberately not read.
enum Shield {
    case none            // fine to read
    case privateWindow   // Safari Private / Chrome Incognito window
    case unverified      // couldn't confirm it's NOT private → treated as private (fail-safe)
    case blockedSite     // site is on the blocked-sites list
}

/// Short message for the toolbar.
func shieldMessage(_ shield: Shield, app: String) -> String {
    switch shield {
    case .privateWindow: return "Private window — nothing read"
    case .unverified:    return app == "Safari" ? "Safari not read — allow Accessibility to check for private windows" : "\(app) not read — couldn't check for Incognito"
    case .blockedSite:   return "Blocked site — nothing read"
    case .none:          return ""
    }
}

var askedForAccessibility = false   // only show the macOS Accessibility prompt once per launch

/// Is the front window of this app a private / Incognito window?
/// This runs BEFORE anything is read from the page.
func privateWindowCheck(bundleID: String) -> Shield {
    guard let browser = knownBrowsers[bundleID] else { return .none }
    switch browser.kind {
    case "chromium":
        // Chrome tells us directly: "incognito" or "normal".
        let r = runAppleScript("tell application \"\(browser.appName)\" to if (count of windows) > 0 then return mode of front window")
        if let error = r.error { lastReadError = "\(browser.appName): \(error)"; return .unverified }
        return r.result == "incognito" ? .privateWindow : .none
    case "safari":
        // Safari's AppleScript can't tell private windows apart, but macOS Accessibility
        // names them "<page>, Private Browsing". No permission → don't read Safari at all.
        guard AXIsProcessTrusted() else {
            if !askedForAccessibility {
                askedForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)          // shows the macOS permission prompt
            }
            return .unverified
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .none }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef) != .success,
           AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            return .unverified
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        return title.contains("Private Browsing") ? .privateWindow : .none
    default:
        return .none     // Preview has no private mode
    }
}

/// The blocked-sites list lives in a plain text file you can edit.
let blocklistURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ChatGPT Bar/blocked-sites.txt")

let defaultBlocklist = """
# ChatGPT Bar never reads pages from these sites (treated like a private window).
# One site per line. "example.com" also covers its subdomains (mail.example.com).
# Use * as a wildcard, e.g. *bank* blocks every site with "bank" in its name.
# Lines starting with # are ignored. Save the file; changes apply right away.

# Email
mail.google.com
outlook.live.com
outlook.office.com
outlook.office365.com
mail.yahoo.com
mail.proton.me
icloud.com

# Sign-in pages
accounts.google.com
login.microsoftonline.com
appleid.apple.com
account.apple.com
*login*
*signin*

# Password managers
1password.com
lastpass.com
bitwarden.com
dashlane.com

# Banks and cards
*bank*
onlinesbi.sbi
sbi.co.in
sbicard.com
kotak.com
americanexpress.com
chase.com
wellsfargo.com
citi.com
capitalone.com

# Payments
paypal.com
paytm.com
phonepe.com
pay.google.com
razorpay.com
cred.club

# Investing and crypto
zerodha.com
groww.in
upstox.com
angelone.in
robinhood.com
fidelity.com
vanguard.com
schwab.com
coinbase.com
binance.com

# Health
practo.com
1mg.com
pharmeasy.in
apollo247.com
*mychart*
*patient*

# Government IDs and tax
incometax.gov.in
uidai.gov.in
digilocker.gov.in
epfindia.gov.in
irs.gov
"""

/// Reads the list (creating it with the defaults the first time).
func loadBlocklist() -> [String] {
    if !FileManager.default.fileExists(atPath: blocklistURL.path) {
        try? FileManager.default.createDirectory(at: blocklistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? defaultBlocklist.write(to: blocklistURL, atomically: true, encoding: .utf8)
    }
    let text = (try? String(contentsOf: blocklistURL, encoding: .utf8)) ?? defaultBlocklist
    return text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// True if this web address is on the blocked-sites list.
func isBlockedSite(_ urlString: String) -> Bool {
    guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
    for entry in loadBlocklist() {
        if entry.contains("*") {
            if NSPredicate(format: "SELF LIKE %@", entry).evaluate(with: host) { return true }
        } else if host == entry || host.hasSuffix("." + entry) {
            return true
        }
    }
    return false
}

/// Removes the "?…" and "#…" part of a link — that's where login/tracking tokens live.
func stripLinkTokens(_ url: String) -> String {
    guard var parts = URLComponents(string: url), parts.scheme?.hasPrefix("http") == true else { return url }
    parts.query = nil
    parts.fragment = nil
    return parts.string ?? url
}

/// Replaces every regex match with whatever `transform` returns (nil = leave it alone).
func replaceMatches(_ pattern: String, in text: String, _ transform: (String) -> String?) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    var result = text
    // Go backwards so earlier positions stay valid while we replace.
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        if let replacement = transform(String(result[range])) { result.replaceSubrange(range, with: replacement) }
    }
    return result
}

/// Luhn checksum — real card numbers pass it, random digit runs usually don't.
func passesLuhn(_ digits: String) -> Bool {
    var sum = 0
    for (i, ch) in digits.reversed().enumerated() {
        guard var d = ch.wholeNumberValue else { return false }
        if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
        sum += d
    }
    return sum % 10 == 0
}

/// Hides personal details in page text before it goes to ChatGPT.
func redactPersonalDetails(_ text: String) -> String {
    let digitsOnly = { (s: String) in s.filter(\.isNumber) }
    var t = text
    // 1) Links: drop ?query and #fragment (tokens), keep the address.
    t = replaceMatches(#"https?://[^\s?#]+[?#][^\s)\]>"']*"#, in: t) { link in
        String(link.prefix { $0 != "?" && $0 != "#" })
    }
    // 2) Email addresses.
    t = replaceMatches(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: t) { _ in "[email]" }
    // 3) Card numbers: 13–19 digits (spaces/dashes allowed) that pass the Luhn check.
    t = replaceMatches(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, in: t) { m in
        passesLuhn(digitsOnly(m)) ? "[card]" : nil
    }
    // 4) 12-digit ID numbers written in groups of 4 (e.g. Aadhaar).
    //    (Not when it's part of a longer digit run, e.g. a 16-digit number.)
    t = replaceMatches(#"(?<!\d)(?<!\d[ -])\d{4}[ -]\d{4}[ -]\d{4}(?![ -]?\d)"#, in: t) { _ in "[id-number]" }
    // 5) Phone numbers: 10–13 digits, optional +country code, spaces/dashes/brackets.
    //    (A full stop right after is fine; "98.4" style decimals are not phones.)
    t = replaceMatches(#"(?<![\w.,/])(?:\+\d{1,3}[\s-]?)?(?:\(?\d{2,5}\)?[\s-]?){1,4}\d{2,5}(?!\w|[.,]\d|/)"#, in: t) { m in
        (10...13).contains(digitsOnly(m).count) ? "[phone]" : nil
    }
    return t
}

/// JavaScript run inside the browser tab.
/// It returns the selected text if there is any, otherwise the main article text.
/// (Written with single quotes and no backslashes so it can sit inside an AppleScript string.)
/// Same as above but always the whole page (used when you ask about a selection,
/// so ChatGPT gets the surrounding page as background).
let fullPageJS = "(function(){var el=document.querySelector('article')||document.querySelector('main')||document.body;return el?el.innerText:'';})()"
/// Just the text you have selected (empty if nothing is selected).
let selectionJS = "String(window.getSelection())"

let pageTextJS = "(function(){var nl=String.fromCharCode(10);var s=String(window.getSelection());if(s.trim().length>0){return 'SELECTED TEXT:'+nl+s;}var el=document.querySelector('article')||document.querySelector('main')||document.body;return el?el.innerText:'';})()"

/// Runs an AppleScript and returns its text result, or an error message.
/// Error number -1743 means macOS has not allowed this app to control that browser.
func runAppleScript(_ source: String) -> (result: String?, error: String?) {
    var errorInfo: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return (nil, "Could not build script") }
    let output = script.executeAndReturnError(&errorInfo)
    if let errorInfo = errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
        let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        return (nil, "\(message) (\(number))")
    }
    return (output.stringValue, nil)
}

/// Why the last page read failed (shown to the user so problems aren't silent).
var lastReadError: String?

/// Browsers ordered by which one has a window closest to the front of the screen.
/// This is more reliable than "the browser you clicked last".
func browsersFrontToBack() -> [String] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var ordered: [String] = []
    for info in windows {                                          // the list is already front → back
        guard (info[kCGWindowLayer as String] as? Int) == 0,       // 0 = normal app windows
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              knownBrowsers[id] != nil, !ordered.contains(id) else { continue }
        ordered.append(id)
    }
    return ordered
}

/// Finds the page you are looking at: tries the front-most browser first, then the
/// one you used last, then any other running browser.
func findPage(lastUsed: String?, includeText: Bool) -> PageContext? {
    lastReadError = nil
    guard Settings.readingEnabled else { return nil }          // privacy switch is off
    var candidates = browsersFrontToBack()
    if let last = lastUsed, !candidates.contains(last) { candidates.append(last) }
    for id in knownBrowsers.keys where !candidates.contains(id) { candidates.append(id) }
    for id in candidates where Settings.isAppAllowed(id) {
        if let ctx = readPage(bundleID: id, includeText: includeText) { return ctx }
    }
    return nil
}

/// Reads title + URL (+ text if `includeText`) of the front tab of the given browser.
func readPage(bundleID: String, includeText: Bool, wholePage: Bool = false) -> PageContext? {
    guard let browser = knownBrowsers[bundleID] else { return nil }
    // Never launch a browser by accident: only talk to it if it is already running.
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }

    let app = browser.appName
    if browser.kind == "preview" {
        var ctx = readPreview(includeText: includeText)
        ctx?.bundleID = bundleID
        return ctx
    }
    // Privacy first: private / Incognito windows are never read — not even the title.
    let shield = privateWindowCheck(bundleID: bundleID)
    if shield != .none {
        return PageContext(bundleID: bundleID, browserName: app, title: "", url: "", text: nil, error: nil, shield: shield)
    }

    // AppleScript vocabulary differs: Safari says "current tab", Chrome says "active tab".
    let tab = browser.kind == "safari" ? "current tab of front window" : "active tab of front window"
    let titleWord = browser.kind == "safari" ? "name" : "title"

    // 1) Title and URL (works without any extra browser setting).
    let infoScript = """
    tell application "\(app)"
        if (count of windows) = 0 then return ""
        return (\(titleWord) of \(tab)) & linefeed & (URL of \(tab))
    end tell
    """
    let info = runAppleScript(infoScript)
    if let error = info.error { lastReadError = "\(app): \(error)" }
    guard let raw = info.result, !raw.isEmpty else { return nil }
    let parts = raw.components(separatedBy: "\n")
    var ctx = PageContext(bundleID: bundleID, browserName: app, title: parts.first ?? "", url: parts.count > 1 ? parts[1] : "", text: nil, error: nil)
    // Blocked site (bank, email, …)? Forget what we saw and read nothing.
    if isBlockedSite(ctx.url) {
        return PageContext(bundleID: bundleID, browserName: app, title: "", url: "", text: nil, error: nil, shield: .blockedSite)
    }
    if !includeText { return ctx }
    let pageJS = wholePage ? fullPageJS : pageTextJS

    // 2) Page text (needs "Allow JavaScript from Apple Events" turned on in the browser).
    let jsScript = browser.kind == "safari"
        ? "tell application \"\(app)\" to do JavaScript \"\(pageJS)\" in \(tab)"
        : "tell application \"\(app)\" to execute \(tab) javascript \"\(pageJS)\""
    let js = runAppleScript(jsScript)
    if let text = js.result, !text.isEmpty {
        ctx.text = text
    } else {
        ctx.error = js.error ?? "Page returned no text"
    }
    return ctx
}

/// The text currently selected in Safari/Chrome ("" if none or not allowed).
/// (Preview selections arrive through the right-click "Ask ChatGPT" service instead.)
func readSelection(bundleID: String) -> String {
    guard let browser = knownBrowsers[bundleID], browser.kind != "preview" else { return "" }
    guard privateWindowCheck(bundleID: bundleID) == .none else { return "" }   // never peek into private windows
    let tab = browser.kind == "safari" ? "current tab of front window" : "active tab of front window"
    let script = browser.kind == "safari"
        ? "tell application \"\(browser.appName)\" to do JavaScript \"\(selectionJS)\" in \(tab)"
        : "tell application \"\(browser.appName)\" to execute \(tab) javascript \"\(selectionJS)\""
    return (runAppleScript(script).result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Long documents (e.g. a whole book in Preview) are cut to `limit` characters,
/// keeping the part AROUND your selection rather than just the beginning.
func excerpt(_ text: String, around selection: String, limit: Int) -> String {
    if text.count <= limit { return text }
    let probe = String(selection.prefix(80))
    guard !probe.isEmpty, let hit = text.range(of: probe) else {
        return String(text.prefix(limit)) + "\n[…cut at \(limit) characters…]"
    }
    let center = text.distance(from: text.startIndex, to: hit.lowerBound)
    let startOffset = max(0, min(center - limit / 2, text.count - limit))
    let start = text.index(text.startIndex, offsetBy: startOffset)
    let end = text.index(start, offsetBy: limit)
    return "[…earlier text cut…]\n" + text[start..<end] + "\n[…later text cut…]"
}

/// Preview: get the open document's name and file path, then read a PDF's text with PDFKit.
func readPreview(includeText: Bool) -> PageContext? {
    let info = runAppleScript("""
    tell application "Preview"
        if (count of windows) = 0 then return ""
        set d to document of front window
        return (name of d) & linefeed & (path of d)
    end tell
    """)
    if let error = info.error { lastReadError = "Preview: \(error)" }
    guard let raw = info.result, !raw.isEmpty else { return nil }
    let parts = raw.components(separatedBy: "\n")
    let path = parts.count > 1 ? parts[1] : ""
    let fileURL = URL(fileURLWithPath: path)
    var ctx = PageContext(browserName: "Preview", title: parts.first ?? "", url: fileURL.absoluteString, text: nil, error: nil)
    if !includeText { return ctx }
    if let pdf = PDFDocument(url: fileURL), let text = pdf.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ctx.text = text
    } else {
        ctx.error = "No readable text (images or scanned PDFs only give the file name)"
    }
    return ctx
}

// MARK: - Main window content (toolbar + ChatGPT web view)

final class ChatViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    let pageLabel = NSTextField(labelWithString: "No page")
    let autoCheckbox = NSButton(checkboxWithTitle: "Auto", target: nil, action: nil)
    let pinButton = NSButton()
    let privacyButton = NSButton()               // 📃 privacy switch: page reading on/off
    let addButton = NSButton()
    var popupWindows: [NSWindow] = []        // login popups (Google/Apple/Microsoft)
    var pageLoaded = false
    var lastAutoURL = ""                     // page we already auto-added (avoid duplicates)
    var pendingAutoAdd = false               // auto-add waiting for the page to finish loading
    var lastSelection = ""                   // selection we already asked about (avoid duplicates)
    var suppressAutoOnce = false             // skip auto-add when "Ask ChatGPT" opened the window

    /// Which browser to read from — set by the AppDelegate.
    var browserBundleID: () -> String? = { nil }
    /// Called when the user toggles the pin button.
    var onPinChanged: (Bool) -> Void = { _ in }
    /// Called when the user presses the "bigger / smaller" button.
    var onToggleSize: (Bool) -> Void = { _ in }

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // keeps you logged in between launches
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        // Pretend to be normal Safari so Google login does not block the embedded browser.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }  // right-click → Inspect, for debugging
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let size = Settings.large ? NSSize(width: 760, height: 860) : NSSize(width: 440, height: 680)
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        // ---- Toolbar buttons ----
        func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        privacyButton.isBordered = false
        privacyButton.target = self
        privacyButton.action = #selector(privacyToggled)

        let addButton = self.addButton
        addButton.title = "Add page"
        addButton.target = self
        addButton.action = #selector(addPageClicked)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.toolTip = "Put the current Safari/Chrome page (or your selected text) into the message box"

        autoCheckbox.target = self
        autoCheckbox.action = #selector(autoToggled)
        autoCheckbox.state = Settings.autoContext ? .on : .off
        autoCheckbox.controlSize = .small
        autoCheckbox.toolTip = "Automatically add the page each time you open ChatGPT Bar on a new page"

        pinButton.image = NSImage(systemSymbolName: Settings.pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(pinToggled)
        pinButton.toolTip = "Keep open when clicking elsewhere"

        pageLabel.lineBreakMode = .byTruncatingTail
        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [
            iconButton("square.and.pencil", "New chat (⌘N)", #selector(newChat)),
            privacyButton, pageLabel, addButton, autoCheckbox, pinButton,
            iconButton("arrow.up.left.and.arrow.down.right", "Bigger / smaller", #selector(toggleSize)),
            iconButton("arrow.clockwise", "Reload (⌘R)", #selector(reload)),
        ])
        bar.orientation = .horizontal
        bar.spacing = 6
        // Left inset leaves room for the window's red close button (the toolbar sits in the title bar).
        bar.edgeInsets = NSEdgeInsets(top: 2, left: 30, bottom: 2, right: 8)

        // ---- Layout: toolbar on top, web view fills the rest ----
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refreshPrivacyUI()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    // MARK: Toolbar actions

    @objc func newChat() { webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!)) }
    @objc func reload() { webView.reload() }
    @objc func addPageClicked() { addPage(manual: true) }
    /// 📃 button: turn all page reading on or off.
    @objc func privacyToggled() {
        Settings.readingEnabled.toggle()
        refreshPrivacyUI()
        if Settings.readingEnabled { windowDidAppear() }
    }

    /// Updates the page icon and greys out Add page / Auto while reading is off.
    func refreshPrivacyUI() {
        let on = Settings.readingEnabled
        // A plain page icon (📃). When reading is off: the crossed-out page, in red.
        // ("text.page.slash" needs macOS 15; older macOS falls back to an empty page.)
        let offIcon = NSImage(systemSymbolName: "text.page.slash", accessibilityDescription: "Page reading off")
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: "Page reading off")
        privacyButton.image = on ? NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Page reading on") : offIcon
        privacyButton.contentTintColor = on ? nil : .systemRed
        privacyButton.toolTip = on
            ? "Page reading is ON (Safari, Chrome, Preview). Click to turn it off for privacy."
            : "Page reading is OFF: nothing is read from your apps. Click to turn it back on."
        addButton.isEnabled = on
        autoCheckbox.isEnabled = on
        if !on { pageLabel.stringValue = "Page reading off"; pageLabel.toolTip = nil }
    }

    @objc func autoToggled() { Settings.autoContext = autoCheckbox.state == .on }
    @objc func pinToggled() {
        Settings.pinned.toggle()
        pinButton.image = NSImage(systemSymbolName: Settings.pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        onPinChanged(Settings.pinned)
    }
    @objc func toggleSize() {
        Settings.large.toggle()
        onToggleSize(Settings.large)
    }

    // MARK: Page context

    /// Called every time the window opens: show the page name and auto-add if enabled.
    func windowDidAppear() {
        view.window?.makeFirstResponder(webView)
        if suppressAutoOnce { suppressAutoOnce = false; return }   // "Ask ChatGPT" handles this opening
        guard Settings.readingEnabled else { refreshPrivacyUI(); return }
        guard let ctx = findPage(lastUsed: browserBundleID(), includeText: false) else {
            pageLabel.stringValue = isPermissionError ? "Needs permission — click Add page" : "Open a page in Safari, Chrome or Preview"
            pageLabel.toolTip = lastReadError
            return
        }
        // Private window or blocked site: say so, and do nothing else.
        if ctx.shield != .none {
            pageLabel.stringValue = shieldMessage(ctx.shield, app: ctx.browserName)
            pageLabel.toolTip = pageLabel.stringValue
            return
        }
        pageLabel.stringValue = ctx.title.isEmpty ? ctx.url : ctx.title
        pageLabel.toolTip = "\(ctx.browserName): \(ctx.url)"

        // Text selected in Safari/Chrome? Ask about that selection (with the page as background).
        if Settings.autoContext && Settings.isAppAllowed(ctx.bundleID) {
            let selection = readSelection(bundleID: ctx.bundleID)
            if !selection.isEmpty && selection != lastSelection {
                ask(selection: selection, sourceID: ctx.bundleID)
                return
            }
        }

        // Auto mode: only once per page, and never for ChatGPT itself or empty tabs.
        let isUsefulPage = (ctx.url.hasPrefix("http") || ctx.url.hasPrefix("file:")) && !ctx.url.contains("chatgpt.com")
        if Settings.autoContext && isUsefulPage && ctx.url != lastAutoURL {
            if pageLoaded { addPage(manual: false) } else { pendingAutoAdd = true }
        }
    }

    /// Reads the page text and drops it into ChatGPT's message box.
    func addPage(manual: Bool) {
        guard let ctx = findPage(lastUsed: browserBundleID(), includeText: true) else {
            pageLabel.stringValue = isPermissionError ? "Needs permission to read your apps" : "No Safari/Chrome/Preview page found"
            pageLabel.toolTip = lastReadError
            if manual { showReadFailureHelp() }
            return
        }
        if ctx.shield != .none {
            pageLabel.stringValue = shieldMessage(ctx.shield, app: ctx.browserName)
            pageLabel.toolTip = pageLabel.stringValue
            if manual { NSSound.beep() }
            return
        }
        lastAutoURL = ctx.url

        let isFile = ctx.url.hasPrefix("file:")
        let shownURL = Settings.redact ? stripLinkTokens(ctx.url) : ctx.url
        var message = isFile
            ? "Context from the document I'm viewing in \(ctx.browserName):\nTitle: \(ctx.title)\nFile: \(URL(string: ctx.url)?.path ?? ctx.url)\n"
            : "Context from the page I'm viewing:\nTitle: \(ctx.title)\nURL: \(shownURL)\n"
        if var text = ctx.text {
            if Settings.redact { text = redactPersonalDetails(text) }
            // Very long pages are cut so the message stays reasonable.
            let limit = 60_000
            if text.count > limit { text = String(text.prefix(limit)) + "\n[…page text cut at \(limit) characters…]" }
            message += "\n\(text)\n"
        } else if manual && !isFile {
            // Explain the one-time browser setting that is needed for page text.
            showJavaScriptHelp(browser: ctx.browserName, error: ctx.error ?? "")
        }
        message += "\n---\n"
        deliver(message)
        pageLabel.stringValue = (ctx.text != nil ? "Added: " : "Added link only: ") + (ctx.title.isEmpty ? ctx.url : ctx.title)
    }

    /// "Ask about this selection": puts the selected text in the message box, plus the whole
    /// page/PDF as background, then leaves the cursor for your question.
    /// If the 📃 privacy switch is off, only the selected text (which you chose to send) is used.
    func ask(selection: String, sourceID: String?) {
        lastSelection = selection
        var ctx: PageContext? = nil
        if Settings.readingEnabled, let id = sourceID, knownBrowsers[id] != nil, Settings.isAppAllowed(id) {
            ctx = readPage(bundleID: id, includeText: true, wholePage: true)
        }
        // Private window / blocked site: you chose to send the selection, but nothing else is used.
        let shielded = ctx?.shield ?? .none
        if shielded != .none { ctx = nil }
        var message = ""
        if let ctx = ctx {
            lastAutoURL = ctx.url                       // don't also auto-add this page
            let isFile = ctx.url.hasPrefix("file:")
            let shownURL = Settings.redact ? stripLinkTokens(ctx.url) : ctx.url
            let source = isFile ? "file: \(URL(string: ctx.url)?.path ?? ctx.url)" : shownURL
            message += "I'm reading \"\(ctx.title)\" in \(ctx.browserName) (\(source)).\n\n"
        }
        // Your own selection is sent exactly as you selected it.
        message += "I selected this part:\n\"\"\"\n\(selection)\n\"\"\"\n"
        if var text = ctx?.text {
            if Settings.redact { text = redactPersonalDetails(text) }
            message += "\nFull text for background (use it to answer, focusing on the selected part):\n\(excerpt(text, around: selection, limit: 40_000))\n"
        }
        message += "\n---\nMy question about the selected part: "
        deliver(message)
        if shielded != .none {
            pageLabel.stringValue = shieldMessage(shielded, app: knownBrowsers[sourceID ?? ""]?.appName ?? "") + " — only your selection was sent"
        } else {
            pageLabel.stringValue = "Asking about: \"" + selection.prefix(40) + (selection.count > 40 ? "…\"" : "\"")
        }
        pageLabel.toolTip = selection
    }

    var pendingInsert: String?               // text waiting for the Temporary Chat to load

    /// True when the ChatGPT page is a Temporary Chat (not saved to history or memory).
    var isTemporaryChat: Bool { webView.url?.query?.contains("temporary-chat=true") == true }

    /// Sends page context to the message box — inside a Temporary Chat when that setting is on.
    func deliver(_ text: String) {
        if Settings.useTemporaryChat && !isTemporaryChat {
            pendingInsert = text                 // inserted once the Temporary Chat finishes loading
            webView.load(URLRequest(url: URL(string: "https://chatgpt.com/?temporary-chat=true")!))
        } else {
            insertIntoComposer(text, attemptsLeft: 12)
        }
    }

    /// Puts text into ChatGPT's message box. Retries a few times because the box appears
    /// a moment after the page loads.
    func insertIntoComposer(_ text: String, attemptsLeft: Int) {
        let js = """
        const box = document.querySelector('#prompt-textarea') || document.querySelector('div[contenteditable="true"]') || document.querySelector('textarea');
        if (!box) { return 'missing'; }
        box.focus();
        // 1st try: a real "paste" so ChatGPT can turn long text into an attachment chip.
        try {
            const data = new DataTransfer();
            data.setData('text/plain', text);
            const ev = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
            box.dispatchEvent(ev);
            if (ev.defaultPrevented) { return 'pasted'; }
        } catch (e) {}
        // 2nd try: type the text in.
        if (box.tagName === 'TEXTAREA') {
            box.value = text + box.value;
            box.dispatchEvent(new Event('input', { bubbles: true }));
            return 'set';
        }
        document.execCommand('insertText', false, text);
        return 'typed';
        """
        webView.callAsyncJavaScript(js, arguments: ["text": text], in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result, (value as? String) == "missing", attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.insertIntoComposer(text, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    /// True when macOS blocked us from controlling the browser (error -1743).
    var isPermissionError: Bool { lastReadError?.contains("-1743") == true }

    /// Explains why no page was found, with a button to the right System Settings page.
    func showReadFailureHelp() {
        let alert = NSAlert()
        if isPermissionError {
            alert.messageText = "Please allow ChatGPT Bar to read your browser"
            alert.informativeText = "macOS is blocking it. In System Settings → Privacy & Security → Automation, turn on Safari, Google Chrome and Preview under ChatGPT Bar.\n\n(\(lastReadError ?? ""))"
            alert.addButton(withTitle: "Open Automation Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        } else {
            alert.messageText = "No Safari, Chrome or Preview page found"
            alert.informativeText = "Please open a web page in Safari or Chrome, or a PDF in Preview, then try again. (Also check the app is ticked in the menu bar icon's right-click menu.)" + (lastReadError.map { "\n\n(\($0))" } ?? "")
            alert.runModal()
        }
    }

    func showJavaScriptHelp(browser: String, error: String) {
        let alert = NSAlert()
        alert.messageText = "Allow ChatGPT Bar to read page text"
        let where_ = browser.contains("Safari")
            ? "Safari → Settings → Advanced → tick \"Show features for web developers\", then Develop menu → tick \"Allow JavaScript from Apple Events\"."
            : "\(browser) → View → Developer → tick \"Allow JavaScript from Apple Events\"."
        alert.informativeText = "Only the page title and link were added.\n\nOne-time setup: \(where_)\n\nAlso allow ChatGPT Bar under System Settings → Privacy & Security → Automation.\n\n(\(error))"
        alert.runModal()
    }

    // MARK: Navigation (login, external links, downloads)

    /// Sites that should stay inside the app (ChatGPT itself + login providers).
    func isInternalHost(_ host: String?) -> Bool {
        guard let host = host else { return true }
        let allowed = ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
                       "google.com", "accounts.google.com", "apple.com", "icloud.com",
                       "microsoft.com", "live.com", "microsoftonline.com", "cloudflare.com"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == self.webView {
            pageLoaded = true
            if let text = pendingInsert { pendingInsert = nil; insertIntoComposer(text, attemptsLeft: 12) }
            if pendingAutoAdd { pendingAutoAdd = false; addPage(manual: false) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        // Clicking a normal outside link (e.g. a citation) opens it in your default browser.
        if webView == self.webView, action.navigationType == .linkActivated,
           let url = action.request.url, url.scheme?.hasPrefix("http") == true, !isInternalHost(url.host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    /// Downloads (files ChatGPT makes for you) are saved to ~/Downloads.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = folder.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {   // don't overwrite existing files
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            target = folder.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }

    // MARK: UI delegate (file upload, popups, microphone)

    /// The "attach file" button in ChatGPT opens a normal macOS file picker.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    /// Links / popups that want a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        // Plain outside links → default browser.
        if let url = url, url.scheme?.hasPrefix("http") == true, !isInternalHost(url.host) {
            NSWorkspace.shared.open(url)
            return nil
        }
        // ChatGPT's own links → just open in the main view.
        if let host = url?.host, host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            self.webView.load(action.request)
            return nil
        }
        // Login popups (Google / Apple / Microsoft) → small real window so login can finish.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 650), configuration: configuration)
        popup.customUserAgent = self.webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popupWindows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows.removeAll { window in
            if window.contentView === webView { window.close(); return true }
            return false
        }
    }

    /// Allow the microphone for ChatGPT voice mode.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(isInternalHost(origin.host) ? .grant : .prompt)
    }
}

// MARK: - The chat window

/// The floating window. Clicking its red close button just hides it
/// instead of really closing it (so the chat stays loaded).
final class ChatWindow: NSWindow {
    var onCloseButton: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func performClose(_ sender: Any?) { onCloseButton() }
}

// MARK: - App delegate: menu bar icon + window + ⌥Space shortcut

/// Carbon hot keys need a plain C callback, so it reaches the app through this global.
weak var sharedDelegate: AppDelegate?

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: ChatWindow!
    let chat = ChatViewController()
    var clickOutsideMonitor: Any?
    var lastBrowserID: String?     // last Safari/Chrome window you used
    var hotKeyRef: EventHotKeyRef?

    let normalSize = NSSize(width: 440, height: 680)
    let largeSize = NSSize(width: 760, height: 860)

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedDelegate = self
        buildMainMenu()

        // Menu bar icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "ChatGPT")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "ChatGPT Bar (⌥Space)"

        buildWindow()
        registerHotKey()

        // Right-click → "Ask ChatGPT" on selected text (Safari, Chrome, Preview only — see build.sh).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Remember which browser you used last, so we know whose page to read.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, knownBrowsers[front] != nil {
            lastBrowserID = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let id = app.bundleIdentifier, knownBrowsers[id] != nil {
                self?.lastBrowserID = id
            }
        }
        chat.browserBundleID = { [weak self] in self?.lastBrowserID ?? "com.apple.Safari" }
        chat.onPinChanged = { [weak self] pinned in self?.applyPin(pinned) }
        chat.onToggleSize = { [weak self] large in self?.resizeKeepingBottomRight(large ? self!.largeSize : self!.normalSize) }
    }

    // MARK: Window setup

    func buildWindow() {
        window = ChatWindow(contentRect: NSRect(origin: .zero, size: normalSize),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        window.title = "ChatGPT"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.minSize = NSSize(width: 340, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Show on whichever desktop/Space you're on, even over full-screen apps.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = chat          // also starts loading ChatGPT right away
        window.onCloseButton = { [weak self] in self?.hideWindow() }

        // Position: put it back exactly where you left it (macOS saves this automatically
        // under the name below). First launch → bottom-right corner of the screen.
        let restored = window.setFrameUsingName("ChatGPTBarWindow")
        if !restored || !isOnSomeScreen(window.frame) {
            window.setFrame(bottomRightFrame(size: normalSize), display: false)
        }
        window.setFrameAutosaveName("ChatGPTBarWindow")   // saves every move/resize from now on
        applyPin(Settings.pinned)
    }

    /// Bottom-right corner of the main screen, 16 pt away from the edges and the Dock.
    func bottomRightFrame(size: NSSize) -> NSRect {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(x: area.maxX - size.width - 16, y: area.minY + 16, width: size.width, height: size.height)
    }

    /// True if the window's middle is on a connected screen (it might not be if a monitor was unplugged).
    func isOnSomeScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
    }

    /// If part of the window hangs off the screen edge, slide it back so all of it shows.
    /// (Only moves it; the size is kept unless it's bigger than the screen.)
    func keepFullyOnScreen() {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = window.frame
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
        f.origin.y = min(max(f.minY, area.minY), area.maxY - f.height)
        if f != window.frame { window.setFrame(f, display: false) }
    }

    /// The "bigger / smaller" button: keep the bottom-right corner where it is.
    func resizeKeepingBottomRight(_ size: NSSize) {
        let f = window.frame
        window.setFrame(NSRect(x: f.maxX - size.width, y: f.minY, width: size.width, height: size.height), display: true, animate: false)
        keepFullyOnScreen()
    }

    /// Pinned = stay on top of other apps and don't hide when clicking elsewhere.
    func applyPin(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        if pinned { stopOutsideMonitor() } else if window.isVisible { startOutsideMonitor() }
    }

    // MARK: Show / hide (instant, like a normal pop-up window)

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showRightClickMenu(); return }
        toggleWindow()
    }

    /// ⌥Space and the menu bar icon both come here.
    func toggleWindow() {
        if window.isVisible {
            if window.isKeyWindow && NSApp.isActive {
                hideWindow()
            } else {
                // Visible but behind another app → just bring it to the front.
                bringToFront()
                chat.windowDidAppear()
            }
        } else {
            showWindow()
        }
    }

    func showWindow() {
        // If the saved spot is on a monitor that's no longer connected, use the bottom-right corner.
        if !isOnSomeScreen(window.frame) { window.setFrame(bottomRightFrame(size: window.frame.size), display: false) }
        keepFullyOnScreen()
        bringToFront()
        if !Settings.pinned { startOutsideMonitor() }
        chat.windowDidAppear()
    }

    /// Puts the window on top of every other app and makes it ready for typing.
    /// (Newer macOS can refuse to switch apps while you're typing elsewhere, so we also
    /// use orderFrontRegardless, which always shows the window on top.)
    func bringToFront() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hideWindow() {
        guard window.isVisible else { return }
        stopOutsideMonitor()
        window.orderOut(nil)       // hides it; position and size stay saved
    }

    // MARK: ⌥Space keyboard shortcut

    func registerHotKey() {
        // Listen for "hot key pressed" events…
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { sharedDelegate?.toggleWindow() }
            return noErr
        }, 1, &eventType, nil, nil)
        // …and register Option (⌥) + Space as that hot key.
        let id = EventHotKeyID(signature: OSType(0x43475042), id: 1)   // "CGPB"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)

        // The official ChatGPT app also uses ⌥Space by default — warn if it's running.
        let officialRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").isEmpty
        if status != noErr || officialRunning {
            let alert = NSAlert()
            alert.messageText = status != noErr ? "⌥Space is already taken" : "Two apps want ⌥Space"
            alert.informativeText = "The official ChatGPT app also uses Option+Space. Please change its shortcut: ChatGPT app → Settings → Keyboard shortcut, or quit it. You can still click the menu bar icon."
            alert.runModal()
        }
    }

    /// Hide when you click in any other app (unless pinned).
    func startOutsideMonitor() {
        stopOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideWindow()
        }
    }
    func stopOutsideMonitor() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
    }

    /// Called by macOS when you pick "Ask ChatGPT" on selected text.
    @objc func askChatGPT(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let selection = (pboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return }
        // The app you right-clicked in is still the front app at this moment.
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? lastBrowserID
        if window.isVisible {
            bringToFront()
        } else {
            chat.suppressAutoOnce = true
            showWindow()
        }
        chat.ask(selection: selection, sourceID: source)
    }

    @objc func toggleReading() {
        Settings.readingEnabled.toggle()
        chat.refreshPrivacyUI()
        if Settings.readingEnabled && window.isVisible { chat.windowDidAppear() }
    }

    @objc func toggleAppAllowed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.setAppAllowed(id, !Settings.isAppAllowed(id))
    }

    @objc func toggleTemporaryChat() { Settings.useTemporaryChat.toggle() }
    @objc func toggleRedact() { Settings.redact.toggle() }

    /// Opens the blocked-sites text file (creating it first if needed).
    @objc func editBlocklist() {
        _ = loadBlocklist()
        NSWorkspace.shared.open(blocklistURL)
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func resetPosition() {
        window.setFrame(bottomRightFrame(size: normalSize), display: true, animate: window.isVisible)
    }

    // MARK: Right-click menu

    func showRightClickMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let open = NSMenuItem(title: "Open chatgpt.com in Browser", action: #selector(openInBrowser), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reset = NSMenuItem(title: "Move Window to Bottom-Right", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        // Privacy controls
        let reading = NSMenuItem(title: "Read Pages from Apps", action: #selector(toggleReading), keyEquivalent: "")
        reading.target = self
        reading.state = Settings.readingEnabled ? .on : .off
        menu.addItem(reading)
        for id in knownAppOrder {
            let item = NSMenuItem(title: "    " + (knownBrowsers[id]?.appName ?? id), action: #selector(toggleAppAllowed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = Settings.isAppAllowed(id) ? .on : .off
            item.isEnabled = Settings.readingEnabled
            menu.addItem(item)
        }
        let temp = NSMenuItem(title: "Use Temporary Chat for Page Context", action: #selector(toggleTemporaryChat), keyEquivalent: "")
        temp.target = self
        temp.state = Settings.useTemporaryChat ? .on : .off
        menu.addItem(temp)
        let redact = NSMenuItem(title: "Hide Emails, Phones, Cards & Link Tokens", action: #selector(toggleRedact), keyEquivalent: "")
        redact.target = self
        redact.state = Settings.redact ? .on : .off
        menu.addItem(redact)
        let blocked = NSMenuItem(title: "Edit Blocked Sites…", action: #selector(editBlocklist), keyEquivalent: "")
        blocked.target = self
        menu.addItem(blocked)
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "Allow Accessibility (Safari private check)…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Show / hide: ⌥Space", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ChatGPT Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // shows the menu
        statusItem.menu = nil                  // so left-click goes back to opening the window
    }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "You can add it manually: System Settings → General → Login Items → +"
            alert.runModal()
        }
    }

    @objc func openInBrowser() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!) }

    /// Menu-bar-only apps have no Edit menu by default, which breaks ⌘C / ⌘V / ⌘A.
    /// This hidden main menu brings those shortcuts back.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let reload = viewMenu.addItem(withTitle: "Reload", action: #selector(ChatViewController.reload), keyEquivalent: "r")
        reload.target = chat
        let new = viewMenu.addItem(withTitle: "New Chat", action: #selector(ChatViewController.newChat), keyEquivalent: "n")
        new.target = chat
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Start the app

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only — no Dock icon
app.run()
