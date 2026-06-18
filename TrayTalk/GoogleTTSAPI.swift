//
//  api.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import Security

struct TTSVoice: Hashable, Codable {
    let name: String
    let languageCodes: [String]
    let ssmlGender: String
    let naturalSampleRateHertz: Int
    
    var displayName: String {
        // Just use the name from the API and gender
        return "\(name) (\(ssmlGender.lowercased()))"
    }
}

struct VoicesResponse: Codable {
    let voices: [TTSVoice]
}

private struct GoogleErrorResponse: Codable {
    let error: GoogleErrorDetail?
}

private struct GoogleErrorDetail: Codable {
    let code: Int?
    let message: String?
    let status: String?
}

enum GoogleTTSError: LocalizedError {
    case invalidURL
    case invalidCredentials
    case authenticationFailed(String)
    case noToken
    case invalidResponse
    case httpError(Int, String?)
    case noData
    case jsonEncodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidCredentials:
            return "Invalid credentials data"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .noToken:
            return "No token received"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let body):
            if let body = body {
                return "HTTP Error \(code): \(body)"
            }
            return "HTTP Error \(code)"
        case .noData:
            return "No data received"
        case .jsonEncodingError:
            return "Failed to encode request body"
        }
    }

    var userMessage: String {
        switch self {
        case .invalidURL:
            return "Smooth Talker could not reach Google Cloud because the service URL is invalid."
        case .invalidCredentials:
            return "The Google Cloud credentials could not be read. Run Automatic Setup again."
        case .authenticationFailed(let message):
            return "Google rejected the credentials. Run Automatic Setup again. \(message)"
        case .noToken:
            return "Google did not return an access token. Run Automatic Setup again."
        case .invalidResponse:
            return "Google Cloud returned a response Smooth Talker could not understand. Try again in a moment."
        case .httpError(let code, let body):
            return Self.userMessage(forHTTPStatus: code, body: body)
        case .noData:
            return "Google Cloud did not return any data. Check your network connection and try again."
        case .jsonEncodingError:
            return "Smooth Talker could not prepare the text-to-speech request."
        }
    }

    static func userMessage(for error: Error) -> String {
        if let googleError = error as? GoogleTTSError {
            return googleError.userMessage
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You appear to be offline. Connect to the internet and try again."
            case .timedOut:
                return "The request to Google Cloud timed out. Try again in a moment."
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }

        return error.localizedDescription
    }

    private static func userMessage(forHTTPStatus code: Int, body: String?) -> String {
        let googleMessage = body.flatMap { body -> String? in
            guard let data = body.data(using: .utf8),
                  let response = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) else {
                return nil
            }
            return response.error?.message
        }

        let searchableMessage = (googleMessage ?? body ?? "").lowercased()

        if searchableMessage.contains("billing") {
            return "Billing is not enabled for this Google Cloud project. Open Google Cloud Billing, attach a billing account, then try again."
        }

        if searchableMessage.contains("disabled") ||
            searchableMessage.contains("not been used") ||
            searchableMessage.contains("serviceusage") {
            return "The Cloud Text-to-Speech API is not enabled for this project. Enable it in Google Cloud, then try again."
        }

        switch code {
        case 400:
            return googleMessage ?? "Google Cloud could not accept this request. Check the selected voice and credentials."
        case 401:
            return "The Google Cloud credentials could not be authenticated. Run Automatic Setup again."
        case 403:
            return googleMessage ?? "Smooth Talker does not have access to Cloud Text-to-Speech, or the project needs billing/API setup."
        case 404:
            return "Google Cloud could not find the requested Text-to-Speech resource. Confirm the API is enabled for this project."
        case 429:
            return "This Google Cloud project has hit a Text-to-Speech quota limit. Wait a bit or check quotas in Google Cloud."
        case 500...599:
            return "Google Cloud is having trouble right now. Try again in a moment."
        default:
            if let googleMessage {
                return "Google Cloud error \(code): \(googleMessage)"
            }
            return "Google Cloud returned HTTP \(code)."
        }
    }
}

private struct GoogleServiceAccountTokenCredentials: Decodable {
    let clientEmail: String
    let privateKey: String
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case clientEmail = "client_email"
        case privateKey = "private_key"
        case tokenURI = "token_uri"
    }
}

