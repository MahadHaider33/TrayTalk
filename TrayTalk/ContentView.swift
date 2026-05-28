//
//  ContentView.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            VStack(alignment: .leading, spacing: 16) {
                header
                inputArea
                settingsCard
                cloudCard
                StatusCard(status: readyStatus)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 590)
        .sheet(isPresented: $isCredentialsSheetPresented) {
            CredentialsSetupSheet(credentials: credentials) { newCredentials, voices in
                saveValidatedCredentials(newCredentials, voices: voices)
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
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Smooth Talker")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Natural sounding text-to-speech")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer(minLength: 0)
        }
    }
    
    private var inputArea: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $inputText)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(15)
                    .padding(.bottom, 24)
                    .frame(minHeight: 124)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                
                Text("\(inputText.count) / \(inputLimit)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
            
            Button(action: {
                speakText(inputText)
            }) {
                Label("Speak", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 164, height: 50)
            }
            .buttonStyle(OrangeProminentButtonStyle())
            .disabled(!canSpeak)
        }
    }
    
    private var settingsCard: some View {
        SettingsCard {
            VStack(spacing: 14) {
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
                        .controlSize(.regular)
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
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                    }
                }
                
                SettingsRow(symbolName: "speedometer", title: "Speaking Speed") {
                    HStack(spacing: 12) {
                        Text("-")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                        
                        Slider(value: $speakingSpeed, in: 0.25...4.0)
                            .tint(.orange)
                        
                        Text("+")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                        
                        Text("\(speakingSpeed, specifier: "%.2f")x")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .frame(width: 66, height: 34)
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
                    .padding(.leading, 76)
                
                SettingsRow(symbolName: "keyboard", title: "Hotkey") {
                    HStack(spacing: 10) {
                        Text(editingHotkey ? "Press keys" : hotkey)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
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
                        .controlSize(.regular)
                        .frame(width: 122)
                        .disabled(editingHotkey)
                    }
                }
            }
        }
    }
    
    private var cloudCard: some View {
        SettingsCard {
            HStack(spacing: 16) {
                IconTile(symbolName: cloudStatus.symbolName, color: cloudStatus.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Cloud")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text(cloudStatus.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cloudStatus.color)
                }
                
                Spacer(minLength: 16)
                
                HStack(spacing: 10) {
                    if !credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Remove") {
                            clearCredentials()
                        }
                        .controlSize(.regular)
                    }

                    Button(credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Set Up Google Cloud..." : "Manage Credentials...") {
                        isCredentialsSheetPresented = true
                    }
                    .controlSize(.regular)
                }
            }
        }
    }
    
    private func saveValidatedCredentials(_ newCredentials: String, voices: [TTSVoice]) {
        let trimmedCredentials = newCredentials.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials = trimmedCredentials
        isCredentialsSheetPresented = false
        GoogleTTSAPI.resetSharedInstance()
        applyVoices(voices)
        result = "Google Cloud connected. Ready to play."
    }

    private func clearCredentials() {
        credentials = ""
        GoogleTTSAPI.resetSharedInstance()
        api = nil
        availableVoices = []
        availableLanguages = []
        selectedVoice = nil
        result = ""
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
            api.fetchVoices { fetchResult in
                DispatchQueue.main.async {
                    switch fetchResult {
                    case .success(let voices):
                        if voices.isEmpty {
                            result = "Google Cloud connected, but no Text-to-Speech voices were returned. Try again in a moment."
                        } else {
                            applyVoices(voices)
                            result = "Success! Ready to play"
                        }
                    case .failure(let error):
                        self.availableVoices = []
                        self.availableLanguages = []
                        self.selectedVoice = nil
                        result = GoogleTTSError.userMessage(for: error)
                    }
                                        
                    isInitializing = false
                }
            }
        }
    }

    private func applyVoices(_ voices: [TTSVoice]) {
        let selectableVoices = voices.filter(isSelectableGoogleVoice).sorted(by: compareVoicesByCategory)
        availableVoices = selectableVoices
        
        let allLanguages = Set(selectableVoices.flatMap { $0.languageCodes })
        availableLanguages = Array(allLanguages).sorted()
        
        if selectedVoice == nil || !selectableVoices.contains(where: { $0.name == selectedVoice?.name }) {
            let savedVoiceName = Preferences.shared.voiceName
            if !savedVoiceName.isEmpty {
                selectedVoice = selectableVoices.first { $0.name == savedVoiceName }
                if let voice = selectedVoice {
                    selectedLanguage = voice.languageCodes.first ?? "en-US"
                }
            }
            
            if selectedVoice == nil, let firstVoice = selectableVoices.first {
                selectedVoice = firstVoice
                selectedLanguage = firstVoice.languageCodes.first ?? "en-US"
            }
            
            Preferences.shared.language = selectedLanguage
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct SettingsRow<Content: View>: View {
    let symbolName: String
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(spacing: 16) {
            IconTile(symbolName: symbolName, color: .primary)
            
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 160, alignment: .leading)
            
            content
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 44)
    }
}

