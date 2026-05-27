//
//  ContentView.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @AppStorage("credentials") private var credentials = ""
    @AppStorage("inputText") private var inputText = "Have a nice day!"
    @State private var result: String = ""
    @State private var isLoading = false
    @State private var isInitializing = false
    @State private var selectedVoice: TTSVoice?
    @AppStorage("speakingSpeed") private var speakingSpeed = 1.0
    @State private var api: GoogleTTSAPI?
    @State private var availableVoices: [TTSVoice] = []
    @State private var selectedLanguage: String = "en-US"
    @State private var availableLanguages: [String] = []
    @AppStorage("hotkey") private var hotkey = "option + `"
    @State private var editingHotkey = false
    @State var loadVoicesTask: Task<Void, Never>?
    @State private var isCredentialsSheetPresented = false
    
    private let inputLimit = 5000
    
    var filteredVoices: [TTSVoice] {
        if selectedLanguage.isEmpty {
            return availableVoices
        }
        return availableVoices.filter { voice in
            voice.languageCodes.contains(selectedLanguage)
        }
    }
    
    private var filteredVoiceGroups: [VoiceGroup] {
        VoiceCategory.allCases.compactMap { category in
            let voices = filteredVoices.filter { VoiceCategory(for: $0.name) == category }
            guard !voices.isEmpty else { return nil }
            return VoiceGroup(category: category, voices: voices)
        }
    }
    
    private var canSpeak: Bool {
        !credentials.isEmpty && !inputText.isEmpty && !isLoading && !isInitializing && selectedVoice != nil
    }
    
    private var hasError: Bool {
        result.localizedCaseInsensitiveContains("error") ||
        result.localizedCaseInsensitiveContains("failed")
    }
    
    private var cloudStatus: ConnectionStatus {
        if credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notConfigured
        }
        
        if isInitializing {
            return .loading
        }
        
        if hasError {
            return .error
        }
        
        if !availableVoices.isEmpty {
            return .connected
        }
        
        return .notConfigured
    }
    
    private var readyStatus: ReadyStatus {
        if credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ReadyStatus(
                title: "Not configured",
                message: "Add Google Cloud credentials to start using Smooth Talker.",
                symbolName: "exclamationmark.circle.fill",
                color: .orange
            )
        }
        
        if isInitializing {
            return ReadyStatus(
                title: "Loading voices",
                message: "Smooth Talker is checking your Google Cloud credentials.",
                symbolName: "arrow.triangle.2.circlepath",
                color: .orange
            )
        }
        
        if hasError {
            return ReadyStatus(
                title: "Needs attention",
                message: result,
                symbolName: "xmark.circle.fill",
                color: .red
            )
        }
        
        if selectedVoice == nil {
            return ReadyStatus(
                title: "Choose a voice",
                message: "Select a voice before speaking text.",
                symbolName: "person.wave.2.fill",
                color: .orange
            )
        }
        
        return ReadyStatus(
            title: "Ready",
            message: "Select any text and press \(hotkey) to hear it.",
            symbolName: "checkmark.circle.fill",
            color: .green
        )
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                inputArea
                settingsCard
                cloudCard
                StatusCard(status: readyStatus)
            }
            .padding(.horizontal, 34)
            .padding(.top, 32)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 650)
        .sheet(isPresented: $isCredentialsSheetPresented) {
            CredentialsSheet(credentials: credentials) { newCredentials in
                saveCredentials(newCredentials)
            }
        }
        .onAppear {
            if inputText.count > inputLimit {
                inputText = String(inputText.prefix(inputLimit))
            }
            
            if !credentials.isEmpty && availableVoices.isEmpty {
                startLoadVoicesTask(resetAPI: false)
            }
        }
        .onChange(of: inputText) { _, newValue in
            guard newValue.count > inputLimit else { return }
            inputText = String(newValue.prefix(inputLimit))
        }
        .onChange(of: credentials) { _, newValue in
            if !newValue.isEmpty {
                startLoadVoicesTask(resetAPI: true)
            } else {
                GoogleTTSAPI.resetSharedInstance()
                api = nil
                availableVoices = []
                availableLanguages = []
                selectedVoice = nil
                result = ""
            }
        }
        .onChange(of: selectedVoice, { _, _ in
            Preferences.shared.voiceName = selectedVoice?.name ?? ""
            Preferences.shared.language = selectedVoice?.languageCodes.first ?? "unknown"
            print("changed voice")
        })
        .onChange(of: editingHotkey) { _, newValue in
            if newValue {
                Task {
                    hotkey = (await HotkeyManager.shared.hotkey?.waitForHotkey()) ?? ""
                    editingHotkey = false
                }
            }
        }
    }
    
    private var header: some View {
        HStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Smooth Talker")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Natural sounding text-to-speech")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer(minLength: 0)
        }
    }
    
    private var inputArea: some View {
        VStack(alignment: .trailing, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $inputText)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .padding(18)
                    .padding(.bottom, 26)
                    .frame(minHeight: 148)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                
                Text("\(inputText.count) / \(inputLimit)")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 18)
                    .padding(.bottom, 16)
            }
            
            Button(action: {
                speakText(inputText)
            }) {
                Label("Speak", systemImage: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 176, height: 54)
            }
            .buttonStyle(OrangeProminentButtonStyle())
            .disabled(!canSpeak)
        }
    }
    
    private var settingsCard: some View {
        SettingsCard {
            VStack(spacing: 18) {
                SettingsRow(symbolName: "globe", title: "Language") {
                    if availableLanguages.isEmpty {
                        PlaceholderValue(text: isInitializing ? "Loading languages..." : "Add credentials first")
                    } else {
                        Picker("Language", selection: $selectedLanguage) {
                            Text("All Languages").tag("")
                            ForEach(availableLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedLanguage) {
                            selectedVoice = nil
                        }
                    }
                }
                
                SettingsRow(symbolName: "person.wave.2", title: "Voice") {
                    if availableVoices.isEmpty {
                        PlaceholderValue(text: isInitializing ? "Loading voices..." : "No voices loaded")
                    } else {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(filteredVoiceGroups) { group in
                                Section(header: Text(group.category.title)) {
                                    ForEach(group.voices, id: \.name) { voice in
                                        Text(voice.displayName).tag(voice as TTSVoice?)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }
                }
                
                SettingsRow(symbolName: "speedometer", title: "Speaking Speed") {
                    HStack(spacing: 14) {
                        Text("-")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        
                        Slider(value: $speakingSpeed, in: 0.25...4.0)
                            .tint(.orange)
                        
                        Text("+")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        
                        Text("\(speakingSpeed, specifier: "%.2f")x")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .frame(width: 70, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                
                Divider()
                    .padding(.leading, 96)
                
                SettingsRow(symbolName: "keyboard", title: "Hotkey") {
                    HStack(spacing: 12) {
                        Text(editingHotkey ? "Press keys" : hotkey)
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                        Button(editingHotkey ? "Listening..." : "Change...") {
                            editingHotkey = true
                        }
                        .controlSize(.large)
                        .frame(width: 132)
                        .disabled(editingHotkey)
                    }
                }
            }
        }
    }
    
    private var cloudCard: some View {
        SettingsCard {
            HStack(spacing: 20) {
                IconTile(symbolName: cloudStatus.symbolName, color: cloudStatus.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Cloud")
                        .font(.system(size: 18, weight: .semibold))
                    
                    Text(cloudStatus.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(cloudStatus.color)
                }
                
                Spacer(minLength: 20)
                
                Button("Change Credentials...") {
                    isCredentialsSheetPresented = true
                }
                .controlSize(.large)
            }
        }
    }
    
    private func saveCredentials(_ newCredentials: String) {
        let trimmedCredentials = newCredentials.trimmingCharacters(in: .whitespacesAndNewlines)
        let didChangeCredentials = trimmedCredentials != credentials
        credentials = trimmedCredentials
        isCredentialsSheetPresented = false
        
        if trimmedCredentials.isEmpty {
            GoogleTTSAPI.resetSharedInstance()
            api = nil
            availableVoices = []
            availableLanguages = []
            selectedVoice = nil
            result = ""
        } else if !didChangeCredentials {
            startLoadVoicesTask(resetAPI: true)
        }
    }
    
    private func startLoadVoicesTask(resetAPI: Bool) {
        loadVoicesTask?.cancel()
        loadVoicesTask = Task {
            loadVoices(resetAPI: resetAPI)
        }
    }
    
    private func loadVoices(resetAPI: Bool) {
        if resetAPI {
            GoogleTTSAPI.resetSharedInstance()
        }
        
        isInitializing = true
        result = "Loading voices..."
        GoogleTTSAPI.getInstance(credentialsJson: credentials) { api in
            self.api = api
            api.fetchVoices { voices in
                DispatchQueue.main.async {
                    let selectableVoices = voices.filter(isSelectableGoogleVoice).sorted(by: compareVoicesByCategory)
                    self.availableVoices = selectableVoices
                    
                    let allLanguages = Set(selectableVoices.flatMap { $0.languageCodes })
                    self.availableLanguages = Array(allLanguages).sorted()
                    
                    if self.selectedVoice == nil || !selectableVoices.contains(where: { $0.name == self.selectedVoice?.name }) {
                        let savedVoiceName = Preferences.shared.voiceName
                        if !savedVoiceName.isEmpty {
                            self.selectedVoice = selectableVoices.first { $0.name == savedVoiceName }
                            if let voice = self.selectedVoice {
                                self.selectedLanguage = voice.languageCodes.first ?? "en-US"
                            }
                        }
                        
                        if self.selectedVoice == nil, let firstVoice = selectableVoices.first {
                            self.selectedVoice = firstVoice
                            self.selectedLanguage = firstVoice.languageCodes.first ?? "en-US"
                        }
                        
                        Preferences.shared.language = selectedLanguage
                    }
                    if voices.isEmpty {
                        result = "Failed to fetch voices, is the API key correct?"
                    } else {
                        result = "Success! Ready to play"
                    }
                                        
                    isInitializing = false
                }
            }
        }
    }
    
    private func isSelectableGoogleVoice(_ voice: TTSVoice) -> Bool {
        voice.name.range(of: #"^[a-z]{2,3}-[A-Z]{2}-"#, options: .regularExpression) != nil
    }
    
    private func compareVoicesByCategory(_ lhs: TTSVoice, _ rhs: TTSVoice) -> Bool {
        let lhsCategory = VoiceCategory(for: lhs.name)
        let rhsCategory = VoiceCategory(for: rhs.name)
        
        if lhsCategory != rhsCategory {
            return lhsCategory.rawValue < rhsCategory.rawValue
        }
        
        return lhs.name < rhs.name
    }
    
    private func speakText(_ text: String) {
        SpeechManager.shared.speak(text)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct SettingsRow<Content: View>: View {
    let symbolName: String
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(spacing: 20) {
            IconTile(symbolName: symbolName, color: .primary)
            
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 180, alignment: .leading)
            
            content
        }
        .frame(minHeight: 52)
    }
}

private struct IconTile: View {
    let symbolName: String
    let color: Color
    
    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct PlaceholderValue: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

private struct StatusCard: View {
    let status: ReadyStatus
    
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: status.symbolName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, value: status.title)
                .frame(width: 46, height: 46)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(status.color)
                
                Text(status.message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer(minLength: 20)
            
            WaveformView(color: status.color)
                .frame(width: 150, height: 42)
                .opacity(status.title == "Ready" ? 1 : 0.35)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct WaveformView: View {
    let color: Color
    
    private let samples: [CGFloat] = [0.2, 0.45, 0.25, 0.75, 0.18, 0.62, 0.28, 0.9, 0.3, 0.5, 0.2, 0.72, 0.34, 0.42, 0.24, 0.8, 0.22, 0.48, 0.28]
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let step = width / CGFloat(max(samples.count - 1, 1))
            
            Path { path in
                for index in samples.indices {
                    let x = CGFloat(index) * step
                    let y = height / 2 - ((samples[index] - 0.5) * height * 0.82)
                    
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(0.62), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct CredentialsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftCredentials: String
    let onSave: (String) -> Void
    
    init(credentials: String, onSave: @escaping (String) -> Void) {
        _draftCredentials = State(initialValue: credentials)
        self.onSave = onSave
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Google Cloud Credentials")
                    .font(.title2.bold())
                
                Text("Paste the service account JSON key used for Google Text-to-Speech.")
                    .foregroundStyle(.secondary)
            }
            
            TextEditor(text: $draftCredentials)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(width: 620, height: 280)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    onSave(draftCredentials)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

private struct ReadyStatus {
    let title: String
    let message: String
    let symbolName: String
    let color: Color
}

private enum ConnectionStatus {
    case connected
    case loading
    case notConfigured
    case error
    
    var title: String {
        switch self {
        case .connected:
            return "Connected"
        case .loading:
            return "Loading"
        case .notConfigured:
            return "Not configured"
        case .error:
            return "Connection issue"
        }
    }
    
    var symbolName: String {
        switch self {
        case .connected:
            return "checkmark.icloud.fill"
        case .loading:
            return "icloud.and.arrow.down.fill"
        case .notConfigured:
            return "icloud.slash.fill"
        case .error:
            return "exclamationmark.icloud.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .connected:
            return .green
        case .loading:
            return .orange
        case .notConfigured:
            return .secondary
        case .error:
            return .red
        }
    }
}

private struct OrangeProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.gradient)
            )
            .shadow(color: .orange.opacity(configuration.isPressed ? 0.12 : 0.26), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 1 : 5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.48)
    }
}

private struct VoiceGroup: Identifiable {
    let category: VoiceCategory
    let voices: [TTSVoice]
    
    var id: VoiceCategory { category }
}

private enum VoiceCategory: Int, CaseIterable {
    case standard
    case waveNet
    case casual
    case neural2
    case news
    case polyglot
    case chirpHD
    case chirp3HD
    case studio
    case other
    
    init(for voiceName: String) {
        if voiceName.contains("-Standard-") {
            self = .standard
        } else if voiceName.contains("-Wavenet-") || voiceName.contains("-WaveNet-") {
            self = .waveNet
        } else if voiceName.contains("-Casual-") {
            self = .casual
        } else if voiceName.contains("-Neural2-") {
            self = .neural2
        } else if voiceName.contains("-News-") {
            self = .news
        } else if voiceName.contains("-Polyglot-") {
            self = .polyglot
        } else if voiceName.contains("-Chirp-HD-") {
            self = .chirpHD
        } else if voiceName.contains("-Chirp3-HD-") {
            self = .chirp3HD
        } else if voiceName.contains("-Studio-") {
            self = .studio
        } else {
            self = .other
        }
    }
    
    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .waveNet:
            return "WaveNet"
        case .casual:
            return "Casual"
        case .neural2:
            return "Neural2"
        case .news:
            return "News"
        case .polyglot:
            return "Polyglot"
        case .chirpHD:
            return "Chirp HD"
        case .chirp3HD:
            return "Chirp3 HD"
        case .studio:
            return "Studio"
        case .other:
            return "Other"
        }
    }
}

#Preview {
    ContentView()
}
