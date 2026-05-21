import AVFoundation
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SnoreMonitor.self) private var monitor
    @State private var dragOffset: CGFloat = 0
    @State private var showsAnalysis = false
    @State private var showsResultScreen = false

    var body: some View {
        ZStack {
            backgroundView
                .zIndex(0)

            GeometryReader { proxy in
                if monitor.isMonitoring {
                    sleepingColor
                        .ignoresSafeArea()
                } else if monitor.latestResult == nil && dragOffset > 0 {
                    SleepWave(progress: dragProgress(height: proxy.size.height))
                        .fill(sleepingColor)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .zIndex(1)

            Text(instructionText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textColor.opacity(0.82))
                .tracking(0)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .allowsHitTesting(false)
                .zIndex(2)

            if isResultScreenActive, !monitor.isMonitoring {
                VStack {
                    Button {
                        showsAnalysis = false
                        showsResultScreen = false
                        Task {
                            await monitor.startNight()
                        }
                    } label: {
                        Text("寝る")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(textColor.opacity(0.88))
                            .frame(width: 120, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)

                    Spacer()

                    Button {
                        openAnalysis()
                    } label: {
                        Text("分析")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(textColor.opacity(0.84))
                            .frame(width: 120, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)
                }
                .zIndex(10)
            } else if monitor.isMonitoring {
                VStack {
                    Spacer()
                    Button {
                        monitor.cancelNight()
                    } label: {
                        Text("戻る")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 120, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 18)
                }
                .zIndex(10)
            } else if !monitor.isMonitoring {
                VStack {
                    Spacer()
                    Button {
                        showsResultScreen = true
                    } label: {
                        Text("結果")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0)
                            .foregroundStyle(textColor.opacity(0.84))
                            .frame(width: 120, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 18)
                }
                .zIndex(10)
            }
        }
        .contentShape(Rectangle())
        .gesture(sleepGesture, including: isSleepGestureEnabled ? .all : .none)
        .animation(.spring(response: 0.52, dampingFraction: 0.86), value: monitor.isMonitoring)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: dragOffset)
        .sheet(isPresented: $showsAnalysis) {
            if let result = analysisResult {
                AnalysisView(result: result, history: monitor.resultHistory)
            } else {
                EmptyAnalysisView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                monitor.wakeUpIfReady()
            }
        }
    }

    private var instructionText: String {
        if monitor.isMonitoring {
            return "充電に繋いでロック"
        }

        if isResultScreenActive {
            return ""
        }

        return "下にスワイプで寝る"
    }

    @ViewBuilder
    private var backgroundView: some View {
        if monitor.permissionDenied || monitor.errorMessage != nil {
            Color.red.ignoresSafeArea()
        } else if isResultScreenActive {
            HistoryGradientView(results: displayHistory)
                .ignoresSafeArea()
        } else {
            baseColor.ignoresSafeArea()
        }
    }

    private var displayHistory: [SnoreResult] {
        var history = monitor.resultHistory
        if let latest = monitor.latestResult,
           !history.contains(where: { Calendar.current.isDate($0.checkedAt, inSameDayAs: latest.checkedAt) }) {
            history.append(latest)
        } else if let resultScreenResult,
                  !history.contains(where: { Calendar.current.isDate($0.checkedAt, inSameDayAs: resultScreenResult.checkedAt) }) {
            history.append(resultScreenResult)
        }
        return history.sorted { $0.checkedAt < $1.checkedAt }
    }

    private var analysisResult: SnoreResult? {
        monitor.latestResult ?? resultScreenResult ?? monitor.resultHistory.sorted { $0.checkedAt < $1.checkedAt }.last
    }

    private var resultScreenResult: SnoreResult? {
        monitor.latestResult ?? (showsResultScreen ? monitor.resultHistory.sorted { $0.checkedAt < $1.checkedAt }.last : nil)
    }

    private var isResultScreenActive: Bool {
        resultScreenResult != nil
    }

    private var textColor: Color {
        if monitor.isMonitoring {
            return .white
        }

        guard let result = resultScreenResult else {
            return .black
        }

        switch result.verdict {
        case .snoring, .safe:
            return .white
        case .borderline:
            return .black
        }
    }

    private var baseColor: Color {
        if monitor.permissionDenied || monitor.errorMessage != nil {
            return .red
        }

        guard let result = resultScreenResult else {
            return pureBlue
        }

        switch result.verdict {
        case .snoring:
            return .red
        case .borderline:
            return .yellow
        case .safe:
            return pureBlue
        }
    }

    private var pureBlue: Color {
        Color(red: 0, green: 0.419, blue: 1)
    }

    private var sleepingColor: Color {
        Color(red: 0.01, green: 0.03, blue: 0.18)
    }

    private var sleepGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !monitor.isMonitoring, !isResultScreenActive else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !monitor.isMonitoring, !isResultScreenActive else {
                    dragOffset = 0
                    return
                }

                if value.translation.height > 110 {
                    Task {
                        await monitor.startNight()
                    }
                }

                withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) {
                    dragOffset = 0
                }
            }
    }

    private var isSleepGestureEnabled: Bool {
        !monitor.isMonitoring && !isResultScreenActive
    }

    private func dragProgress(height: CGFloat) -> CGFloat {
        if monitor.isMonitoring {
            return 1
        }

        return min(max(dragOffset / max(height * 0.92, 1), 0), 1)
    }

    private func openAnalysis() {
        showsAnalysis = true
    }
}

