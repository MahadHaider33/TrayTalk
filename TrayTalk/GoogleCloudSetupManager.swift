import AppKit
import AuthenticationServices
import CryptoKit
import Darwin
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

enum GoogleCloudSetupStage: Equatable {
    case idle
    case signingIn
    case loadingProjects
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
        case .signingIn, .loadingProjects, .creatingProject, .checkingBilling, .linkingBilling, .enablingServices, .creatingCredentials:
            return true
        default:
            return false
        }
    }
}

enum GoogleCloudSetupFailureReason {
    case missingConfig
    case loginCanceled
    case billing
    case apiEnable
    case keyCreationBlocked
    case other
}

@MainActor
final class GoogleCloudSetupModel: ObservableObject {
    @Published private(set) var stage: GoogleCloudSetupStage = .idle
    @Published private(set) var statusMessage = "Smooth Talker can configure Google Cloud automatically."
    @Published private(set) var technicalDetails: [String] = []
    @Published private(set) var failureReason: GoogleCloudSetupFailureReason?
    @Published private(set) var projectID: String?
    @Published private(set) var existingProjects: [GoogleCloudProject] = []
    @Published private(set) var billingAccounts: [GoogleCloudBillingAccount] = []
    @Published private(set) var generatedCredentialsJSON: String?

    private let setupManager = GoogleCloudSetupManager()
    private var accessToken: String?
    private var workTask: Task<Void, Never>?

    deinit {
        workTask?.cancel()
    }

    func startAutomaticSetup() {
        run { [self] in
            do {
                resetFailure()
                accessToken = try await setupManager.signIn()
                appendDetail("Google sign-in finished.")
                try await discoverProjects()
            } catch {
                await fail(error)
            }
        }
    }

    func createNewProjectAndContinue() {
        run { [self] in
            do {
                resetFailure()
                try await createProject()
                try await discoverBillingAccounts()
            } catch {
                await fail(error)
            }
        }
    }

    func useExistingProject(_ project: GoogleCloudProject) {
        run { [self] in
            do {
                resetFailure()
                projectID = project.projectId
                appendDetail("Selected project \(project.projectId).")
                try await discoverBillingAccounts()
            } catch {
                await fail(error)
            }
        }
    }

    func useBillingAccount(_ account: GoogleCloudBillingAccount) {
        run { [self] in
            do {
                resetFailure()
                try await linkBilling(account)
                try await finishProvisioning()
            } catch {
                await fail(error)
            }
        }
    }

    func continueAfterAddingBilling() {
        run { [self] in
            do {
                resetFailure()
                try await discoverBillingAccounts()
            } catch {
                await fail(error)
            }
        }
    }

    func openBillingConsole() {
        guard let url = URL(string: "https://console.cloud.google.com/billing") else { return }
        NSWorkspace.shared.open(url)
    }

