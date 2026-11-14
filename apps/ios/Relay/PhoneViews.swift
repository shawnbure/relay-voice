import AudioToolbox
import AVFoundation
import ContactsUI
import SwiftUI

private let relayGreen = Color(red: 0.74, green: 0.96, blue: 0.29)
private let relayInk = Color(red: 0.09, green: 0.13, blue: 0.10)

struct DialerView: View {
    let onMessage: (String) -> Void
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @State private var number = ""
    @State private var showingContacts = false
    private let keys = [DialKey("1", ""), DialKey("2", "ABC"), DialKey("3", "DEF"), DialKey("4", "GHI"), DialKey("5", "JKL"), DialKey("6", "MNO"), DialKey("7", "PQRS"), DialKey("8", "TUV"), DialKey("9", "WXYZ"), DialKey("*", ""), DialKey("0", "+"), DialKey("#", "")]
    var body: some View {
        GeometryReader { geometry in
            let keySize = min(max((geometry.size.width - 112) / 3, 64), 78)
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Button { showingContacts = true } label: { Image(systemName: "person.crop.circle").font(.title2).frame(width: 44, height: 48) }
                            .accessibilityLabel("Choose contact").opacity(voice.isInCall ? 0 : 1).disabled(voice.isInCall)
                        if voice.isInCall {
                            Text(voice.remoteNumber.displayPhone).font(.system(size: 30, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: .infinity)
                        } else {
                            PhoneNumberField(number: $number).frame(height: 48).frame(maxWidth: .infinity).accessibilityLabel("Phone number")
                        }
                        Image(systemName: "delete.left").font(.title2).frame(width: 44, height: 48).contentShape(Rectangle())
                            .onTapGesture { deleteDigit() }
                            .onLongPressGesture(minimumDuration: 0.45) { number = ""; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                            .opacity(number.isEmpty || voice.isInCall ? 0 : 1).allowsHitTesting(!number.isEmpty && !voice.isInCall)
                            .accessibilityAddTraits(.isButton).accessibilityLabel("Delete digit").accessibilityHint("Touch and hold to clear the number")
                    }
                    Text(voice.status.label).font(.callout).foregroundStyle(.secondary)
                }.frame(height: 78).padding(.horizontal, 20)
                Spacer(minLength: 12)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(keySize), spacing: 24), count: 3), spacing: 14) {
                    ForEach(keys, id: \.self) { key in
                        DialPadKey(key: key, size: keySize, onTap: { press(key.digit) }, onLongPress: key.digit == "0" ? { press("+") } : nil)
                    }
                }.frame(maxWidth: .infinity)
                Spacer(minLength: 18)
                if voice.isInCall {
                    HStack(spacing: 28) { CallControl(title: "Mute", icon: voice.muted ? "mic.slash.fill" : "mic.fill", active: voice.muted) { voice.toggleMute() }; CallControl(title: "Hold", icon: "pause.fill", active: voice.status == .held) { voice.toggleHold() }; AudioRouteControl() }
                    Button { voice.hangup() } label: { Image(systemName: "phone.down.fill").font(.title2.bold()).frame(width: 72, height: 72).background(.red).foregroundStyle(.white).clipShape(Circle()) }.accessibilityLabel("Hang up").padding(.top, 12)
                } else {
                    HStack(spacing: 54) {
                        DialAction(title: "Message", icon: "message.fill", color: relayGreen, enabled: number.e164 != nil) { if let destination = number.e164 { onMessage(destination) } }
                        DialAction(title: number.e164 == session.identity?.phone?.e164 ? "Test call" : "Call", icon: "phone.fill", color: .green, enabled: number.e164 != nil) { voice.start(number: number) }
                    }
                }
                Spacer(minLength: 18)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.navigationTitle("Keypad").navigationBarTitleDisplayMode(.inline)
            .background(ContactPhonePicker(isPresented: $showingContacts) { number = $0 })
    }
    private func press(_ digit: String) {
        if voice.isInCall { voice.sendDTMF(digit); return }
        if digit == "+" { if number.isEmpty { number = "+" } else { press("0") }; return }
        guard number.phoneDigits.count < maxDialDigits(number) || !digit.allSatisfy(\.isNumber) else { return }
        number += digit
    }
    private func deleteDigit() { if !number.isEmpty { number.removeLast() } }
}