private struct IconTile: View {
    let symbolName: String
    let color: Color
    
    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct PlaceholderValue: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
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
        HStack(spacing: 14) {
            Image(systemName: status.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, value: status.title)
                .frame(width: 38, height: 38)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(status.color)
                
                Text(status.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer(minLength: 16)
            
            WaveformView(color: status.color)
                .frame(width: 118, height: 30)
                .opacity(status.title == "Ready" ? 0.7 : 0.25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .stroke(color.opacity(0.52), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private enum CredentialSetupMode {
    case guided
    case automatic
    case importExisting
}

private enum CredentialValidationState {
    case idle
    case validating(String)
    case success(String)
    case failure(String)
}

private struct CredentialSetupStep: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let instructions: [String]
    let buttonTitle: String
    let url: URL

    static let defaults: [CredentialSetupStep] = [
        CredentialSetupStep(
            id: "project",
            title: "Create a Google Cloud project",
            subtitle: "Make a dedicated project for Smooth Talker.",
            instructions: [
                "Click \"Open Projects\".",
                "Press \"New Project\".",
                "Name the project \"Smooth Talker\".",
                "Click \"Create\".",
                "Return here after the project opens."
            ],
            buttonTitle: "Open Projects",
            url: URL(string: "https://console.cloud.google.com/projectselector2/home/dashboard")!
        ),
        CredentialSetupStep(
            id: "billing",
            title: "Enable billing",
            subtitle: "Google Cloud requires active billing before Text-to-Speech can run.",
            instructions: [
                "Click \"Open Billing\".",
                "Press \"Manage Billing\" if Google asks you to choose a billing page.",
                "Press \"Link Billing Account\".",
                "Add a payment method if prompted.",
                "Return here when the billing status says \"Active\"."
            ],
            buttonTitle: "Open Billing",
            url: URL(string: "https://console.cloud.google.com/billing")!
        ),
        CredentialSetupStep(
            id: "api",
            title: "Enable speech voices",
            subtitle: "Turn on the Cloud Text-to-Speech API for this project.",
            instructions: [
                "Click \"Open API\".",
                "Press the blue \"Enable\" button.",
                "Wait for the API dashboard to load.",
                "Return here afterward."
            ],
            buttonTitle: "Open API",
            url: URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!
        ),
        CredentialSetupStep(
            id: "service-account",
            title: "Create a key file",
            subtitle: "Download the JSON key Smooth Talker will use to talk to Google Cloud.",
            instructions: [
                "Click \"Open Credentials\".",
                "Press \"+ Create Credentials\".",
                "Select \"Service Account\".",
                "Continue through the service account setup.",
                "Open the \"Keys\" tab.",
                "Press \"Add Key\" and choose \"Create New Key\".",
                "Choose \"JSON\".",
                "The key file will download automatically.",
                "Drag the downloaded JSON file into Smooth Talker."
            ],
            buttonTitle: "Open Credentials",
            url: URL(string: "https://console.cloud.google.com/apis/credentials")!
        )
    ]
}

private struct CredentialsSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var automaticSetup = GoogleCloudRuntimeSetupModel()
    @State private var mode: CredentialSetupMode
    @State private var draftCredentials: String
    @State private var validationState: CredentialValidationState = .idle
    @State private var openedStepIDs: Set<String> = []
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @State private var importedFileName: String?
    let onSave: (String, [TTSVoice]) -> Void
    
    init(credentials: String, onSave: @escaping (String, [TTSVoice]) -> Void) {
        _draftCredentials = State(initialValue: credentials)
        _mode = State(initialValue: credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .guided : .importExisting)
        self.onSave = onSave
    }
    
    var body: some View {
        HStack(spacing: 0) {
            setupSidebar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch mode {
                    case .guided:
                        guidedSetupContent
                    case .automatic:
                        automaticSetupContent
                    case .importExisting:
                        importExistingContent
                    }

                    Divider()

                    footer
                }
                .padding(26)
            }
        }
        .frame(width: 860, height: 640)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    readCredentialsFile(url)
                }
            case .failure(let error):
                validationState = .failure(error.localizedDescription)
            }
        }
        .onChange(of: automaticSetup.generatedCredentialsJSON) { _, credentialsJSON in
            guard let credentialsJSON else { return }
            draftCredentials = credentialsJSON
            importedFileName = "Generated by Automatic Setup"
            validationState = .idle
            automaticSetup.resetGeneratedCredentials()
            validateAndConnect()
        }
    }

    private var setupSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Google Cloud")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text("Connect Smooth Talker to your own Text-to-Speech project.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)

            CredentialSetupModeButton(
                title: "Set Up Google Cloud",
                symbolName: "sparkles",
                isSelected: mode == .guided
            ) {
                mode = .guided
            }

            CredentialSetupModeButton(
                title: "Automatic Setup",
                symbolName: "wand.and.stars",
                isSelected: mode == .automatic
            ) {
                mode = .automatic
            }

            CredentialSetupModeButton(
                title: "Import Existing",
                symbolName: "doc.badge.plus",
                isSelected: mode == .importExisting
            ) {
                mode = .importExisting
            }

            Spacer()

            Text("Your credentials are saved locally in app settings after validation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var guidedSetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Google Cloud")
                    .font(.title2.bold())

                Text("Follow the steps in Google Cloud, download the service account JSON key, then drag it back here.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(CredentialSetupStep.defaults) { step in
                    CredentialSetupStepRow(
                        step: step,
                        isOpened: openedStepIDs.contains(step.id)
                    ) {
                        openedStepIDs.insert(step.id)
                        NSWorkspace.shared.open(step.url)
                    }
                }
            }

            credentialsImportArea(title: "Drop the downloaded JSON here")
        }
    }

    private var automaticSetupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            GoogleCloudAutomaticSetupPanel(model: automaticSetup)
            validationStatus
        }
    }

    private var importExistingContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Existing Credentials")
                    .font(.title2.bold())

                Text("Choose a service account JSON key you already downloaded from Google Cloud.")
                    .foregroundStyle(.secondary)
            }

            credentialsImportArea(title: "Drop your service account JSON here")
        }
    }

    private func credentialsImportArea(title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(spacing: 4) {
                    Text(importedFileName ?? title)
                        .font(.system(size: 17, weight: .semibold))

                    Text("Use the JSON key file downloaded from the service account Keys tab.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button("Choose JSON File...") {
                    isFileImporterPresented = true
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDropTargeted ? Color.orange.opacity(0.12) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isDropTargeted ? Color.orange : Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            .onDrop(of: [UTType.fileURL, .json, .plainText], isTargeted: $isDropTargeted, perform: handleDrop)

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste JSON")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextEditor(text: $draftCredentials)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .onChange(of: draftCredentials) {
                        importedFileName = nil
                        validationState = .idle
                    }
            }

            validationStatus
        }
    }

    @ViewBuilder
    private var validationStatus: some View {
        switch validationState {
        case .idle:
            EmptyView()
        case .validating(let message):
            Label(message, systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.system(size: 14, weight: .medium))
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14, weight: .medium))
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Validate and Connect") {
                validateAndConnect()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canValidate)
        }
    }

    private var canValidate: Bool {
        if case .validating = validationState {
            return false
        }

        return !draftCredentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validateAndConnect() {
        let trimmedCredentials = draftCredentials.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let info = try GoogleServiceAccountCredentials.validate(trimmedCredentials)
            validationState = .validating("Checking \(info.projectID) with Google Cloud...")
        } catch {
            validationState = .failure(error.localizedDescription)
            return
        }

        GoogleTTSAPI.resetSharedInstance()
        GoogleTTSAPI.getInstance(credentialsJson: trimmedCredentials) { api in
            api.fetchVoices { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let voices):
                        guard !voices.isEmpty else {
                            validationState = .failure("Google Cloud connected, but no Text-to-Speech voices were returned. Try again in a moment.")
                            GoogleTTSAPI.resetSharedInstance()
                            return
                        }

                        onSave(trimmedCredentials, voices)
                        validationState = .success("Connected to Google Cloud.")
                    case .failure(let error):
                        validationState = .failure(GoogleTTSError.userMessage(for: error))
                        GoogleTTSAPI.resetSharedInstance()
                    }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                readCredentialsFile(url)
            }
            return true
        }

        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            let typeIdentifier = textProvider.hasItemConformingToTypeIdentifier(UTType.json.identifier) ? UTType.json.identifier : UTType.plainText.identifier
            textProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data,
                      let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    draftCredentials = text
                    importedFileName = nil
                    validationState = .idle
                }
            }
            return true
        }

        return false
    }

    private func readCredentialsFile(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                DispatchQueue.main.async {
                    draftCredentials = text
                    importedFileName = url.lastPathComponent
                    validationState = .idle
                }
            } catch {
                DispatchQueue.main.async {
                    validationState = .failure(error.localizedDescription)
                }
            }
        }
    }
}

