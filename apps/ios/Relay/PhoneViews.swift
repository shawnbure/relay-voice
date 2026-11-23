import AudioToolbox
import AVFoundation
import ContactsUI
#if targetEnvironment(macCatalyst)
import ServiceManagement
#endif
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
                    if session.lines.count > 1 && !voice.isInCall {
                        // Caller ID for calls and messages started here.
                        Menu {
                            ForEach(session.lines) { line in Button { Task { await session.selectLine(line.e164) } } label: { Label(line.name, systemImage: line.e164 == session.currentLine?.e164 ? "checkmark" : "phone") } }
                        } label: { Label("From \(session.currentLine?.name ?? "")", systemImage: "chevron.up.chevron.down").font(.footnote.weight(.semibold)) }
                    }
                }.frame(height: session.lines.count > 1 ? 100 : 78).padding(.horizontal, 20)
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
                        DialAction(title: number.e164 == session.currentLine?.e164 ? "Test Call" : "Call", icon: "phone.fill", color: .green, enabled: number.e164 != nil) { voice.start(number: number) }
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
                Text(active ? "\(title) On" : title).font(.caption.weight(active ? .bold : .regular)).foregroundStyle(active ? relayInk : Color.primary)
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
                VStack(spacing: 6) {
                    Text("Incoming Relay Call").font(.subheadline).foregroundStyle(.secondary)
                    Text(voice.remoteNumber.displayPhone).font(.title.bold()).minimumScaleFactor(0.7).lineLimit(1)
                    if let line = voice.incomingLineName { Label("To \(line)", systemImage: "phone.arrow.down.left").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                }
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
            Button { voice.hangup(); dismiss() } label: { Label("Hang Up", systemImage: "phone.down.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 50) }.buttonStyle(.borderedProminent).tint(.red)
        }.padding(20)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: RelaySession
    @EnvironmentObject private var voice: VoiceManager
    @EnvironmentObject private var lock: AppLock
    @State private var saving = false
    @State private var showingAddLine = false
    @State private var editingLine: PhoneLine?
    @State private var confirmingSignOut = false
    @State private var showingPassword = false
    @State private var openAtLogin = LoginItem.isEnabled
    @StateObject private var greetingRecorder = GreetingRecorder()
    private var isMac: Bool { ProcessInfo.processInfo.isMacCatalystApp }
    var body: some View {
        Form {
            Section {
                ForEach(session.lines) { line in
                    Button { if session.identity?.user.role != "member" { editingLine = line } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.name).fontWeight(.semibold).foregroundStyle(Color.primary)
                                if line.label != nil { Text(line.e164.displayPhone).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if line.e164 == session.currentLine?.e164 { Text("In Use").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                        }
                    }.accessibilityHint("Rename this line")
                }
                if session.identity?.user.role == "owner" { Button { showingAddLine = true } label: { Label("Add Number", systemImage: "plus.circle.fill") } }
                LabeledContent { Text(voice.status.label).foregroundStyle(voice.status == .ready ? .green : .secondary) } label: { Label("Calling", systemImage: "antenna.radiowaves.left.and.right") }
            } header: { Text("Phone Numbers") } footer: { Text(session.lines.count > 1 ? "Switch numbers from the title at the top of Conversations. Each number has its own inbox." : "Add numbers you already own in Telnyx to use them in Relay.") }
            Section {
                Toggle(isOn: binding(\.receiveMobile)) { Label(isMac ? "This Mac" : "This iPhone", systemImage: isMac ? "laptopcomputer" : "iphone") }
                Toggle(isOn: binding(\.receiveWeb)) { Label("Web Browsers", systemImage: "desktopcomputer") }
            } header: { Text("Ring On") } footer: { Text(isMac ? "Relay rings on this Mac while the app is open." : "Push notifications wake Relay for incoming calls even when the app is not open.") }
            Section {
                Toggle(isOn: binding(\.voicemailEnabled)) { Label("Answer Missed Calls", systemImage: "recordingtape") }
                HStack {
                    Label(session.settings.hasVoicemailGreeting ? "Personal Greeting" : "Default Greeting", systemImage: "waveform")
                    Spacer()
                    if session.settings.hasVoicemailGreeting { Button { Task { _ = await AudioPlayback.shared.toggle(path: "/v1/settings/voicemail-greeting") } } label: { Image(systemName: "play.circle.fill").font(.title2) }.accessibilityLabel("Play greeting") }
                }
                Button { Task { await recordGreeting() } } label: { Label(greetingRecorder.isRecording ? "Stop and Save" : "Record New Greeting", systemImage: greetingRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill").foregroundStyle(greetingRecorder.isRecording ? .red : relayInk) }
            } header: { Text("Voicemail") } footer: { Text("Tap again to stop and save your greeting.") }
            Section("Account") {
                LabeledContent { Text(session.identity?.user.email ?? "").foregroundStyle(.secondary) } label: { Label("Signed In As", systemImage: "person.crop.circle") }
                Toggle(isOn: $lock.isEnabled) { Label("Require \(lock.biometryName)", systemImage: "faceid") }
                Button { showingPassword = true } label: { Label("Change Password", systemImage: "key.fill") }
                if isMac {
                    Toggle(isOn: Binding(get: { openAtLogin }, set: { value in
                        do { try LoginItem.set(value); openAtLogin = LoginItem.isEnabled } catch { session.error = "Could not change Open at Login: \(error.localizedDescription)" }
                    })) { Label("Open at Login", systemImage: "power") }
                }
                Button(role: .destructive) { confirmingSignOut = true } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Section { LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") }
        }.navigationTitle("Settings").overlay { if saving { ProgressView("Saving…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
        .confirmationDialog("Sign Out of Relay?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
        } message: { Text("This device stops ringing and getting notifications until you sign in again.") }
        .sheet(isPresented: $showingPassword) { PasswordEditor().environmentObject(session) }
        .sheet(isPresented: $showingAddLine) { LineEditor(mode: .add).environmentObject(session) }
        .sheet(item: $editingLine) { LineEditor(mode: .rename($0)).environmentObject(session) }
    }
    private func binding(_ path: WritableKeyPath<RelaySettings, Bool>) -> Binding<Bool> { Binding(get: { session.settings[keyPath: path] }, set: { value in var next = session.settings; next[keyPath: path] = value; saving = true; Task { do { try await session.saveSettings(next) } catch { session.error = error.localizedDescription }; saving = false } }) }
    private func recordGreeting() async {
        do {
            if let recording = try await greetingRecorder.toggle() { saving = true; try await session.saveVoicemailGreeting(data: recording, contentType: "audio/mp4"); saving = false }
        } catch { saving = false; session.error = error.localizedDescription }
    }
}

/// Starts Relay when you log in to the Mac, so it is running (and can ring) without opening it by hand.
enum LoginItem {
    static var isEnabled: Bool {
        #if targetEnvironment(macCatalyst)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }
    static func set(_ enabled: Bool) throws {
        #if targetEnvironment(macCatalyst)
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        #endif
    }
}

/// Sets a new account password (used by the apps and the web).
private struct PasswordEditor: View {
    @EnvironmentObject private var session: RelaySession
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var message: String?
    private var valid: Bool { password.count >= 12 && password == confirm }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New Password", text: $password).textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirm).textContentType(.newPassword)
                } footer: { Text(confirm.isEmpty || password == confirm ? "At least 12 characters. Used to sign in to Relay on iPhone, Mac, and the web." : "The passwords don't match.") }
                if let message { Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            }
            .navigationTitle("Change Password").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { if working { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(!valid) } }
            }
        }
    }
    private func save() async {
        working = true; message = nil; defer { working = false }
        do { try await session.changePassword(password); dismiss() } catch { message = error.localizedDescription }
    }
}

/// Adds a number the account already owns in Telnyx, or renames an existing line.
private struct LineEditor: View {
    enum Mode { case add, rename(PhoneLine) }
    let mode: Mode
    @EnvironmentObject private var session: RelaySession
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var label = ""
    @State private var working = false
    @State private var message: String?
    private var isAdding: Bool { if case .add = mode { return true }; return false }
    var body: some View {
        NavigationStack {
            Form {
                if case .rename(let line) = mode {
                    LabeledContent("Number", value: line.e164.displayPhone)
                } else {
                    Section { TextField("Phone Number", text: $number).keyboardType(.phonePad).textContentType(.telephoneNumber) } footer: { Text("Use a number already in your Telnyx account. Relay sets it up for texts and calls; nothing is purchased.") }
                }
                Section { TextField("Label (Optional)", text: $label) } footer: { Text("For example Work or Personal. Shown in the line switcher and on alerts.") }
                if let message { Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            }
            .navigationTitle(isAdding ? "Add Number" : "Rename Line").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button(isAdding ? "Add" : "Save") { Task { await save() } }.disabled(isAdding && number.e164 == nil) }
                }
            }
            .task { if case .rename(let line) = mode { label = line.label ?? "" } }
        }
    }
    private func save() async {
        working = true; message = nil; defer { working = false }
        do {
            switch mode {
            case .add: guard let e164 = number.e164 else { return }; try await session.addLine(e164: e164, label: label)
            case .rename(let line): try await session.renameLine(e164: line.e164, label: label)
            }
            dismiss()
        } catch { message = error.localizedDescription }
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