/// Presents the system contact picker from UIKit. Wrapping CNContactPickerViewController directly in a SwiftUI
/// sheet leaves an empty host sheet behind and drops the selection callback, so present it modally instead.
struct ContactPhonePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // A contact with one number is picked immediately; contacts with several numbers open so one can be chosen.
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }
    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPhonePicker
        init(parent: ContactPhonePicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            finish(contact.phoneNumbers.first?.value)
        }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            finish(contactProperty.value as? CNPhoneNumber)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.isPresented = false }
        private func finish(_ phone: CNPhoneNumber?) {
            parent.isPresented = false
            guard let raw = phone?.stringValue else { return }
            parent.onSelect(raw.e164 ?? raw)
        }
    }
}

private struct PhoneNumberField: UIViewRepresentable {
    @Binding var number: String
    func makeCoordinator() -> Coordinator { Coordinator(number: $number) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.textAlignment = .center
        let baseFont = UIFont.systemFont(ofSize: 30, weight: .medium)
        field.font = baseFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 30) } ?? baseFont
        field.placeholder = "Enter a number"
        field.keyboardType = .phonePad
        field.textContentType = .telephoneNumber
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 20
        field.inputView = UIView(frame: .zero)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) { let shown = formatDialInput(number); if field.text != shown { field.text = shown } }
    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var number: String
        init(number: Binding<String>) { _number = number }
        @objc func changed(_ field: UITextField) { number = (field.text ?? "").filter { $0.isNumber || "+*#".contains($0) } }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let current = textField.text, let swiftRange = Range(range, in: current) else { return false }
            let candidate = current.replacingCharacters(in: swiftRange, with: string)
            return candidate.phoneDigits.count <= maxDialDigits(candidate)
        }
    }
}

private struct AudioRouteControl: View {
    @EnvironmentObject private var voice: VoiceManager
    private var selected: VoiceManager.AudioRoute { voice.audioRoutes.first { $0.id == voice.selectedAudioRouteID } ?? voice.audioRoutes[0] }
    var body: some View {
        Menu {
            ForEach(voice.audioRoutes) { route in
                Button { voice.selectAudioRoute(route) } label: { Label(route.name, systemImage: route.id == voice.selectedAudioRouteID ? "checkmark" : route.icon) }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: selected.icon).font(.title2.bold()).frame(width: 58, height: 58)
                    .background(voice.selectedAudioRouteID == "receiver" ? Color(.secondarySystemBackground) : relayGreen)
                    .foregroundStyle(voice.selectedAudioRouteID == "receiver" ? Color.primary : relayInk).clipShape(Circle())
                    .overlay(Circle().stroke(voice.selectedAudioRouteID == "receiver" ? Color(.separator) : relayInk.opacity(0.7), lineWidth: voice.selectedAudioRouteID == "receiver" ? 1 : 2.5))
                Text(selected.name).font(.caption.weight(voice.selectedAudioRouteID == "receiver" ? .regular : .bold)).lineLimit(1).frame(maxWidth: 72)
            }
        }.accessibilityLabel("Audio output").accessibilityValue(selected.name)
    }
}

/// US numbers allow 10 digits, or 11 with a leading 1; international (+) numbers allow up to 15.
private func maxDialDigits(_ input: String) -> Int { input.hasPrefix("+") && !input.hasPrefix("+1") ? 15 : input.phoneDigits.first == "1" ? 11 : 10 }
/// Formats US numbers as they are typed: 480, 480-7885, (480) 788-5010, 1 (480) 788-5010.
func formatDialInput(_ input: String) -> String {
    guard !input.contains(where: { "*#".contains($0) }), !(input.hasPrefix("+") && !input.hasPrefix("+1")) else { return input }
    var digits = input.phoneDigits; var prefix = input.hasPrefix("+") ? "+" : ""
    if digits.first == "1" { prefix += digits.count > 1 ? "1 " : "1"; digits.removeFirst() }
    guard digits.count <= 10 else { return input }
    let d = Array(digits)
    switch d.count {
    case 0...3: return prefix + digits
    case 4...7: return prefix + String(d[0..<3]) + "-" + String(d[3...])
    default: return prefix + "(" + String(d[0..<3]) + ") " + String(d[3..<6]) + "-" + String(d[6...])
    }
}
private struct DialPadKey: View {
    let key: DialKey; let size: CGFloat; let onTap: () -> Void; let onLongPress: (() -> Void)?
    @State private var longPressed = false
    var body: some View {
        Button {
            if longPressed { longPressed = false; return }
            feedback(); onTap()
        } label: {
            VStack(spacing: -1) {
                Text(key.digit).font(.system(size: 32, weight: .regular, design: .rounded))
                Text(key.letters).font(.system(size: 9, weight: .semibold)).tracking(1.2).frame(height: 10)
            }.frame(width: size, height: size)
        }
        .buttonStyle(DialPadKeyStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard let onLongPress else { return }
            longPressed = true; feedback(); onLongPress()
        })
        .accessibilityLabel(key.digit)
    }
    private func feedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // System DTMF tones: 1200–1209 are 0–9, 1210 is *, 1211 is #.
        let tone: SystemSoundID = key.digit == "*" ? 1210 : key.digit == "#" ? 1211 : 1200 + SystemSoundID(Int(key.digit) ?? 0)
        AudioServicesPlaySystemSound(tone)
    }
}
private struct DialPadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray3) : Color(.secondarySystemBackground)).clipShape(Circle())
            .animation(.easeOut(duration: configuration.isPressed ? 0.04 : 0.25), value: configuration.isPressed)
    }
}

