//
//  ContentView.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var purchaseManager = PurchaseManager.shared
    @State private var credentials = Preferences.shared.credentials
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
    @State private var isUnlockSheetPresented = false
    @State private var pendingLockedVoice: TTSVoice?
    @State private var deferredPremiumVoiceName: String?

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
        let selectedVoiceCanPlay = selectedVoice.map { !isVoiceLocked($0) } ?? false
        return !credentials.isEmpty && !inputText.isEmpty && !isLoading && !isInitializing && selectedVoiceCanPlay
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
            CredentialsSetupSheet { newCredentials, voices in
                saveValidatedCredentials(newCredentials, voices: voices)
            }
        }
        .sheet(isPresented: $isUnlockSheetPresented) {
            PremiumVoicesUnlockSheet(
                purchaseManager: purchaseManager,
                lockedVoice: pendingLockedVoice
            ) {
                selectPendingLockedVoiceIfUnlocked()
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
        .task {
            await purchaseManager.start()
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
        .onChange(of: selectedVoice) { oldValue, newValue in
            if let voice = newValue, isVoiceLocked(voice) {
                pendingLockedVoice = voice
                isUnlockSheetPresented = true
                selectedVoice = oldValue.flatMap { isVoiceLocked($0) ? nil : $0 } ?? firstAccessibleVoice()
                return
            }

            Preferences.shared.voiceName = newValue?.name ?? ""
            Preferences.shared.language = newValue?.languageCodes.first ?? "unknown"
        }
        .onChange(of: purchaseManager.hasPremiumVoices) { _, hasPremiumVoices in
            if hasPremiumVoices {
                selectDeferredPremiumVoiceIfAvailable()
                selectPendingLockedVoiceIfUnlocked()
            } else {
                ensureSelectedVoiceIsAccessible()
            }
        }
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
                            selectedVoice = firstAccessibleVoice(in: filteredVoices)
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
                                        Text(voiceMenuTitle(for: voice)).tag(voice as TTSVoice?)
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
        Preferences.shared.credentials = trimmedCredentials
        credentials = trimmedCredentials
        isCredentialsSheetPresented = false
        GoogleTTSAPI.resetSharedInstance()
        applyVoices(voices)
        result = "Google Cloud connected. Ready to play."
    }

    private func clearCredentials() {
        Preferences.shared.credentials = ""
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

        if selectedVoice == nil ||
            !selectableVoices.contains(where: { $0.name == selectedVoice?.name }) ||
            selectedVoice.map(isVoiceLocked) == true {
            let savedVoiceName = Preferences.shared.voiceName
            if !savedVoiceName.isEmpty {
                if let savedVoice = selectableVoices.first(where: { $0.name == savedVoiceName }) {
                    if isVoiceLocked(savedVoice) {
                        deferredPremiumVoiceName = savedVoice.name
                        selectedLanguage = savedVoice.languageCodes.first ?? selectedLanguage
                    } else {
                        selectedVoice = savedVoice
                    }
                }

                if let voice = selectedVoice {
                    selectedLanguage = voice.languageCodes.first ?? "en-US"
                }
            }

            if selectedVoice == nil, let firstVoice = firstAccessibleVoice() {
                selectedVoice = firstVoice
                selectedLanguage = firstVoice.languageCodes.first ?? "en-US"
            }

            Preferences.shared.language = selectedLanguage
        }
    }

    private func isSelectableGoogleVoice(_ voice: TTSVoice) -> Bool {
        voice.name.range(of: #"^[a-z]{2,3}-[A-Z]{2}-"#, options: .regularExpression) != nil
    }

    private func voiceMenuTitle(for voice: TTSVoice) -> String {
        if isVoiceLocked(voice) {
            return "\(voice.displayName) (Locked)"
        }

        return voice.displayName
    }

    private func isVoiceLocked(_ voice: TTSVoice) -> Bool {
        VoiceCategory(for: voice.name).requiresPremiumUnlock && !purchaseManager.hasPremiumVoices
    }

    private func firstAccessibleVoice(in voices: [TTSVoice]? = nil) -> TTSVoice? {
        let candidates = voices ?? filteredVoices
        return candidates.first { !isVoiceLocked($0) } ?? availableVoices.first { !isVoiceLocked($0) }
    }

    private func ensureSelectedVoiceIsAccessible() {
        if let selectedVoice, isVoiceLocked(selectedVoice) {
            self.selectedVoice = firstAccessibleVoice()
        } else if selectedVoice == nil {
            selectedVoice = firstAccessibleVoice()
        }
    }

    private func selectDeferredPremiumVoiceIfAvailable() {
        guard let deferredPremiumVoiceName,
              let voice = availableVoices.first(where: { $0.name == deferredPremiumVoiceName }),
              !isVoiceLocked(voice) else {
            return
        }

        self.deferredPremiumVoiceName = nil
        selectedVoice = voice
        selectedLanguage = voice.languageCodes.first ?? selectedLanguage
    }

    private func selectPendingLockedVoiceIfUnlocked() {
        guard purchaseManager.hasPremiumVoices,
              let voice = pendingLockedVoice else {
            return
        }

        pendingLockedVoice = nil
        isUnlockSheetPresented = false
        selectedVoice = voice
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

private struct PremiumVoicesUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var purchaseManager: PurchaseManager

    let lockedVoice: TTSVoice?
    let onUnlocked: () -> Void

    private var priceText: String {
        purchaseManager.premiumVoicesProduct?.displayPrice ?? "one-time purchase"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(symbolName: "lock.open.fill", color: .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Premium Voices")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text(lockedVoice?.displayName ?? "Premium Google voices")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Standard and WaveNet voices are free. Unlock Casual, Neural2, News, Polyglot, Chirp HD, Chirp3 HD, Studio, and other premium voices forever for \(priceText).")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let statusMessage = purchaseManager.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Label("Not Now", systemImage: "xmark")
                }
                .controlSize(.large)

                Spacer()

                Button {
                    Task {
                        await purchaseManager.restorePurchases()
                        if purchaseManager.hasPremiumVoices {
                            onUnlocked()
                            dismiss()
                        }
                    }
                } label: {
                    Label("Restore", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .disabled(purchaseManager.isLoading)

                Button {
                    Task {
                        await purchaseManager.purchasePremiumVoices()
                        if purchaseManager.hasPremiumVoices {
                            onUnlocked()
                            dismiss()
                        }
                    }
                } label: {
                    Label("Buy \(priceText)", systemImage: "cart.fill")
                }
                .buttonStyle(OrangeProminentButtonStyle())
                .controlSize(.large)
                .disabled(purchaseManager.isLoading)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            purchaseManager.clearStatusMessage()
        }
        .onChange(of: purchaseManager.hasPremiumVoices) { _, hasPremiumVoices in
            guard hasPremiumVoices else { return }
            onUnlocked()
            dismiss()
        }
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

private enum CredentialValidationState {
    case idle
    case validating(String)
    case success(String)
    case failure(String)
}

private struct CredentialsSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var automaticSetup = GoogleCloudSetupModel()
    @State private var validationState: CredentialValidationState = .idle
    let onSave: (String, [TTSVoice]) -> Void

    init(onSave: @escaping (String, [TTSVoice]) -> Void) {
        self.onSave = onSave
    }

    var body: some View {
        HStack(spacing: 0) {
            setupIntro

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    automaticSetupContent

                    Divider()

                    footer
                }
                .padding(26)
            }
        }
        .frame(width: 860, height: 640)
        .onChange(of: automaticSetup.generatedCredentialsJSON) { _, credentialsJSON in
            guard let credentialsJSON else { return }
            automaticSetup.resetGeneratedCredentials()
            validateAndConnect(credentialsJSON)
        }
    }

    private var setupIntro: some View {
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

            Label("Automatic setup", systemImage: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange)
                )

            Spacer()

            Text("Smooth Talker creates and saves credentials automatically after validation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var automaticSetupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            GoogleCloudAutomaticSetupPanel(model: automaticSetup)
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
        }
    }

    private func validateAndConnect(_ credentialsJSON: String) {
        let trimmedCredentials = credentialsJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let info = try GoogleServiceAccountCredentials.validate(trimmedCredentials)
            validationState = .validating("Finalizing Google Cloud setup for \(info.projectID)...")
        } catch {
            validationState = .failure(error.localizedDescription)
            return
        }

        fetchVoicesWithRetry(credentialsJSON: trimmedCredentials, attempt: 1)
    }

    private func fetchVoicesWithRetry(credentialsJSON: String, attempt: Int) {
        GoogleTTSAPI.resetSharedInstance()
        GoogleTTSAPI.getInstance(credentialsJson: credentialsJSON) { api in
            api.fetchVoices { result in
                DispatchQueue.main.async {
                    handleVoiceValidationResult(result, credentialsJSON: credentialsJSON, attempt: attempt)
                }
            }
        }
    }

    private func handleVoiceValidationResult(_ result: Result<[TTSVoice], Error>, credentialsJSON: String, attempt: Int) {
        switch result {
        case .success(let voices):
            guard !voices.isEmpty else {
                retryOrFail(
                    credentialsJSON: credentialsJSON,
                    attempt: attempt,
                    message: "Google Cloud connected, but voices are still loading. Trying again..."
                )
                return
            }

            onSave(credentialsJSON, voices)
            validationState = .success("Connected to Google Cloud.")
        case .failure(let error):
            if shouldRetryValidation(error), attempt < 5 {
                retryOrFail(
                    credentialsJSON: credentialsJSON,
                    attempt: attempt,
                    message: "Google Cloud is finishing setup. Trying again..."
                )
            } else {
                validationState = .failure(GoogleTTSError.userMessage(for: error))
                GoogleTTSAPI.resetSharedInstance()
            }
        }
    }

    private func retryOrFail(credentialsJSON: String, attempt: Int, message: String) {
        guard attempt < 5 else {
            validationState = .failure("Google Cloud connected, but no Text-to-Speech voices were returned. Try again in a moment.")
            GoogleTTSAPI.resetSharedInstance()
            return
        }

        validationState = .validating(message)
        let delay = DispatchTime.now() + .seconds(attempt * 2)
        DispatchQueue.main.asyncAfter(deadline: delay) {
            fetchVoicesWithRetry(credentialsJSON: credentialsJSON, attempt: attempt + 1)
        }
    }

    private func shouldRetryValidation(_ error: Error) -> Bool {
        if let googleError = error as? GoogleTTSError {
            switch googleError {
            case .httpError(let code, let body):
                let searchable = body?.lowercased() ?? ""
                return code == 403 ||
                    code == 404 ||
                    code == 429 ||
                    (500...599).contains(code) ||
                    searchable.contains("disabled") ||
                    searchable.contains("not been used") ||
                    searchable.contains("billing") ||
                    searchable.contains("permission")
            case .noToken, .invalidResponse, .noData:
                return true
            default:
                return false
            }
        }

        if let urlError = error as? URLError {
            return urlError.code == .timedOut ||
                urlError.code == .cannotFindHost ||
                urlError.code == .cannotConnectToHost ||
                urlError.code == .networkConnectionLost
        }

        return false
    }
}