    func openOAuthSetup() {
        guard let url = URL(string: "https://console.cloud.google.com/apis/credentials") else { return }
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

    private func discoverProjects() async throws {
        guard let accessToken else { throw GoogleCloudSetupError.tokenMissing }

        await setStage(.loadingProjects, "Looking for Google Cloud projects...")
        existingProjects = try await setupManager.listProjects(accessToken: accessToken)
        await setStage(.choosingProject, "Choose an existing project or create a new Smooth Talker project.")
    }

    private func createProject() async throws {
        guard let accessToken else { throw GoogleCloudSetupError.tokenMissing }

        await setStage(.creatingProject, "Creating a Google Cloud project...")
        let createdProjectID = try await setupManager.createProject(accessToken: accessToken)
        projectID = createdProjectID
        appendDetail("Created project \(createdProjectID).")
    }

    private func discoverBillingAccounts() async throws {
        guard let accessToken else { throw GoogleCloudSetupError.tokenMissing }

        await setStage(.checkingBilling, "Checking Google Cloud billing...")
        let accounts = try await setupManager.listBillingAccounts(accessToken: accessToken)
            .filter { $0.open != false }
        billingAccounts = accounts

        if accounts.isEmpty {
            await setStage(.waitingForBilling, "Add a billing account in Google Cloud, then come back and continue.")
            openBillingConsole()
            return
        }

        await setStage(.choosingBilling, "Choose the billing account to link to this project.")
    }

    private func linkBilling(_ account: GoogleCloudBillingAccount) async throws {
        guard let accessToken else { throw GoogleCloudSetupError.tokenMissing }
        guard let projectID else { throw GoogleCloudSetupError.projectMissing }

        await setStage(.linkingBilling, "Linking billing to the project...")
        try await setupManager.linkBilling(
            accessToken: accessToken,
            projectID: projectID,
            billingAccountName: account.name
        )
        appendDetail("Linked billing account \(account.billingAccountID).")
    }

    private func finishProvisioning() async throws {
        guard let accessToken else { throw GoogleCloudSetupError.tokenMissing }
        guard let projectID else { throw GoogleCloudSetupError.projectMissing }

        await setStage(.enablingServices, "Enabling Google Cloud services...")
        try await setupManager.enableRequiredServices(accessToken: accessToken, projectID: projectID)
        appendDetail("Enabled Text-to-Speech services.")

        await setStage(.creatingCredentials, "Creating Smooth Talker credentials...")
        try await setupManager.createOrReuseServiceAccount(accessToken: accessToken, projectID: projectID)
        let credentialsJSON = try await setupManager.createServiceAccountKey(accessToken: accessToken, projectID: projectID)

        await setStage(.readyToValidate, "Validating generated credentials...")
        generatedCredentialsJSON = credentialsJSON
    }

    private func setStage(_ stage: GoogleCloudSetupStage, _ message: String) async {
        self.stage = stage
        statusMessage = message
    }

    private func fail(_ error: Error) async {
        let message = GoogleCloudSetupError.userMessage(for: error)
        failureReason = GoogleCloudSetupError.failureReason(for: error, message: message)
        technicalDetails.append(GoogleCloudSetupError.technicalMessage(for: error))
        await setStage(.failed(message), message)
    }

    private func resetFailure() {
        failureReason = nil
        if case .failed = stage {
            stage = .idle
        }
    }

    private func appendDetail(_ detail: String) {
        technicalDetails.append(detail)
        if technicalDetails.count > 80 {
            technicalDetails.removeFirst(technicalDetails.count - 80)
        }
    }
}

final class GoogleCloudSetupManager {
    private let session: URLSession
    private let authenticator = GoogleOAuthAuthenticator()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func signIn() async throws -> String {
        let config = try GoogleOAuthConfig.load()
        return try await authenticator.authenticate(config: config)
    }

    func listProjects(accessToken: String) async throws -> [GoogleCloudProject] {
        let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects?filter=lifecycleState:ACTIVE")!
        let response: GoogleCloudProjectsResponse = try await send(url: url, accessToken: accessToken)
        return response.projects ?? []
    }

    func createProject(accessToken: String) async throws -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let projectID = "smooth-talker-tts-\(suffix)"
        let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
        let operation: GoogleCloudOperation = try await send(
            url: url,
            method: "POST",
            accessToken: accessToken,
            body: [
                "projectId": projectID,
                "name": "Smooth Talker"
            ]
        )
        try await waitForOperation(
            operation,
            accessToken: accessToken,
            baseURL: URL(string: "https://cloudresourcemanager.googleapis.com/v1/")!
        )
        return projectID
    }

    func listBillingAccounts(accessToken: String) async throws -> [GoogleCloudBillingAccount] {
        let url = URL(string: "https://cloudbilling.googleapis.com/v1/billingAccounts")!
        let response: GoogleCloudBillingAccountsResponse = try await send(url: url, accessToken: accessToken)
        return response.billingAccounts ?? []
    }

    func linkBilling(accessToken: String, projectID: String, billingAccountName: String) async throws {
        let url = URL(string: "https://cloudbilling.googleapis.com/v1/projects/\(projectID)/billingInfo")!
        let _: GoogleCloudBillingInfo = try await send(
            url: url,
            method: "PUT",
            accessToken: accessToken,
            body: ["billingAccountName": billingAccountName]
        )
    }

    func enableRequiredServices(accessToken: String, projectID: String) async throws {
        let url = URL(string: "https://serviceusage.googleapis.com/v1/projects/\(projectID)/services:batchEnable")!
        let operation: GoogleCloudOperation = try await send(
            url: url,
            method: "POST",
            accessToken: accessToken,
            body: [
                "serviceIds": [
                    "serviceusage.googleapis.com",
                    "iam.googleapis.com",
                    "texttospeech.googleapis.com"
                ]
            ]
        )
        try await waitForOperation(
            operation,
            accessToken: accessToken,
            baseURL: URL(string: "https://serviceusage.googleapis.com/v1/")!
        )
    }

