import AppKit
import CryptoKit
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

struct GoogleCloudProject: Codable, Identifiable, Hashable {
    let projectId: String
    let name: String?
    let lifecycleState: String?

    var id: String { projectId }

    var title: String {
        if let name, !name.isEmpty, name != projectId {
            return "\(name) (\(projectId))"
        }

        return projectId
    }
}

enum GoogleCloudRuntimeStage: Equatable {
    case idle
    case validatingRuntime
    case repairingRuntime
    case ready
    case signingIn
    case choosingProject
    case creatingProject
    case checkingBilling
    case choosingBilling
    case waitingForBilling
    case linkingBilling
    case enablingServices
    case creatingCredentials
    case readyToValidate
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .validatingRuntime, .repairingRuntime, .signingIn, .creatingProject,
                .checkingBilling, .linkingBilling, .enablingServices, .creatingCredentials:
            return true
        default:
            return false
        }
    }
}

enum GoogleCloudRuntimeFailureReason {
    case runtimeBroken
    case loginCanceled
    case billing
    case apiEnable
    case keyCreationBlocked
    case other
}

@MainActor
final class GoogleCloudRuntimeSetupModel: ObservableObject {
    @Published private(set) var stage: GoogleCloudRuntimeStage = .idle
    @Published private(set) var statusMessage = "Smooth Talker can configure Google Cloud automatically."
    @Published private(set) var technicalDetails: [String] = []
    @Published private(set) var failureReason: GoogleCloudRuntimeFailureReason?
    @Published private(set) var projectID: String?
    @Published private(set) var existingProjects: [GoogleCloudProject] = []
    @Published private(set) var billingAccounts: [GoogleCloudBillingAccount] = []
    @Published private(set) var generatedCredentialsJSON: String?

    private let runtime = GoogleCloudRuntimeManager()
    private var workTask: Task<Void, Never>?

    deinit {
        workTask?.cancel()
    }

    func startAutomaticSetup() {
        run { [self] in
            do {
                self.resetFailure()
                try await self.ensureRuntime()
                try await self.signIn()
                try await self.discoverProjects()
            } catch {
                await self.fail(error)
            }
        }
    }

    func createNewProjectAndContinue() {
        run { [self] in
            do {
                self.resetFailure()
                try await self.createProject()
                try await self.discoverBillingAccounts()
            } catch {
                await self.fail(error)
            }
        }
    }

    func useExistingProject(_ project: GoogleCloudProject) {
        run { [self] in
            do {
                self.resetFailure()
                self.projectID = project.projectId
                self.appendDetail("Selected project \(project.projectId).")
                try await self.discoverBillingAccounts()
            } catch {
                await self.fail(error)
            }
        }
    }

    func useBillingAccount(_ account: GoogleCloudBillingAccount) {
        run { [self] in
            do {
                self.resetFailure()
                try await self.linkBilling(account)
                try await self.finishProvisioning()
            } catch {
                await self.fail(error)
            }
        }
    }

    func continueAfterAddingBilling() {
        run { [self] in
            do {
                self.resetFailure()
                try await self.discoverBillingAccounts()
            } catch {
                await self.fail(error)
            }
        }
    }

    func repairRuntime() {
        run { [self] in
            do {
                self.resetFailure()
                await self.setStage(.repairingRuntime, "Repairing automatic setup...")
                try self.runtime.resetRuntime()
                try await self.ensureRuntime()
            } catch {
                await self.fail(error)
            }
        }
    }

    func resetAutomaticSetup() {
        run { [self] in
            do {
                self.resetFailure()
                try self.runtime.resetConfig()
                self.projectID = nil
                self.billingAccounts = []
                self.existingProjects = []
                await self.setStage(.idle, "Automatic setup has been reset.")
            } catch {
                await self.fail(error)
            }
        }
    }

