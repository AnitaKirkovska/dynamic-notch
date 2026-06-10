import AppKit
import SwiftUI
import Combine
import AVFoundation
import Speech
import ApplicationServices

// MARK: - Theme
enum Theme {
    static let accent = Color(red: 0.66, green: 0.55, blue: 0.98)
    static let accent2 = Color(red: 0.55, green: 0.42, blue: 0.95)
    static let bubbleAssistant = Color(red: 0.17, green: 0.17, blue: 0.21)
    static let textDim = Color.white.opacity(0.55)
}

struct Notch {
    static var width: CGFloat = 200
    static var height: CGFloat = 32
}

// MARK: - Real MacBook notch shape (concave top fillets -> narrower body -> rounded bottom)
struct NotchShape: Shape {
    var radius: CGFloat
    var topRadius: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, r.height / 2)
        let br = min(radius, (r.height - tr))
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tr),
                       control: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tr, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr + br, y: r.maxY),
                       control: CGPoint(x: r.minX + tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY - br),
                       control: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - tr, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchOutline: Shape {
    var radius: CGFloat
    var topRadius: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, r.height / 2)
        let br = min(radius, r.height - tr)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tr),
                       control: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tr, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr + br, y: r.maxY),
                       control: CGPoint(x: r.minX + tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY - br),
                       control: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - tr, y: r.minY))
        return p
    }
}

// MARK: - Brushed-metal shimmer text
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 15
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: 2.2)) / 2.2) // 0..1
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(white: 0.45), location: 0),
                            .init(color: Color(white: 0.55), location: max(0, phase - 0.18)),
                            .init(color: Color(white: 0.98), location: phase),
                            .init(color: Color(white: 0.55), location: min(1, phase + 0.18)),
                            .init(color: Color(white: 0.45), location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing)
                )
                .shadow(color: .white.opacity(0.10), radius: 0.5, y: 0.5)
        }
    }
}

// MARK: - Model
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, ava }
    let id = UUID()
    let role: Role
    var text: String
    var pending: Bool = false
}

enum Phase { case idle, listening, thinking, speaking }

// Reads the relay's NDJSON stream and surfaces frames as they arrive.
final class StreamTask: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var session: URLSession!
    private var task: URLSessionDataTask!
    var onFrame: (([String: Any]) -> Void)?
    var onClosed: (() -> Void)?

    init(url: URL, body: [String: Any]) {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180
        task = session.dataTask(with: req)
        task.resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                DispatchQueue.main.async { self.onFrame?(obj) }
            }
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { self.onClosed?() }
        session.finishTasksAndInvalidate()
    }

    func cancel() { task.cancel() }
}

final class ChatVM: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var loading: Bool = false
    private let base = "http://127.0.0.1:8473"
    private var stream: StreamTask?

    // task bulb hooks (set by the app delegate)
    var onTaskBegin: (() -> Void)?
    var onTaskDone: (() -> Void)?
    var onTaskCancel: (() -> Void)?

    func askStream(_ text: String, voice: Bool,
                   onDelta: ((String) -> Void)? = nil,
                   onAudio: ((Data) -> Void)? = nil,
                   onDone: ((String) -> Void)? = nil) {
        guard let url = URL(string: base + "/chat-stream") else { return }
        // silently drop any in-flight stream (no error callback)
        stream?.onFrame = nil
        stream?.onClosed = nil
        stream?.cancel()
        var finished = false
        let s = StreamTask(url: url, body: ["message": text, "voice": voice])
        s.onFrame = { obj in
            switch obj["type"] as? String {
            case "delta":
                if let t = obj["text"] as? String { onDelta?(t) }
            case "audio":
                if let b = obj["b64"] as? String, let d = Data(base64Encoded: b) { onAudio?(d) }
            case "working":
                // assistant started real work (tool use): pin the task bulb
                self.onTaskBegin?()
            case "done":
                finished = true
                self.onTaskDone?()
                onDone?(obj["reply"] as? String ?? "")
            case "error":
                finished = true
                self.onTaskCancel?()
                onDone?(obj["error"] as? String ?? "something went wrong, try again")
            default: break
            }
        }
        s.onClosed = { [weak self] in
            if !finished {
                self?.onTaskCancel?()
                onDone?("couldn't reach the relay 😕")
            }
        }
        stream = s
    }

    func cancelStream() {
        stream?.onFrame = nil
        stream?.onClosed = nil
        stream?.cancel()
        stream = nil
        loading = false
        onTaskCancel?()
        // keep any partial text we already streamed in; drop empty bubbles
        if let i = messages.lastIndex(where: { $0.pending }) {
            if messages[i].text.isEmpty { messages.remove(at: i) }
            else { messages[i].pending = false }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loading else { return }
        messages.append(ChatMessage(role: .user, text: text))
        input = ""
        loading = true
        messages.append(ChatMessage(role: .ava, text: "", pending: true))
        var acc = ""
        askStream(text, voice: false, onDelta: { [weak self] t in
            guard let self = self else { return }
            acc += t
            if let i = self.messages.lastIndex(where: { $0.pending }) {
                self.messages[i].text = acc
            }
        }, onDone: { [weak self] reply in
            guard let self = self else { return }
            self.loading = false
            self.messages.removeAll { $0.pending }
            self.messages.append(ChatMessage(role: .ava, text: reply.isEmpty ? acc : reply))
        })
    }
}

