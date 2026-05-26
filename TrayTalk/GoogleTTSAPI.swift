//
//  api.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import OAuth2

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
}


class GoogleTTSAPI {
    // Singleton instance
    private static var shared: GoogleTTSAPI?
    private static let defaultGeminiModelName = "gemini-2.5-flash-tts"
    
    private let credentials: String
    private let baseURL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    private let scope = "https://www.googleapis.com/auth/cloud-platform"
    private let voicesURL = "https://texttospeech.googleapis.com/v1/voices"
    
    // Cache for the access token
    private var _cachedToken: String?
    private var tokenExpirationDate: Date?
    private var isInitializing = false
    private var initializationCompletion: (() -> Void)?
    private let audioTasksQueue = DispatchQueue(label: "com.traytalk.google-tts.audio-tasks")
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
        print("Getting access token...")
        
        // Check if we have a valid cached token
        if let token = cachedToken, isTokenValid() {
            print("Using cached token")
            completion(.success(token))
            return
        }
        
        guard let credentialsData = credentials.data(using: .utf8) else {
            print("Failed to convert credentials to data")
            completion(.failure(GoogleTTSError.invalidCredentials))
            return
        }
        
        print(credentialsData)
        
        guard let authentication = ServiceAccountTokenProvider(
            credentialsData: credentialsData,
            scopes: [scope]
        ) else {
            print("Failed to create authentication provider")
            completion(.failure(GoogleTTSError.authenticationFailed("Failed to create token provider")))
            return
        }
        
        print("Requesting new token...")
        try! authentication.withToken { [weak self] token, error in
            if let error = error {
                print("Token error: \(error.localizedDescription)")
                completion(.failure(GoogleTTSError.authenticationFailed(error.localizedDescription)))
                return
            }
            
            guard let token = token,
                  let accessToken = token.AccessToken else {
                print("No token received")
                completion(.failure(GoogleTTSError.noToken))
                return
            }
            
            // Cache the new token and its expiration date
            self?._cachedToken = accessToken
            if let expiresIn = token.ExpiresIn {
                self?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            
            print("Got new access token: \(accessToken.prefix(10))...")
            completion(.success(accessToken))
        }
    }
    
    func cancelAudioRequests(excluding activeSpeechID: UUID) {
        audioTasksQueue.sync {
            let inactiveSessionIDs = audioTasksBySession.keys.filter { $0 != activeSpeechID }
            
            for sessionID in inactiveSessionIDs {
                let cancelledCount = audioTasksBySession[sessionID]?.count ?? 0
                TTSLogger.log("session=\(TTSLogger.shortID(sessionID)) cancelled inactive-session pendingRequests=\(cancelledCount)")
                audioTasksBySession[sessionID]?.values.forEach { $0.cancel() }
                audioTasksBySession.removeValue(forKey: sessionID)
                cancelledAudioSessions.insert(sessionID)
            }
        }
    }
    