private struct GoogleServiceAccountTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private final class GoogleServiceAccountTokenProvider {
    private let credentials: GoogleServiceAccountTokenCredentials
    private let scopes: [String]

    init(credentialsData: Data, scopes: [String]) throws {
        self.credentials = try JSONDecoder().decode(GoogleServiceAccountTokenCredentials.self, from: credentialsData)
        self.scopes = scopes
    }

    func fetchToken(completion: @escaping (Result<GoogleServiceAccountTokenResponse, Error>) -> Void) {
        do {
            let assertion = try makeJWTAssertion()
            guard let tokenURL = URL(string: credentials.tokenURI) else {
                completion(.failure(GoogleTTSError.invalidCredentials))
                return
            }

            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var body = URLComponents()
            body.queryItems = [
                URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                URLQueryItem(name: "assertion", value: assertion)
            ]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(GoogleTTSError.invalidResponse))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) }
                    completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, body)))
                    return
                }

                guard let data else {
                    completion(.failure(GoogleTTSError.noData))
                    return
                }

                do {
                    completion(.success(try JSONDecoder().decode(GoogleServiceAccountTokenResponse.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    private func makeJWTAssertion() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = [
            "alg": "RS256",
            "typ": "JWT"
        ]
        let claims: [String: Any] = [
            "iss": credentials.clientEmail,
            "scope": scopes.joined(separator: " "),
            "aud": credentials.tokenURI,
            "iat": now,
            "exp": now + 3600
        ]

        let signingInput = try [
            JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).base64URLEncodedString(),
            JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).base64URLEncodedString()
        ].joined(separator: ".")

        let signature = try sign(Data(signingInput.utf8))
        return "\(signingInput).\(signature.base64URLEncodedString())"
    }

    private func sign(_ data: Data) throws -> Data {
        let privateKeyData = try Self.privateRSAKeyData(fromPEM: credentials.privateKey)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]

        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &keyError) else {
            throw keyError?.takeRetainedValue() ?? GoogleTTSError.invalidCredentials
        }

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &signingError
        ) else {
            throw signingError?.takeRetainedValue() ?? GoogleTTSError.authenticationFailed("Failed to sign Google service account token")
        }

        return signature as Data
    }

    private static func privateRSAKeyData(fromPEM pem: String) throws -> Data {
        if pem.contains("-----BEGIN RSA PRIVATE KEY-----") {
            return try base64DecodedPEMBody(
                pem,
                beginMarker: "-----BEGIN RSA PRIVATE KEY-----",
                endMarker: "-----END RSA PRIVATE KEY-----"
            )
        }

        let pkcs8Data = try base64DecodedPEMBody(
            pem,
            beginMarker: "-----BEGIN PRIVATE KEY-----",
            endMarker: "-----END PRIVATE KEY-----"
        )
        return try extractRSAPrivateKey(fromPKCS8Data: pkcs8Data)
    }

    private static func base64DecodedPEMBody(_ pem: String, beginMarker: String, endMarker: String) throws -> Data {
        let body = pem
            .replacingOccurrences(of: beginMarker, with: "")
            .replacingOccurrences(of: endMarker, with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let data = Data(base64Encoded: body) else {
            throw GoogleTTSError.invalidCredentials
        }
        return data
    }

    private static func extractRSAPrivateKey(fromPKCS8Data data: Data) throws -> Data {
        var index = 0
        let sequence = try readASN1Element(from: data, index: &index)
        guard sequence.tag == 0x30 else { throw GoogleTTSError.invalidCredentials }

        var sequenceIndex = 0
        _ = try readASN1Element(from: sequence.value, index: &sequenceIndex)
        _ = try readASN1Element(from: sequence.value, index: &sequenceIndex)
        let privateKey = try readASN1Element(from: sequence.value, index: &sequenceIndex)
        guard privateKey.tag == 0x04 else { throw GoogleTTSError.invalidCredentials }
        return privateKey.value
    }

    private static func readASN1Element(from data: Data, index: inout Int) throws -> (tag: UInt8, value: Data) {
        guard index < data.count else { throw GoogleTTSError.invalidCredentials }
        let tag = data[index]
        index += 1

        guard index < data.count else { throw GoogleTTSError.invalidCredentials }
        let firstLengthByte = data[index]
        index += 1

        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7f)
            guard lengthByteCount > 0,
                  lengthByteCount <= 4,
                  index + lengthByteCount <= data.count else {
                throw GoogleTTSError.invalidCredentials
            }

            var parsedLength = 0
            for _ in 0..<lengthByteCount {
                parsedLength = (parsedLength << 8) | Int(data[index])
                index += 1
            }
            length = parsedLength
        }

        guard index + length <= data.count else { throw GoogleTTSError.invalidCredentials }
        let value = data.subdata(in: index..<(index + length))
        index += length
        return (tag, value)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