// MARK: - Voice: speech-to-text (Apple Speech) + TTS playback (relay /tts)
final class VoiceManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var phase: Phase = .idle
    @Published var transcript: String = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var player: AVAudioPlayer?
    private let base = "http://127.0.0.1:8473"

    var onPhaseChange: ((Phase) -> Void)?
    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p; self.onPhaseChange?(p) }
    }

    // speak a fixed line aloud (used for the greeting), no brain needed
    private var greeted = false
    func greet() {
        guard !greeted else { return }
        greeted = true
        speakLine("hey, what are we working on today?")
    }
    func speakLine(_ text: String) {
        guard let url = URL(string: base + "/tts") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = obj["audio"] as? String, let audio = Data(base64Encoded: b64) else { return }
            DispatchQueue.main.async {
                do {
                    self.player = try AVAudioPlayer(data: audio)
                    self.player?.prepareToPlay()
                    if let p = self.player { p.play(atTime: p.deviceCurrentTime + 0.3) }
                } catch {}
            }
        }.resume()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // synchronous truth for listening state; phase updates are async and can race
    private var isListening = false
    // set by the app delegate: cancels any in-flight brain stream (barge-in)
    var onBargeIn: (() -> Void)?

    // hard-stop all output: player, queue, pending stream audio
    func interruptPlayback() {
        player?.stop()
        player = nil
        audioQueue.removeAll()
        playing = false
        streamDone = true
        onBargeIn?()
    }

    func startListening() {
        guard !isListening else { return }
        isListening = true
        // barge-in: starting to talk interrupts speaking/thinking
        interruptPlayback()
        transcript = ""
        setPhase(.listening)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            setPhase(.idle); return
        }
        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            if let r = result { self?.transcript = r.bestTranscription.formattedString }
        }
    }

    // streaming audio queue: sentences play in order as they arrive
    private var audioQueue: [Data] = []
    private var playing = false
    private var streamDone = false

    private func enqueueAudio(_ data: Data) {
        audioQueue.append(data)
        playNextIfIdle()
    }

    private func playNextIfIdle() {
        guard !playing, !audioQueue.isEmpty else { return }
        playing = true
        setPhase(.speaking)
        let data = audioQueue.removeFirst()
        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
        } catch {
            playing = false
            playNextIfIdle()
        }
    }

    func stopAndSend(_ vm: ChatVM) {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()

        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { setPhase(.idle); return }

        setPhase(.thinking)
        vm.messages.append(ChatMessage(role: .user, text: said))
        vm.messages.append(ChatMessage(role: .ava, text: "", pending: true))
        audioQueue.removeAll()
        streamDone = false
        var acc = ""
        vm.askStream(said, voice: true, onDelta: { t in
            acc += t
            if let i = vm.messages.lastIndex(where: { $0.pending }) {
                vm.messages[i].text = acc
            }
        }, onAudio: { [weak self] data in
            self?.enqueueAudio(data)
        }, onDone: { [weak self] reply in
            guard let self = self else { return }
            vm.messages.removeAll { $0.pending }
            vm.messages.append(ChatMessage(role: .ava, text: reply.isEmpty ? acc : reply))
            self.streamDone = true
            if !self.playing && self.audioQueue.isEmpty { self.setPhase(.idle) }
        })
    }

    func cancel() {
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        interruptPlayback()
        setPhase(.idle)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
        if !audioQueue.isEmpty {
            playNextIfIdle()
        } else if streamDone {
            setPhase(.idle)
        }
        // else: stream still running, more audio coming; stay in .speaking
    }
}