    func createOrReuseServiceAccount(accessToken: String, projectID: String) async throws {
        let url = URL(string: "https://iam.googleapis.com/v1/projects/\(projectID)/serviceAccounts")!

        do {
            let _: GoogleCloudServiceAccount = try await send(
                url: url,
                method: "POST",
                accessToken: accessToken,
                body: [
                    "accountId": "smooth-talker-tts",
                    "serviceAccount": [
                        "displayName": "Smooth Talker Text-to-Speech"
                    ]
                ]
            )
        } catch let error as GoogleCloudSetupError {
            if case .api(let statusCode, _) = error, statusCode == 409 {
                return
            }
            throw error
        }
    }

    func createServiceAccountKey(accessToken: String, projectID: String) async throws -> String {
        let email = "smooth-talker-tts@\(projectID).iam.gserviceaccount.com"
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        let url = URL(string: "https://iam.googleapis.com/v1/projects/\(projectID)/serviceAccounts/\(encodedEmail)/keys")!
        let response: GoogleCloudServiceAccountKey = try await send(
            url: url,
            method: "POST",
            accessToken: accessToken,
            body: [
                "privateKeyType": "TYPE_GOOGLE_CREDENTIALS_FILE",
                "keyAlgorithm": "KEY_ALG_RSA_2048"
            ]
        )

        guard let encodedKey = response.privateKeyData,
              let data = Data(base64Encoded: encodedKey),
              let json = String(data: data, encoding: .utf8) else {
            throw GoogleCloudSetupError.invalidResponse("Google Cloud did not return a service account JSON key.")
        }

        return json
    }

