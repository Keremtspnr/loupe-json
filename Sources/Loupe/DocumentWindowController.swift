import AppKit
@preconcurrency import JsonCore

/// One window showing one jsonDocument.
///
/// Threading: the tree (`JsonNode`) is only touched on the main thread. Reading files,
/// scanning large containers and searching run on background queues against the
/// immutable buffer and hand plain record arrays back to the main thread.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {

    /// Containers smaller than this are scanned inline when expanded.
    private static let inlineScanLimit = 4 << 20
    /// Copying a value larger than this asks for confirmation first.
    private static let largeCopyLimit = 64 << 20
    private static var cascadePoint = NSPoint.zero

    var onClose: (() -> Void)?
    private(set) var jsonDocument: JsonDocument?
    /// The node whose children are the outline's top-level rows. For a single top-level
    /// object or array this is that container, so its members appear at the top level.
    private var displayRoot: JsonNode?
    private var sourceURL: URL?

    private let preferences = Preferences.shared
    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let caseSwitch = NSSwitch()
    private let resultLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let loadLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString:
        "Open a JSON file (⌘O), drop one here,\nor open from the clipboard (⇧⌘V)")
    private lazy var renderer = RowRenderer(font: preferences.font)
    private var highlight: RowRenderer.Highlight?
    private var guideMetrics: (chevron: CGFloat, cell: CGFloat)?

    private let workQueue = DispatchQueue(label: "loupe.work", qos: .userInitiated, attributes: .concurrent)
    private let searchQueue = DispatchQueue(label: "loupe.search", qos: .userInitiated)
    private var busyTokens: [CancelToken] = []
    private var scansInFlight: Set<ObjectIdentifier> = []
    private var searchToken: CancelToken?
    private var navigationToken: CancelToken?

    private var matches: [Int] = []
    private var matchIndex = -1
    private var searchFinished = true
    private var searchProgress = 0.0
    private var lastQuery: (text: String, caseSensitive: Bool)?

    var isEmpty: Bool { jsonDocument == nil && busyTokens.isEmpty }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Loupe"
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildUI(in: window)
        applyPreferences()
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged(_:)),
                                               name: Preferences.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildUI(in window: NSWindow) {
        let content = DropView()
        content.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        window.contentView = content

        // Toolbar: font size, search, navigation, case sensitivity.
        let symbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let fontSize = NSSegmentedControl(
            images: ["textformat.size.smaller", "textformat.size.larger"].map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)!.withSymbolConfiguration(symbol)!
            },
            trackingMode: .momentary, target: self, action: #selector(fontSizeSegment(_:)))
        fontSize.setToolTip("Decrease font size (⌘−)", forSegment: 0)
        fontSize.setToolTip("Increase font size (⌘+)", forSegment: 1)
        searchField.placeholderString = "Find"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchAction(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let previous = symbolButton("chevron.left", "Previous match (⇧⌘G)", #selector(findPreviousMatch(_:)))
        let next = symbolButton("chevron.right", "Next match (⌘G)", #selector(findNextMatch(_:)))
        caseSwitch.controlSize = .small
        caseSwitch.target = self
        caseSwitch.action = #selector(caseSensitivityChanged(_:))
        let caseLabel = NSTextField(labelWithString: "Case Sensitive")
        caseLabel.font = .systemFont(ofSize: 12)
        caseLabel.textColor = .secondaryLabelColor
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let toolbar = ColorView(Palette.barBackground)
        let toolbarStack = row([fontSize, spacer(6), searchField, previous, next, spacer(6), caseLabel, caseSwitch, spacer(6), resultLabel])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .fullWidth
        outline.backgroundColor = Palette.background
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(toggleClickedRow(_:))
        outline.menu = contextMenu()
        scrollView.documentView = outline
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Status bar: format, size, path, progress, load time.
        for label in [formatLabel, sizeLabel, pathLabel, loadLabel, progressLabel] {
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = Palette.statusText
        }
        formatLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        pathLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelBusy(_:))
        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .rounded
        setBusyUI(visible: false)
        let statusBar = ColorView(Palette.statusBackground)
        let statusStack = row([formatLabel, sizeLabel, pathLabel, progressLabel, progressBar, cancelButton, loadLabel])
        statusStack.spacing = 14
        statusStack.distribution = .fill
        statusStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = Palette.emptyText

        let topLine = ColorView(Palette.separator)
        for view in [toolbar, topLine, scrollView, statusBar, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for (bar, stack) in [(toolbar, toolbarStack), (statusBar, statusStack)] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                stack.topAnchor.constraint(equalTo: bar.topAnchor),
                stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            topLine.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return stack
    }

    private func spacer(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func symbolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        return button
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Value", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Key", action: #selector(copyKey(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: Preferences

    @objc private func fontSizeSegment(_ sender: NSSegmentedControl) {
        let action = sender.selectedSegment == 0
            ? #selector(AppDelegate.decreaseFontSize(_:)) : #selector(AppDelegate.increaseFontSize(_:))
        NSApp.sendAction(action, to: nil, from: sender)
    }

    @objc private func preferencesChanged(_ notification: Notification) {
        applyPreferences()
    }

    /// Applies font size: row height, indentation and text all scale with it.
    private func applyPreferences() {
        renderer.font = preferences.font
        guard outline.rowHeight != preferences.rowHeight || outline.indentationPerLevel != preferences.indentation
                || outline.numberOfRows > 0 else {
            outline.rowHeight = preferences.rowHeight
            outline.indentationPerLevel = preferences.indentation
            return
        }
        let selected = selectedNode
        outline.rowHeight = preferences.rowHeight
        outline.indentationPerLevel = preferences.indentation
        guideMetrics = nil
        outline.reloadData()
        if let selected {
            let row = outline.row(forItem: selected)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
    }

    // MARK: Loading

    func open(url: URL) {
        sourceURL = url
        load(name: url.lastPathComponent) { token, progress in
            try JsonBuffer.load(path: url.path, cancel: token, progress: progress)
        }
    }

    func openClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        sourceURL = nil
        let data = Data(text.utf8)
        load(name: "Clipboard") { _, _ in try JsonBuffer.from(data: data) }
    }

    private func handleDrop(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(url: first)
        for url in urls.dropFirst() { (NSApp.delegate as? AppDelegate)?.open(url) }
    }

    private func load(
        name: String,
        reader: @escaping @Sendable (CancelToken, (Int, Int) -> Void) throws -> JsonBuffer
    ) {
        resetDocument()
        window?.title = name
        let token = beginBusy("Reading…")
        workQueue.async { [weak self] in
            let started = Date()
            do {
                let buffer = try reader(token) { done, total in
                    DispatchQueue.main.async { self?.setProgress(Double(done) / Double(max(total, 1))) }
                }
                let doc = JsonDocument(buffer: buffer, name: name)
                DispatchQueue.main.async { self?.progressLabel.stringValue = "Scanning…" }
                // The document is not shared with the main thread yet, so building
                // its first levels here is safe.
                let records = try doc.scanJob(for: doc.root).run(cancel: token) { fraction in
                    DispatchQueue.main.async { self?.setProgress(fraction) }
                }
                doc.root.setRecords(records)
                if records.count == 1, records[0].hasChildren {
                    let top = doc.root.child(at: 0)
                    top.setRecords(try doc.scanJob(for: top).run(cancel: token) { fraction in
                        DispatchQueue.main.async { self?.setProgress(fraction) }
                    })
                }
                let scanned = Date()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBusy(token)
                    guard !token.isCancelled else { return }
                    self.install(doc, loadTime: scanned.timeIntervalSince(started))
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBusy(token)
                    if !(error is CancelledError), !token.isCancelled { self.present(error) }
                }
            }
        }
    }

    private func install(_ doc: JsonDocument, loadTime: Double) {
        jsonDocument = doc
        let records = doc.root.records ?? []
        displayRoot = records.count == 1 && records[0].hasChildren ? doc.root.child(at: 0) : doc.root
        emptyLabel.isHidden = true
        guideMetrics = nil
        outline.reloadData()

        let isStream = records.count > 1
        formatLabel.stringValue = isStream ? "NDJSON" : "JSON"
        let size = ByteCountFormatter.string(fromByteCount: Int64(doc.buffer.count), countStyle: .file)
        let items = isStream ? "  ·  \(records.count.formatted()) lines" : ""
        sizeLabel.stringValue = "Size: \(size)\(items)"
        loadLabel.stringValue = "Load: \(Int((loadTime * 1000).rounded()).formatted()) ms"

        if outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
        window?.makeFirstResponder(outline)
        if !searchField.stringValue.isEmpty { searchAction(nil) }
    }

    private func resetDocument() {
        busyTokens.forEach { $0.cancel() }
        busyTokens.removeAll()
        scansInFlight.removeAll()
        setBusyUI(visible: false)
        clearSearch()
        jsonDocument = nil
        displayRoot = nil
        outline.reloadData()
        emptyLabel.isHidden = false
        for label in [formatLabel, sizeLabel, pathLabel, loadLabel] { label.stringValue = "" }
    }

    @objc func reloadDocument(_ sender: Any?) {
        if let url = sourceURL { open(url: url) }
    }

    // MARK: Busy state

    private func beginBusy(_ text: String) -> CancelToken {
        let token = CancelToken()
        busyTokens.append(token)
        progressLabel.stringValue = text
        progressBar.doubleValue = 0
        setBusyUI(visible: true)
        return token
    }

    private func endBusy(_ token: CancelToken) {
        busyTokens.removeAll { $0 === token }
        if busyTokens.isEmpty { setBusyUI(visible: false) }
    }

    private func setProgress(_ value: Double) {
        guard !busyTokens.isEmpty else { return }
        progressBar.doubleValue = value
    }

    private func setBusyUI(visible: Bool) {
        progressLabel.isHidden = !visible
        progressBar.isHidden = !visible
        cancelButton.isHidden = !visible
        loadLabel.isHidden = visible
    }

    @objc func cancelBusy(_ sender: Any?) {
        busyTokens.forEach { $0.cancel() }
        busyTokens.removeAll()
        scansInFlight.removeAll()
        setBusyUI(visible: false)
        if jsonDocument == nil { emptyLabel.isHidden = false }
    }

    // MARK: Lazy scanning

    /// Scans `node` inline if small; otherwise in the background, calling `completion` when done.
    /// Returns true when the node is scanned on return.
    private func ensureScanned(_ node: JsonNode, completion: @escaping () -> Void) -> Bool {
        guard let doc = jsonDocument else { return false }
        if node.isScanned { return true }
        let job = doc.scanJob(for: node)
        if job.byteLength <= Self.inlineScanLimit {
            node.setRecords((try? job.run()) ?? [])
            refreshRow(node)
            return true
        }

        let id = ObjectIdentifier(node)
        guard !scansInFlight.contains(id) else { return false }
        scansInFlight.insert(id)
        let token = beginBusy("Scanning…")
        workQueue.async { [weak self] in
            let result = try? job.run(cancel: token) { fraction in
                DispatchQueue.main.async { self?.setProgress(fraction) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scansInFlight.remove(id)
                self.endBusy(token)
                guard let result, !token.isCancelled, self.jsonDocument === doc else { return }
                node.setRecords(result)
                if self.outline.row(forItem: node) >= 0 {
                    self.outline.reloadItem(node, reloadChildren: true)
                }
                completion()
            }
        }
        return false
    }

    private func refreshRow(_ node: JsonNode) {
        guard let doc = jsonDocument else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        cell.textField?.attributedStringValue = renderer.render(node, in: doc, highlight: highlight)
    }

    /// Re-renders the visible rows (search highlight changes).
    private func refreshVisibleRows() {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)), columnIndexes: [0])
    }

    // MARK: NSOutlineViewDataSource / Delegate

    private func node(for item: Any?) -> JsonNode? {
        (item as? JsonNode) ?? displayRoot
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(for: item)?.displayCount ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(for: item)!.child(at: index)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? JsonNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? JsonNode else { return false }
        return ensureScanned(node) { [weak self] in self?.outline.expandItem(node) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let doc = jsonDocument, let node = item as? JsonNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        cell.textField?.attributedStringValue = renderer.render(node, in: doc, highlight: highlight)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = outlineView.makeView(withIdentifier: id, owner: self) as? JsonRowView ?? {
            let view = JsonRowView()
            view.identifier = id
            return view
        }()
        guard let node = item as? JsonNode else { return view }

        // Depth and which ancestor lines continue past this row.
        var ancestors: [JsonNode] = []
        var current = node.parent
        while let ancestor = current, ancestor !== displayRoot, ancestor.role != .root {
            ancestors.append(ancestor)
            current = ancestor.parent
        }
        let indentation = outlineView.indentationPerLevel
        let metrics = guidePositions()
        view.level = ancestors.count
        view.continues = ancestors.reversed().map { !$0.isLastChild }
        view.isLastChild = node.isLastChild
        view.hasDisclosure = node.isExpandable
        view.indentation = indentation
        view.chevronBase = metrics.chevron
        view.textStart = metrics.cell + CGFloat(ancestors.count) * indentation
        view.needsDisplay = true
        return view
    }

    /// x of the level-0 disclosure chevron center and cell start, measured from the outline.
    private func guidePositions() -> (chevron: CGFloat, cell: CGFloat) {
        if let guideMetrics { return guideMetrics }
        let indentation = outline.indentationPerLevel
        for row in 0..<min(outline.numberOfRows, 200) {
            guard let item = outline.item(atRow: row), outline.isExpandable(item) else { continue }
            let disclosure = outline.frameOfOutlineCell(atRow: row)
            guard disclosure.width > 0 else { continue }
            let level = CGFloat(outline.level(forRow: row))
            let cell = outline.frameOfCell(atColumn: 0, row: row)
            let metrics = (disclosure.midX - level * indentation, cell.minX - level * indentation)
            guideMetrics = metrics
            return metrics
        }
        return (indentation * 0.5 + 4, indentation + 6)
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let doc = jsonDocument, let node = selectedNode else {
            pathLabel.stringValue = ""
            return
        }
        guard node.role == .value else { return pathLabel.stringValue = "" }
        pathLabel.stringValue = doc.path(of: node)
    }

    private var selectedNode: JsonNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? JsonNode : nil
    }

    /// Context-menu target if there is one, otherwise the selection.
    private var targetNode: JsonNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? JsonNode : nil
    }

    @objc private func toggleClickedRow(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.clickedRow) else { return }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    @objc func expandSelected(_ sender: Any?) {
        if let node = selectedNode { outline.expandItem(node) }
    }

    @objc func collapseAll(_ sender: Any?) {
        outline.collapseItem(nil, collapseChildren: true)
    }

    // MARK: Copy

    @objc func copy(_ sender: Any?) {
        guard let doc = jsonDocument, let node = targetNode, node.role == .value else { return NSSound.beep() }
        let r = node.record
        if r.valueLen > Self.largeCopyLimit {
            let alert = NSAlert()
            alert.messageText = "Copy a large value?"
            alert.informativeText = "This value is \(ByteCountFormatter.string(fromByteCount: r.valueLen, countStyle: .file))."
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setPasteboard(doc.valueText(r))
    }

    @objc func copyKey(_ sender: Any?) {
        guard let doc = jsonDocument, let node = targetNode, node.role == .value, node.record.hasName else { return NSSound.beep() }
        setPasteboard(doc.keyText(node.record, limit: Int.max))
    }

    @objc func copyPath(_ sender: Any?) {
        guard let doc = jsonDocument, let node = targetNode, node.role == .value else { return NSSound.beep() }
        setPasteboard(doc.path(of: node))
    }

    private func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(copyPath(_:)):
            return targetNode?.role == .value
        case #selector(copyKey(_:)):
            return targetNode?.role == .value && targetNode?.record.hasName == true
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return !matches.isEmpty
        case #selector(reloadDocument(_:)):
            return sourceURL != nil
        case #selector(expandSelected(_:)), #selector(collapseAll(_:)):
            return jsonDocument != nil
        default:
            return true
        }
    }

    // MARK: Search

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func searchAction(_ sender: Any?) {
        let text = searchField.stringValue
        guard let doc = jsonDocument else { return }
        guard !text.isEmpty else { return clearSearch() }
        let caseSensitive = caseSwitch.state == .on
        if let last = lastQuery, last.text == text, last.caseSensitive == caseSensitive, !matches.isEmpty {
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            return step(backwards ? -1 : 1)
        }
        startSearch(text, caseSensitive: caseSensitive, in: doc)
    }

    private func startSearch(_ text: String, caseSensitive: Bool, in doc: JsonDocument) {
        clearSearch()
        let token = CancelToken()
        searchToken = token
        lastQuery = (text, caseSensitive)
        searchFinished = false
        highlight = RowRenderer.Highlight(query: text, caseSensitive: caseSensitive, current: nil)
        refreshVisibleRows()
        updateResultLabel()

        let needle = Array(text.utf8)
        let buffer = doc.buffer
        searchQueue.async { [weak self] in
            TextSearch.run(buffer: buffer, needle: needle, caseSensitive: caseSensitive, cancel: token) { batch, finished, progress in
                DispatchQueue.main.async {
                    guard let self, self.searchToken === token else { return }
                    self.matches += batch
                    self.searchFinished = finished
                    self.searchProgress = progress
                    if self.matchIndex < 0 && !self.matches.isEmpty { self.goToMatch(0) }
                    self.updateResultLabel()
                }
            }
        }
    }

    private func clearSearch() {
        searchToken?.cancel()
        searchToken = nil
        navigationToken?.cancel()
        matches = []
        matchIndex = -1
        searchFinished = true
        lastQuery = nil
        resultLabel.stringValue = ""
        if highlight != nil {
            highlight = nil
            refreshVisibleRows()
        }
    }

    @objc private func caseSensitivityChanged(_ sender: Any?) {
        guard let doc = jsonDocument, !searchField.stringValue.isEmpty else { return }
        startSearch(searchField.stringValue, caseSensitive: caseSwitch.state == .on, in: doc)
    }

    private func updateResultLabel() {
        if searchToken == nil {
            resultLabel.stringValue = ""
        } else if matches.isEmpty {
            resultLabel.stringValue = searchFinished ? "No matches" : "Searching… \(Int(searchProgress * 100))%"
        } else {
            let current = matchIndex >= 0 ? (matchIndex + 1).formatted() : "–"
            let suffix = searchFinished ? "" : "+  \(Int(searchProgress * 100))%"
            resultLabel.stringValue = "\(current) / \(matches.count.formatted())\(suffix)"
        }
    }

    @objc func findNextMatch(_ sender: Any?) { step(1) }
    @objc func findPreviousMatch(_ sender: Any?) { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return NSSound.beep() }
        let next = matchIndex < 0 ? 0 : (matchIndex + delta + matches.count) % matches.count
        goToMatch(next)
    }

    private func goToMatch(_ index: Int) {
        matchIndex = index
        highlight?.current = matches[index]
        updateResultLabel()
        navigate(to: matches[index])
    }

    /// Walks from the root to the node containing `offset`, scanning levels as needed.
    private func navigate(to offset: Int) {
        guard let doc = jsonDocument else { return }
        navigationToken?.cancel()
        let token = CancelToken()
        navigationToken = token

        func proceed() {
            guard !token.isCancelled, jsonDocument === doc else { return }
            while true {
                switch doc.locate(offset: offset) {
                case .found(let node):
                    reveal(node)
                    return
                case .needsScan(let node):
                    guard ensureScanned(node, completion: proceed) else { return }
                }
            }
        }
        proceed()
    }

    private func reveal(_ node: JsonNode) {
        guard node.role != .root, node !== displayRoot else { return }
        var chain: [JsonNode] = []
        var current = node.parent
        while let ancestor = current, ancestor.role != .root, ancestor !== displayRoot {
            chain.append(ancestor)
            current = ancestor.parent
        }
        for ancestor in chain.reversed() { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        let rect = outline.rect(ofRow: row)
        let visible = scrollView.contentView.bounds.height
        outline.scroll(NSPoint(x: 0, y: max(0, rect.midY - visible / 2)))
        refreshVisibleRows()
    }

    // MARK: Errors / lifecycle

    private func present(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
        emptyLabel.isHidden = jsonDocument != nil
    }

    func windowWillClose(_ notification: Notification) {
        busyTokens.forEach { $0.cancel() }
        searchToken?.cancel()
        navigationToken?.cancel()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }
}