// MARK: - App state
enum Mode { case collapsed, chat, voice }

final class AppState: ObservableObject {
    @Published var mode: Mode = .collapsed
    @Published var hovering: Bool = false
    var onChange: ((Mode) -> Void)?
    func set(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        onChange?(m)
    }
}

// MARK: - Avatar
let avatarImage: NSImage? = {
    if let url = Bundle.main.url(forResource: "avatar", withExtension: "png"),
       let img = NSImage(contentsOf: url) { return img }
    return nil
}()

struct AvatarView: View {
    var size: CGFloat = 26
    var glow: Bool = false
    var body: some View {
        Group {
            if let img = avatarImage {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else { Text("✨").font(.system(size: size * 0.6)) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Theme.accent.opacity(glow ? 0.7 : 0), radius: 7)
    }
}

// MARK: - Collapsed notch
struct CollapsedView: View {
    @ObservedObject var ui: AppState
    var shellW: CGFloat { Notch.width + 96 }
    var shellH: CGFloat { Notch.height }
    var body: some View {
        ZStack {
            NotchShape(radius: 18).fill(Color.black)
                .frame(width: shellW, height: shellH)
                .overlay(
                    NotchOutline(radius: 18)
                        .stroke(Theme.accent.opacity(ui.hovering ? 0.9 : 0.0), lineWidth: 1.2)
                        .frame(width: shellW, height: shellH))
            HStack {
                Spacer()
                AvatarView(size: max(Notch.height - 8, 18), glow: ui.hovering)
                    .scaleEffect(ui.hovering ? 1.08 : 1.0)
                    .padding(.trailing, 16)
            }
            .frame(width: shellW, height: shellH)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { ui.hovering = h } }
        .onTapGesture { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { ui.set(.chat) } }
    }
}

// MARK: - Voice drawer (Listening / Thinking / Speaking)
struct VoiceView: View {
    @ObservedObject var voice: VoiceManager
    var width: CGFloat
    var label: String {
        switch voice.phase {
        case .listening: return "Listening"
        case .thinking:  return "Thinking"
        case .speaking:  return "Speaking"
        case .idle:      return ""
        }
    }
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: 22).fill(Color.black)
            VStack(spacing: 3) {
                Spacer().frame(height: Notch.height - 6)
                HStack(spacing: 9) {
                    AvatarView(size: 20, glow: voice.phase == .speaking)
                    ShimmerText(text: label, size: 14)
                    VoiceBars(active: voice.phase == .listening || voice.phase == .speaking)
                }
                if voice.phase == .listening && !voice.transcript.isEmpty {
                    Text(voice.transcript)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 18)
                }
                Spacer(minLength: 2)
            }
        }
        .frame(width: width)
    }
}

struct VoiceBars: View {
    var active: Bool
    @State private var seed = 0.0
    let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { i in
                Capsule().fill(Color(white: 0.8))
                    .frame(width: 2.5, height: active ? CGFloat(5 + (sin(seed + Double(i)) + 1) * 6) : 3)
            }
        }
        .frame(height: 18)
        .opacity(active ? 0.9 : 0.3)
        .onReceive(timer) { _ in if active { seed += 0.6 } }
    }
}

