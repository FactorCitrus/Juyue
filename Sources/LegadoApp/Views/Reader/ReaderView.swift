import SwiftUI
import CoreText
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct ContentBlock: Identifiable {
    public let id: Int
    public let isImage: Bool
    public let text: String
    public let imageUrl: String?
}

public struct LoadedChapter: Identifiable {
    public var id: Int { chapter.index }
    public let chapter: BookChapter
    public var content: String
    public var blocks: [ContentBlock]
    public var pages: [[ContentBlock]] = []
}

public struct BlockFrameInfo: Equatable {
    public let chapterIndex: Int
    public let blockId: Int
    public let minY: CGFloat
    public let maxY: CGFloat
}

public struct ReaderScrollPreferenceKey: PreferenceKey {
    public static var defaultValue: [BlockFrameInfo] = []
    public static func reduce(value: inout [BlockFrameInfo], nextValue: () -> [BlockFrameInfo]) {
        value.append(contentsOf: nextValue())
    }
}

public struct ScrollOffsetPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var readerConfig = ReaderConfig.shared
    @StateObject private var audioService = AudioBookService.shared

    let book: Book
    let source: BookSource?

    private var effectiveSource: BookSource? {
        source ?? BookStore.shared.findSource(for: book)
    }

    @State private var chapters: [BookChapter] = []
    @State private var currentChapterIndex: Int = 0
    @State private var loadedChapters: [LoadedChapter] = []
    @State private var currentPageIndex: Int = 0
    @State private var currentReadingBlockId: Int = 0
    @State private var chapterCache: [Int: LoadedChapter] = [:]
    @State private var readerContainerSize: CGSize = CGSize(width: 390, height: 700)

    @State private var isLoadingInitial: Bool = true
    @State private var isLoadingNextChapter: Bool = false
    @State private var scrollSessionId: UUID = UUID()
    @State private var scrollToChapterId: String? = nil
    @State private var errorMessage: String? = nil

    @State private var showTOC: Bool = false
    @State private var showSettings: Bool = false
    @State private var showSearch: Bool = false
    @State private var showControls: Bool = false

    public var onDismiss: (() -> Void)? = nil

    public init(book: Book, source: BookSource?, initialChapterIndex: Int? = nil, onDismiss: (() -> Void)? = nil) {
        self.book = book
        self.source = source
        self._currentChapterIndex = State(initialValue: initialChapterIndex ?? book.durChapterIndex)
        self.onDismiss = onDismiss
    }

    private var currentLoadedChapter: LoadedChapter? {
        loadedChapters.first(where: { $0.chapter.index == currentChapterIndex }) ?? loadedChapters.first
    }

    private var currentChapterContent: String {
        currentLoadedChapter?.content ?? ""
    }

    public var body: some View {
        GeometryReader { outerGeo in
            ZStack {
                readerConfig.theme.backgroundColor
                    .ignoresSafeArea()

                // 1. Reading Canvas with Permanent Fixed Bottom Info Bar
                VStack(spacing: 0) {
                    Group {
                        if isLoadingInitial {
                            VStack(spacing: 16) {
                                Spacer()
                                ProgressView()
                                Text("正在加载章节内容...")
                                    .font(.subheadline)
                                    .foregroundColor(readerConfig.theme.textColor.opacity(0.7))
                                Spacer()
                            }
                        } else if let error = errorMessage {
                            VStack(spacing: 12) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundColor(.orange)
                                Text("加载失败")
                                    .font(.headline)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                Button("重试") {
                                    loadInitialChapter(at: currentChapterIndex)
                                }
                                .buttonStyle(.borderedProminent)
                                Spacer()
                            }
                        } else {
                            ZStack {
                                if readerConfig.pageMode == .scroll {
                                    infiniteScrollView
                                } else {
                                    pageByPageView
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    // Fixed Bottom Information Bar (Apple Books Style)
                    fixedBottomStatusBar
                }

                // 2. Dismiss Backdrop (when controls are open, tapping anywhere outside bars dismisses them)
                if showControls && !showSettings {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showControls = false
                            }
                        }
                        .ignoresSafeArea()
                }

                // 3. Top Navigation Bar Overlay (Sliding down from top)
                if showControls && !showSettings {
                    VStack(spacing: 0) {
                        topNavigationBar
                        Spacer()
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }

                // 4. Bottom Control Panel Overlay (Sliding up from bottom)
                if showControls && !showSettings {
                    VStack(spacing: 0) {
                        Spacer()
                        bottomControlPanel
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }

                // 5. Reading Settings Card Overlay (Bottom 1/3 of the screen)
                if showSettings {
                    Color.black.opacity(0.2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showSettings = false
                                showControls = false
                            }
                        }
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        Spacer()
                        readingSettingsCard
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
            .onAppear {
                let readingHeight = max(200, outerGeo.size.height - 26)
                updateContainerSizeIfNeeded(CGSize(width: outerGeo.size.width, height: readingHeight))
            }
            .onChange(of: outerGeo.size) { newSize in
                let readingHeight = max(200, newSize.height - 26)
                updateContainerSizeIfNeeded(CGSize(width: newSize.width, height: readingHeight))
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        #endif
        .sheet(isPresented: $showTOC) {
            tocSheet
        }
        .sheet(isPresented: $showSearch) {
            searchSheet
        }
        .task {
            await loadTOCAndStart()
        }
        .onDisappear {
            saveCurrentProgress()
            audioService.stop()
        }
        .onChange(of: readerConfig.pageMode) { newMode in
            handlePageModeChange(to: newMode)
        }
    }



    // MARK: - Mode 1: Infinite Scroll Down (连续滚动)
    private var infiniteScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    GeometryReader { probeGeo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: probeGeo.frame(in: .named("readerScrollCoordinate")).minY
                        )
                    }
                    .frame(height: 0)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(loadedChapters) { loadedCh in
                            VStack(alignment: .leading, spacing: readerConfig.lineSpacing) {
                                // Chapter Title
                                Text(loadedCh.chapter.title)
                                    .font(.system(size: readerConfig.fontSize + 4, weight: .bold))
                                    .foregroundColor(readerConfig.theme.textColor)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 20)
                                    .padding(.bottom, 10)
                                    .id("chapter_\(loadedCh.chapter.index)")
                                    .onAppear {
                                        if currentChapterIndex != loadedCh.chapter.index {
                                            currentChapterIndex = loadedCh.chapter.index
                                            BookStore.shared.updateProgress(bookUrl: book.bookUrl, chapterIndex: currentChapterIndex, chapterTitle: loadedCh.chapter.title, chapterPos: currentChapterCharOffset())
                                            preCacheNeighbors(around: currentChapterIndex)
                                        }
                                    }

                                // Chapter Paragraphs and Images
                                ForEach(loadedCh.blocks) { block in
                                    if block.isImage, let urlStr = block.imageUrl {
                                        ChapterImageView(urlString: urlStr, referer: effectiveSource?.bookSourceUrl)
                                            .padding(.horizontal, 20)
                                            .id("block_\(loadedCh.chapter.index)_\(block.id)")
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear
                                                        .preference(
                                                            key: ReaderScrollPreferenceKey.self,
                                                            value: [BlockFrameInfo(
                                                                chapterIndex: loadedCh.chapter.index,
                                                                blockId: block.id,
                                                                minY: geo.frame(in: .named("readerScrollCoordinate")).minY,
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY
                                                            )]
                                                        )
                                                }
                                            )
                                    } else {
                                        Text(block.text)
                                            .font(.system(size: readerConfig.fontSize))
                                            .lineSpacing(readerConfig.lineSpacing)
                                            .foregroundColor(readerConfig.theme.textColor)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, readerConfig.lineSpacing / 3)
                                            .id("block_\(loadedCh.chapter.index)_\(block.id)")
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear
                                                        .preference(
                                                            key: ReaderScrollPreferenceKey.self,
                                                            value: [BlockFrameInfo(
                                                                chapterIndex: loadedCh.chapter.index,
                                                                blockId: block.id,
                                                                minY: geo.frame(in: .named("readerScrollCoordinate")).minY,
                                                                maxY: geo.frame(in: .named("readerScrollCoordinate")).maxY
                                                            )]
                                                        )
                                                }
                                            )
                                    }
                                }

                                // Empty space between chapters (pure blank space, no lines or text prompts)
                                Color.clear
                                    .frame(height: 64)
                                    .id("chapter_end_\(loadedCh.chapter.index)")
                                    .onAppear {
                                        if loadedCh.chapter.index < chapters.count - 1 {
                                            loadNextChapterForInfiniteScroll(after: loadedCh.chapter.index)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .coordinateSpace(name: "readerScrollCoordinate")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                let scrollY = -minY
                handleScrollOffsetChanged(scrollY: scrollY)
            }
            .onPreferenceChange(ReaderScrollPreferenceKey.self) { frames in
                handleBlockFramesChanged(frames)
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { notification in
                guard readerConfig.pageMode == .scroll else { return }
                if let clipView = notification.object as? NSClipView {
                    let scrollY = clipView.documentVisibleRect.origin.y
                    handleScrollOffsetChanged(scrollY: scrollY)
                }
            }
            #endif
            .id(scrollSessionId)
            .refreshable {
                if let first = loadedChapters.first, first.chapter.index > 0 {
                    let prevIndex = first.chapter.index - 1
                    if let prevLoaded = await getOrFetchChapter(at: prevIndex) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            loadedChapters.insert(prevLoaded, at: 0)
                            currentChapterIndex = prevIndex
                            scrollToChapterId = "chapter_end_\(prevIndex)"
                        }
                        BookStore.shared.updateProgress(bookUrl: book.bookUrl, chapterIndex: prevIndex, chapterTitle: prevLoaded.chapter.title)
                        preCacheNeighbors(around: prevIndex)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
            }
            .onAppear {
                if let target = scrollToChapterId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        let anchor: UnitPoint = target.hasPrefix("chapter_end") ? .center : .top
                        proxy.scrollTo(target, anchor: anchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(target, anchor: anchor)
                            scrollToChapterId = nil
                        }
                    }
                }
            }
            .onChange(of: scrollToChapterId) { target in
                if let target = target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let anchor: UnitPoint = target.hasPrefix("chapter_end") ? .center : .top
                        proxy.scrollTo(target, anchor: anchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(target, anchor: anchor)
                            scrollToChapterId = nil
                        }
                    }
                }
            }
        }
    }

    private func handleBlockFramesChanged(_ frames: [BlockFrameInfo]) {
        guard !frames.isEmpty else { return }
        if let active = frames.first(where: { $0.minY <= 140 && $0.maxY >= 20 }) ??
                        frames.min(by: { abs($0.minY - 50) < abs($1.minY - 50) }) {
            if self.currentChapterIndex != active.chapterIndex {
                self.currentChapterIndex = active.chapterIndex
                self.preCacheNeighbors(around: active.chapterIndex)
            }
            self.currentReadingBlockId = active.blockId
        }
    }

    private func handleScrollOffsetChanged(scrollY: CGFloat) {
        guard scrollY > 0, !loadedChapters.isEmpty else { return }
        let width = max(240, readerContainerSize.width)
        let usableWidth = max(200, width - 40)
        let charsPerLine = max(10, Int(usableWidth / readerConfig.fontSize))
        let lineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
        let titleHeight = (readerConfig.fontSize + 4) * 1.3 + 30.0

        let targetY = scrollY + 60.0
        var currentY: CGFloat = 0

        for loadedCh in loadedChapters {
            currentY += titleHeight

            for block in loadedCh.blocks {
                let blockH: CGFloat
                if block.isImage {
                    blockH = 260.0
                } else {
                    let lines = max(1, Int(ceil(Double(block.text.count) / Double(charsPerLine))))
                    blockH = CGFloat(lines) * lineHeight + (readerConfig.lineSpacing * 2.0 / 3.0)
                }

                if targetY >= currentY && targetY < currentY + blockH {
                    if self.currentChapterIndex != loadedCh.chapter.index {
                        self.currentChapterIndex = loadedCh.chapter.index
                        self.preCacheNeighbors(around: loadedCh.chapter.index)
                    }
                    self.currentReadingBlockId = block.id
                    return
                }
                currentY += blockH
            }

            currentY += 64.0
            if targetY < currentY {
                if self.currentChapterIndex != loadedCh.chapter.index {
                    self.currentChapterIndex = loadedCh.chapter.index
                }
                return
            }
        }
    }

    // MARK: - Mode 2: Page by Page (左右翻页)
    private var pageByPageView: some View {
        GeometryReader { geo in
            let pages = currentLoadedChapter?.pages ?? []

            ZStack {
                if pages.isEmpty || currentPageIndex >= pages.count {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    let pageBlocks = pages[currentPageIndex]
                    let usableWidth = max(200, readerContainerSize.width - 48)

                    VStack(alignment: .leading, spacing: 0) {
                        // If it's page 0, display Chapter Title at top
                        if currentPageIndex == 0, let cur = currentLoadedChapter {
                            Text(cur.chapter.title)
                                .font(.system(size: readerConfig.fontSize + 3, weight: .bold))
                                .foregroundColor(readerConfig.theme.textColor)
                                .padding(.bottom, 8)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Page Content
                        if pageBlocks.first?.isImage == true, let urlStr = pageBlocks.first?.imageUrl {
                            ChapterImageView(urlString: urlStr, referer: effectiveSource?.bookSourceUrl)
                        } else {
                            let lines = pageBlocks.map { $0.text }
                            let isParagraphEnd = pageBlocks.map { $0.imageUrl == "p_end" }
                            let effectiveLineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
                            let pageContentHeight = CGFloat(lines.count) * effectiveLineHeight

                            CoreTextPageView(
                                lines: lines,
                                isParagraphEnd: isParagraphEnd,
                                fontSize: readerConfig.fontSize,
                                lineSpacing: readerConfig.lineSpacing,
                                textColor: readerConfig.theme.textColor,
                                width: usableWidth,
                                height: pageContentHeight
                            )
                            .frame(width: usableWidth, height: pageContentHeight, alignment: .topLeading)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .id("page_\(currentChapterIndex)_\(currentPageIndex)")
                }

                // Three-Zone Tap Controller & Drag Gesture
                HStack(spacing: 0) {
                    // Left 30%: Previous Page
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width * 0.3)
                        .onTapGesture {
                            turnPage(forward: false)
                        }

                    // Middle 40%: Toggle Controls
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width * 0.4)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                        }

                    // Right 30%: Next Page
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width * 0.3)
                        .onTapGesture {
                            turnPage(forward: true)
                        }
                }
            }
            .contentShape(Rectangle())
            .onAppear {
                updateContainerSizeIfNeeded(geo.size)
            }
            .onChange(of: geo.size) { newSize in
                updateContainerSizeIfNeeded(newSize)
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            turnPage(forward: true)
                        } else if value.translation.width > 40 {
                            turnPage(forward: false)
                        }
                    }
            )
        }
    }

    private func updateContainerSizeIfNeeded(_ size: CGSize) {
        guard size.width > 100 && size.height > 100 else { return }
        if abs(size.width - readerContainerSize.width) > 6 || abs(size.height - readerContainerSize.height) > 6 {
            DispatchQueue.main.async {
                self.readerContainerSize = size
                self.recomputePagination()
            }
        }
    }

    private func updateReadingBlockIdFromCurrentPage() {
        guard let cur = currentLoadedChapter, !cur.pages.isEmpty else { return }
        var charPos = 0
        let limit = min(currentPageIndex, cur.pages.count)
        for p in 0..<limit {
            for block in cur.pages[p] {
                charPos += block.text.count
            }
        }
        var accumulated = 0
        var targetBlockId = cur.blocks.first?.id ?? 0
        for block in cur.blocks {
            if accumulated + block.text.count > charPos {
                targetBlockId = block.id
                break
            }
            accumulated += block.text.count
            targetBlockId = block.id
        }
        currentReadingBlockId = targetBlockId
    }

    // MARK: - Page Turn Handler (Once chapter ends, next chapter starts next page)
    private func turnPage(forward: Bool) {
        guard let current = currentLoadedChapter else { return }
        let totalPages = current.pages.count

        if forward {
            if currentPageIndex < totalPages - 1 {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentPageIndex += 1
                }
                updateReadingBlockIdFromCurrentPage()
                saveCurrentProgress()
            } else {
                // Chapter ended! Once one chapter ends, the new chapter starts the next page!
                if currentChapterIndex < chapters.count - 1 {
                    audioService.stop()
                    let nextIdx = currentChapterIndex + 1
                    currentChapterIndex = nextIdx
                    currentPageIndex = 0
                    currentReadingBlockId = 0
                    loadInitialChapter(at: nextIdx, targetPageIndex: 0)
                }
            }
        } else {
            if currentPageIndex > 0 {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentPageIndex -= 1
                }
                updateReadingBlockIdFromCurrentPage()
                saveCurrentProgress()
            } else {
                // Return to previous chapter's last page!
                if currentChapterIndex > 0 {
                    audioService.stop()
                    let prevIdx = currentChapterIndex - 1
                    currentChapterIndex = prevIdx
                    loadInitialChapter(at: prevIdx, targetPageIndex: -1) // -1 indicates last page
                }
            }
        }
    }

    // MARK: - Navigation Bars & Toolbars (Apple Books Layout)
    private var topNavigationBar: some View {
        HStack(alignment: .center) {
            // Exit button
            Button(action: {
                audioService.stop()
                if let onDismiss = onDismiss {
                    onDismiss()
                }
                dismiss()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                    Text("书架")
                        .font(.system(size: 16))
                }
                .foregroundColor(readerConfig.theme.textColor)
                .contentShape(Rectangle())
            }

            Spacer()

            // Book Title in Center (No reading progress/chapter info)
            Text(book.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(readerConfig.theme.textColor)
                .lineLimit(1)
                .frame(maxWidth: 240)

            Spacer()

            // Balanced placeholder so center title remains perfectly centered
            Color.clear
                .frame(width: 54, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            readerConfig.theme.backgroundColor
                .opacity(0.97)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(
            Rectangle()
                .fill(readerConfig.theme.textColor.opacity(0.12))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 12) {
            chapterNavigationRow

            Rectangle()
                .fill(readerConfig.theme.textColor.opacity(0.12))
                .frame(height: 0.5)

            bottomActionRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            readerConfig.theme.backgroundColor
                .opacity(0.97)
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Permanent Fixed Bottom Status Bar
    private var fixedBottomStatusBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // Chapter Name
            if !chapters.isEmpty && currentChapterIndex < chapters.count {
                Text(chapters[currentChapterIndex].title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(readerConfig.theme.textColor.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(book.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(readerConfig.theme.textColor.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            // Reading Percentage / Page Info
            if !chapters.isEmpty {
                let progressPercent = Double(currentChapterIndex + 1) / Double(chapters.count) * 100.0
                if readerConfig.pageMode == .pageByPage, let cur = currentLoadedChapter, !cur.pages.isEmpty {
                    Text("\(currentPageIndex + 1)/\(cur.pages.count) · \(String(format: "%.1f%%", progressPercent))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(readerConfig.theme.textColor.opacity(0.55))
                } else {
                    Text("\(currentChapterIndex + 1)/\(chapters.count) (\(String(format: "%.1f%%", progressPercent)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(readerConfig.theme.textColor.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(height: 26)
        .background(readerConfig.theme.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }

    private var chapterNavigationRow: some View {
        HStack(spacing: 14) {
            Button(action: {
                previousChapter()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("上一章")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(currentChapterIndex > 0 ? readerConfig.theme.textColor : readerConfig.theme.textColor.opacity(0.3))
            }
            .disabled(currentChapterIndex <= 0)

            if chapters.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentChapterIndex) },
                        set: { newValue in
                            let target = Int(newValue.rounded())
                            if target != currentChapterIndex && target >= 0 && target < chapters.count {
                                jumpToChapter(target)
                            }
                        }
                    ),
                    in: 0...Double(chapters.count - 1),
                    step: 1
                )
                .accentColor(.accentColor)
            } else {
                Spacer()
            }

            Button(action: {
                nextChapter()
            }) {
                HStack(spacing: 4) {
                    Text("下一章")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(currentChapterIndex < chapters.count - 1 ? readerConfig.theme.textColor : readerConfig.theme.textColor.opacity(0.3))
            }
            .disabled(currentChapterIndex >= chapters.count - 1)
        }
    }

    private func previousChapter() {
        guard currentChapterIndex > 0 else { return }
        let prevIndex = currentChapterIndex - 1

        if readerConfig.pageMode == .scroll {
            if loadedChapters.contains(where: { $0.chapter.index == prevIndex }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollToChapterId = "chapter_end_\(prevIndex)"
                }
            } else if let first = loadedChapters.first, first.chapter.index == currentChapterIndex {
                Task {
                    if let prevLoaded = await getOrFetchChapter(at: prevIndex) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.loadedChapters.insert(prevLoaded, at: 0)
                            self.currentChapterIndex = prevIndex
                            self.scrollToChapterId = "chapter_end_\(prevIndex)"
                        }
                        BookStore.shared.updateProgress(bookUrl: book.bookUrl, chapterIndex: prevIndex, chapterTitle: prevLoaded.chapter.title)
                        self.preCacheNeighbors(around: prevIndex)
                    }
                }
            } else {
                jumpToChapter(prevIndex, toEnd: true)
            }
        } else {
            jumpToChapter(prevIndex, toEnd: true)
        }
    }

    private func nextChapter() {
        guard currentChapterIndex < chapters.count - 1 else { return }
        let nextIndex = currentChapterIndex + 1

        if readerConfig.pageMode == .scroll {
            if loadedChapters.contains(where: { $0.chapter.index == nextIndex }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollToChapterId = "chapter_\(nextIndex)"
                }
            } else {
                jumpToChapter(nextIndex, toEnd: false)
            }
        } else {
            jumpToChapter(nextIndex, toEnd: false)
        }
    }

    private func jumpToChapter(_ targetIndex: Int, toEnd: Bool = false) {
        guard targetIndex >= 0 && targetIndex < chapters.count else { return }
        audioService.stop()
        currentChapterIndex = targetIndex
        currentPageIndex = 0
        currentReadingBlockId = 0
        scrollSessionId = UUID()
        loadInitialChapter(at: targetIndex, targetPageIndex: toEnd ? -1 : 0, scrollToTargetEnd: toEnd)
    }

    private func handlePageModeChange(to newMode: PageMode) {
        guard let cur = currentLoadedChapter else { return }

        if newMode == .pageByPage {
            // 1. Switching from Continuous Scroll to Page-by-Page:
            var charPos = 0
            for block in cur.blocks {
                if block.id == currentReadingBlockId {
                    break
                }
                charPos += block.text.count
            }

            var accumulated = 0
            var targetPage = 0
            for (pIdx, page) in cur.pages.enumerated() {
                let pageCharCount = page.reduce(0) { $0 + $1.text.count }
                if accumulated + pageCharCount > charPos {
                    targetPage = pIdx
                    break
                }
                accumulated += pageCharCount
                targetPage = pIdx
            }
            currentPageIndex = min(targetPage, max(0, cur.pages.count - 1))
            updateReadingBlockIdFromCurrentPage()
        } else {
            // 2. Switching from Page-by-Page to Continuous Scroll:
            var charPos = 0
            let limit = min(currentPageIndex, cur.pages.count)
            for p in 0..<limit {
                for block in cur.pages[p] {
                    charPos += block.text.count
                }
            }

            var accumulated = 0
            var targetBlockId = cur.blocks.first?.id ?? 0
            for block in cur.blocks {
                if accumulated + block.text.count > charPos {
                    targetBlockId = block.id
                    break
                }
                accumulated += block.text.count
                targetBlockId = block.id
            }

            currentReadingBlockId = targetBlockId
            scrollSessionId = UUID()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                scrollToChapterId = "block_\(currentChapterIndex)_\(targetBlockId)"
            }
        }
        saveCurrentProgress()
    }

    private var bottomActionRow: some View {
        HStack(spacing: 0) {
            // Contents Table (目录)
            Button(action: { showTOC = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20))
                    Text("目录")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.theme.textColor)
                .frame(maxWidth: .infinity)
            }

            // Text Search (搜索)
            Button(action: { showSearch = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                    Text("搜索")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.theme.textColor)
                .frame(maxWidth: .infinity)
            }

            // TTS (听书)
            Button(action: {
                audioService.togglePlayPause(text: currentChapterContent)
            }) {
                VStack(spacing: 4) {
                    Image(systemName: audioService.isPlaying ? "pause.circle.fill" : (audioService.isPaused ? "play.circle.fill" : "headphones"))
                        .font(.system(size: 20))
                        .foregroundColor(audioService.isPlaying ? .accentColor : readerConfig.theme.textColor)
                    Text(audioService.isPlaying ? "暂停" : (audioService.isPaused ? "继续" : "听书"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(audioService.isPlaying ? .accentColor : readerConfig.theme.textColor)
                }
                .foregroundColor(readerConfig.theme.textColor)
                .frame(maxWidth: .infinity)
            }

            // Interface Settings (界面设置)
            Button(action: { showSettings = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 20))
                    Text("界面")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(readerConfig.theme.textColor)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var searchSheet: some View {
        ReaderSearchSheet(
            book: book,
            currentChapterIndex: currentChapterIndex,
            currentChapterTitle: (!chapters.isEmpty && currentChapterIndex < chapters.count) ? chapters[currentChapterIndex].title : "",
            currentContent: currentChapterContent,
            chapters: chapters,
            onSelectChapter: { targetIndex, _ in
                showSearch = false
                withAnimation {
                    showControls = false
                }
                if targetIndex != currentChapterIndex {
                    jumpToChapter(targetIndex)
                }
            }
        )
    }

    private var tocSheet: some View {
        NavigationView {
            List(chapters) { ch in
                Button(action: {
                    showTOC = false
                    jumpToChapter(ch.index)
                }) {
                    HStack {
                        Text(ch.title)
                            .foregroundColor(ch.index == currentChapterIndex ? .accentColor : .primary)
                        Spacer()
                        if ch.index == currentChapterIndex {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("目录 (\(chapters.count)章)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showTOC = false }
                }
            }
        }
    }

    // MARK: - Bottom 1/3 Reading Settings Card (非侵入式底部设置卡片)
    private var readingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsHeader
            pageModeRow
            fontSizeRow
            themeRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(
            readerConfig.theme.backgroundColor
                .opacity(0.98)
                .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(readerConfig.theme.textColor.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var settingsHeader: some View {
        HStack {
            Text("阅读设置")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(readerConfig.theme.textColor)

            Spacer()

            Button(action: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showSettings = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(readerConfig.theme.textColor.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    private var pageModeRow: some View {
        HStack(spacing: 12) {
            Text("模式")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.7))
                .frame(width: 36, alignment: .leading)

            Picker("阅读模式", selection: $readerConfig.pageMode) {
                ForEach(PageMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var fontSizeRow: some View {
        HStack(spacing: 12) {
            Text("字号")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.7))
                .frame(width: 36, alignment: .leading)

            Text("A-")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.8))

            Slider(value: $readerConfig.fontSize, in: 12...32, step: 1)
                .accentColor(.accentColor)
                .onChange(of: readerConfig.fontSize) { _ in
                    recomputePagination()
                }

            Text("A+")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.8))

            Text("\(Int(readerConfig.fontSize)) pt")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.7))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var themeRow: some View {
        HStack(spacing: 12) {
            Text("主题")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(readerConfig.theme.textColor.opacity(0.7))
                .frame(width: 36, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(ReaderTheme.allCases) { t in
                    themeButton(for: t)
                }
            }
        }
    }

    private func themeButton(for t: ReaderTheme) -> some View {
        let isSelected = (readerConfig.theme == t)
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                readerConfig.theme = t
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(t.backgroundColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(readerConfig.theme.textColor.opacity(0.25), lineWidth: 1)
                    )
                Text(t.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : readerConfig.theme.textColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : readerConfig.theme.textColor)
    }

    // MARK: - Data Loading Pipeline
    private func loadTOCAndStart() async {
        if book.origin == "local" {
            var localChapters = BookStore.shared.getChapters(for: book.bookUrl)
            if !localChapters.isEmpty {
                for i in 0..<localChapters.count {
                    localChapters[i].index = i
                }
                self.chapters = localChapters
                if currentChapterIndex >= localChapters.count {
                    currentChapterIndex = max(0, localChapters.count - 1)
                }
                loadInitialChapter(at: currentChapterIndex)
                return
            }
        }

        guard let source = effectiveSource else {
            errorMessage = "未找到书籍关联的书源"
            isLoadingInitial = false
            return
        }

        do {
            var fetchedChapters = try await BookContentService.shared.fetchChapterList(book: book, source: source)
            for i in 0..<fetchedChapters.count {
                fetchedChapters[i].index = i
            }
            self.chapters = fetchedChapters
            if currentChapterIndex >= fetchedChapters.count {
                currentChapterIndex = max(0, fetchedChapters.count - 1)
            }
            loadInitialChapter(at: currentChapterIndex)
        } catch {
            self.errorMessage = "目录解析失败: \(error.localizedDescription)"
            self.isLoadingInitial = false
        }
    }

    @MainActor
    private func getOrFetchChapter(at index: Int) async -> LoadedChapter? {
        guard index >= 0 && index < chapters.count else { return nil }
        if let cached = chapterCache[index] {
            return cached
        }
        let targetChapter = chapters[index]
        do {
            let content = try await BookContentService.shared.fetchChapterContent(chapter: targetChapter, source: effectiveSource)
            let blocks = parseContentBlocks(from: content)
            let pages = paginate(blocks: blocks)
            let loaded = LoadedChapter(chapter: targetChapter, content: content, blocks: blocks, pages: pages)
            self.chapterCache[index] = loaded
            return loaded
        } catch {
            return nil
        }
    }

    private func preCacheNeighbors(around index: Int) {
        let source = effectiveSource
        // 1. In-memory pre-cache previous chapter
        if index > 0 && chapterCache[index - 1] == nil {
            let prevCh = chapters[index - 1]
            Task { @MainActor in
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: prevCh, source: source) {
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks)
                    let loaded = LoadedChapter(chapter: prevCh, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index - 1] = loaded
                }
            }
        }
        // 2. In-memory pre-cache next chapter
        if index < chapters.count - 1 && chapterCache[index + 1] == nil {
            let nextCh = chapters[index + 1]
            Task { @MainActor in
                if let content = try? await BookContentService.shared.fetchChapterContent(chapter: nextCh, source: source) {
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks)
                    let loaded = LoadedChapter(chapter: nextCh, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index + 1] = loaded
                }
            }
        }
        // 3. Disk cache pre-download for 10 chapters around
        BookContentService.shared.preDownloadChapters(around: index, chapters: self.chapters, source: source)
    }

    private func loadInitialChapter(at index: Int, targetPageIndex: Int = 0, scrollToTargetEnd: Bool = false) {
        guard !chapters.isEmpty, index < chapters.count else { return }
        let currentChapter = chapters[index]
        if loadedChapters.isEmpty {
            isLoadingInitial = true
        }
        errorMessage = nil

        let source = effectiveSource

        Task { @MainActor in
            do {
                let loaded: LoadedChapter
                if let cached = self.chapterCache[index] {
                    loaded = cached
                } else {
                    let content = try await BookContentService.shared.fetchChapterContent(chapter: currentChapter, source: source)
                    let blocks = parseContentBlocks(from: content)
                    let pages = paginate(blocks: blocks)
                    loaded = LoadedChapter(chapter: currentChapter, content: content, blocks: blocks, pages: pages)
                    self.chapterCache[index] = loaded
                }

                self.currentChapterIndex = index

                // Restore position if durChapterPos is saved and opening the current chapter
                if targetPageIndex == 0 && self.book.durChapterPos > 0 && index == self.book.durChapterIndex {
                    if self.readerConfig.pageMode == .pageByPage {
                        var accumulated = 0
                        var targetPage = 0
                        for (pIdx, page) in loaded.pages.enumerated() {
                            let pageCount = page.reduce(0) { $0 + $1.text.count }
                            if accumulated + pageCount > self.book.durChapterPos {
                                targetPage = pIdx
                                break
                            }
                            accumulated += pageCount
                            targetPage = pIdx
                        }
                        self.currentPageIndex = min(targetPage, max(0, loaded.pages.count - 1))
                    } else {
                        var accumulated = 0
                        var targetBlock = loaded.blocks.first?.id ?? 0
                        for block in loaded.blocks {
                            if accumulated + block.text.count > self.book.durChapterPos {
                                targetBlock = block.id
                                break
                            }
                            accumulated += block.text.count
                            targetBlock = block.id
                        }
                        self.currentReadingBlockId = targetBlock
                        self.scrollToChapterId = "block_\(index)_\(targetBlock)"
                    }
                } else if targetPageIndex == -1 {
                    self.currentPageIndex = max(0, loaded.pages.count - 1)
                } else {
                    self.currentPageIndex = min(targetPageIndex, max(0, loaded.pages.count - 1))
                }

                if self.currentPageIndex < loaded.pages.count {
                    self.currentReadingBlockId = loaded.pages[self.currentPageIndex].first?.id ?? 0
                }

                // If jumping to end in continuous scroll, also attach the next chapter right below it if available!
                if readerConfig.pageMode == .scroll && scrollToTargetEnd && index < self.chapters.count - 1 {
                    let nextIndex = index + 1
                    if let nextCached = self.chapterCache[nextIndex] {
                        self.loadedChapters = [loaded, nextCached]
                    } else {
                        self.loadedChapters = [loaded]
                        Task {
                            if let nextLoaded = await self.getOrFetchChapter(at: nextIndex) {
                                if !self.loadedChapters.contains(where: { $0.chapter.index == nextIndex }) {
                                    self.loadedChapters.append(nextLoaded)
                                }
                            }
                        }
                    }
                } else {
                    self.loadedChapters = [loaded]
                }

                self.isLoadingInitial = false
                let currentPos = self.currentChapterCharOffset()
                BookStore.shared.updateProgress(bookUrl: book.bookUrl, chapterIndex: index, chapterTitle: currentChapter.title, chapterPos: currentPos)
                self.preCacheNeighbors(around: index)

                if readerConfig.pageMode == .scroll && self.scrollToChapterId == nil {
                    self.scrollToChapterId = scrollToTargetEnd ? "chapter_end_\(index)" : "chapter_\(index)"
                }
            } catch {
                self.errorMessage = "正文解析失败: \(error.localizedDescription)"
                self.isLoadingInitial = false
            }
        }
    }

    private func loadNextChapterForInfiniteScroll(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < chapters.count else { return }
        if loadedChapters.contains(where: { $0.chapter.index == nextIndex }) || isLoadingNextChapter {
            return
        }

        if let cached = chapterCache[nextIndex] {
            self.loadedChapters.append(cached)
            self.preCacheNeighbors(around: nextIndex)
            return
        }

        let nextChapter = chapters[nextIndex]
        isLoadingNextChapter = true
        let source = effectiveSource

        Task { @MainActor in
            do {
                let content = try await BookContentService.shared.fetchChapterContent(chapter: nextChapter, source: source)
                let blocks = parseContentBlocks(from: content)
                let pages = paginate(blocks: blocks)
                let loaded = LoadedChapter(chapter: nextChapter, content: content, blocks: blocks, pages: pages)

                self.loadedChapters.append(loaded)
                self.chapterCache[nextIndex] = loaded
                self.isLoadingNextChapter = false
                self.preCacheNeighbors(around: nextIndex)
            } catch {
                print("[ReaderView] ⚠️ Failed to preload chapter \(nextIndex): \(error)")
                self.isLoadingNextChapter = false
            }
        }
    }

    private func recomputePagination() {
        let charPos = currentChapterCharOffset()

        for i in 0..<loadedChapters.count {
            loadedChapters[i].pages = paginate(blocks: loadedChapters[i].blocks)
        }

        if let cur = currentLoadedChapter, !cur.pages.isEmpty {
            var accumulated = 0
            var targetPage = 0
            for (pIdx, page) in cur.pages.enumerated() {
                let pageCharCount = page.reduce(0) { $0 + $1.text.count }
                if accumulated + pageCharCount > charPos {
                    targetPage = pIdx
                    break
                }
                accumulated += pageCharCount
                targetPage = pIdx
            }
            currentPageIndex = min(targetPage, max(0, cur.pages.count - 1))
            updateReadingBlockIdFromCurrentPage()
        }
    }

    // MARK: - Paragraph and Page Parser
    private func parseContentBlocks(from text: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var currentId = 0
        let regex = try? NSRegularExpression(pattern: "\\[image:(.*?)\\]")
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let regex = regex {
                let nsLine = trimmed as NSString
                let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length))
                if !matches.isEmpty {
                    var lastIndex = 0
                    for match in matches {
                        if match.range.location > lastIndex {
                            let textBefore = nsLine.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex)).trimmingCharacters(in: .whitespaces)
                            if !textBefore.isEmpty {
                                let indent = (textBefore.hasPrefix("　") || textBefore.hasPrefix("    ")) ? "" : "　　"
                                blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textBefore, imageUrl: nil))
                                currentId += 1
                            }
                        }
                        if match.numberOfRanges > 1 {
                            let imgUrl = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                            blocks.append(ContentBlock(id: currentId, isImage: true, text: "", imageUrl: imgUrl))
                            currentId += 1
                        }
                        lastIndex = match.range.location + match.range.length
                    }
                    if lastIndex < nsLine.length {
                        let textAfter = nsLine.substring(with: NSRange(location: lastIndex, length: nsLine.length - lastIndex)).trimmingCharacters(in: .whitespaces)
                        if !textAfter.isEmpty {
                            let indent = (textAfter.hasPrefix("　") || textAfter.hasPrefix("    ")) ? "" : "　　"
                            blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + textAfter, imageUrl: nil))
                            currentId += 1
                        }
                    }
                    continue
                }
            }

            let indent = (trimmed.hasPrefix("　") || trimmed.hasPrefix("    ")) ? "" : "　　"
            blocks.append(ContentBlock(id: currentId, isImage: false, text: indent + trimmed, imageUrl: nil))
            currentId += 1
        }
        return blocks
    }

    private func currentChapterCharOffset() -> Int {
        guard let cur = currentLoadedChapter else { return 0 }
        if readerConfig.pageMode == .pageByPage {
            var offset = 0
            let limit = min(currentPageIndex, cur.pages.count)
            for p in 0..<limit {
                for block in cur.pages[p] {
                    offset += block.text.count
                }
            }
            return offset
        } else {
            var offset = 0
            for block in cur.blocks {
                if block.id == currentReadingBlockId {
                    break
                }
                offset += block.text.count
            }
            return offset
        }
    }

    private func saveCurrentProgress() {
        guard let cur = currentLoadedChapter else { return }
        let pos = currentChapterCharOffset()
        BookStore.shared.updateProgress(
            bookUrl: book.bookUrl,
            chapterIndex: currentChapterIndex,
            chapterTitle: cur.chapter.title,
            chapterPos: pos
        )
    }

    private func calculateLayoutMetrics() -> (linesPerPage: Int, firstPageLines: Int) {
        let height = max(400, readerContainerSize.height)

        let lineHeight = readerConfig.fontSize * 1.25 + readerConfig.lineSpacing
        let usableHeight = max(200, height - 48)

        // First page has chapter title (+ title padding)
        let titleLineHeight = (readerConfig.fontSize + 3) * 1.3 + readerConfig.lineSpacing
        let titleHeight = titleLineHeight * 1.5 + 16.0
        let firstPageUsableHeight = max(100, usableHeight - titleHeight)

        let normalLines = max(6, Int(usableHeight / lineHeight))
        let firstPageLines = max(3, Int(firstPageUsableHeight / lineHeight))

        return (linesPerPage: normalLines, firstPageLines: firstPageLines)
    }

    private func splitParagraphIntoLines(text: String, width: Double, fontSize: CGFloat) -> [(text: String, isParagraphEnd: Bool)] {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
        guard let attrString = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary) else {
            return [(text, true)]
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString)
        var start = 0
        let textLen = CFStringGetLength(text as CFString)
        var result: [(text: String, isParagraphEnd: Bool)] = []
        let nsStr = text as NSString

        while start < textLen {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, width)
            if count <= 0 { break }
            let sub = nsStr.substring(with: NSRange(location: start, length: count))
            let isEnd = (start + count >= textLen)
            result.append((sub, isEnd))
            start += count
        }
        return result
    }

    private func buildPageBlocks(from lines: [(text: String, isParagraphEnd: Bool)], startingId: inout Int) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for line in lines {
            blocks.append(ContentBlock(
                id: startingId,
                isImage: false,
                text: line.text,
                imageUrl: line.isParagraphEnd ? "p_end" : nil
            ))
            startingId += 1
        }
        return blocks
    }

    private func paginate(blocks: [ContentBlock]) -> [[ContentBlock]] {
        let metrics = calculateLayoutMetrics()
        let normalLines = metrics.linesPerPage
        let firstPageLines = metrics.firstPageLines
        let usableWidth = Double(max(200, readerContainerSize.width - 48))

        var pages: [[ContentBlock]] = []
        var currentPageLines: [(text: String, isParagraphEnd: Bool)] = []
        var maxLinesForCurrentPage = firstPageLines
        var blockIdCounter = 10000

        for block in blocks {
            if block.isImage {
                if !currentPageLines.isEmpty {
                    pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                    currentPageLines = []
                    maxLinesForCurrentPage = normalLines
                }
                pages.append([block])
                maxLinesForCurrentPage = normalLines
            } else {
                let pLines = splitParagraphIntoLines(text: block.text, width: usableWidth, fontSize: readerConfig.fontSize)
                for lineInfo in pLines {
                    currentPageLines.append(lineInfo)
                    if currentPageLines.count >= maxLinesForCurrentPage {
                        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                        currentPageLines = []
                        maxLinesForCurrentPage = normalLines
                    }
                }
            }
        }

        if !currentPageLines.isEmpty {
            pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
        }

        return pages.isEmpty ? [[]] : pages
    }
}

