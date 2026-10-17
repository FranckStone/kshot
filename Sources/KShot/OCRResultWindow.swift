import AppKit

/// OCR / 翻译结果：原文与译文分栏，支持编辑、调整窗口大小与独立复制。
final class OCRResultWindow: NSWindow, NSTextViewDelegate, NSComboBoxDelegate {
    nonisolated(unsafe) private static var all: [OCRResultWindow] = []
    nonisolated(unsafe) static weak var latest: OCRResultWindow?

    private let sourcePane = OCRTextPane(title: "原文", symbol: "doc.text")
    private let translationPane = OCRTextPane(title: "译文", symbol: "character.bubble")
    private let titleLabel = NSTextField(labelWithString: "提取文字")
    private let subtitleLabel = NSTextField(labelWithString: "识别结果可直接编辑")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourceLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelCombo = NSComboBox(frame: .zero)
    private let refreshModelsButton = NSButton(title: "", target: nil, action: nil)
    private var modelListTask: Task<Void, Never>?
    private var modelListID = UUID()
    private var loadingModels = false
    private(set) var engineSelection = TranslationEngineSelection.saved
    private var sourceLanguages = TargetLanguage.all
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制原文", target: nil, action: nil)
    private let openLinkButton = NSButton(title: "打开链接", target: nil, action: nil)
    private let translator = Translator()
    private var link: URL?
    private var recognizedCodes: [String] = []
    private var isTranslationMode: Bool
    private(set) var isTranslating = false
    private var translationSource: String?
    private var requestID = UUID()
    private var textView: NSTextView { sourcePane.textView }
    private var translatedView: NSTextView { translationPane.textView }
    private var targetLanguage: TargetLanguage { TargetLanguage.all[max(0, languagePopup.indexOfSelectedItem)] }
    private var sourceLanguage: TargetLanguage? {
        let index = sourceLanguagePopup.indexOfSelectedItem - 1
        return sourceLanguages.indices.contains(index) ? sourceLanguages[index] : nil
    }
    private var canCopyTranslation: Bool {
        !translatedView.string.isEmpty && translationSource == textView.string
    }

