import AppKit
import Foundation

struct GoogleCloudBillingAccount: Codable, Identifiable, Hashable {
    let name: String
    let displayName: String?
    let open: Bool?

    var id: String { billingAccountID }

    var billingAccountID: String {
        name.replacingOccurrences(of: "billingAccounts/", with: "")
    }

    var title: String {
        if let displayName, !displayName.isEmpty {
            return "\(displayName) (\(billingAccountID))"
        }

        return billingAccountID
    }
}

enum GoogleCloudCLIStage: Equatable {
    case idle
    case checkingCLI
    case needsInstall
    case ready
    case installing
    case authenticating
    case creatingProject
    case checkingBilling
    case waitingForBilling
    case choosingBilling
    case linkingBilling
    case enablingServices
    case creatingServiceAccount
    case creatingKey
    case readyToValidate
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checkingCLI, .installing, .authenticating, .creatingProject, .checkingBilling,
                .linkingBilling, .enablingServices, .creatingServiceAccount, .creatingKey:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class GoogleCloudCLISetupModel: ObservableObject {
    @Published private(set) var stage: GoogleCloudCLIStage = .idle
    @Published private(set) var statusMessage = "Smooth Talker can create a new Google Cloud project and service account for you."
    @Published private(set) var gcloudPath: String?
    @Published private(set) var projectID: String?
    @Published private(set) var billingAccounts: [GoogleCloudBillingAccount] = []
    @Published private(set) var generatedCredentialsJSON: String?
    @Published private(set) var logs: [String] = []

    private let fileManager = FileManager.default
    private var gcloudURL: URL?
    private var workTask: Task<Void, Never>?

    deinit {
        workTask?.cancel()
    }

    func checkForCLI() {
        run { [self] in
            await self.setStage(.checkingCLI, "Looking for Google Cloud CLI...")

            if let existingURL = self.findGcloud() {
                self.gcloudURL = existingURL
                self.gcloudPath = existingURL.path
                await self.setStage(.ready, "Google Cloud CLI is ready.")
                self.appendLog("Using gcloud at \(existingURL.path)")
            } else {
                await self.setStage(.needsInstall, "Google Cloud CLI is not installed. Smooth Talker can download it from Google.")
            }
        }
    }

    func installCLI() {
        run { [self] in
            await self.setStage(.installing, "Downloading Google Cloud CLI...")

            do {
                let installedURL = try await self.downloadAndInstallGcloud()
                self.gcloudURL = installedURL
                self.gcloudPath = installedURL.path
                self.appendLog("Installed gcloud at \(installedURL.path)")
                await self.setStage(.ready, "Google Cloud CLI is installed and ready.")
            } catch {
                await self.fail("Could not install Google Cloud CLI: \(error.localizedDescription)")
            }
        }
    }

    func startProvisioning() {
        run { [self] in
            do {
                try await self.requireGcloud()
                try await self.authenticate()
                try await self.createProject()
                try await self.discoverBillingAccounts()
            } catch {
                await self.fail(error.localizedDescription)
            }
        }
    }

    func openBillingConsole() {
        guard let url = URL(string: "https://console.cloud.google.com/billing") else { return }
        NSWorkspace.shared.open(url)
    }

    func openPythonDownload() {
        guard let url = URL(string: "https://www.python.org/downloads/macos/") else { return }
        NSWorkspace.shared.open(url)
    }

    var failedBecausePythonNeedsUpdate: Bool {
        guard case .failed(let message) = stage else { return false }
        return GoogleCloudCLIError.isUnsupportedPythonMessage(message)
    }

    func continueAfterAddingBilling() {
        run { [self] in
            do {
                try await self.discoverBillingAccounts()
            } catch {
                await self.fail(error.localizedDescription)
            }
        }
    }

    func useBillingAccount(_ account: GoogleCloudBillingAccount) {
        run { [self] in
            do {
                try await self.linkBilling(account)
                try await self.finishProvisioning()
            } catch {
                await self.fail(error.localizedDescription)
            }
        }
    }

    func resetGeneratedCredentials() {
        generatedCredentialsJSON = nil
    }

    private func run(_ operation: @escaping () async -> Void) {
        workTask?.cancel()
        workTask = Task {
            await operation()
        }
    }

    private func requireGcloud() async throws {
        if let gcloudURL {
            self.gcloudPath = gcloudURL.path
            return
        }

        if let existingURL = findGcloud() {
            gcloudURL = existingURL
            gcloudPath = existingURL.path
            return
        }

        await setStage(.needsInstall, "Google Cloud CLI is not installed.")
        throw GoogleCloudCLIError.gcloudMissing
    }

    private func authenticate() async throws {
        await setStage(.authenticating, "Opening Google sign-in...")
        _ = try await runGcloud(["auth", "login", "--brief"])
        appendLog("Google sign-in finished.")
    }

    private func createProject() async throws {
        let suffix = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        let newProjectID = "smooth-talker-tts-\(suffix)"
        projectID = newProjectID

        await setStage(.creatingProject, "Creating Google Cloud project \(newProjectID)...")
        _ = try await runGcloud([
            "projects",
            "create",
            newProjectID,
            "--name=Smooth Talker",
            "--quiet"
        ])
        appendLog("Created project \(newProjectID).")
    }

    private func discoverBillingAccounts() async throws {
        await setStage(.checkingBilling, "Checking available billing accounts...")
        let result = try await runGcloud(["billing", "accounts", "list", "--format=json", "--quiet"])
        let data = Data(result.output.utf8)
        let accounts = try JSONDecoder().decode([GoogleCloudBillingAccount].self, from: data)
            .filter { $0.open != false }

        billingAccounts = accounts

        switch accounts.count {
        case 0:
            await setStage(.waitingForBilling, "No active billing account was found. Add billing in Google Cloud, then continue here.")
        case 1:
            try await linkBilling(accounts[0])
            try await finishProvisioning()
        default:
            await setStage(.choosingBilling, "Choose the billing account Smooth Talker should link to this new project.")
        }
    }

    private func linkBilling(_ account: GoogleCloudBillingAccount) async throws {
        guard let projectID else {
            throw GoogleCloudCLIError.projectMissing
        }

        await setStage(.linkingBilling, "Linking billing account \(account.billingAccountID)...")
        _ = try await runGcloud([
            "billing",
            "projects",
            "link",
            projectID,
            "--billing-account=\(account.billingAccountID)",
            "--quiet"
        ])
        appendLog("Linked billing account \(account.billingAccountID).")
    }

    private func finishProvisioning() async throws {
        try await enableServices()
        try await createServiceAccount()
        try await createServiceAccountKey()
    }

    private func enableServices() async throws {
        guard let projectID else {
            throw GoogleCloudCLIError.projectMissing
        }

        await setStage(.enablingServices, "Enabling Google Cloud Text-to-Speech...")
        _ = try await runGcloud([
            "services",
            "enable",
            "serviceusage.googleapis.com",
            "iam.googleapis.com",
            "texttospeech.googleapis.com",
            "--project=\(projectID)",
            "--quiet"
        ])
        appendLog("Enabled required Google Cloud APIs.")
    }

    private func createServiceAccount() async throws {
        guard let projectID else {
            throw GoogleCloudCLIError.projectMissing
        }

        await setStage(.creatingServiceAccount, "Creating Smooth Talker service account...")
        _ = try await runGcloud([
            "iam",
            "service-accounts",
            "create",
            "smooth-talker-tts",
            "--display-name=Smooth Talker Text-to-Speech",
            "--project=\(projectID)",
            "--quiet"
        ])
        appendLog("Created service account smooth-talker-tts.")
    }

    private func createServiceAccountKey() async throws {
        guard let projectID else {
            throw GoogleCloudCLIError.projectMissing
        }

        await setStage(.creatingKey, "Creating service account JSON key...")
        let keyURL = try temporaryKeyURL()
        defer {
            try? fileManager.removeItem(at: keyURL)
        }

        _ = try await runGcloud([
            "iam",
            "service-accounts",
            "keys",
            "create",
            keyURL.path,
            "--iam-account=smooth-talker-tts@\(projectID).iam.gserviceaccount.com",
            "--project=\(projectID)",
            "--quiet"
        ])

        generatedCredentialsJSON = try String(contentsOf: keyURL, encoding: .utf8)
        appendLog("Created and imported service account key.")
        await setStage(.readyToValidate, "Service account key created. Smooth Talker is validating it now...")
    }

    private func runGcloud(_ arguments: [String]) async throws -> GoogleCloudCLICommandResult {
        guard let gcloudURL else {
            throw GoogleCloudCLIError.gcloudMissing
        }

        let environment = try commandEnvironment()
        appendLog("$ gcloud \(arguments.joined(separator: " "))")
        let result = try await GoogleCloudCLIProcess.run(executableURL: gcloudURL, arguments: arguments, environment: environment)

        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard result.exitCode == 0 else {
            throw GoogleCloudCLIError.commandFailed(result.combinedOutput)
        }

        return result
    }

    private func commandEnvironment() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let configURL = try cloudSDKConfigURL()
        environment["CLOUDSDK_CONFIG"] = configURL.path
        environment["PATH"] = [
            gcloudURL?.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
            .compactMap { $0 }
            .joined(separator: ":")
        return environment
    }

    private func findGcloud() -> URL? {
        let candidates = [
            appManagedGcloudURL(),
            URL(fileURLWithPath: "/opt/homebrew/bin/gcloud"),
            URL(fileURLWithPath: "/usr/local/bin/gcloud"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("google-cloud-sdk/bin/gcloud")
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func downloadAndInstallGcloud() async throws -> URL {
        let supportURL = try appSupportURL()
        let archive = gcloudArchiveDescriptor()
        let destinationURL = supportURL.appendingPathComponent(archive.fileName)

        try? fileManager.removeItem(at: destinationURL)
        let (downloadedURL, _) = try await URLSession.shared.download(from: archive.url)
        try fileManager.moveItem(at: downloadedURL, to: destinationURL)

        try? fileManager.removeItem(at: supportURL.appendingPathComponent("google-cloud-sdk"))
        _ = try await GoogleCloudCLIProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", destinationURL.path, "-C", supportURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        try? fileManager.removeItem(at: destinationURL)

        let gcloudURL = appManagedGcloudURL()
        guard fileManager.isExecutableFile(atPath: gcloudURL.path) else {
            throw GoogleCloudCLIError.installFailed
        }

        return gcloudURL
    }

    private func appSupportURL() throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = baseURL.appendingPathComponent("Smooth Talker/Google Cloud CLI", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cloudSDKConfigURL() throws -> URL {
        let url = try appSupportURL().appendingPathComponent("config", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appManagedGcloudURL() -> URL {
        let baseURL = try? appSupportURL()
        return (baseURL ?? fileManager.temporaryDirectory)
            .appendingPathComponent("google-cloud-sdk/bin/gcloud")
    }

    private func temporaryKeyURL() throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("SmoothTalkerGoogleCloud", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("smooth-talker-service-account-\(UUID().uuidString).json")
    }

    private func gcloudArchiveDescriptor() -> (fileName: String, url: URL) {
        #if arch(arm64)
        let fileName = "google-cloud-cli-darwin-arm.tar.gz"
        #else
        let fileName = "google-cloud-cli-darwin-x86_64.tar.gz"
        #endif

        return (
            fileName,
            URL(string: "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/\(fileName)")!
        )
    }

    private func setStage(_ stage: GoogleCloudCLIStage, _ message: String) async {
        self.stage = stage
        statusMessage = message
        appendLog(message)
    }

    private func fail(_ message: String) async {
        stage = .failed(message)
        statusMessage = message
        appendLog(message)
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }
}

private struct GoogleCloudCLICommandResult {
    let exitCode: Int32
    let output: String
    let error: String

    var combinedOutput: String {
        [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum GoogleCloudCLIProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> GoogleCloudCLICommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            return GoogleCloudCLICommandResult(
                exitCode: process.terminationStatus,
                output: String(data: outputData, encoding: .utf8) ?? "",
                error: String(data: errorData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

private enum GoogleCloudCLIError: LocalizedError {
    case gcloudMissing
    case projectMissing
    case installFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .gcloudMissing:
            return "Google Cloud CLI is not installed yet."
        case .projectMissing:
            return "Smooth Talker could not find the project it just created."
        case .installFailed:
            return "The Google Cloud CLI archive was downloaded, but the gcloud executable was not found after extraction."
        case .commandFailed(let output):
            if output.isEmpty {
                return "A Google Cloud CLI command failed."
            }

            if Self.isUnsupportedPythonMessage(output) {
                return """
                Google Cloud CLI needs a newer Python version.

                Smooth Talker found Python 3.9, but Google Cloud CLI now requires Python 3.10 through 3.14. Install the latest Python for macOS, then come back and click Try Again.

                https://www.python.org/downloads/macos/
                """
            }

            return output
        }
    }

    static func isUnsupportedPythonMessage(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("running gcloud with python 3.9") ||
            normalizedMessage.contains("no longer supported by gcloud") ||
            normalizedMessage.contains("install a compatible version of python 3.10-3.14")
    }
}