private struct AnalysisView: View {
    let result: SnoreResult
    let history: [SnoreResult]
    @State private var selectedDate: Date

    init(result: SnoreResult, history: [SnoreResult]) {
        self.result = result
        self.history = history
        _selectedDate = State(initialValue: result.checkedAt)
    }

    var body: some View {
        TabView(selection: $selectedDate) {
            ForEach(displayHistory, id: \.checkedAt) { entry in
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 6) {
                            Text("分析")
                                .font(.system(size: 22, weight: .semibold))
                            Text(dayLabel(entry.checkedAt))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 26)

                        NightInsightSummary(result: entry)
                            .padding(.horizontal, 30)

                        NightTimelineGraph(result: entry)
                            .padding(.horizontal, 28)

                        VStack(alignment: .leading, spacing: 13) {
                            Text("詳細")
                                .font(.system(size: 13, weight: .semibold))
                            AnalysisLine(title: "記録時間", value: analysisDurationText(entry.recordedSeconds))
                            AnalysisLine(title: "推定回数", value: countText(entry.snoreEventCount))
                            AnalysisLine(title: "最長連続", value: analysisDurationText(entry.longestSnoreRunSeconds))
                            AnalysisLine(title: "平均信頼度", value: analysisProbabilityText(entry.averageSnoreProbability))
                            AnalysisLine(title: "最大信頼度", value: analysisProbabilityText(entry.maximumSnoreProbability))
                            AnalysisLine(title: "ピーク音量", value: analysisDecibelText(entry.peakDecibels))
                            AnalysisLine(title: "保存データ", value: segmentText(entry.savedTrainingSegmentCount))
                            AnalysisLine(title: "判定方式", value: entry.usedMachineLearning == true ? "ML" : "音量")
                        }
                        .padding(.horizontal, 34)

                        HistoryTable(history: displayHistory)
                            .padding(.horizontal, 28)

                        AudioClipList(result: entry)
                            .padding(.horizontal, 28)

                        Text("医療診断ではなく、端末マイク音声からの推定です。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 34)
                            .padding(.bottom, 44)
                    }
                }
                .tag(entry.checkedAt)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .presentationDetents([.large])
    }

    private var displayHistory: [SnoreResult] {
        var values = history
        if !values.contains(where: { Calendar.current.isDate($0.checkedAt, inSameDayAs: result.checkedAt) }) {
            values.append(result)
        }
        return values.sorted { $0.checkedAt < $1.checkedAt }
    }

