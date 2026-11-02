import AppKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
///
/// This inherits from transparent styling so that the titlebar matches the background color
/// of the window.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// How far the traffic lights, tabs and title sit below AppKit's default position, to free
    /// up the top of the titlebar for dragging the window.
    private static let titlebarContentShift: CGFloat = 6

    /// Keeps the tabs clear of the traffic lights, updated as the window enters and exits fullscreen.
    private var tabBarLeftConstraint: NSLayoutConstraint?

    /// The traffic lights aren't in the tab bar's row in fullscreen, so the tabs can use the full width.
    private var tabBarLeftPadding: CGFloat {
        guard !styleMask.contains(.fullScreen) else { return 0 }
        return switch derivedConfig.macosWindowButtons {
        case .hidden: 0
        case .visible: 88
        }
    }

    /// Titlebar tabs can't support the update accessory because of the way we layout
    /// the native tabs back into the menu bar.
    override var supportsUpdateAccessory: Bool { false }

    deinit {
        tabBarObserver = nil
    }

    // MARK: NSWindow

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionWindowButtons()

        if let tabBarLeftConstraint, tabBarLeftConstraint.constant != tabBarLeftPadding {
            tabBarLeftConstraint.constant = tabBarLeftPadding
        }
    }

    /// AppKit resets the traffic lights on layout, so this has to be reapplied each time.
    private func positionWindowButtons() {
        // Fullscreen shows them in a separate toolbar window that we leave alone.
        guard !styleMask.contains(.fullScreen) else { return }

        let centerFromTop = 26 + Self.titlebarContentShift
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type), let superview = button.superview else { continue }
            let center = superview.convert(NSPoint(x: 0, y: frame.height - centerFromTop), from: nil)
            let y = center.y - button.frame.height / 2
            if abs(button.frame.origin.y - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }

    override var titlebarFont: NSFont? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.titleFont = self.titlebarFont
            }
        }
    }

    override var title: String {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.title = self.title
            }
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // We must hide the title since we're going to be moving tabs into
        // the titlebar which have their own title.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers.insert(.title)
        self.toolbar = toolbar
        toolbarStyle = .unified
    }
    // Called after new tab finishes adjusting and setupTabBar is called in order to prevent Tab Bar hiding/size bug that occurs with some interactions with Mac UI
    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            self.setupTabBar()
        }
    }

    override func becomeMain() {
        super.becomeMain()

        // Check if we have a tab bar and set it up if we have to. See the comment
        // on this function to learn why we need to check this here.
        setupTabBar()

        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()

        viewModel.isMainWindow = false
    }
    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        // If this is the tab bar then we need to set it up for the titlebar
        guard isTabBar(childViewController) else {
            // After dragging a tab into a new window, `hasTabBar` needs to be
            // updated to properly review window title
            viewModel.hasTabBar = false

            super.addTitlebarAccessoryViewController(childViewController)
            return
        }

        // When an existing tab is being dragged in to another tab group,
        // system will also try to add tab bar to this window, so we want to reset observer,
        // to put tab bar where we want again
        tabBarObserver = nil

        // Some setup needs to happen BEFORE it is added, such as layout. If
        // we don't do this before the call below, we'll trigger an AppKit
        // assertion.
        childViewController.layoutAttribute = .right

        super.addTitlebarAccessoryViewController(childViewController)

        // Setup the tab bar to go into the titlebar.
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            self.setupTabBar()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        guard let childViewController = titlebarAccessoryViewControllers[safe: index],
                isTabBar(childViewController) else {
            super.removeTitlebarAccessoryViewController(at: index)
            return
        }

        super.removeTitlebarAccessoryViewController(at: index)

        removeTabBar()
    }

    // MARK: Tab Bar Setup

    private var tabBarObserver: NSObjectProtocol? {
        didSet {
            // When we change this we want to clear our old observer
            guard let oldValue else { return }
            NotificationCenter.default.removeObserver(oldValue)
        }
    }

    /// Take the NSTabBar that is on the window and convert it into titlebar tabs.
    ///
    /// Let me explain more background on what is happening here. When a tab bar is created, only the
    /// main window actually has an NSTabBar. When an NSWindow in the tab group gains main, AppKit
    /// creates/moves (unsure which) the NSTabBar for it and shows it. When it loses main, the tab bar
    /// is removed from the view hierarchy.
    ///
    /// We can't reliably detect this via `addTitlebarAccessoryViewController` because AppKit
    /// creates an accessory view controller for every window in the tab group, but only attaches
    /// the actual NSTabBar to the main window's accessory view.
    ///
    /// The best way I've found to detect this is to search for and setup the tab bar anytime the
    /// window gains focus. There are probably edge cases to check but to resolve all this I made
    /// this function which is idempotent to call.
    ///
    /// There are more scenarios to look out for and they're documented within the method.
    func setupTabBar() {
        // We only want to setup the observer once
        guard tabBarObserver == nil else { return }

        guard
            let titlebarView,
            let tabBarView = self.tabBarView
        else { return }

        // View model updates must happen on their own ticks.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.hasTabBar = true
        }

        // Find our clip view
        // macOS 26: NSTitlebarAccessoryClipView
        // macOS 27(beta 2): NSTitlebarAccessoryContainerView
        guard let clipView = tabBarView.firstSuperview(withClassName: "NSTitlebarAccessoryClipView") ?? tabBarView.firstSuperview(withClassName: "NSTitlebarAccessoryContainerView") else { return }
        guard let accessoryView = clipView.subviews[safe: 0] else { return }
        guard let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView") else { return }

        // Make sure tabBar's height won't be stretched
        guard let newTabButton = titlebarView.firstDescendant(withClassName: "NSTabBarNewTabButton") else { return }
        tabBarView.frame.size.height = newTabButton.frame.width

        // The container is the view that we'll constrain our tab bar within.
        let container = toolbarView

        // Constrain the accessory clip view (the parent of the accessory view
        // usually that clips the children) to the container view.
        clipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false

        // Replace rather than stack this one: its constant changes, so an old copy would conflict.
        tabBarLeftConstraint?.isActive = false
        let leftConstraint = clipView.leftAnchor.constraint(equalTo: container.leftAnchor, constant: tabBarLeftPadding)
        tabBarLeftConstraint = leftConstraint

        // Setup all our constraints
        NSLayoutConstraint.activate([
            leftConstraint,
            clipView.rightAnchor.constraint(equalTo: container.rightAnchor),
            // AppKit lays the tabs out low in the taller .unified toolbar; -18 lines them up with AppKit's traffic lights.
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: -18 + Self.titlebarContentShift),
            clipView.heightAnchor.constraint(equalTo: container.heightAnchor),
            accessoryView.leftAnchor.constraint(equalTo: clipView.leftAnchor),
            accessoryView.rightAnchor.constraint(equalTo: clipView.rightAnchor),
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor),
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])

        clipView.needsLayout = true
        accessoryView.needsLayout = true

        if #available(macOS 27.0, *) {
            // Add some delay to cover the case where:
            // AppKit resets the style after exiting fullscreen
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.reduceTabBarBackgroundGoldenGate()
            }
        }

        // Setup an observer for the NSTabBar frame. When system appearance changes or
        // other events occur, the tab bar can resize and clear our constraints. When this
        // happens, we need to remove our custom constraints and re-apply them once the
        // tab bar has proper dimensions again to avoid constraint conflicts.
        tabBarView.postsFrameChangedNotifications = true
        tabBarObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: tabBarView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // Remove the observer so we can call setup again.
            self.tabBarObserver = nil

            // Wait a tick to let the new tab bars appear and then set them up.
            DispatchQueue.main.async {
                self.setupTabBar()
            }
        }
    }

    func removeTabBar() {
        // View model needs to be updated on another tick because it
        // triggers view updates.
        DispatchQueue.main.async {
            self.viewModel.hasTabBar = false
        }

        // Clear our observations
        self.tabBarObserver = nil
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.title, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .title, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .title:
            let item = NSToolbarItem(itemIdentifier: .title)
            item.view = ClickThroughHostingView(rootView: TitleItem(viewModel: viewModel))
            // Fix: https://github.com/ghostty-org/ghostty/discussions/9027
            item.view?.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.visibilityPriority = .user
            item.isEnabled = false

            // This is the documented way to avoid the glass view on an item.
            // We don't want glass on our title.
            item.isBordered = false

            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    // MARK: SwiftUI

    class ViewModel: ObservableObject {
        @Published var titleFont: NSFont?
        @Published var title: String = "👻 Ghostty"
        @Published var hasTabBar: Bool = false
        @Published var isMainWindow: Bool = true
    }
}