private struct DialKey: Hashable { let digit: String; let letters: String; init(_ digit: String, _ letters: String) { self.digit = digit; self.letters = letters } }
private struct DialAction: View {
    let title: String; let icon: String; let color: Color; let enabled: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.title2.bold()).frame(width: 72, height: 72).background(enabled ? color : Color(.tertiarySystemFill)).foregroundStyle(enabled ? relayInk : Color.secondary).clipShape(Circle())
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(enabled ? Color.primary : Color.secondary)
            }
        }.buttonStyle(.plain).disabled(!enabled)
    }
}

private struct CallControl: View {
    let title: String; let icon: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2.bold()).frame(width: 58, height: 58)
                    .background(active ? relayGreen : Color(.secondarySystemBackground))
                    .foregroundStyle(active ? relayInk : Color.primary).clipShape(Circle())
                    .overlay(Circle().stroke(active ? relayInk.opacity(0.7) : Color(.separator), lineWidth: active ? 2.5 : 1))
                Text(active ? "\(title) on" : title).font(.caption.weight(active ? .bold : .regular)).foregroundStyle(active ? relayInk : Color.primary)
            }
        }.buttonStyle(.plain).accessibilityValue(active ? "On" : "Off")
    }
}

struct CallBar: View {
    @EnvironmentObject private var voice: VoiceManager
    @State private var now = Date()
    @State private var showingKeypad = false
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) { Text(voice.status.label).font(.caption).foregroundStyle(.secondary); Text(voice.remoteNumber.displayPhone).font(.headline).lineLimit(1) }
            Spacer()
            if let start = voice.startedAt { Text(start, style: .timer).font(.system(.callout, design: .monospaced)) }
            Button { showingKeypad = true } label: { Image(systemName: "circle.grid.3x3.fill").frame(width: 44, height: 44).background(Color(.secondarySystemBackground)).clipShape(Circle()) }.accessibilityLabel("Keypad")
            Button { voice.hangup() } label: { Image(systemName: "phone.down.fill").frame(width: 44, height: 44).background(.red).foregroundStyle(.white).clipShape(Circle()) }.accessibilityLabel("Hang up")
        }
        .padding(10).background(.ultraThickMaterial).clipShape(RoundedRectangle(cornerRadius: 20)).shadow(radius: 14)
        .sheet(isPresented: $showingKeypad) { InCallKeypadView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .onChange(of: voice.isInCall) { _, active in if !active { showingKeypad = false } }
    }
}

struct IncomingCallView: View {
    @EnvironmentObject private var voice: VoiceManager
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "phone.arrow.down.left.fill").font(.system(size: 34)).frame(width: 76, height: 76).background(relayGreen).foregroundStyle(relayInk).clipShape(Circle())
                VStack(spacing: 6) { Text("Incoming Relay call").font(.subheadline).foregroundStyle(.secondary); Text(voice.remoteNumber.displayPhone).font(.title.bold()).minimumScaleFactor(0.7).lineLimit(1) }
                HStack(spacing: 54) {
                    VStack { Button { voice.hangup() } label: { Image(systemName: "phone.down.fill").font(.title2).frame(width: 68, height: 68).background(.red).foregroundStyle(.white).clipShape(Circle()) }; Text("Decline").font(.caption) }
                    VStack { Button { voice.answer() } label: { Image(systemName: "phone.fill").font(.title2).frame(width: 68, height: 68).background(.green).foregroundStyle(.white).clipShape(Circle()) }; Text("Answer").font(.caption) }
                }
            }.padding(30).frame(maxWidth: 340).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 30)).shadow(radius: 24)
        }.transition(.opacity)
    }
}