    func getAudio(text: String, language: String, voiceName: String, speed: Double, speechID: UUID, chunkLabel: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let requestedAt = Date()
        TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) getAudio-requested chars=\(text.count)", date: requestedAt)
        registerAudioSession(speechID)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) token-requested voice=\(voiceName) speed=\(speed)")
            self?.getAccessToken { result in
                switch result {
                case .success(let token):
                    guard self?.isAudioSessionCancelled(speechID) == false else {
                        TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) cancelled before-task")
                        return
                    }
                    
                    TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) token-ready elapsed=\(Self.elapsedString(since: requestedAt))")
                    self?.performAudioRequest(with: token,
                                              text: text,
                                              language: language,
                                              voiceName: voiceName,
                                              speed: speed,
                                              speechID: speechID,
                                              chunkLabel: chunkLabel,
                                              requestedAt: requestedAt,
                                              completion: completion)
                case .failure(let error):
                    print("Token acquisition failed: \(error)")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    private func performAudioRequest(with token: String, text: String, language: String, voiceName: String, speed: Double, speechID: UUID, chunkLabel: String, requestedAt: Date, completion: @escaping (Result<Data, Error>) -> Void) {
        TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) audio-request-preparing")
        guard let url = URL(string: baseURL) else {
            print("Invalid URL: \(baseURL)")
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
        
        var voiceConfig: [String: Any] = [
            "languageCode": language,
            "name": voiceName
        ]
        let modelName = modelName(for: voiceName)
        if let modelName = modelName {
            voiceConfig["model_name"] = modelName
        }
        
        let requestBody: [String: Any] = [
            "input": [
                "text": text
            ],
            "voice": voiceConfig,
            "audioConfig": audioConfig
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            request.httpBody = jsonData
            let modelLogValue = modelName ?? "none"
            TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) request-body-prepared chars=\(text.count) model=\(modelLogValue)")
        } catch {
            print("JSON encoding error: \(error)")
            completion(.failure(GoogleTTSError.jsonEncodingError))
            return
        }

        print("Creating URLSession task...")
        let requestID = UUID()
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            self.removeAudioTask(requestID, from: speechID)
            
            DispatchQueue.main.async {
                if let error = error {
                    TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) response error=\(error.localizedDescription) elapsed=\(Self.elapsedString(since: requestedAt))")
                    print("Network error: \(error)")
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Invalid response type")
                    completion(.failure(GoogleTTSError.invalidResponse))
                    return
                }
                
                TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) response status=\(httpResponse.statusCode) elapsed=\(Self.elapsedString(since: requestedAt))")
                print("Got response with status code: \(httpResponse.statusCode)")
                print("Response headers: \(httpResponse.allHeaderFields)")
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) }
                    print("HTTP error \(httpResponse.statusCode): \(errorBody ?? "no error body")")
                    completion(.failure(GoogleTTSError.httpError(httpResponse.statusCode, errorBody)))
                    return
                }
                
                guard let data = data else {
                    print("No data in response")
                    completion(.failure(GoogleTTSError.noData))
                    return
                }
                
                do {
                    // Parse the JSON response
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let audioContent = json["audioContent"] as? String,
                          let audioData = Data(base64Encoded: audioContent) else {
                        print("Failed to extract audio content from response")
                        completion(.failure(GoogleTTSError.invalidResponse))
                        return
                    }
                    
                    print("Success! Decoded \(audioData.count) bytes of audio data")
                    completion(.success(audioData))
                } catch {
                    print("JSON parsing error: \(error)")
                    completion(.failure(error))
                }
            }
        }
        
        print("Resuming task...")
        guard registerAudioTask(task, requestID: requestID, for: speechID, chunkLabel: chunkLabel) else { return }
        task.resume()
        TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) task-resumed requestID=\(TTSLogger.shortID(requestID)) elapsed=\(Self.elapsedString(since: requestedAt))")
    }
    
    private func modelName(for voiceName: String) -> String? {
        let localePrefixedVoicePattern = #"^[a-z]{2,3}-[A-Z]{2}-"#
        let range = NSRange(voiceName.startIndex..<voiceName.endIndex, in: voiceName)
        let regex = try? NSRegularExpression(pattern: localePrefixedVoicePattern)
        let isLocalePrefixedVoice = regex?.firstMatch(in: voiceName, range: range) != nil
        
        return isLocalePrefixedVoice ? nil : Self.defaultGeminiModelName
    }
    
    private func registerAudioSession(_ speechID: UUID) {
        audioTasksQueue.sync {
            if audioTasksBySession[speechID] == nil {
                audioTasksBySession[speechID] = [:]
            }
            cancelledAudioSessions.remove(speechID)
        }
    }
    
    private func registerAudioTask(_ task: URLSessionDataTask, requestID: UUID, for speechID: UUID, chunkLabel: String) -> Bool {
        audioTasksQueue.sync {
            guard !cancelledAudioSessions.contains(speechID) else {
                task.cancel()
                TTSLogger.log("session=\(TTSLogger.shortID(speechID)) chunk=\(chunkLabel) cancelled before-task-resume")
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
    
    private static func elapsedString(since startDate: Date) -> String {
        String(format: "%.3fs", Date().timeIntervalSince(startDate))
    }
    
    func fetchVoices(languageCode: String? = nil, completion: @escaping ([TTSVoice]) -> Void) {
        getAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                var urlComponents = URLComponents(string: self?.voicesURL ?? "")
                
                if let languageCode = languageCode {
                    urlComponents?.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
                    
                }
                
                guard let url = urlComponents?.url else {
                    print("Invalid URL")
                    completion([])
                    return
                }
                
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        print("No data received: \(error?.localizedDescription ?? "Unknown error")")
                        completion([])
                        return
                    }
                    
                    do {
                        let decoder = JSONDecoder()
                        let response = try decoder.decode(VoicesResponse.self, from: data)
                        DispatchQueue.main.async {
                            self?.voices = response.voices
                            completion(response.voices)
                        }
                    } catch {
                        print("Decoding error: \(error)")
                        completion([])
                    }
                }.resume()
                
            case .failure(let error):
                print("Failed to get token for voices: \(error)")
                completion([])
            }
        }
    }
}