private struct CredentialSetupModeButton: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.orange : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct GoogleCloudAutomaticSetupPanel: View {
    @ObservedObject var model: GoogleCloudRuntimeSetupModel
    @State private var selectedBillingAccountID = ""
    @State private var selectedProjectID = ""
    @State private var isShowingTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automatic Google Cloud Setup")
                    .font(.title2.bold())

                Text("Let Smooth Talker sign into Google, configure Text-to-Speech, and create credentials automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusPanel
            actionPanel

            HStack(spacing: 10) {
                Button("Reset Automatic Setup") {
                    model.resetAutomaticSetup()
                }
                .controlSize(.regular)

                if model.failureReason == .runtimeBroken {
                    Button("Repair Automatic Setup") {
                        model.repairRuntime()
                    }
                    .controlSize(.regular)
                }
            }

            if !model.technicalDetails.isEmpty {
                technicalDetailsPanel
            }
        }
        .onChange(of: model.existingProjects) { _, projects in
            if selectedProjectID.isEmpty, let firstProject = projects.first {
                selectedProjectID = firstProject.id
            }
        }
        .onChange(of: model.billingAccounts) { _, accounts in
            if selectedBillingAccountID.isEmpty, let firstAccount = accounts.first {
                selectedBillingAccountID = firstAccount.id
            }
        }
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressIcon(stage: model.stage)