    init(text: String, near rect: CGRect, translation: Bool = false) {
        isTranslationMode = translation
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        let size = CGSize(width: min(translation ? 820 : 680, visible.width - 24),
                          height: min(translation ? 520 : 420, visible.height - 24))
        let origin = CGPoint(x: min(max(visible.minX + 12, rect.midX - size.width / 2), visible.maxX - size.width - 12),
                             y: min(max(visible.minY + 12, rect.midY - size.height / 2), visible.maxY - size.height - 12))
        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "识别与翻译"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = CGSize(width: min(640, size.width), height: min(380, size.height))
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let content = OCRSurfaceView(frame: root.bounds)
        content.autoresizingMask = [.width, .height]
        let backdrop = GlassBackdrop.make(cornerRadius: 20, content: content)
        backdrop.frame = root.bounds
        root.addSubview(backdrop)
        contentView = root

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for language in TargetLanguage.all { languagePopup.addItem(withTitle: language.title) }
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: TargetLanguage.defaultTarget(for: text)) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(targetChanged)
        languagePopup.toolTip = "目标语言，切换后重新翻译"
        languagePopup.setAccessibilityLabel("翻译目标语言")
        let targetLabel = NSTextField(labelWithString: "译为")
        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor
        let languageControls = NSStackView(views: [targetLabel, languagePopup, translateButton])
        languageControls.spacing = 8
        languageControls.setContentHuggingPriority(.required, for: .horizontal)
        configureButton(translateButton, symbol: "translate", action: #selector(translateAction))
        translateButton.keyEquivalent = "\r"
        translateButton.keyEquivalentModifierMask = [.command]
        translateButton.isEnabled = engineSelection.isAvailable
        translateButton.toolTip = engineSelection.isAvailable ? "翻译原文  ⌘↩" : "翻译需要 macOS 15 或更高版本"
        languagePopup.isEnabled = engineSelection.isAvailable
        let header = NSView()
        for view in [heading, languageControls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: header.topAnchor),
            heading.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: languageControls.leadingAnchor, constant: -20),
            languageControls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            languageControls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        for provider in TranslationProvider.allCases { enginePopup.addItem(withTitle: provider.title) }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.setAccessibilityLabel("翻译引擎")
        enginePopup.toolTip = "切换翻译引擎并重新翻译，自动记住选择"
        modelCombo.isEditable = true
        modelCombo.completes = true
        modelCombo.target = self
        modelCombo.action = #selector(modelChanged)
        modelCombo.delegate = self
        modelCombo.placeholderString = "选择或输入模型名称"
        modelCombo.setAccessibilityLabel("翻译模型")
        modelCombo.toolTip = "选择模型，或输入名称后按回车重新翻译"
        modelCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelCombo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureButton(refreshModelsButton, symbol: "arrow.clockwise", action: #selector(refreshModelList))
        refreshModelsButton.imagePosition = .imageOnly
        refreshModelsButton.toolTip = "刷新可用模型"
        refreshModelsButton.setAccessibilityLabel("刷新可用模型")
        let serviceSettings = NSButton(title: "", target: nil, action: nil)
        configureButton(serviceSettings, symbol: "gearshape", action: #selector(openTranslationSettings))
        serviceSettings.imagePosition = .imageOnly
        serviceSettings.toolTip = "配置服务地址和 API Key"
        serviceSettings.setAccessibilityLabel("翻译服务设置")
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        }
        let engineControls = NSStackView(views: [label("引擎"), enginePopup, label("模型"), modelCombo, refreshModelsButton, serviceSettings])
        engineControls.spacing = 8
        engineControls.alignment = .centerY
        engineControls.detachesHiddenViews = true
        updateEngineControls()

        textView.string = text
        textView.delegate = self
        translatedView.delegate = self
        translatedView.isEditable = false
        sourceLanguagePopup.addItem(withTitle: "自动检测")
        for language in sourceLanguages { sourceLanguagePopup.addItem(withTitle: language.title) }
        sourceLanguagePopup.target = self
        sourceLanguagePopup.action = #selector(sourceLanguageChanged)
        sourceLanguagePopup.controlSize = .small
        sourceLanguagePopup.toolTip = "原文语言；无法自动识别时，请在这里指定"
        sourceLanguagePopup.setAccessibilityLabel("原文语言")
        sourceLanguagePopup.isEnabled = engineSelection.isAvailable
        sourcePane.addHeaderAccessory(sourceLanguagePopup)
        configureButton(sourcePane.copyButton, symbol: "doc.on.doc", action: #selector(copyAll))
        configureButton(translationPane.copyButton, symbol: "doc.on.doc", action: #selector(copyTranslation))
        sourcePane.copyButton.toolTip = "复制原文"
        translationPane.copyButton.toolTip = "复制译文"
        sourcePane.copyButton.setAccessibilityLabel("复制原文")
        translationPane.copyButton.setAccessibilityLabel("复制译文")
        translationPane.setPlaceholder("译文将在这里显示")
        translationPane.isHidden = !translation
        let panes = NSStackView(views: [sourcePane, translationPane])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.alignment = .height
        panes.spacing = 14
        panes.detachesHiddenViews = true

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureButton(openLinkButton, symbol: "arrow.up.right.square", action: #selector(openLink))
        openLinkButton.isHidden = true
        configureButton(copyButton, symbol: "doc.on.doc", action: #selector(copyPrimary))
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = []
        if #available(macOS 26.0, *) { copyButton.bezelColor = .accentGreen }
        let footer = NSStackView(views: [progress, statusLabel, openLinkButton, copyButton])
        footer.distribution = .fill
        footer.spacing = 10
        footer.alignment = .centerY
        footer.detachesHiddenViews = true

        for view in [header, engineControls, panes, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        content.addSubview(translator.hostView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            languagePopup.widthAnchor.constraint(equalToConstant: 116),
            sourceLanguagePopup.widthAnchor.constraint(equalToConstant: 116),
            translateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            engineControls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            engineControls.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            engineControls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            engineControls.heightAnchor.constraint(equalToConstant: 28),
            enginePopup.widthAnchor.constraint(equalToConstant: 150),
            modelCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            refreshModelsButton.widthAnchor.constraint(equalToConstant: 28),
            serviceSettings.widthAnchor.constraint(equalToConstant: 28),
            panes.topAnchor.constraint(equalTo: engineControls.bottomAnchor, constant: 14),
            panes.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108)
        ])
        updateMode()
        updateCopyButtons()
        initialFirstResponder = textView
        setStatus(engineSelection.isAvailable ? "可编辑原文 · ⌘↩ 翻译 · Esc 关闭" : "翻译需要 macOS 15 或更高版本")
        OCRResultWindow.all.append(self)
        OCRResultWindow.latest = self
        refreshModelList()
        Task { @MainActor [weak self] in
            let languages = await Translator.supportedSourceLanguages()
            guard let self else { return }
            let selected = self.sourceLanguage
            let autoTitle = self.sourceLanguagePopup.itemTitle(at: 0)
            self.sourceLanguages = languages
            self.sourceLanguagePopup.removeAllItems()
            self.sourceLanguagePopup.addItem(withTitle: autoTitle)
            for language in languages { self.sourceLanguagePopup.addItem(withTitle: language.title) }
            self.sourceLanguagePopup.selectItem(at: selected.flatMap { languages.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
    }

    override var canBecomeKey: Bool { true }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func updateEngineControls() {
        enginePopup.selectItem(at: TranslationProvider.allCases.firstIndex(of: engineSelection.provider) ?? 0)
        modelCombo.stringValue = engineSelection.provider == .system ? "系统离线翻译" : engineSelection.model
        modelCombo.isEnabled = engineSelection.provider != .system
        refreshModelsButton.isHidden = engineSelection.provider == .system
        refreshModelsButton.isEnabled = !loadingModels
        languagePopup.isEnabled = engineSelection.isAvailable && !isTranslating
        sourceLanguagePopup.isEnabled = engineSelection.isAvailable && !isTranslating
    }

    @objc private func engineChanged() {
        let provider = TranslationProvider.allCases[enginePopup.indexOfSelectedItem]
        selectEngine(TranslationEngineSelection(provider: provider, model: provider == .system ? "" : Settings.aiTranslationModel(for: provider)))
    }

    @objc private func modelChanged() {
        guard engineSelection.provider != .system else { return }
        let model = modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            modelCombo.stringValue = engineSelection.model
            setStatus("请选择或输入模型名称")
            return
        }
        selectEngine(TranslationEngineSelection(provider: engineSelection.provider, model: model))
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let selected = modelCombo.objectValueOfSelectedItem as? String {
            modelCombo.stringValue = selected
            modelChanged()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSComboBox === modelCombo { modelChanged() }
    }

    private func selectEngine(_ selection: TranslationEngineSelection) {
        guard selection != engineSelection else { return }
        let providerChanged = selection.provider != engineSelection.provider
        if isTranslating { stopTranslation(keepPartial: false) }
        engineSelection = selection
        engineSelection.remember()
        translatedView.string = ""
        translationSource = nil
        sourceLanguagePopup.item(at: 0)?.title = "自动检测"
        translationPane.setPlaceholder("已切换翻译引擎，译文将在这里显示")
        updateEngineControls()
        updateCopyButtons()
        if isTranslationMode && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selection.provider == .system || !selection.model.isEmpty) {
            translateAction()
        } else {
            setStatus(selection.model.isEmpty && selection.provider != .system ? "请选择或输入模型名称，再开始翻译" : "已选择 \(selection.provider.title)")
        }
        if providerChanged { refreshModelList() }
    }

    @objc private func refreshModelList() {
        modelListTask?.cancel()
        let id = UUID()
        modelListID = id
        loadingModels = false
        let currentText = modelCombo.stringValue
        modelCombo.removeAllItems()
        modelCombo.stringValue = currentText
        guard engineSelection.provider != .system else { updateEngineControls(); return }
        if !engineSelection.model.isEmpty { modelCombo.addItem(withObjectValue: engineSelection.model) }
        loadingModels = true
        refreshModelsButton.isEnabled = false
        refreshModelsButton.toolTip = "正在读取模型列表…"
        let selection = engineSelection
        let request = requestID
        modelListTask = Task { @MainActor [weak self] in
            do {
                let models = try await AITranslator().models(configuration: selection.configuration())
                guard let self, !Task.isCancelled, self.modelListID == id else { return }
                let draft = self.modelCombo.stringValue
                self.modelCombo.removeAllItems()
                let values = Array(Set(models + (self.engineSelection.model.isEmpty ? [] : [self.engineSelection.model]))).sorted()
                self.modelCombo.addItems(withObjectValues: values)
                self.modelCombo.stringValue = draft
                self.refreshModelsButton.toolTip = models.isEmpty ? "服务中没有可用模型，下载后点击刷新" : "已读取 \(models.count) 个模型，点击可刷新"
                if models.isEmpty, !self.isTranslating, self.requestID == request {
                    self.setStatus("服务中没有可用模型，请先下载模型或直接输入模型名称")
                }
            } catch {
                guard let self, !Task.isCancelled, self.modelListID == id else { return }
                self.refreshModelsButton.toolTip = "模型列表读取失败：\(error.localizedDescription)；点击重试"
                if !self.isTranslating, self.requestID == request, self.translatedText.isEmpty {
                    self.setStatus("模型列表读取失败：\(error.localizedDescription)，仍可直接输入模型名称")
                }
            }
            guard let self, self.modelListID == id else { return }
            self.loadingModels = false
            self.refreshModelsButton.isEnabled = true
        }
    }

    @objc private func openTranslationSettings() { PreferencesWindow.show(tab: .translation) }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    private func updateMode() {
        titleLabel.stringValue = "识别与翻译"
        title = titleLabel.stringValue
        subtitleLabel.stringValue = isTranslationMode ? "原文与译文对照，随时编辑和复制" : "识别文字、二维码和链接，可继续翻译"
        copyButton.title = isTranslationMode ? "复制译文" : "复制原文"
        translationPane.title = "译文 · \(targetLanguage.title)"
    }

    private func updateCopyButtons() {
        translateButton.isEnabled = isTranslating || (engineSelection.isAvailable && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        sourcePane.copyButton.isEnabled = !textView.string.isEmpty
        translationPane.copyButton.isEnabled = canCopyTranslation
        copyButton.isEnabled = isTranslationMode ? canCopyTranslation : !textView.string.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        updateCopyButtons()
        if notification.object as? NSTextView === textView {
            if isTranslating { stopTranslation(keepPartial: false) }
            sourceLanguagePopup.item(at: 0)?.title = "自动检测"
            sourcePane.setPlaceholder(nil)
            if isTranslationMode { setStatus("原文已修改，点击“翻译”更新译文") }
        }
    }

    /// 识别到二维码，链接操作放在状态栏，避免与复制按钮重叠。
    func setCodes(_ codes: [String]) {
        recognizedCodes = codes
        guard !codes.isEmpty else { return }
        if let first = codes.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }), let url = URL(string: first) {
            link = url
            openLinkButton.isHidden = false
            openLinkButton.toolTip = first
        }
    }

    @objc private func openLink() {
        guard let link else { return }
        NSWorkspace.shared.open(link)
        close()
    }

    /// 识别图片中的二维码与文字并弹出结果窗口（结果自动复制）。
    @MainActor
    static func present(image: CGImage, near rect: CGRect, translate: Bool) {
        let win = OCRResultWindow(text: "", near: rect, translation: translate && Translator.isAvailable)
        win.sourcePane.setPlaceholder("正在识别截图中的文字…")
        win.sourcePane.copyButton.isEnabled = false
        win.copyButton.isEnabled = false
        win.translateButton.isEnabled = false
        win.setStatus("正在识别…")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let codes = await TextRecognizer.detectCodes(image)
            var lines: [TextRecognizer.Line] = []
            var failure: Error?
            do { lines = try await TextRecognizer.recognize(image) } catch { failure = error }
            let ocrText = TextRecognizer.joined(lines)
            let text = (codes + (ocrText.isEmpty ? [] : [ocrText])).joined(separator: codes.isEmpty ? "" : "\n\n")
            guard win.isVisible else { return }
            win.setCodes(codes)
            win.setText(text)
            win.translateButton.isEnabled = win.engineSelection.isAvailable && !text.isEmpty
            if text.isEmpty {
                win.sourcePane.setPlaceholder("未识别到文字，可在这里输入或粘贴")
                win.setStatus(failure.map { "识别失败：\($0.localizedDescription)" } ?? "未识别到文字或二维码")
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                var parts: [String] = []
                if !codes.isEmpty { parts.append("\(codes.count) 个二维码") }
                if !lines.isEmpty { parts.append("\(lines.count) 处文字") }
                win.setStatus("已识别 " + parts.joined(separator: "、") + "，原文已复制")
                if ocrText.isEmpty && !codes.isEmpty {
                    // 二维码内容可以是链接、账号或编号，不自动送去语言检测和翻译。
                    win.isTranslationMode = false
                    win.translationPane.isHidden = true
                    win.updateMode()
                    win.updateCopyButtons()
                } else if translate && win.engineSelection.isAvailable {
                    win.translateAction()
                }
            }
            Log.info("ocr: \(lines.count) lines, \(codes.count) codes")
        }
    }

    func setText(_ text: String) {
        if isTranslating { stopTranslation(keepPartial: false) }
        textView.string = text
        sourceLanguagePopup.item(at: 0)?.title = "自动检测"
        sourcePane.setPlaceholder(nil)
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: TargetLanguage.defaultTarget(for: text)) ?? 0)
        translationSource = nil
        updateMode()
        updateCopyButtons()
    }
    var text: String { textView.string }
    var translatedText: String { translatedView.string }

    @objc private func targetChanged() {
        translationSource = nil
        updateMode()
        updateCopyButtons()
        if isTranslationMode { translateAction() }
    }

    @objc private func sourceLanguageChanged() {
        translationSource = nil
        updateCopyButtons()
        if isTranslationMode { translateAction() }
    }

    @objc func translateAction() {
        if isTranslating {
            stopTranslation(keepPartial: true)
            return
        }
        let source = textView.string
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("没有可翻译的文字")
            return
        }
        showTranslationPane()
        let target = targetLanguage
        let request = UUID()
        requestID = request
        isTranslating = true
        translatedView.string = ""
        translatedView.isEditable = false
        translationSource = nil
        translationPane.setPlaceholder("正在翻译为\(target.title)…")
        translateButton.title = "停止翻译"
        translateButton.isEnabled = true
        translateButton.toolTip = "停止本次翻译，保留已生成的文字"
        languagePopup.isEnabled = false
        sourceLanguagePopup.isEnabled = false
        progress.isHidden = false
        progress.startAnimation(nil)
        updateCopyButtons()
        let provider = engineSelection.provider
        setStatus(provider == .system ? "正在翻译，首次使用请按系统提示下载语言包" : "正在使用 \(provider.title) 翻译整段文字…")
        // 混合结果中的二维码保持原样；只有二维码时，用户仍可主动翻译其文字内容。
        let codeOnly = source == recognizedCodes.joined(separator: "\n\n")
        translator.translate(source, from: sourceLanguage, to: target, using: engineSelection, excluding: codeOnly ? [] : recognizedCodes,
                             onUpdate: { [weak self] partial in
            guard let self, self.requestID == request, self.isTranslating, self.textView.string == source else { return }
            self.displayTranslation(partial)
            self.translationSource = source
            self.translationPane.setPlaceholder(nil)
            self.setStatus("\(provider.title) · 正在翻译为\(target.title)…")
            self.updateCopyButtons()
        }) { [weak self] result in
            guard let self, self.requestID == request else { return }
            self.isTranslating = false
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            self.translateButton.title = "重新翻译"
            self.translateButton.toolTip = "重新翻译原文  ⌘↩"
            self.translateButton.isEnabled = self.engineSelection.isAvailable
            self.languagePopup.isEnabled = self.engineSelection.isAvailable
            self.sourceLanguagePopup.isEnabled = self.engineSelection.isAvailable
            guard self.textView.string == source else {
                self.translationPane.setPlaceholder("原文已修改，请重新翻译")
                self.setStatus("原文已修改，点击“重新翻译”更新译文")
                self.updateCopyButtons()
                return
            }
            switch result {
            case .success(let output):
                self.displayTranslation(output.text)
                self.translatedView.isEditable = true
                self.translationSource = source
                self.translationPane.setPlaceholder(nil)
                if self.sourceLanguage == nil {
                    let names = output.sourceLanguages.map(\.title).joined(separator: "、")
                    let label = output.sourceLanguages.count > 1 ? "多语" : output.sourceLanguages.first?.title
                    self.sourceLanguagePopup.item(at: 0)?.title = label.map { "自动·\($0)" } ?? "自动检测"
                    self.sourceLanguagePopup.toolTip = names.isEmpty ? "原文语言" : "自动识别为\(names)，可手动指定"
                    if output.provider != .system {
                        self.sourceLanguagePopup.item(at: 0)?.title = "自动·AI"
                        self.sourceLanguagePopup.toolTip = "由 \(output.provider.title) 根据整段原文判断语言，也可手动指定"
                    }
                }
                if output.didTranslate {
                    self.setStatus("\(output.provider.title) · 已翻译为\(target.title) · 译文可编辑")
                } else if output.sourceLanguages.isEmpty {
                    self.setStatus("内容为链接、编号或符号，已保留原文")
                } else {
                    self.setStatus("原文已是\(target.title)，无需翻译")
                }
                Log.info("translate ok: \(output.text.count) chars, languages=\(output.sourceLanguages.map(\.identifier).joined(separator: ","))")
            case .failure(let error):
                self.translatedView.isEditable = true
                if case TranslatorError.sourceLanguageRequired = error {
                    self.translationPane.setPlaceholder("请在原文顶部选择语言，然后重新翻译")
                    self.makeFirstResponder(self.sourceLanguagePopup)
                } else {
                    self.translationPane.setPlaceholder(provider == .system ? "翻译未完成，可指定原文语言后重试" : "翻译未完成，请检查设置 › 翻译中的服务配置")
                }
                let partial = !self.translatedView.string.isEmpty
                if partial { self.translationPane.setPlaceholder(nil) }
                self.setStatus(partial ? "翻译未完成，已保留生成的文字：\(error.localizedDescription)" : "翻译失败：\(error.localizedDescription)")
                Log.info("translate failed: \(error)")
            }
            self.updateCopyButtons()
        }
    }