// MARK: - Smoke test

/// `LOUPE_SNAPSHOT_DIR=<dir>` drives the window through load → expand → search,
/// writing a PNG of the window after each step plus `report.txt`, then quits.
extension DocumentWindowController {
    func runSmokeTest(into directory: String) {
        var report: [String] = []
        let started = Date()

        func when(_ condition: @escaping () -> Bool, then action: @escaping () -> Void) {
            if condition() { return action() }
            guard Date().timeIntervalSince(started) < 120 else {
                report.append("TIMEOUT")
                return finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { when(condition, then: action) }
        }
        func idle() -> Bool { jsonDocument != nil && busyTokens.isEmpty }
        func snapshot(_ name: String) {
            guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            report.append("[\(name)] rows=\(outline.numberOfRows) selected=\(pathLabel.stringValue) results=\(resultLabel.stringValue) status=\(formatLabel.stringValue) | \(sizeLabel.stringValue) | \(loadLabel.stringValue) guides=\(guidePositions())")
        }
        func finish() {
            try? report.joined(separator: "\n").write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        if let name = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_APPEARANCE"] {
            window?.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        when(idle) {
            snapshot("1-loaded.png")
            let items = (0..<self.outline.numberOfRows)
                .compactMap { self.outline.item(atRow: $0) as? JsonNode }
                .first { $0.isExpandable && !self.outline.isItemExpanded($0) && $0.role == .value }
            if let items { self.outline.expandItem(items) }
            when({ idle() && (items.map { self.outline.isItemExpanded($0) } ?? true) }) {
                snapshot("2-expanded.png")
                self.searchField.stringValue = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_QUERY"] ?? "needle_LAST_ITEM"
                self.searchAction(nil)
                when({ idle() && self.searchFinished && (self.matches.isEmpty || self.selectedNode != nil) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        snapshot("3-search.png")
                        // Bigger text, then restore the user's setting.
                        let size = self.preferences.fontSize
                        self.preferences.fontSize = size + 4
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            snapshot("4-larger-font.png")
                            self.preferences.fontSize = size
                            report.append(String(format: "total %.2f s", Date().timeIntervalSince(started)))
                            finish()
                        }
                    }
                }
            }
        }
    }
}