// MARK: - Chapter Image Component with Anti-Hotlinking Headers & Cache
public struct ChapterImageView: View {
    public let urlString: String
    public let referer: String?

    @State private var imageData: Data? = nil
    @State private var isLoading: Bool = false
    @State private var loadFailed: Bool = false

    private static let imageCache = NSCache<NSString, NSData>()

    public init(urlString: String, referer: String? = nil) {
        self.urlString = urlString
        self.referer = referer
    }

    public var body: some View {
        Group {
            if let data = imageData, let img = platformImage(from: data) {
                img
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(8)
                    .padding(.vertical, 6)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载插图中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                .padding(.vertical, 6)
            } else if loadFailed {
                Button(action: { Task { await loadImage() } }) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                        Text("插图加载失败，点击重试")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: urlString) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Check in-memory cache
        if let cached = Self.imageCache.object(forKey: trimmed as NSString) {
            self.imageData = cached as Data
            self.isLoading = false
            self.loadFailed = false
            return
        }

        // 2. Check local file
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed), let data = try? Data(contentsOf: url) {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                self.imageData = data
                return
            }
        }

        // 3. Remote URL with proper browser headers
        guard let url = URL(string: trimmed) else {
            self.loadFailed = true
            return
        }

        self.isLoading = true
        self.loadFailed = false

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            request.setValue("image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            // Determine Referer
            if let ref = referer, !ref.isEmpty {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            } else if let host = url.host {
                request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 304), !data.isEmpty {
                Self.imageCache.setObject(data as NSData, forKey: trimmed as NSString)
                await MainActor.run {
                    self.imageData = data
                    self.isLoading = false
                    self.loadFailed = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                    self.loadFailed = true
                }
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) {
            return Image(nsImage: ns)
        }
        #endif
        return nil
    }
}

