//
//  SpeechManager.swift
//  Smooth Talker
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
        Task { @MainActor in
            self.speakFromMainActor(text)
        }
    }

    @MainActor
    private func speakFromMainActor(_ text: String) {
        let speechID = UUID()
        activeSpeechID = speechID
        let chunks = TextChunker.chunks(text)
        
        DispatchQueue.main.async {
            self.appDelegate?.setTrayLoading(true)
        }
        
        audioPlayer.stop()
        GoogleTTSAPI.cancelAudioRequests(except: speechID)
        
        let voiceName = Preferences.shared.voiceName
        if voiceName.isEmpty {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        if VoiceCategory(for: voiceName).requiresPremiumUnlock && !PurchaseManager.shared.hasPremiumVoices {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        if chunks.isEmpty {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        GoogleTTSAPI.getInstance(credentialsJson: Preferences.shared.credentials) { api in
            guard self.activeSpeechID == speechID else { return }
            api.cancelAudioRequests(excluding: speechID)
            
            var audioByChunkIndex: [Int: Data] = [:]
            var nextChunkToPlay = 0
            var failedChunkIndex: Int?
            var didStartPlayback = false
            
            func drainReadyChunks() {
                while let audio = audioByChunkIndex[nextChunkToPlay] {
                    if let failedChunkIndex = failedChunkIndex,
                       nextChunkToPlay >= failedChunkIndex {
                        audioByChunkIndex[nextChunkToPlay] = nil
                        return
                    }
                    
                    audioByChunkIndex[nextChunkToPlay] = nil
                    
                    if didStartPlayback {
                        self.audioPlayer.enqueue(data: audio)
                    } else {
                        self.audioData = audio
                        self.audioPlayer.play(data: audio)
                        didStartPlayback = true
                        
                        DispatchQueue.main.async {
                            self.appDelegate?.setTrayLoading(false)
                        }
                    }
                    
                    nextChunkToPlay += 1
                }
            }
            
            func markChunkFailed(_ index: Int, error _: Error) {
                if let existingFailedChunkIndex = failedChunkIndex {
                    failedChunkIndex = min(existingFailedChunkIndex, index)
                } else {
                    failedChunkIndex = index
                }
                
                let firstFailedChunkIndex = failedChunkIndex ?? index
                audioByChunkIndex = audioByChunkIndex.filter { $0.key < firstFailedChunkIndex }

                if index == 0 && !didStartPlayback {
                    DispatchQueue.main.async {
                        self.appDelegate?.setTrayLoading(false)
                    }
                } else {
                    drainReadyChunks()
                }
            }
            
            for (index, chunk) in chunks.enumerated() {
                let chunkLabel = "chunk-\(index + 1)"
                
                api.getAudio(text: chunk,
                             language: Preferences.shared.language,
                             voiceName: voiceName,
                             speed: Preferences.shared.speakingSpeed,
                             speechID: speechID,
                             chunkLabel: chunkLabel
                ) { result in
                    guard self.activeSpeechID == speechID else { return }
                    
                    switch result {
                    case .success(let data):
                        if let failedChunkIndex = failedChunkIndex,
                           index >= failedChunkIndex {
                            return
                        }
                        
                        audioByChunkIndex[index] = data
                        drainReadyChunks()
                    case .failure(let error):
                        markChunkFailed(index, error: error)
                    }
                }
            }
        }
    }
}

private struct TextChunker {
    private static let chunkTargets = [125, 500, 800]
    private static let defaultChunkTarget = 1000
    
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        while !remaining.isEmpty {
            let target = targetLength(forChunkAt: chunks.count)
            
            guard remaining.count > target,
                  let breakIndex = firstBreakIndex(in: remaining, after: target) else {
                chunks.append(remaining)
                break
            }
            
            let chunk = String(remaining[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            
            remaining = String(remaining[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return chunks
    }
    
    private static func targetLength(forChunkAt index: Int) -> Int {
        guard index < chunkTargets.count else {
            return defaultChunkTarget
        }
        
        return chunkTargets[index]
    }
    
    private static func firstBreakIndex(in text: String, after target: Int) -> String.Index? {
        var index = text.index(text.startIndex, offsetBy: target)
        
        while index < text.endIndex {
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
        } catch {
        }
    }

    func stop() {
        if let player = player {
            player.pause() // Pause playback
            player.removeAllItems()
        }
        player = nil

        for tempURL in tempURLs {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
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