class GoogleTTSAPI {
    // Singleton instance
    private static var shared: GoogleTTSAPI?
    
    private let credentials: String
    private let baseURL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    private let scope = "https://www.googleapis.com/auth/cloud-platform"
    private let voicesURL = "https://texttospeech.googleapis.com/v1/voices"
    
    // Cache for the access token
    private var _cachedToken: String?
    private var tokenExpirationDate: Date?
    private var isInitializing = false
    private var initializationCompletion: (() -> Void)?
    private let audioTasksQueue = DispatchQueue(label: "com.kriyak.smoothtalker.google-tts.audio-tasks")
    private var audioTasksBySession: [UUID: [UUID: URLSessionDataTask]] = [:]
    private var cancelledAudioSessions: Set<UUID> = []
    
    private var voices: [TTSVoice] = []
    
    var cachedToken: String? {
        if isTokenValid() {
            return _cachedToken
        }
        return nil
    }
    
    static func getInstance(credentialsJson: String, completion: @escaping (GoogleTTSAPI) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let existing = shared {
                DispatchQueue.main.async {
                    completion(existing)
                }
                return
            }
            
            let api = GoogleTTSAPI(credentialsJson: credentialsJson)
            shared = api
            
            api.initializeToken {
                DispatchQueue.main.async {
                    completion(api)
                }
            }
        }
    }
    
    static func cancelAudioRequests(except activeSpeechID: UUID) {
        shared?.cancelAudioRequests(excluding: activeSpeechID)
    }
    
    static func resetSharedInstance() {
        shared = nil
    }
    
    private init(credentialsJson: String) {
        self.credentials = credentialsJson
    }
    
    private func initializeToken(completion: @escaping () -> Void) {
        if isInitializing {
            initializationCompletion = completion
            return
        }
        
        isInitializing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.getAccessToken { result in
                DispatchQueue.main.async {
                    self?.isInitializing = false
                    self?.initializationCompletion?()
                    self?.initializationCompletion = nil
                    completion()
                }
            }
        }
    }
    
    private func isTokenValid() -> Bool {
        guard let expirationDate = tokenExpirationDate,
              let _ = _cachedToken else {
            return false
        }
        
        // Add a 5-minute buffer to ensure token doesn't expire during use
        let bufferedDate = expirationDate.addingTimeInterval(-300)
        return bufferedDate > Date()
    }
    
    private func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        // Check if we have a valid cached token
        if let token = cachedToken, isTokenValid() {
            completion(.success(token))
            return
        }
        
        guard let credentialsData = credentials.data(using: .utf8) else {
            completion(.failure(GoogleTTSError.invalidCredentials))
            return
        }
        
        let authentication: GoogleServiceAccountTokenProvider
        do {
            authentication = try GoogleServiceAccountTokenProvider(
                credentialsData: credentialsData,
                scopes: [scope]
            )
        } catch {
            completion(.failure(GoogleTTSError.authenticationFailed("Failed to create token provider")))
            return
        }

        authentication.fetchToken { [weak self] result in
            switch result {
            case .success(let token):
                let accessToken = token.accessToken
                guard !accessToken.isEmpty else {
                    completion(.failure(GoogleTTSError.noToken))
                    return
                }

                self?._cachedToken = accessToken
                if let expiresIn = token.expiresIn {
                    self?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
                }

                completion(.success(accessToken))
            case .failure(let error):
                completion(.failure(GoogleTTSError.authenticationFailed(error.localizedDescription)))
            }
        }
    }
    
    func cancelAudioRequests(excluding activeSpeechID: UUID) {
        audioTasksQueue.sync {
            let inactiveSessionIDs = audioTasksBySession.keys.filter { $0 != activeSpeechID }
            
            for sessionID in inactiveSessionIDs {
                audioTasksBySession[sessionID]?.values.forEach { $0.cancel() }
                audioTasksBySession.removeValue(forKey: sessionID)
                cancelledAudioSessions.insert(sessionID)
            }
        }
    }
    
    func getAudio(text: String, language: String, voiceName: String, speed: Double, speechID: UUID, chunkLabel _: String, completion: @escaping (Result<Data, Error>) -> Void) {
        registerAudioSession(speechID)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.getAccessToken { result in
                switch result {
                case .success(let token):
                    guard self?.isAudioSessionCancelled(speechID) == false else {
                        return
                    }
                    
                    self?.performAudioRequest(with: token,
                                              text: text,
                                              language: language,
                                              voiceName: voiceName,
                                              speed: speed,
                                              speechID: speechID,
                                              completion: completion)
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    private func performAudioRequest(with token: String, text: String, language: String, voiceName: String, speed: Double, speechID: UUID, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: baseURL) else {
            completion(.failure(GoogleTTSError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let audioConfig: [String: Any] = [
            "audioEncoding": "MP3",
            // "speakingRate": speed, // we are speeding it up afterwards for better quality
            "speakingRate": 1.0
        ]
        
        let requestBody: [String: Any] = [
            "input": [
                "text": text
            ],
            "voice": [
                "languageCode": language,
                "name": voiceName
            ],
            "audioConfig": audioConfig
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            request.httpBody = jsonData
        } catch {
            completion(.failure(GoogleTTSError.jsonEncodingError))
            return
        }

        let requestID = UUID()
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            self.removeAudioTask(requestID, from: speechID)
            
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(GoogleTTSError.invalidResponse))
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                    completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(GoogleTTSError.noData))
                    return
                }
                
                do {
                    // Parse the JSON response
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let audioContent = json["audioContent"] as? String,
                          let audioData = Data(base64Encoded: audioContent) else {
                        completion(.failure(GoogleTTSError.invalidResponse))
                        return
                    }
                    
                    completion(.success(audioData))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        guard registerAudioTask(task, requestID: requestID, for: speechID) else { return }
        task.resume()
    }
    
    private func registerAudioSession(_ speechID: UUID) {
        audioTasksQueue.sync {
            if audioTasksBySession[speechID] == nil {
                audioTasksBySession[speechID] = [:]
            }
            cancelledAudioSessions.remove(speechID)
        }
    }
    
    private func registerAudioTask(_ task: URLSessionDataTask, requestID: UUID, for speechID: UUID) -> Bool {
        audioTasksQueue.sync {
            guard !cancelledAudioSessions.contains(speechID) else {
                task.cancel()
                return false
            }
            
            audioTasksBySession[speechID, default: [:]][requestID] = task
            return true
        }
    }
    
    private func removeAudioTask(_ requestID: UUID, from speechID: UUID) {
        audioTasksQueue.sync {
            guard var tasks = audioTasksBySession[speechID] else { return }
            
            tasks.removeValue(forKey: requestID)
            
            if tasks.isEmpty {
                audioTasksBySession.removeValue(forKey: speechID)
            } else {
                audioTasksBySession[speechID] = tasks
            }
        }
    }
    
    private func isAudioSessionCancelled(_ speechID: UUID) -> Bool {
        audioTasksQueue.sync {
            cancelledAudioSessions.contains(speechID)
        }
    }
    
    func fetchVoices(languageCode: String? = nil, completion: @escaping (Result<[TTSVoice], Error>) -> Void) {
        getAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                var urlComponents = URLComponents(string: self?.voicesURL ?? "")
                
                if let languageCode = languageCode {
                    urlComponents?.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
                    
                }
                
                guard let url = urlComponents?.url else {
                    completion(.failure(GoogleTTSError.invalidURL))
                    return
                }
                
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.invalidResponse))
                        }
                        return
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                        }
                        return
                    }
                    
                    guard let data = data else {
                        DispatchQueue.main.async {
                            completion(.failure(GoogleTTSError.noData))
                        }
                        return
                    }
                    
                    do {
                        let decoder = JSONDecoder()
                        let response = try decoder.decode(VoicesResponse.self, from: data)
                        DispatchQueue.main.async {
                            self?.voices = response.voices
                            completion(.success(response.voices))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }.resume()
                
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