// MARK: - Reader Search Sheet
public struct ReaderSearchSheet: View {
    let book: Book
    let currentChapterIndex: Int
    let currentChapterTitle: String
    let currentContent: String
    let chapters: [BookChapter]
    let onSelectChapter: (Int, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var searchScope: Int = 0 // 0: 本章内容, 1: 目录章节

    public struct SearchItem: Identifiable {
        public let id = UUID()
        public let chapterIndex: Int
        public let title: String
        public let snippet: String
    }

    private var currentChapterMatches: [SearchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var results: [SearchItem] = []
        let lines = currentContent.components(separatedBy: "\n")
        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.localizedCaseInsensitiveContains(query) {
                results.append(SearchItem(
                    chapterIndex: currentChapterIndex,
                    title: "\(currentChapterTitle) (第 \(lineIdx + 1) 段)",
                    snippet: trimmed
                ))
            }
        }
        return results
    }

    private var tocMatches: [SearchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return chapters.compactMap { ch in
            if ch.title.localizedCaseInsensitiveContains(query) {
                return SearchItem(
                    chapterIndex: ch.index,
                    title: "第 \(ch.index + 1) 章",
                    snippet: ch.title
                )
            }
            return nil
        }
    }

    private var activeResults: [SearchItem] {
        searchScope == 0 ? currentChapterMatches : tocMatches
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("搜索范围", selection: $searchScope) {
                    Text("当前章节正文").tag(0)
                    Text("目录章节搜索").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if searchText.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(searchScope == 0 ? "输入关键词搜索当前章节正文" : "输入关键词搜索目录章节")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if activeResults.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("未找到包含 “\(searchText)” 的内容")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List(activeResults) { item in
                        Button(action: {
                            onSelectChapter(item.chapterIndex, item.snippet)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(item.snippet)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("查找")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: searchScope == 0 ? "搜索当前章节内容..." : "搜索章节名称...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - CoreText Two-End Justified Page View (两端对齐与定高排版组件)
#if os(macOS)
import AppKit

public struct CoreTextPageView: NSViewRepresentable {
    public let lines: [String]
    public let isParagraphEnd: [Bool]
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let textColor: Color
    public let width: CGFloat
    public let height: CGFloat

    public func makeNSView(context: Context) -> CoreTextNSView {
        let view = CoreTextNSView()
        updateNSView(view, context: context)
        return view
    }

    public func updateNSView(_ nsView: CoreTextNSView, context: Context) {
        nsView.lines = lines
        nsView.isParagraphEnd = isParagraphEnd
        nsView.fontSize = fontSize
        nsView.lineSpacing = lineSpacing
        nsView.textColor = NSColor(textColor)
        nsView.containerWidth = width
        nsView.containerHeight = height
        nsView.needsDisplay = true
    }
}

public class CoreTextNSView: NSView {
    public var lines: [String] = []
    public var isParagraphEnd: [Bool] = []
    public var fontSize: CGFloat = 18
    public var lineSpacing: CGFloat = 6
    public var textColor: NSColor = .textColor
    public var containerWidth: CGFloat = 340
    public var containerHeight: CGFloat = 600

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !lines.isEmpty else { return }

        let ctFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
        let effectiveLineHeight = fontSize * 1.25 + lineSpacing
        let targetWidth = Double(max(100, containerWidth))

        for (index, lineText) in lines.enumerated() {
            guard !lineText.isEmpty else { continue }
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: ctFont,
                kCTForegroundColorAttributeName: textColor.cgColor
            ]
            guard let attrStr = CFAttributedStringCreate(nil, lineText as CFString, attrs as CFDictionary) else { continue }
            let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: lineText.count))

            let isEnd = (index < isParagraphEnd.count) ? isParagraphEnd[index] : false
            let finalLine: CTLine
            if !isEnd && lineText.count > 5 {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, targetWidth) ?? ctLine
            } else {
                finalLine = ctLine
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(finalLine, &ascent, &descent, &leading)

            let baselineY = CGFloat(index) * effectiveLineHeight + ascent

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: baselineY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(finalLine, ctx)
            ctx.restoreGState()
        }
    }
}
#endif

#if os(iOS)
import UIKit

public struct CoreTextPageView: UIViewRepresentable {
    public let lines: [String]
    public let isParagraphEnd: [Bool]
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let textColor: Color
    public let width: CGFloat
    public let height: CGFloat

    public func makeUIView(context: Context) -> CoreTextUIView {
        let view = CoreTextUIView()
        updateUIView(view, context: context)
        return view
    }

    public func updateUIView(_ uiView: CoreTextUIView, context: Context) {
        uiView.lines = lines
        uiView.isParagraphEnd = isParagraphEnd
        uiView.fontSize = fontSize
        uiView.lineSpacing = lineSpacing
        uiView.textColor = UIColor(textColor)
        uiView.containerWidth = width
        uiView.containerHeight = height
        uiView.backgroundColor = .clear
        uiView.setNeedsDisplay()
    }
}

public class CoreTextUIView: UIView {
    public var lines: [String] = []
    public var isParagraphEnd: [Bool] = []
    public var fontSize: CGFloat = 18
    public var lineSpacing: CGFloat = 6
    public var textColor: UIColor = .label
    public var containerWidth: CGFloat = 340
    public var containerHeight: CGFloat = 600

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }

        let ctFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
        let effectiveLineHeight = fontSize * 1.25 + lineSpacing
        let targetWidth = Double(max(100, containerWidth))

        for (index, lineText) in lines.enumerated() {
            guard !lineText.isEmpty else { continue }
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: ctFont,
                kCTForegroundColorAttributeName: textColor.cgColor
            ]
            guard let attrStr = CFAttributedStringCreate(nil, lineText as CFString, attrs as CFDictionary) else { continue }
            let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: lineText.count))

            let isEnd = (index < isParagraphEnd.count) ? isParagraphEnd[index] : false
            let finalLine: CTLine
            if !isEnd && lineText.count > 5 {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, targetWidth) ?? ctLine
            } else {
                finalLine = ctLine
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(finalLine, &ascent, &descent, &leading)

            let baselineY = CGFloat(index) * effectiveLineHeight + ascent

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: baselineY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(finalLine, ctx)
            ctx.restoreGState()
        }
    }
}
#endif