// MARK: - Chat drawer (matches notch width, opens like a drawer)
struct ChatView: View {
    @ObservedObject var vm: ChatVM
    @ObservedObject var ui: AppState
    @ObservedObject var voice: VoiceManager
    var width: CGFloat
    @FocusState private var focused: Bool
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: 26).fill(Color.black)
                .overlay(NotchShape(radius: 26).stroke(Color.white.opacity(0.06), lineWidth: 1))
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    AvatarView(size: 20)
                    Text("ava").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    Spacer()
                    Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { ui.set(.collapsed) } }) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.textDim)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, Notch.height + 6).padding(.bottom, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            if vm.messages.isEmpty {
                                Text("hey, what are we working on today?")
                                    .font(.system(size: 13)).foregroundColor(Theme.textDim).padding(.top, 4)
                            }
                            ForEach(vm.messages) { m in BubbleView(msg: m).id(m.id) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(.horizontal, 12)
                    }
                    .onChange(of: vm.messages) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }

                HStack(spacing: 8) {
                    TextField("message ava…", text: $vm.input, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                        .lineLimit(1...4).focused($focused).onSubmit { vm.send() }
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.07)))
                    Button(action: { vm.send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.loading)
                    .opacity(vm.input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                }
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
            }
        }
        .frame(width: width)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { voice.greet() }
        }
    }
}

struct BubbleView: View {
    let msg: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if msg.role == .user { Spacer(minLength: 30) }
            Group {
                if msg.pending { TypingDots() }
                else {
                    Text(msg.text).font(.system(size: 13)).foregroundColor(.white)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(msg.role == .user
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Theme.bubbleAssistant)))
            if msg.role == .ava { Spacer(minLength: 30) }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Color.white.opacity(0.7)).frame(width: 5, height: 5)
                    .opacity(Int(phase) % 3 == i ? 1 : 0.3)
            }
        }.onReceive(timer) { _ in phase += 1 }
    }
}

// MARK: - Root
struct RootView: View {
    @ObservedObject var vm: ChatVM
    @ObservedObject var ui: AppState
    @ObservedObject var voice: VoiceManager
    var drawerWidth: CGFloat { Notch.width + 96 }
    var body: some View {
        VStack {
            switch ui.mode {
            case .collapsed: CollapsedView(ui: ui)
            case .voice:     VoiceView(voice: voice, width: drawerWidth)
            case .chat:      ChatView(vm: vm, ui: ui, voice: voice, width: drawerWidth)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: ui.mode)
    }
}

final class NotchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Task bulb (floating status orb, top-right corner)
final class TaskState: ObservableObject {
    enum S { case hidden, running, done }
    @Published var s: S = .hidden
    var onChange: ((S) -> Void)?
    private var hideTimer: Timer?
    private func set(_ v: S) {
        DispatchQueue.main.async { self.s = v; self.onChange?(v) }
    }
    func begin() { DispatchQueue.main.async { self.hideTimer?.invalidate() }; set(.running) }
    func done() {
        set(.done)
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.set(.hidden)
            }
        }
    }
    func hide() { DispatchQueue.main.async { self.hideTimer?.invalidate() }; set(.hidden) }
}

// face.png in the bundle wins (drop any face there); falls back to avatar.png
let bulbFaceImage: NSImage? = {
    if let url = Bundle.main.url(forResource: "face", withExtension: "png"),
       let img = NSImage(contentsOf: url) { return img }
    return avatarImage
}()

struct BulbView: View {
    @ObservedObject var task: TaskState
    var onTap: () -> Void
    @State private var spin = 0.0
    let timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(Color.black.opacity(0.85))
                Group {
                    if let img = bulbFaceImage {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else { Text("✨").font(.system(size: 24)) }
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())
                if task.s == .running {
                    Circle().trim(from: 0, to: 0.7)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 54, height: 54)
                        .rotationEffect(.degrees(spin))
                } else {
                    Circle().stroke(Color.green.opacity(0.85), lineWidth: 2.5)
                        .frame(width: 54, height: 54)
                }
            }
            .frame(width: 58, height: 58)
            if task.s == .done {
                ZStack {
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 17, height: 17)
                .offset(x: 1, y: 1)
            }
        }
        .frame(width: 62, height: 62)
        .shadow(color: Color.black.opacity(0.45), radius: 6)
        .contentShape(Circle())
        .onTapGesture { onTap() }
        .onReceive(timer) { _ in if task.s == .running { spin += 5 } }
    }
}

// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vm = ChatVM()
    let ui = AppState()
    let voice = VoiceManager()
    var window: NotchWindow!
    var clickMonitor: Any?
    var flagsMonitorG: Any?
    var flagsMonitorL: Any?
    var keyMonitorG: Any?
    var keyMonitorL: Any?
    var holding = false
    let task = TaskState()
    var bulbWindow: NSPanel?
    var escTimer: Timer?
    var escWasDown = false

    var drawerWidth: CGFloat { Notch.width + 96 }
    func sizeFor(_ m: Mode) -> CGSize {
        switch m {
        case .collapsed: return CGSize(width: Notch.width + 96, height: Notch.height + 4)
        case .voice:     return CGSize(width: drawerWidth, height: Notch.height + 42)
        case .chat:      return CGSize(width: drawerWidth, height: 540)
        }
    }

    func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
    }

    func measureNotch(_ screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        Notch.height = top > 0 ? top : NSStatusBar.system.thickness
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            Notch.width = max(150, screen.frame.width - l.width - r.width)
        } else { Notch.width = 200 }
    }

    func targetFrame(_ m: Mode) -> NSRect {
        let sf = activeScreen().frame
        let s = sizeFor(m)
        return NSRect(x: sf.midX - s.width / 2, y: sf.maxY - s.height, width: s.width, height: s.height)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        measureNotch(activeScreen())
        voice.requestPermissions()
        promptAccessibility()

        let frame = targetFrame(.collapsed)
        window = NotchWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: RootView(vm: vm, ui: ui, voice: voice))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        ui.onChange = { [weak self] m in
            guard let self = self else { return }
            let f = self.targetFrame(m)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().setFrame(f, display: true)
            }
            if m == .chat { self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        }

        // voice phase drives the drawer: open while active, close on idle
        voice.onPhaseChange = { [weak self] p in
            guard let self = self else { return }
            if p == .idle {
                if self.ui.mode == .voice {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.ui.set(.collapsed) }
                }
            } else if self.ui.mode != .chat {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.ui.set(.voice) }
            }
        }

        window.orderFrontRegardless()

        // click outside collapses chat
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.ui.mode == .chat else { return }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.ui.set(.collapsed) }
            }
        }

        // Ctrl+Opt hold-to-talk (global + local so it works whether or not we're key)
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        flagsMonitorG = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handler)
        flagsMonitorL = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { e in handler(e); return e }

        // starting to talk interrupts any in-flight reply
        voice.onBargeIn = { [weak self] in self?.vm.cancelStream() }

        // ESC = shut up + stand down. Global keyDown monitors need Input
        // Monitoring permission and silently get nothing without it, so we
        // poll the hardware key state instead (no permission needed).
        keyMonitorL = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.interruptAll(); return nil }
            return e
        }
        escTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(53))
            if down && !self.escWasDown { self.interruptAll() }
            self.escWasDown = down
        }

        // task bulb wiring
        task.onChange = { [weak self] s in
            if s == .hidden { self?.hideBulb() } else { self?.showBulb() }
        }
        vm.onTaskBegin = { [weak self] in self?.task.begin() }
        // only flash the checkmark if the bulb was actually up (a real task ran)
        vm.onTaskDone = { [weak self] in
            guard let self = self else { return }
            if self.task.s == .running { self.task.done() } else { self.task.hide() }
        }
        vm.onTaskCancel = { [weak self] in self?.task.hide() }
    }

    func showBulb() {
        if bulbWindow == nil {
            let size = CGSize(width: 62, height: 62)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false
            let host = NSHostingView(rootView: BulbView(task: task, onTap: { [weak self] in
                guard let self = self else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.ui.set(.chat) }
            }))
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            bulbWindow = panel
        }
        let vf = activeScreen().visibleFrame
        bulbWindow?.setFrameOrigin(NSPoint(x: vf.maxX - 62 - 12, y: vf.maxY - 62 - 12))
        bulbWindow?.orderFrontRegardless()
    }

    func hideBulb() { bulbWindow?.orderOut(nil) }

    func interruptAll() {
        vm.cancelStream()
        if voice.phase != .idle { voice.cancel() }
    }

    func handleFlags(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wanted: NSEvent.ModifierFlags = [.control, .option]
        let down = f.contains(.control) && f.contains(.option) && !f.contains(.command) && !f.contains(.shift)
        if down && !holding {
            holding = true
            voice.startListening()
        } else if !down && holding {
            holding = false
            voice.stopAndSend(vm)
        }
        _ = wanted
    }

    func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