    private func countText(_ count: Int?) -> String {
        guard let count else { return "-" }
        return "\(count)回"
    }

    private func segmentText(_ count: Int?) -> String {
        guard let count else { return "-" }
        return "\(count)個"
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今日"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

private struct HistoryGradientView: View {
    let results: [SnoreResult]
    @State private var zoomScale: CGFloat = 1
    @State private var committedZoomScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let height = contentHeight(for: proxy.size.height)
            let edgeHeight = edgeHeight(for: proxy.size.height)
            let fullHeight = height + edgeHeight * 2

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            topColor
                                .frame(height: edgeHeight)
                            LinearGradient(
                                stops: stops,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: height)
                            bottomColor
                                .frame(height: edgeHeight)
                        }

                        ForEach(timelineMarkers(height: height), id: \.id) { marker in
                            Text(marker.label)
                                .font(.system(size: labelFontSize, weight: .semibold))
                                .tracking(0)
                                .foregroundStyle(labelColor(for: marker.result).opacity(labelOpacity))
                                .position(x: 24, y: edgeHeight + marker.y)
                        }

                        Color.clear
                            .frame(width: 1, height: 1)
                            .position(x: 1, y: edgeHeight + height - 1)
                            .id(todayAnchorID)
                    }
                    .frame(width: proxy.size.width, height: fullHeight)
                }
                .background(
                    LinearGradient(
                        colors: [topColor, bottomColor],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    scrollToToday(scrollProxy)
                }
                .simultaneousGesture(zoomGesture)
            }
        }
    }

    private var topColor: Color {
        snoreColor(sortedResults.first?.verdict ?? .safe)
    }

    private var bottomColor: Color {
        snoreColor(sortedResults.last?.verdict ?? .safe)
    }

    private var stops: [Gradient.Stop] {
        let values = sortedResults
        guard values.count > 1 else {
            return [.init(color: snoreColor(values.last?.verdict ?? .safe), location: 0)]
        }

        return values.enumerated().map { index, result in
            Gradient.Stop(
                color: snoreColor(result.verdict),
                location: Double(index) / Double(values.count - 1)
            )
        }
    }

    private var sortedResults: [SnoreResult] {
        results.sorted { $0.checkedAt < $1.checkedAt }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = clampedZoom(committedZoomScale * value)
            }
            .onEnded { value in
                zoomScale = clampedZoom(committedZoomScale * value)
                committedZoomScale = zoomScale
            }
    }

    private var labelFontSize: CGFloat {
        zoomScale >= 2.3 ? 10 : 9
    }

    private var labelOpacity: Double {
        zoomScale >= 1.5 ? 0.52 : 0.42
    }

    private var todayAnchorID: String {
        "history-today-anchor"
    }

    private func contentHeight(for viewportHeight: CGFloat) -> CGFloat {
        let dayCount = max(sortedResults.count - 1, 1)
        let dayHeight = CGFloat(dayCount) * (115 + zoomScale * 55)
        return max(viewportHeight, dayHeight + 56)
    }

    private func edgeHeight(for viewportHeight: CGFloat) -> CGFloat {
        max(viewportHeight * 0.9, 360)
    }

    private func timelineMarkers(height: CGFloat) -> [HistoryMarker] {
        let values = sortedResults
        guard !values.isEmpty else { return [] }

        var markers: [HistoryMarker] = []

        for (index, result) in values.enumerated() where shouldShowMarker(for: result, index: index, total: values.count) {
            markers.append(marker(for: result, index: index, total: values.count, height: height))
        }

        if zoomScale < 1.8 {
            let middleIndex = max(0, min(values.count - 1, values.count / 2))
            markers.append(marker(for: values[middleIndex], index: middleIndex, total: values.count, height: height))
        }

        if let todayIndex = values.lastIndex(where: { Calendar.current.isDateInToday($0.checkedAt) }) {
            markers.append(marker(for: values[todayIndex], index: todayIndex, total: values.count, height: height))
        }

        var seen: Set<String> = []
        return markers.filter { marker in
            let key = marker.label
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func marker(for result: SnoreResult, index: Int, total: Int, height: CGFloat) -> HistoryMarker {
        HistoryMarker(
            id: "\(index)-\(Int(result.checkedAt.timeIntervalSince1970))",
            label: Calendar.current.isDateInToday(result.checkedAt) ? "今日" : shortDate(result.checkedAt),
            result: result,
            index: index,
            total: total,
            y: markerY(index: index, total: total, height: height)
        )
    }

    private func markerY(index: Int, total: Int, height: CGFloat) -> CGFloat {
        guard total > 1 else { return height - 32 }
        let usableHeight = max(height - 64, 1)
        return 32 + CGFloat(index) / CGFloat(total - 1) * usableHeight
    }

    private func shouldShowMarker(for result: SnoreResult, index: Int, total: Int) -> Bool {
        if index == 0 || index == total - 1 || Calendar.current.isDateInToday(result.checkedAt) {
            return true
        }

        if zoomScale >= 2.3 {
            return true
        }

        if zoomScale >= 1.45 {
            return isWeekStart(result.checkedAt) || index.isMultiple(of: 2)
        }

        return isWeekStart(result.checkedAt)
    }

    private func isWeekStart(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == Calendar.current.firstWeekday
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func labelColor(for result: SnoreResult) -> Color {
        switch result.verdict {
        case .borderline:
            return .black
        case .snoring, .safe:
            return .white
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.65), 3.4)
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(todayAnchorID, anchor: .bottom)
        }
    }
}