private struct InCallKeypadView: View {
    @EnvironmentObject private var voice: VoiceManager
    @Environment(\.dismiss) private var dismiss
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]
    var body: some View {
        VStack(spacing: 12) {
            HStack { VStack(alignment: .leading, spacing: 2) { Text(voice.remoteNumber.displayPhone).font(.headline); Text("Send keypad tones").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.fontWeight(.semibold) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 10) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        voice.sendDTMF(key)
                    } label: {
                        Text(key).font(.system(size: 28, weight: .medium, design: .rounded)).frame(maxWidth: .infinity).frame(height: 54).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityLabel("Send \(key)")
                }
            }
            Button { voice.hangup(); dismiss() } label: { Label("Hang up", systemImage: "phone.down.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 50) }.buttonStyle(.borderedProminent).tint(.red)
        }.padding(20)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @State private var saving = false
    @StateObject private var greetingRecorder = GreetingRecorder()
    var body: some View {
        Form {
            Section("Relay line") {
                LabeledContent { Text(session.identity?.phone?.e164.displayPhone ?? "Not provisioned").fontWeight(.semibold) } label: { Label("Your number", systemImage: "phone.fill") }
                LabeledContent { Text(voice.status.label).foregroundStyle(voice.status == .ready ? .green : .secondary) } label: { Label("Calling", systemImage: "antenna.radiowaves.left.and.right") }
            }
            Section {
                Toggle(isOn: binding(\.receiveMobile)) { Label("This iPhone", systemImage: "iphone") }
                Toggle(isOn: binding(\.receiveWeb)) { Label("Web browsers", systemImage: "desktopcomputer") }
            } header: { Text("Ring on") } footer: { Text("Push notifications wake Relay for incoming calls even when the app is not open.") }
            Section {
                Toggle(isOn: binding(\.voicemailEnabled)) { Label("Answer missed calls", systemImage: "recordingtape") }
                HStack {
                    Label(session.settings.hasVoicemailGreeting ? "Personal greeting" : "Default greeting", systemImage: "waveform")
                    Spacer()
                    if session.settings.hasVoicemailGreeting { Button { Task { _ = await AudioPlayback.shared.toggle(path: "/v1/settings/voicemail-greeting") } } label: { Image(systemName: "play.circle.fill").font(.title2) }.accessibilityLabel("Play greeting") }
                }
                Button { Task { await recordGreeting() } } label: { Label(greetingRecorder.isRecording ? "Stop and save" : "Record new greeting", systemImage: greetingRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill").foregroundStyle(greetingRecorder.isRecording ? .red : relayInk) }
            } header: { Text("Voicemail") } footer: { Text("Tap again to stop and save your greeting.") }
            Section { LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") }
        }.navigationTitle("Settings").overlay { if saving { ProgressView("Saving…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
    }
    private func binding(_ path: WritableKeyPath<RelaySettings, Bool>) -> Binding<Bool> { Binding(get: { session.settings[keyPath: path] }, set: { value in var next = session.settings; next[keyPath: path] = value; saving = true; Task { do { try await session.saveSettings(next) } catch { session.error = error.localizedDescription }; saving = false } }) }
    private func recordGreeting() async {
        do {
            if let recording = try await greetingRecorder.toggle() { saving = true; try await session.saveVoicemailGreeting(data: recording, contentType: "audio/mp4"); saving = false }
        } catch { saving = false; session.error = error.localizedDescription }
    }
}

@MainActor private final class GreetingRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    func toggle() async throws -> Data? {
        if isRecording { return try stop() }
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: granted = true
        case .denied: granted = false
        default: granted = await AVAudioApplication.requestRecordPermission()
        }
        guard granted else { throw RelayAPIError.server("Microphone access is required to record a voicemail greeting.") }
        let audio = AVAudioSession.sharedInstance(); try audio.setCategory(.record, mode: .spokenAudio); try audio.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-greeting-\(UUID().uuidString).m4a")
        recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        recorder?.record(); outputURL = url; isRecording = true
        return nil
    }
    private func stop() throws -> Data? {
        recorder?.stop(); isRecording = false; try? AVAudioSession.sharedInstance().setActive(false)
        guard let outputURL else { return nil }; defer { try? FileManager.default.removeItem(at: outputURL); self.outputURL = nil }
        return try Data(contentsOf: outputURL)
    }
}

extension VoiceManager.Status {
    var label: String { switch self { case .offline: "Voice offline"; case .connecting: "Connecting…"; case .ready: "Ready"; case .ringing: "Ringing…"; case .active: "In call"; case .held: "On hold"; case .ending: "Ending…"; case .failed(let value): value } }
}