            VStack(alignment: .leading, spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))

                Text(model.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let projectID = model.projectID {
                    Text(projectID)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionPanel: some View {
        switch model.stage {
        case .idle:
            startButton
        case .ready:
            startButton
        case .choosingProject:
            VStack(alignment: .leading, spacing: 12) {
                Text("Create a new dedicated project, or use an existing Google Cloud project.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.existingProjects.isEmpty {
                    Picker("Existing Project", selection: $selectedProjectID) {
                        ForEach(model.existingProjects) { project in
                            Text(project.title).tag(project.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 10) {
                    Button("Create New Project") {
                        model.createNewProjectAndContinue()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    Button("Use Selected Project") {
                        guard let project = model.existingProjects.first(where: { $0.id == selectedProjectID }) else { return }
                        model.useExistingProject(project)
                    }
                    .controlSize(.large)
                    .disabled(selectedProjectID.isEmpty)
                }
            }
        case .waitingForBilling:
            VStack(alignment: .leading, spacing: 12) {
                Text("Add or activate a Google Cloud billing account in the browser. Leave this window open, then return here to continue.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Open Google Billing") {
                        model.openBillingConsole()
                    }
                    .controlSize(.large)

                    Button("Continue After Adding Billing") {
                        model.continueAfterAddingBilling()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
        case .choosingBilling:
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirm before linking billing to this project.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Billing Account", selection: $selectedBillingAccountID) {
                    ForEach(model.billingAccounts) { account in
                        Text(account.title).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Button("Link Billing and Continue") {
                    guard let account = model.billingAccounts.first(where: { $0.id == selectedBillingAccountID }) else { return }
                    model.useBillingAccount(account)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(selectedBillingAccountID.isEmpty)
            }
        case .failed:
            switch model.failureReason {
            case .runtimeBroken:
                HStack(spacing: 10) {
                    Button("Repair Automatic Setup") {
                        model.repairRuntime()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    Button("Reset Automatic Setup") {
                        model.resetAutomaticSetup()
                    }
                    .controlSize(.large)
                }
            case .billing:
                HStack(spacing: 10) {
                    Button("Open Google Billing") {
                        model.openBillingConsole()
                    }
                    .controlSize(.large)

                    Button("Continue After Adding Billing") {
                        model.continueAfterAddingBilling()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            default:
                Button("Try Again") {
                    model.startAutomaticSetup()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }

    private var startButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Google will ask you to sign in so Smooth Talker can configure a Text-to-Speech project in your account.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Start Automatic Setup") {
                model.startAutomaticSetup()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var technicalDetailsPanel: some View {
        DisclosureGroup("Technical Details", isExpanded: $isShowingTechnicalDetails) {
            ScrollView {
                Text(model.technicalDetails.suffix(32).joined(separator: "\n"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 170)
            .padding(10)
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

    private var statusTitle: String {
        switch model.stage {
        case .idle:
            return "Ready to start"
        case .validatingRuntime:
            return "Preparing setup"
        case .repairingRuntime:
            return "Repairing setup"
        case .ready:
            return "Ready to start"
        case .signingIn:
            return "Signing into Google"
        case .choosingProject:
            return "Choose project"
        case .creatingProject:
            return "Creating project"
        case .checkingBilling:
            return "Checking billing"
        case .waitingForBilling:
            return "Billing needed"
        case .choosingBilling:
            return "Choose billing"
        case .linkingBilling:
            return "Linking billing"
        case .enablingServices:
            return "Enabling APIs"
        case .creatingCredentials:
            return "Creating credentials"
        case .readyToValidate:
            return "Validating setup"
        case .failed:
            return "Setup needs attention"
        }
    }
}

private struct ProgressIcon: View {
    let stage: GoogleCloudRuntimeStage

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private var symbolName: String {
        switch stage {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .waitingForBilling:
            return "creditcard.fill"
        case .ready, .readyToValidate:
            return "checkmark.circle.fill"
        case let stage where stage.isBusy:
            return "arrow.triangle.2.circlepath"
        default:
            return "wand.and.stars"
        }
    }

    private var color: Color {
        switch stage {
        case .failed:
            return .red
        case .ready, .readyToValidate:
            return .green
        case .waitingForBilling, .choosingBilling, .choosingProject:
            return .orange
        default:
            return .secondary
        }
    }
}

private struct CredentialSetupStepRow: View {
    let step: CredentialSetupStep
    let isOpened: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isOpened ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOpened ? .green : .secondary)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 5) {
                    Text(step.title)
                        .font(.system(size: 17, weight: .semibold))

                    Text(step.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(step.buttonTitle) {
                    onOpen()
                }
                .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(step.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)

                        Text(instruction)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 40)
        }
        .padding(14)
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
            .shadow(color: .orange.opacity(configuration.isPressed ? 0.1 : 0.18), radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 3)
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