private struct HistoryMarker {
    let id: String
    let label: String
    let result: SnoreResult
    let index: Int
    let total: Int
    let y: CGFloat
}

private struct EmptyAnalysisView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("分析")
                .font(.system(size: 22, weight: .semibold))
            Text("まだ記録がありません。次の睡眠記録から表示されます。")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
        }
        .presentationDetents([.medium])
    }
}

private struct NightInsightSummary: View {
    let result: SnoreResult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verdictTitle)
                        .font(.system(size: 24, weight: .semibold))
                    Text("睡眠中の \(analysisPercentText(result.snoreRatio)) をいびきとして検出")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Text(analysisPercentText(result.snoreRatio))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
            }

            HStack(alignment: .top, spacing: 14) {
                AnalysisMetric(title: "いびき推定", value: analysisDurationText(result.estimatedSnoreSeconds))
                AnalysisMetric(title: "多い時間", value: peakTimeText)
                AnalysisMetric(title: "検出範囲", value: detectionRangeText(result))
            }
        }
    }

    private var verdictTitle: String {
        switch result.verdict {
        case .snoring:
            return "いびき多め"
        case .borderline:
            return "少しあり"
        case .safe:
            return "少なめ"
        }
    }

    private var peakTimeText: String {
        guard let peak = result.timeline?.max(by: { $0.snoreRatio < $1.snoreRatio }),
              peak.snoreRatio > 0 else {
            return "-"
        }
        return clockText(for: result, secondsFromStart: Double(peak.minuteIndex) * 60)
    }
}

