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
                ZStack(alignment: .trailing) {
                    VStack(spacing: 5) {
                        if voice.isInCall {
                            Text(voice.remoteNumber.displayPhone).font(.system(size: 30, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
                        } else {
                            TextField("Enter a number", text: $number)
                                .keyboardType(.phonePad).textContentType(.telephoneNumber)
                                .multilineTextAlignment(.center)
                                .font(.system(size: number.isEmpty ? 26 : 30, weight: .medium, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.65)
                                .accessibilityLabel("Phone number")
                        }
                        Text(voice.status.label).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    if !voice.isInCall {
                        HStack(spacing: 2) {
                            Button { showingContacts = true } label: { Image(systemName: "person.crop.circle").font(.title2).frame(width: 44, height: 48) }.accessibilityLabel("Choose contact")
                            if !number.isEmpty { Button { number = String(number.dropLast()) } label: { Image(systemName: "delete.left").font(.title2).frame(width: 44, height: 48) }.accessibilityLabel("Delete digit") }
                        }
                    }
                }.frame(height: 78).padding(.horizontal, 20)
                Spacer(minLength: 12)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(keySize), spacing: 24), count: 3), spacing: 14) {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            if voice.isInCall { voice.sendDTMF(key.digit) }
                            else if number.phoneDigits.count < 10 || ["*", "#"].contains(key.digit) { number += key.digit }
                        } label: {
                            VStack(spacing: -1) {
                                Text(key.digit).font(.system(size: 30, weight: .regular, design: .rounded))
                                Text(key.letters).font(.system(size: 9, weight: .semibold)).tracking(1.2).frame(height: 10)
                            }.frame(width: keySize, height: keySize).background(Color(.secondarySystemBackground)).clipShape(Circle())
                        }.buttonStyle(.plain)
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
            .sheet(isPresented: $showingContacts) { ContactPhonePicker { number = $0 } }
    }
}

struct ContactPhonePicker: UIViewControllerRepresentable {
    let onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}
    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPhonePicker
        init(parent: ContactPhonePicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard let phone = contactProperty.value as? CNPhoneNumber, let normalized = phone.stringValue.e164 else { return }
            parent.onSelect(normalized)
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
    @State private var saving = false
    var body: some View {
        Form {
            Section("Your Relay number") { Text(session.identity?.phone?.e164.displayPhone ?? "Not provisioned").font(.title3.bold()) }
            Section("Receive calls on") { Toggle("Web browsers", isOn: binding(\.receiveWeb)); Toggle("This iPhone", isOn: binding(\.receiveMobile)) }
            Section("Voicemail") { Toggle("Voicemail answering", isOn: binding(\.voicemailEnabled)); LabeledContent("Greeting", value: session.settings.hasVoicemailGreeting ? "Personal" : "Default") }
        }.navigationTitle("Settings").overlay { if saving { ProgressView().padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
    }
    private func binding(_ path: WritableKeyPath<RelaySettings, Bool>) -> Binding<Bool> { Binding(get: { session.settings[keyPath: path] }, set: { value in var next = session.settings; next[keyPath: path] = value; saving = true; Task { do { try await session.saveSettings(next) } catch { session.error = error.localizedDescription }; saving = false } }) }
}

extension VoiceManager.Status {
    var label: String { switch self { case .offline: "Voice offline"; case .connecting: "Connecting…"; case .ready: "Ready"; case .ringing: "Ringing…"; case .active: "In call"; case .held: "On hold"; case .ending: "Ending…"; case .failed(let value): value } }
}