    /// 尽量只追加文字；用户上滚查看时不把滚动位置强制拉回底部。
    private func displayTranslation(_ text: String) {
        guard text != translatedView.string else { return }
        let old = translatedView.string
        let scroll = translatedView.enclosingScrollView
        let follow = scroll.map { $0.documentVisibleRect.maxY >= translatedView.bounds.maxY - 24 } ?? true
        let value = text as NSString
        if (old.isEmpty || value.range(of: old, options: [.anchored, .literal]).location == 0), let storage = translatedView.textStorage {
            let suffix = value.substring(from: (old as NSString).length)
            storage.append(NSAttributedString(string: suffix, attributes: translatedView.typingAttributes))
        } else {
            translatedView.string = text
        }
        if follow { translatedView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0)) }
    }

    private func stopTranslation(keepPartial: Bool) {
        requestID = UUID()
        translator.cancel()
        isTranslating = false
        progress.stopAnimation(nil)
        progress.isHidden = true
        translateButton.title = "重新翻译"
        translateButton.toolTip = "重新翻译原文  ⌘↩"
        languagePopup.isEnabled = engineSelection.isAvailable
        sourceLanguagePopup.isEnabled = engineSelection.isAvailable
        translatedView.isEditable = true
        if !keepPartial {
            translatedView.string = ""
            translationSource = nil
        }
        translationPane.setPlaceholder(translatedView.string.isEmpty ? "翻译已停止，可重新翻译" : nil)
        setStatus(keepPartial && !translatedView.string.isEmpty ? "已停止，已生成的译文未完成，可复制或重新翻译" : "翻译已停止")
        updateCopyButtons()
    }

    private func showTranslationPane() {
        guard !isTranslationMode else { return }
        isTranslationMode = true
        translationPane.isHidden = false
        updateMode()
        var newFrame = frame
        newFrame.size.width = max(newFrame.width, 820)
        newFrame.size.height = max(newFrame.height, 520)
        newFrame.origin.x = frame.midX - newFrame.width / 2
        newFrame.origin.y = frame.maxY - newFrame.height
        if let screen { newFrame = constrainFrameRect(newFrame, to: screen) }
        setFrame(newFrame, display: true)
    }

    @objc private func copyPrimary() {
        if isTranslationMode { copyTranslation() } else { copyAll() }
    }

    @objc private func copyTranslation() {
        guard canCopyTranslation else { return }
        copy(translatedView.string, status: isTranslating ? "已复制当前译文，翻译仍在继续" : "译文已复制到剪贴板")
    }

    @objc private func copyAll() {
        guard !textView.string.isEmpty else { return }
        copy(textView.string, status: "原文已复制到剪贴板")
    }

    private func copy(_ text: String, status: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        setStatus(status)
    }

    override func close() {
        requestID = UUID()
        translator.cancel()
        modelListTask?.cancel()
        super.close()
        OCRResultWindow.all.removeAll { $0 === self }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// 定向回归：短文本在明确指定原文语言时也能走完整的窗口翻译流程。
    func debugTranslate(from source: TargetLanguage, to target: TargetLanguage) {
        sourceLanguagePopup.selectItem(at: (sourceLanguages.firstIndex(of: source) ?? 0) + 1)
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: target) ?? 0)
        updateMode()
        translateAction()
    }

    func debugTranslateAutomatically(to target: TargetLanguage) {
        sourceLanguagePopup.selectItem(at: 0)
        languagePopup.selectItem(at: TargetLanguage.all.firstIndex(of: target) ?? 0)
        updateMode()
        translateAction()
    }

    var debugModelNames: [String] { modelCombo.objectValues.compactMap { $0 as? String } }
    var debugStatusText: String { statusLabel.stringValue }

    func debugSelectEngine(_ selection: TranslationEngineSelection) {
        enginePopup.selectItem(at: TranslationProvider.allCases.firstIndex(of: selection.provider) ?? 0)
        engineChanged()
        if selection.provider != .system {
            modelCombo.stringValue = selection.model
            modelChanged()
        }
    }
}

/// 用稳定的底色保证玻璃窗口在复杂桌面背景上仍有足够对比度。
private final class OCRSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        }
    }
}

/// 独立的文本卡片，滚动区域随窗口调整，不让正文挤占标题和复制操作。
private final class OCRTextPane: NSView {
    let textView = NSTextView()
    let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let titleLabel: NSTextField
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let header = NSStackView()
    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    init(title: String, symbol: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateColors()
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        for view in [icon, titleLabel, spacer, copyButton] { header.addArrangedSubview(view) }
        header.spacing = 7
        header.alignment = .centerY
        copyButton.controlSize = .small
        let separator = SeparatorView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        textView.setAccessibilityLabel(title)
        scroll.documentView = textView
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        for view in [header, separator, scroll, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 26),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -28)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    func addHeaderAccessory(_ view: NSView) {
        header.insertArrangedSubview(view, at: 2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.86).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        }
    }
}