private struct AnalysisMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NightTimelineGraph: View {
    let result: SnoreResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("時間推移")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("縦軸 いびき")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if values.isEmpty {
                Text("この記録には時系列データがありません。次回の記録から表示されます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 148, alignment: .center)
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { _ in
                                Divider()
                                Spacer(minLength: 0)
                            }
                            Divider()
                        }
                        .opacity(0.24)

                        TimelineBars(values: values)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(height: 148)

                HStack {
                    Text(startLabel)
                    Spacer()
                    Text(midLabel)
                    Spacer()
                    Text(endLabel)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var values: [SnoreTimelinePoint] {
        result.timeline ?? []
    }

    private var startLabel: String {
        clockText(nightStartDate(for: result))
    }

    private var midLabel: String {
        let midpoint = (result.recordedSeconds ?? 0) / 2
        return clockText(for: result, secondsFromStart: midpoint)
    }

    private var endLabel: String {
        clockText(result.checkedAt)
    }
}

private struct TimelineBars: View {
    let values: [SnoreTimelinePoint]

    var body: some View {
        GeometryReader { proxy in
            let maxMinute = max(values.last?.minuteIndex ?? 0, 1)
            let width = proxy.size.width
            let height = proxy.size.height
            let barWidth = max(width / CGFloat(maxMinute + 1), 1)

            ForEach(values, id: \.minuteIndex) { point in
                let x = CGFloat(point.minuteIndex) / CGFloat(maxMinute) * max(width - barWidth, 0)
                let ratio = CGFloat(min(max(point.snoreRatio, 0), 1))
                let barHeight = max(2, ratio * height)

                RoundedRectangle(cornerRadius: min(barWidth * 0.35, 3), style: .continuous)
                    .fill(barColor(point))
                    .frame(width: barWidth, height: barHeight)
                    .position(x: x + barWidth / 2, y: height - barHeight / 2)
            }
        }
    }

    private func barColor(_ point: SnoreTimelinePoint) -> Color {
        if point.snoreRatio >= 0.45 {
            return .red
        }
        if point.snoreRatio >= 0.15 || point.averageProbability >= 0.75 {
            return .yellow
        }
        return Color(red: 0, green: 0.419, blue: 1)
    }
}

private struct HistoryTable: View {
    let history: [SnoreResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日別")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 9) {
                ForEach(Array(history.suffix(7).reversed()), id: \.checkedAt) { result in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(snoreColor(result.verdict))
                            .frame(width: 10, height: 10)
                        Text(dayLabel(result.checkedAt))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int((result.snoreRatio * 100).rounded()))%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                        Text(verdictText(result.verdict))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今日"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func verdictText(_ verdict: SnoreVerdict) -> String {
        switch verdict {
        case .snoring:
            return "赤"
        case .borderline:
            return "黄"
        case .safe:
            return "青"
        }
    }
}

private struct AudioClipList: View {
    let result: SnoreResult
    @State private var clips: [RecordedAudioClip] = []
    @State private var player = AudioClipPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("音声")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !clips.isEmpty {
                    Text("\(clips.count)件")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if clips.isEmpty {
                Text("保存された音声はまだありません。次回の記録から怪しい1秒だけ表示されます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(clips.prefix(12)) { clip in
                        Button {
                            player.play(url: clip.url)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: player.currentURL == clip.url && player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(clip.timeText)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("確率 \(clip.probabilityText) / \(clip.decibelText)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(clip.isSnore ? "検出" : "候補")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(clip.isSnore ? .red : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if clips.count > 12 {
                    Text("上位12件を表示")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: result.checkedAt) {
            clips = RecordedAudioClip.load(for: result)
        }
    }
}

private struct RecordedAudioClip: Identifiable {
    let id: String
    let url: URL
    let secondsFromStart: Double
    let probability: Double
    let isSnore: Bool
    let db: Double
    let result: SnoreResult

    var timeText: String {
        clockText(for: result, secondsFromStart: secondsFromStart)
    }

    var probabilityText: String {
        "\(Int((probability * 100).rounded()))%"
    }

    var decibelText: String {
        "\(Int(db.rounded())) dB"
    }

    static func load(for result: SnoreResult) -> [RecordedAudioClip] {
        guard let sessionDirectory = sessionDirectory(for: result),
              let rows = try? String(contentsOf: sessionDirectory.appendingPathComponent("manifest.csv"), encoding: .utf8) else {
            return []
        }

        return rows
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> RecordedAudioClip? in
                let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard columns.count >= 9,
                      !columns[8].isEmpty,
                      let seconds = Double(columns[2]),
                      let probability = Double(columns[3]),
                      let isSnoreInt = Int(columns[4]),
                      let db = Double(columns[5]) else {
                    return nil
                }

                let url = sessionDirectory.appendingPathComponent(columns[8])
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return nil
                }

                return RecordedAudioClip(
                    id: columns[1],
                    url: url,
                    secondsFromStart: seconds,
                    probability: probability,
                    isSnore: isSnoreInt == 1,
                    db: db,
                    result: result
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSnore != rhs.isSnore {
                    return lhs.isSnore && !rhs.isSnore
                }
                if lhs.db != rhs.db {
                    return lhs.db > rhs.db
                }
                return lhs.probability > rhs.probability
            }
    }

    private static func sessionDirectory(for result: SnoreResult) -> URL? {
        guard let root = trainingRootDirectory(),
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        let resultDay = formatter.string(from: result.checkedAt)

        return directories
            .filter { $0.lastPathComponent.hasPrefix(resultDay) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private static func trainingRootDirectory() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return documents.appendingPathComponent("zzzly-training", isDirectory: true)
    }
}

@Observable
private final class AudioClipPlayer {
    private var player: AVAudioPlayer?
    var currentURL: URL?
    var isPlaying = false

    func play(url: URL) {
        if currentURL == url, isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            currentURL = url
            isPlaying = true
        } catch {
            currentURL = nil
            isPlaying = false
        }
    }
}

private func analysisDurationText(_ seconds: Double?) -> String {
    let minutes = max(0, Int(((seconds ?? 0) / 60).rounded()))
    if minutes >= 60 {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)時間" : "\(hours)時間\(remainingMinutes)分"
    }
    return "\(minutes)分"
}

private func analysisPercentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
}

private func analysisDecibelText(_ decibels: Float) -> String {
    "\(Int(decibels.rounded())) dB"
}

private func analysisProbabilityText(_ probability: Double?) -> String {
    guard let probability else { return "-" }
    return "\(Int((probability * 100).rounded()))%"
}

private func detectionRangeText(_ result: SnoreResult) -> String {
    guard let start = result.firstSnoreSecondsFromStart,
          let end = result.lastSnoreSecondsFromStart else {
        return "-"
    }
    return "\(clockText(for: result, secondsFromStart: start))〜\(clockText(for: result, secondsFromStart: end))"
}

private func nightStartDate(for result: SnoreResult) -> Date {
    result.checkedAt.addingTimeInterval(-(result.recordedSeconds ?? 0))
}

private func clockText(for result: SnoreResult, secondsFromStart: Double) -> String {
    clockText(nightStartDate(for: result).addingTimeInterval(secondsFromStart))
}

private func clockText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "H:mm"
    return formatter.string(from: date)
}

private struct AnalysisLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.system(size: 14))
    }
}

private func snoreColor(_ verdict: SnoreVerdict) -> Color {
    switch verdict {
    case .snoring:
        return .red
    case .borderline:
        return .yellow
    case .safe:
        return Color(red: 0, green: 0.419, blue: 1)
    }
}

private struct SleepWave: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        let amplitude = 6 + clamped * 22
        let depth = rect.height * (0.02 + clamped * 0.98) + amplitude * clamped + 8 * clamped
        let wavelength = max(rect.width * 0.95, 1)
        let phaseOffset = clamped * .pi * 1.15

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: depth))

        let step = max(rect.width / 36, 1)
        var x = rect.maxX
        while x > rect.minX {
            let normalized = x / wavelength
            let y = depth + sin(normalized * .pi * 2 + phaseOffset) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x -= step
        }

        let leftY = depth + sin(phaseOffset) * amplitude
        path.addLine(to: CGPoint(x: rect.minX, y: leftY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ContentView()
        .environment(SnoreMonitor())
}