private struct GoogleCloudAutomaticSetupPanel: View {
    @ObservedObject var model: GoogleCloudSetupModel
    @State private var selectedBillingAccountID = ""
    @State private var selectedProjectID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automatic Setup")
                    .font(.title2.bold())

                Text("Let Smooth Talker sign into Google, configure Text-to-Speech, and create credentials automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusPanel
            actionPanel
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
                Text("Link billing to this project in Google Cloud. Leave this window open, then retry the billing check.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Link Billing Manually") {
                        model.openProjectBillingConsole()
                    }
                    .controlSize(.large)

                    Button("Retry Billing Check") {
                        model.retryBillingCheckAndContinue()
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
            case .missingConfig:
                Button("Try Again") {
                    model.startAutomaticSetup()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            case .billing:
                HStack(spacing: 10) {
                    Button("Link Billing Manually") {
                        model.openProjectBillingConsole()
                    }
                    .controlSize(.large)

                    Button("Retry Billing Check") {
                        model.retryBillingCheckAndContinue()
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

    private var statusTitle: String {
        switch model.stage {
        case .idle:
            return "Ready to start"
        case .signingIn:
            return "Signing into Google"
        case .loadingProjects:
            return "Loading projects"
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
            if model.failureReason == .missingConfig {
                return "Automatic Setup Not Configured"
            }
            return "Setup needs attention"
        }
    }
}

private struct ProgressIcon: View {
    let stage: GoogleCloudSetupStage

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
        case .readyToValidate:
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
        case .readyToValidate:
            return .green
        case .waitingForBilling, .choosingBilling, .choosingProject:
            return .orange
        default:
            return .secondary
        }
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

enum VoiceCategory: Int, CaseIterable {
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

    var isFree: Bool {
        self == .standard || self == .waveNet
    }

    var requiresPremiumUnlock: Bool {
        !isFree
    }
}

#Preview {
    ContentView()
}