    private func waitForOperation(_ operation: GoogleCloudOperation, accessToken: String, baseURL: URL) async throws {
        guard let name = operation.name else { return }

        for _ in 0..<60 {
            let latest: GoogleCloudOperation = try await send(
                url: operationURL(name: name, baseURL: baseURL),
                accessToken: accessToken
            )

            if let error = latest.error {
                throw GoogleCloudSetupError.api(error.code ?? 400, error.message ?? "Google Cloud operation failed.")
            }

            if latest.done == true {
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw GoogleCloudSetupError.invalidResponse("Google Cloud operation timed out.")
    }

    private func operationURL(name: String, baseURL: URL) -> URL {
        if let url = URL(string: name), url.scheme != nil {
            return url
        }

        return URL(string: name, relativeTo: baseURL)!.absoluteURL
    }

    private func send<T: Decodable>(
        url: URL,
        method: String = "GET",
        accessToken: String,
        body: [String: Any]? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCloudSetupError.invalidResponse("Google Cloud returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = GoogleCloudAPIError.message(from: data)
            throw GoogleCloudSetupError.api(httpResponse.statusCode, message)
        }

        if T.self == EmptyGoogleCloudResponse.self {
            return EmptyGoogleCloudResponse() as! T
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleCloudSetupError.invalidResponse(error.localizedDescription)
        }
    }
}

private final class GoogleOAuthAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @MainActor
    func authenticate(config: GoogleOAuthConfig) async throws -> String {
        let loopbackServer = try GoogleOAuthLoopbackServer()
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.codeChallenge(for: verifier)
        let authURL = try authorizationURL(
            config: config,
            challenge: challenge,
            redirectURI: loopbackServer.redirectURI
        )

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: nil
        ) { _, error in
            if let error {
                loopbackServer.cancel(message: error.localizedDescription)
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session

        guard session.start() else {
            throw GoogleCloudSetupError.authCanceled("Smooth Talker could not open Google sign-in.")
        }

        defer {
            session.cancel()
            loopbackServer.stop()
            self.session = nil
        }

        let code = try await loopbackServer.waitForCode()
        return try await exchangeCode(
            code,
            verifier: verifier,
            redirectURI: loopbackServer.redirectURI,
            config: config
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    private func authorizationURL(config: GoogleOAuthConfig, challenge: String, redirectURI: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/cloud-platform"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "online"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components.url else {
            throw GoogleCloudSetupError.invalidResponse("Smooth Talker could not create the Google sign-in URL.")
        }
        return url
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String, config: GoogleOAuthConfig) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        request.httpBody = body
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCloudSetupError.invalidResponse("Google returned an invalid token response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCloudSetupError.api(httpResponse.statusCode, GoogleCloudAPIError.message(from: data))
        }

        let token = try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
        return token.accessToken
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    let redirectURI: String

    private let socketFileDescriptor: Int32
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.kriyak.smoothtalker.oauth-loopback")
    private let stopLock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var didClose = false

    init() throws {
        let socketFileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFileDescriptor >= 0 else {
            throw GoogleCloudSetupError.invalidResponse("Smooth Talker could not start the local sign-in callback.")
        }

        var reuseAddress: Int32 = 1
        setsockopt(
            socketFileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketFileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0, Darwin.listen(socketFileDescriptor, 1) == 0 else {
            Darwin.close(socketFileDescriptor)
            throw GoogleCloudSetupError.invalidResponse("Smooth Talker could not start the local sign-in callback.")
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketFileDescriptor, socketAddress, &boundAddressLength)
            }
        }

        guard nameResult == 0 else {
            Darwin.close(socketFileDescriptor)
            throw GoogleCloudSetupError.invalidResponse("Smooth Talker could not start the local sign-in callback.")
        }

        let port = UInt16(bigEndian: boundAddress.sin_port)
        self.socketFileDescriptor = socketFileDescriptor
        self.port = port
        redirectURI = "http://127.0.0.1:\(port)/oauth2redirect"
    }

    deinit {
        stop()
    }

    func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async {
                    if let pendingResult = self.pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: pendingResult)
                        return
                    }

                    self.continuation = continuation
                    self.acceptOneRequest()
                }
            }
        } onCancel: {
            self.cancel(message: "Google sign-in was canceled.")
        }
    }

    func cancel(message: String) {
        closeSocket()
        finish(.failure(GoogleCloudSetupError.authCanceled(message)))
    }

    func stop() {
        closeSocket()
    }

    private func acceptOneRequest() {
        let clientFileDescriptor = Darwin.accept(socketFileDescriptor, nil, nil)
        guard clientFileDescriptor >= 0 else {
            finish(.failure(GoogleCloudSetupError.authCanceled("Google sign-in was canceled.")))
            return
        }

        defer {
            Darwin.close(clientFileDescriptor)
        }

        let request = readHTTPRequest(from: clientFileDescriptor)
        let result = authorizationCode(from: request)
        writeHTTPResponse(to: clientFileDescriptor, success: result.isSuccess)
        finish(result)
    }

    private func readHTTPRequest(from fileDescriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)

            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func authorizationCode(from request: String) -> Result<String, Error> {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return .failure(GoogleCloudSetupError.authCanceled("Google sign-in did not return a valid callback."))
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(GoogleCloudSetupError.authCanceled("Google sign-in did not return a valid callback."))
        }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1:\(port)\(path)") else {
            return .failure(GoogleCloudSetupError.authCanceled("Google sign-in did not return a valid callback."))
        }

        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            return .failure(GoogleCloudSetupError.authCanceled(description ?? error))
        }

        guard components.path == "/oauth2redirect",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            return .failure(GoogleCloudSetupError.authCanceled("Google did not return an authorization code."))
        }

        return .success(code)
    }

    private func writeHTTPResponse(to fileDescriptor: Int32, success: Bool) {
        let title = success ? "Smooth Talker is connected to Google" : "Smooth Talker could not finish Google sign-in"
        let body = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:48px;">
        <h1>\(title)</h1>
        <p>You can return to Smooth Talker now.</p>
        </body>
        </html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { pointer in
            Darwin.send(fileDescriptor, pointer, strlen(pointer), 0)
        }
    }

    private func finish(_ result: Result<String, Error>) {
        queue.async {
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else if self.pendingResult == nil {
                self.pendingResult = result
            }

            self.closeSocket()
        }
    }

    private func closeSocket() {
        stopLock.lock()
        defer { stopLock.unlock() }

        guard !didClose else { return }
        didClose = true
        Darwin.shutdown(socketFileDescriptor, SHUT_RDWR)
        Darwin.close(socketFileDescriptor)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

private struct GoogleOAuthConfig {
    let clientID: String
    let clientSecret: String

    static func load() throws -> GoogleOAuthConfig {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String ?? ""
        let clientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String ?? ""

        guard !isPlaceholder(clientID) else {
            throw GoogleCloudSetupError.missingOAuthConfig
        }

        guard !isPlaceholder(clientSecret) else {
            throw GoogleCloudSetupError.missingOAuthClientSecret
        }

        return GoogleOAuthConfig(clientID: clientID, clientSecret: clientSecret)
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(")
    }
}

private struct GoogleOAuthTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct GoogleCloudProjectsResponse: Decodable {
    let projects: [GoogleCloudProject]?
}

private struct GoogleCloudBillingAccountsResponse: Decodable {
    let billingAccounts: [GoogleCloudBillingAccount]?
}

private struct GoogleCloudBillingInfo: Decodable {}
private struct GoogleCloudServiceAccount: Decodable {}
private struct EmptyGoogleCloudResponse: Decodable {}

private struct GoogleCloudServiceAccountKey: Decodable {
    let privateKeyData: String?
}

private struct GoogleCloudOperation: Decodable {
    let name: String?
    let done: Bool?
    let error: GoogleCloudAPIError?
}

private struct GoogleCloudErrorResponse: Decodable {
    let error: GoogleCloudAPIError?
}

private struct GoogleCloudAPIError: Decodable {
    let code: Int?
    let message: String?
    let status: String?

    static func message(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(GoogleCloudErrorResponse.self, from: data),
           let message = response.error?.message {
            return message
        }

        return String(data: data, encoding: .utf8) ?? "Google Cloud request failed."
    }
}

enum GoogleCloudSetupError: LocalizedError {
    case missingOAuthConfig
    case missingOAuthClientSecret
    case authCanceled(String)
    case tokenMissing
    case projectMissing
    case api(Int, String)
    case invalidResponse(String)

    var errorDescription: String? {
        Self.userMessage(for: self)
    }

    static func userMessage(for error: Error) -> String {
        guard let setupError = error as? GoogleCloudSetupError else {
            if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
                return "You appear to be offline. Connect to the internet and try again."
            }
            return error.localizedDescription
        }

        switch setupError {
        case .missingOAuthConfig:
            return "This build needs a Google OAuth client ID before Smooth Talker can sign in with Google. Configure OAuth in the project, then rebuild."
        case .missingOAuthClientSecret:
            return "This build needs the Google Desktop OAuth client secret before Smooth Talker can sign in with Google. Add GOOGLE_OAUTH_CLIENT_SECRET to the project, then rebuild."
        case .authCanceled:
            return "Google sign-in was canceled. Try again when you are ready."
        case .tokenMissing:
            return "Smooth Talker needs you to sign in with Google again."
        case .projectMissing:
            return "Choose or create a Google Cloud project before continuing."
        case .api(_, let message):
            return friendlyAPIMessage(message)
        case .invalidResponse(let message):
            return message
        }
    }

    static func technicalMessage(for error: Error) -> String {
        if let setupError = error as? GoogleCloudSetupError {
            switch setupError {
            case .api(let code, let message):
                return "HTTP \(code): \(message)"
            case .authCanceled(let message):
                return message
            case .invalidResponse(let message):
                return message
            default:
                return setupError.localizedDescription
            }
        }

        return error.localizedDescription
    }

    static func failureReason(for error: Error, message: String) -> GoogleCloudSetupFailureReason {
        if case .missingOAuthConfig = error as? GoogleCloudSetupError {
            return .missingConfig
        }

        if case .missingOAuthClientSecret = error as? GoogleCloudSetupError {
            return .missingConfig
        }

        if case .authCanceled = error as? GoogleCloudSetupError {
            return .loginCanceled
        }

        let searchable = message.lowercased()
        if searchable.contains("billing") {
            return .billing
        }

        if searchable.contains("service") || searchable.contains("api") {
            return .apiEnable
        }

        if searchable.contains("key") || searchable.contains("organization policy") || searchable.contains("disable service account key") {
            return .keyCreationBlocked
        }

        return .other
    }

    private static func friendlyAPIMessage(_ message: String) -> String {
        let searchable = message.lowercased()

        if searchable.contains("billing") {
            return "Billing needs attention in Google Cloud. Open Google Billing, attach or activate a billing account, then continue."
        }

        if searchable.contains("client_secret") || searchable.contains("client secret") {
            return "Desktop OAuth needs a client secret. Add GOOGLE_OAUTH_CLIENT_SECRET to the Smooth Talker build settings, then rebuild."
        }

        if searchable.contains("permission") || searchable.contains("denied") {
            return "Google Cloud says this account does not have permission to complete setup. Try another Google account or use Guided Setup."
        }

        if searchable.contains("service account key") ||
            searchable.contains("key creation") ||
            searchable.contains("iam.disableServiceAccountKeyCreation".lowercased()) {
            return "This Google Cloud organization blocks service account key creation. Use Guided Setup with a project that allows JSON keys."
        }

        if searchable.contains("serviceusage") || searchable.contains("api") || searchable.contains("disabled") {
            return "Smooth Talker could not enable the required Google Cloud APIs. Check project permissions, then try again."
        }

        return message
    }
}