extension NSToolbarItem.Identifier {
    /// Displays the title of the window
    static let title = NSToolbarItem.Identifier("Title")
}

extension TitlebarTabsTahoeTerminalWindow {
    /// Displays the window title
    struct TitleItem: View {
        @ObservedObject var viewModel: ViewModel

        var title: String {
            // An empty title makes this view zero-sized and NSToolbar on macOS
            // tahoe just deletes the item when that happens. So we use a space
            // instead to ensure there's always some size.
            return viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            if !viewModel.hasTabBar {
                titleText
            } else {
                // 1x1.gif strikes again! For real: if we render a zero-sized
                // view here then the toolbar just disappears our view. I don't
                // know. On macOS 26.1+ the view no longer disappears, but the
                // toolbar still logs an ambiguous content size warning.
                Color.clear.frame(width: 1, height: 1)
            }
        }

        @ViewBuilder
        var titleText: some View {
            Text(title)
                .font(viewModel.titleFont.flatMap(Font.init(_:)))
                .foregroundStyle(viewModel.isMainWindow ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .greatestFiniteMagnitude, alignment: .center)
                .offset(y: TitlebarTabsTahoeTerminalWindow.titlebarContentShift)
                .opacity(viewModel.hasTabBar ? 0 : 1) // hide when in fullscreen mode, where title bar will appear in the leading area under window buttons
        }
    }
}

/// A "Ghosting" Hosting View, that acts like it's not there
private class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
