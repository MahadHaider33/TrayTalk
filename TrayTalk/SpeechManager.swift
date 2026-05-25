//
//  SpeechManager.swift
//  TrayTalk
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import AVFAudio
import AVFoundation
import Cocoa

class SpeechManager {
    static let shared = SpeechManager()
    
    private var audioPlayer = AudioPlayer()
    private var audioData: Data?
    private var activeSpeechID = UUID()
    var appDelegate: AppDelegate?
    
    private init() {}
    
    func speak(_ text: String) {
        let speechID = UUID()
        activeSpeechID = speechID
        let chunks = TextChunker.firstThenRest(text)
        
        DispatchQueue.main.async {
            self.appDelegate?.setTrayLoading(true)
        }
        
        audioPlayer.stop()
        
        if Preferences.shared.voiceName.isEmpty {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        GoogleTTSAPI.getInstance(credentialsJson: Preferences.shared.credentials) { api in
            guard self.activeSpeechID == speechID else { return }
            
            api.getAudio(text: chunks.first,
                         language: Preferences.shared.language,
                         voiceName: Preferences.shared.voiceName,
                         speed: Preferences.shared.speakingSpeed
            ) { result in
                guard self.activeSpeechID == speechID else { return }
                
                switch result {
                case .success(let data):
                    self.audioData = data
                    self.audioPlayer.play(data: data)
                    DispatchQueue.main.async {
                        self.appDelegate?.setTrayLoading(false)
                    }
                    
                    guard let remainder = chunks.remainder else { return }
                    
                    api.getAudio(text: remainder,
                                 language: Preferences.shared.language,
                                 voiceName: Preferences.shared.voiceName,
                                 speed: Preferences.shared.speakingSpeed
                    ) { result in
                        guard self.activeSpeechID == speechID else { return }
                        
                        switch result {
                        case .success(let data):
                            self.audioPlayer.enqueue(data: data)
                        case .failure(let error):
                            print("\(error.localizedDescription)")
                        }
                    }
                case .failure(let error):
                    print("\(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.appDelegate?.setTrayLoading(false)
                    }
                }
            }
        }
    }
}


private struct TextChunker {
    private static let searchStart = 125
    private static let searchEnd = 300
    
    static func firstThenRest(_ text: String) -> (first: String, remainder: String?) {
        guard text.count > searchEnd,
              let breakIndex = firstBreakIndex(in: text) else {
            return (text, nil)
        }
        
        let first = String(text[..<breakIndex])
        let remainder = String(text[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !remainder.isEmpty else {
            return (text, nil)
        }
        
        return (first, remainder)
    }
    
    private static func firstBreakIndex(in text: String) -> String.Index? {
        var index = text.index(text.startIndex, offsetBy: searchStart)
        let endIndex = text.index(text.startIndex, offsetBy: min(searchEnd, text.count))
        
        while index < endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            
            if character == "\n" || character == ";" || character == "?" || character == "!" {
                return nextIndex
            }
            
            if character == "." && nextIndex < text.endIndex && text[nextIndex].isWhitespace {
                return nextIndex
            }
            
            index = nextIndex
        }
        
        return nil
    }
}


class AudioPlayer: ObservableObject {
    private var player: AVQueuePlayer?
    private var tempURLs: [URL] = []

    func play(data: Data) {
        stop()
        enqueue(data: data)
    }

    func enqueue(data: Data) {
        do {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            try data.write(to: fileURL)
            tempURLs.append(fileURL)

            let playerItem = AVPlayerItem(url: fileURL)
            if let player = player {
                player.insert(playerItem, after: nil)
            } else {
                player = AVQueuePlayer(items: [playerItem])
                player?.automaticallyWaitsToMinimizeStalling = false
            }
            
            startPlayback()

            print("Playback started")
        } catch {
            print("Failed to play audio: \(error)")
        }
    }

    func stop() {
        if let player = player {
            print("Stopping playback")
            player.pause() // Pause playback
            player.removeAllItems()
        }
        player = nil

        for tempURL in tempURLs {
            do {
                try FileManager.default.removeItem(at: tempURL)
                print("Temporary file removed")
            } catch {
                print("Failed to remove temporary file: \(error)")
            }
        }
        tempURLs.removeAll()
    }
    
    private func startPlayback() {
        let rate = Float(Preferences.shared.speakingSpeed)
        player?.defaultRate = rate
        player?.playImmediately(atRate: rate)
    }
}