    func openBillingConsole() {
        guard let url = URL(string: "https://console.cloud.google.com/billing") else { return }
        NSWorkspace.shared.open(url)
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

    private func ensureRuntime() async throws {
        await setStage(.validatingRuntime, "Preparing automatic setup...")
        try await runtime.installOrValidateRuntime { [weak self] detail in
            Task { @MainActor in
                self?.appendDetail(detail)
            }
        }
        await setStage(.ready, "Automatic setup is ready.")
    }

    private func signIn() async throws {
        await setStage(.signingIn, "Signing into Google...")
        _ = try await runCommand(["auth", "login", "--brief"])
        appendDetail("Google sign-in finished.")
    }

    private func discoverProjects() async throws {
        let result = try await runCommand(["projects", "list", "--format=json", "--quiet"])
        let data = Data(result.output.utf8)
        let projects = (try? JSONDecoder().decode([GoogleCloudProject].self, from: data)) ?? []
        existingProjects = projects.filter { $0.lifecycleState != "DELETE_REQUESTED" }

        if existingProjects.isEmpty {
            try await createProject()
            try await discoverBillingAccounts()
        } else {
            await setStage(.choosingProject, "Choose whether to create a new project or use an existing one.")
        }
    }

    private func createProject() async throws {
        let suffix = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        let newProjectID = "smooth-talker-tts-\(suffix)"
        projectID = newProjectID

        await setStage(.creatingProject, "Creating project...")
        _ = try await runCommand([
            "projects",
            "create",
            newProjectID,
            "--name=Smooth Talker",
            "--quiet"
        ])
        appendDetail("Created project \(newProjectID).")
    }

    private func discoverBillingAccounts() async throws {
        await setStage(.checkingBilling, "Checking billing...")
        let result = try await runCommand(["billing", "accounts", "list", "--format=json", "--quiet"])
        let data = Data(result.output.utf8)
        let accounts = (try? JSONDecoder().decode([GoogleCloudBillingAccount].self, from: data)) ?? []
        billingAccounts = accounts.filter { $0.open != false }

        switch billingAccounts.count {
        case 0:
            await setStage(.waitingForBilling, "Add or activate Google Cloud billing, then continue here.")
        case 1:
            await setStage(.choosingBilling, "Confirm the billing account to use for this project.")
        default:
            await setStage(.choosingBilling, "Choose the billing account to use for this project.")
        }
    }

    private func linkBilling(_ account: GoogleCloudBillingAccount) async throws {
        guard let projectID else {
            throw GoogleCloudRuntimeError.projectMissing
        }

        await setStage(.linkingBilling, "Linking billing...")
        _ = try await runCommand([
            "billing",
            "projects",
            "link",
            projectID,
            "--billing-account=\(account.billingAccountID)",
            "--quiet"
        ])
        appendDetail("Linked billing account \(account.billingAccountID).")
    }

    private func finishProvisioning() async throws {
        try await enableServices()
        try await createOrReuseServiceAccount()
        try await createServiceAccountKey()
    }

    private func enableServices() async throws {
        guard let projectID else {
            throw GoogleCloudRuntimeError.projectMissing
        }

        await setStage(.enablingServices, "Enabling APIs...")
        _ = try await runCommand([
            "services",
            "enable",
            "serviceusage.googleapis.com",
            "iam.googleapis.com",
            "texttospeech.googleapis.com",
            "--project=\(projectID)",
            "--quiet"
        ])
        appendDetail("Enabled required Google Cloud APIs.")
    }

    private func createOrReuseServiceAccount() async throws {
        guard let projectID else {
            throw GoogleCloudRuntimeError.projectMissing
        }

        await setStage(.creatingCredentials, "Creating credentials...")
        let email = "smooth-talker-tts@\(projectID).iam.gserviceaccount.com"
        let describeResult = try await runCommand([
            "iam",
            "service-accounts",
            "describe",
            email,
            "--project=\(projectID)",
            "--format=json",
            "--quiet"
        ], allowFailure: true)

        if describeResult.exitCode == 0 {
            appendDetail("Reusing service account smooth-talker-tts.")
            return
        }

        _ = try await runCommand([
            "iam",
            "service-accounts",
            "create",
            "smooth-talker-tts",
            "--display-name=Smooth Talker Text-to-Speech",
            "--project=\(projectID)",
            "--quiet"
        ])
        appendDetail("Created service account smooth-talker-tts.")
    }

    private func createServiceAccountKey() async throws {
        guard let projectID else {
            throw GoogleCloudRuntimeError.projectMissing
        }

        await setStage(.creatingCredentials, "Creating credentials...")
        let keyURL = try runtime.temporaryKeyURL()
        defer {
            try? FileManager.default.removeItem(at: keyURL)
        }

        _ = try await runCommand([
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
        appendDetail("Created and imported service account key.")
        await setStage(.readyToValidate, "Validating setup...")
    }

    private func runCommand(_ arguments: [String], allowFailure: Bool = false) async throws -> GoogleCloudRuntimeCommandResult {
        let result = try await runtime.run(arguments: arguments)
        appendDetail("$ \(arguments.joined(separator: " "))")

        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendDetail(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendDetail(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if result.exitCode != 0, !allowFailure {
            throw GoogleCloudRuntimeError.commandFailed(result.combinedOutput)
        }

        return result
    }

    private func setStage(_ stage: GoogleCloudRuntimeStage, _ message: String) async {
        self.stage = stage
        statusMessage = message
        appendDetail(message)
    }

    private func fail(_ error: Error) async {
        let message = GoogleCloudRuntimeError.userMessage(for: error)
        failureReason = GoogleCloudRuntimeError.failureReason(for: error, message: message)
        stage = .failed(message)
        statusMessage = message
        appendDetail(message)
    }

    private func resetFailure() {
        failureReason = nil
    }

    private func appendDetail(_ line: String) {
        technicalDetails.append(line)
        if technicalDetails.count > 160 {
            technicalDetails.removeFirst(technicalDetails.count - 160)
        }
    }
}

final class GoogleCloudRuntimeManager {
    private let fileManager = FileManager.default

    private var runtimeRootURL: URL {
        applicationSupportURL.appendingPathComponent("GoogleCloudRuntime", isDirectory: true)
    }

    private var configURL: URL {
        applicationSupportURL.appendingPathComponent("GoogleCloudConfig", isDirectory: true)
    }

    private var gcloudURL: URL {
        runtimeRootURL.appendingPathComponent("google-cloud-sdk/bin/gcloud")
    }

    private var pythonURL: URL {
        runtimeRootURL.appendingPathComponent("python/bin/python3")
    }

    private var applicationSupportURL: URL {
        let baseURL = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("Smooth Talker", isDirectory: true)
    }

    func installOrValidateRuntime(log: (String) -> Void) async throws {
        try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configURL, withIntermediateDirectories: true)

        if fileManager.isExecutableFile(atPath: gcloudURL.path),
           fileManager.isExecutableFile(atPath: pythonURL.path),
           try await validateRuntime(log: log) {
            return
        }

        try installRuntimeAssets(log: log)

        guard try await validateRuntime(log: log) else {
            throw GoogleCloudRuntimeError.runtimeBroken("Automatic setup could not validate its private runtime after repair.")
        }
    }

    func resetRuntime() throws {
        try? fileManager.removeItem(at: runtimeRootURL)
    }

    func resetConfig() throws {
        try? fileManager.removeItem(at: configURL)
        try fileManager.createDirectory(at: configURL, withIntermediateDirectories: true)
    }

    func temporaryKeyURL() throws -> URL {
        let directoryURL = applicationSupportURL.appendingPathComponent("TemporaryKeys", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("smooth-talker-service-account-\(UUID().uuidString).json")
    }

    func run(arguments: [String]) async throws -> GoogleCloudRuntimeCommandResult {
        guard fileManager.isExecutableFile(atPath: gcloudURL.path),
              fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw GoogleCloudRuntimeError.runtimeBroken("Automatic setup runtime is missing required executables.")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CLOUDSDK_PYTHON"] = pythonURL.path
        environment["CLOUDSDK_GSUTIL_PYTHON"] = pythonURL.path
        environment["CLOUDSDK_BQ_PYTHON"] = pythonURL.path
        environment["CLOUDSDK_CONFIG"] = configURL.path
        environment["PATH"] = [
            gcloudURL.deletingLastPathComponent().path,
            pythonURL.deletingLastPathComponent().path,
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")

        return try await GoogleCloudRuntimeProcess.run(
            executableURL: gcloudURL,
            arguments: arguments,
            environment: environment
        )
    }

    private func installRuntimeAssets(log: (String) -> Void) throws {
        guard let manifest = GoogleCloudRuntimeManifest.load() else {
            throw GoogleCloudRuntimeError.runtimeBroken("Automatic setup runtime assets are not bundled with this build.")
        }

        try? fileManager.removeItem(at: runtimeRootURL)
        try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)

        for asset in manifest.assets {
            guard let assetURL = asset.bundleURL else {
                throw GoogleCloudRuntimeError.runtimeBroken("Missing bundled runtime asset: \(asset.fileName).")
            }

            let actualChecksum = try sha256Hex(for: assetURL)
            guard actualChecksum == asset.sha256.lowercased() else {
                throw GoogleCloudRuntimeError.runtimeBroken("Bundled runtime asset failed integrity check: \(asset.fileName).")
            }

            log("Expanding runtime asset \(asset.fileName).")
            try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)

            let result = try GoogleCloudRuntimeProcess.runSync(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", assetURL.path, "-C", runtimeRootURL.path],
                environment: ProcessInfo.processInfo.environment
            )

            guard result.exitCode == 0 else {
                throw GoogleCloudRuntimeError.runtimeBroken(result.combinedOutput)
            }
        }

        clearRuntimeLaunchAttributes()
    }

    private func clearRuntimeLaunchAttributes() {
        let environment = ProcessInfo.processInfo.environment
        let xattrURL = URL(fileURLWithPath: "/usr/bin/xattr")

        _ = try? GoogleCloudRuntimeProcess.runSync(
            executableURL: xattrURL,
            arguments: ["-dr", "com.apple.quarantine", runtimeRootURL.path],
            environment: environment
        )

        _ = try? GoogleCloudRuntimeProcess.runSync(
            executableURL: xattrURL,
            arguments: ["-dr", "com.apple.provenance", runtimeRootURL.path],
            environment: environment
        )
    }

    private func validateRuntime(log: (String) -> Void) async throws -> Bool {
        let pythonResult = try await GoogleCloudRuntimeProcess.run(
            executableURL: pythonURL,
            arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment
        )
        let pythonVersion = (pythonResult.output + pythonResult.error).trimmingCharacters(in: .whitespacesAndNewlines)
        log(pythonVersion)

        guard pythonResult.exitCode == 0,
              isSupportedPythonVersion(pythonVersion) else {
            throw GoogleCloudRuntimeError.runtimeBroken("Automatic setup runtime has an incompatible Python runtime.")
        }

        let versionResult = try await run(arguments: ["--version"])
        log(versionResult.combinedOutput)
        return versionResult.exitCode == 0
    }

    private func isSupportedPythonVersion(_ version: String) -> Bool {
        guard let match = version.range(of: #"Python 3\.(1[0-4])"#, options: .regularExpression) else {
            return false
        }
        return !version[match].isEmpty
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct GoogleCloudRuntimeCommandResult {
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

private enum GoogleCloudRuntimeProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> GoogleCloudRuntimeCommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executableURL: executableURL, arguments: arguments, environment: environment)
        }.value
    }

    static func runSync(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> GoogleCloudRuntimeCommandResult {
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

        return GoogleCloudRuntimeCommandResult(
            exitCode: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

private struct GoogleCloudRuntimeManifest: Decodable {
    let assets: [GoogleCloudRuntimeAsset]

    static func load() -> GoogleCloudRuntimeManifest? {
        let bundledURL = Bundle.main.url(
            forResource: "runtime-manifest",
            withExtension: "json",
            subdirectory: "GoogleCloudRuntime"
        ) ?? Bundle.main.url(
            forResource: "runtime-manifest",
            withExtension: "json"
        )

        guard let url = bundledURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(GoogleCloudRuntimeManifest.self, from: data)
    }
}

private struct GoogleCloudRuntimeAsset: Decodable {
    enum Kind: String, Decodable {
        case gcloud
        case python
    }

    let fileName: String
    let sha256: String
    let kind: Kind

    var resourceName: String {
        (fileName as NSString).deletingPathExtension.replacingOccurrences(of: ".tar", with: "")
    }

    var resourceExtension: String {
        fileName.hasSuffix(".tar.gz") ? "tar.gz" : (fileName as NSString).pathExtension
    }

    var bundleURL: URL? {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: "GoogleCloudRuntime"
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        )
    }
}

enum GoogleCloudRuntimeError: LocalizedError {
    case runtimeBroken(String)
    case projectMissing
    case commandFailed(String)

    var errorDescription: String? {
        Self.userMessage(for: self)
    }

    static func userMessage(for error: Error) -> String {
        guard let runtimeError = error as? GoogleCloudRuntimeError else {
            return error.localizedDescription
        }

        switch runtimeError {
        case .runtimeBroken:
            return "Automatic setup needs to repair its private runtime before continuing."
        case .projectMissing:
            return "Smooth Talker could not find the Google Cloud project selected for setup."
        case .commandFailed(let output):
            return userMessage(forCommandOutput: output)
        }
    }

    static func failureReason(for error: Error, message: String) -> GoogleCloudRuntimeFailureReason {
        if case .runtimeBroken = error as? GoogleCloudRuntimeError {
            return .runtimeBroken
        }

        let searchable = message.lowercased()
        if searchable.contains("billing") {
            return .billing
        }
        if searchable.contains("cancel") || searchable.contains("login") {
            return .loginCanceled
        }
        if searchable.contains("api") || searchable.contains("serviceusage") || searchable.contains("enable") {
            return .apiEnable
        }
        if searchable.contains("key creation") || searchable.contains("disable service account key") {
            return .keyCreationBlocked
        }

        return .other
    }

    private static func userMessage(forCommandOutput output: String) -> String {
        let searchable = output.lowercased()

        if searchable.contains("cancel") || searchable.contains("login") {
            return "Google sign-in did not finish. Try signing in again."
        }

        if searchable.contains("billing") {
            return "Google Cloud billing needs attention before setup can continue."
        }

        if searchable.contains("serviceusage") || searchable.contains("enable") {
            return "Smooth Talker could not enable the required Google Cloud APIs."
        }

        if searchable.contains("disable service account key") ||
            searchable.contains("service account key creation") ||
            searchable.contains("key creation") {
            return "This Google Cloud account blocks service account key creation."
        }

        if searchable.contains("permission") || searchable.contains("forbidden") {
            return "This Google account does not have permission to complete automatic setup."
        }

        return "Automatic setup could not finish. Try again or use manual setup."
    }
}
