//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import AppKit
import SimplyCoreAudio
import CoreAudioTypes

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    
    private var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var deviceFormatMonitorCancellable: AnyCancellable?

    private var playbackMonitorCancellable: AnyCancellable?
    private var lastMusicSpecDetectedAt: Date?
    private var lastNonMusicAppliedAt: Date?

    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var previousSampleRate: Float64?
    private var previousBitsPerChannel: UInt32?
    var trackAndSample = [MediaTrack : Float64]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?

    var currentNowPlayingBundleId: String?

    private let musicBundleId = "com.apple.Music"
    private let nonMusicDefaultSampleRate: Float64 = 48_000
    private let nonMusicDefaultBitDepth: Int32 = 24

    private let pollIntervalSeconds: TimeInterval = 0.5
    private let musicIdleRevertAfterSeconds: TimeInterval = 10
    private let musicSwitchWindowSeconds: TimeInterval = 0.5
    
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = selectedOutputDevice.publisher.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        // Keep the status item in sync even when the user changes the format manually
        // via Audio MIDI Setup (CoreAudio notifications are not always reliable across macOS versions).
        deviceFormatMonitorCancellable = Timer
            .publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                self.getDeviceSampleRate()
            }

        // Primary control loop.
        playbackMonitorCancellable = Timer
            .publish(every: pollIntervalSeconds, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                self.consoleQueue.async {
                    self.monitorPlaybackAndApplyFormat()
                }
            }

        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        deviceFormatMonitorCancellable?.cancel()
        playbackMonitorCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        Diagnostics.shared.log("OutputDevices: renewTimer()")
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                // Keep retrying longer since sample rate detection may lag on newer macOS versions.
                if self.timerCalls == 30 {
                    Diagnostics.shared.log("OutputDevices: renewTimer() done")
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    self.timerCalls += 1
                    self.consoleQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        if sampleRate != self.previousSampleRate {
            Diagnostics.shared.log("OutputDevices: device sampleRate changed -> \(sampleRate)")
            self.updateSampleRate(sampleRate)
        }
    }

    private func monitorPlaybackAndApplyFormat() {
        let isMusicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleId).isEmpty

        if isMusicRunning {
            let allStats = self.getAllStats()
            if let best = allStats.first {
                // Avoid switching mid-track (it causes audible drop-outs). Only act on
                // very recent detections, which should occur at (or right after) track start.
                let now = Date()
                let age = now.timeIntervalSince(best.date)
                if age <= musicSwitchWindowSeconds {
                    lastMusicSpecDetectedAt = now
                    switchTo(stat: best)
                } else {
                    Diagnostics.shared.log("OutputDevices: bestStat too old (age=\(String(format: "%.3f", age))s), skip")
                }
                return
            }

            // Music is running, but we haven't detected a spec recently -> revert slowly.
            if let last = lastMusicSpecDetectedAt,
               Date().timeIntervalSince(last) < musicIdleRevertAfterSeconds {
                return
            }
        }

        applyNonMusicDefaultFormat(rateLimited: true)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            }
            else {
                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
            }

            allStats.sort(by: {$0.priority > $1.priority})
            Diagnostics.shared.log("OutputDevices: getAllStats() -> \(allStats.map { "sr=\($0.sampleRate) bd=\($0.bitDepth) p=\($0.priority)" }.joined(separator: ", "))")
        }
        catch {
            Diagnostics.shared.log("OutputDevices: getAllStats() error: \(error)")
        }
        
        return allStats
    }
    
    func switchLatestSampleRate(recursion: Bool = false) {
        // Kept for compatibility with existing call sites (MediaRemote-triggered).
        // The primary control loop is `monitorPlaybackAndApplyFormat()`.
        let allStats = self.getAllStats()
        if let best = allStats.first {
            lastMusicSpecDetectedAt = Date()
            switchTo(stat: best)
            return
        }
    }

    private func switchTo(stat: CMPlayerStats) {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let defaultDevice else { return }

        let sampleRate = Float64(stat.sampleRate)
        let bitDepth = Int32(stat.bitDepth)
        Diagnostics.shared.log("OutputDevices: switchTo(stat) sampleRate=\(sampleRate) bitDepth=\(bitDepth)")

        let formats = getFormats(bestStat: stat, device: defaultDevice) ?? []

        if let selected = selectFormat(
            formats: formats,
            targetSampleRate: sampleRate,
            targetBitDepth: bitDepth
        ) {
            applyFormat(device: defaultDevice, format: selected, reason: "music")
            return
        }

        // Fallback: sample rate only.
        if sampleRate != previousSampleRate {
            Diagnostics.shared.log("OutputDevices: fallback switching nominalSampleRate=\(sampleRate)")
            defaultDevice.setNominalSampleRate(sampleRate)
            updateSampleRate(sampleRate)
        }
    }

    private func applyNonMusicDefaultFormat(rateLimited: Bool) {
        if rateLimited {
            if let last = lastNonMusicAppliedAt, Date().timeIntervalSince(last) < 2 {
                return
            }
        }

        lastNonMusicAppliedAt = Date()
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let defaultDevice else { return }

        let formats = getFormats(
            bestStat: CMPlayerStats(sampleRate: nonMusicDefaultSampleRate, bitDepth: Int(nonMusicDefaultBitDepth), date: Date(), priority: 0),
            device: defaultDevice
        ) ?? []

        if let selected = selectFormat(
            formats: formats,
            targetSampleRate: nonMusicDefaultSampleRate,
            targetBitDepth: nonMusicDefaultBitDepth
        ) {
            applyFormat(device: defaultDevice, format: selected, reason: "default")
            return
        }

        // Fallback: sample rate only.
        if nonMusicDefaultSampleRate != previousSampleRate {
            Diagnostics.shared.log("OutputDevices: default fallback nominalSampleRate=\(nonMusicDefaultSampleRate)")
            defaultDevice.setNominalSampleRate(nonMusicDefaultSampleRate)
            updateSampleRate(nonMusicDefaultSampleRate)
        }
    }

    private func applyFormat(device: AudioDevice, format: AudioStreamBasicDescription, reason: String) {
        if format.mSampleRate == previousSampleRate,
           format.mBitsPerChannel == previousBitsPerChannel {
            return
        }

        Diagnostics.shared.log("OutputDevices: applyFormat(reason=\(reason)) sr=\(format.mSampleRate) bits=\(format.mBitsPerChannel)")
        setFormats(device: device, format: format)
        previousBitsPerChannel = format.mBitsPerChannel
        updateSampleRate(format.mSampleRate)
    }

    private enum SampleRateFamily {
        case fortyFour
        case fortyEight
        case unknown
    }

    private func family(for sampleRate: Float64) -> SampleRateFamily {
        // Determine which clock family this rate belongs to.
        // We prefer preserving family (e.g. 44.1k stays in 44.1k family) to avoid audible resampling.
        let r44100: Float64 = 44_100
        let r48000: Float64 = 48_000
        let ratio441 = sampleRate / r44100
        let ratio48 = sampleRate / r48000

        let dist441 = abs(ratio441 - ratio441.rounded())
        let dist48 = abs(ratio48 - ratio48.rounded())

        if dist441 < 0.02 { return .fortyFour }
        if dist48 < 0.02 { return .fortyEight }
        return .unknown
    }

    private func selectFormat(
        formats: [AudioStreamBasicDescription],
        targetSampleRate: Float64,
        targetBitDepth: Int32
    ) -> AudioStreamBasicDescription? {
        if formats.isEmpty { return nil }

        // 1) Exact match.
        if let exact = formats.first(where: {
            $0.mSampleRate == targetSampleRate && Int32($0.mBitsPerChannel) == targetBitDepth
        }) {
            return exact
        }

        let targetFamily = family(for: targetSampleRate)

        func score(_ format: AudioStreamBasicDescription) -> Double {
            let formatFamily = family(for: format.mSampleRate)
            let familyPenalty: Double = (targetFamily != .unknown && formatFamily != targetFamily) ? 10_000 : 0

            // Prioritize staying in the same family over being "close" numerically.
            let sampleRatePenalty = abs(format.mSampleRate - targetSampleRate)

            let bits = Int32(format.mBitsPerChannel)
            let bitDepthPenalty = abs(Double(bits - targetBitDepth))

            // Avoid 16-bit -> 24-bit if possible.
            let upconvertPenalty: Double
            if targetBitDepth == 16 && bits > 16 {
                upconvertPenalty = 500
            } else {
                upconvertPenalty = 0
            }

            // Prefer bit depth match, but sample rate family is most important.
            return familyPenalty + sampleRatePenalty + (bitDepthPenalty * 5) + upconvertPenalty
        }

        return formats.min(by: { score($0) < score($1) })
    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            
            let delegate = AppDelegate.instance
            delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
        }
        self.runUserScript(sampleRate)
    }
    
    func runUserScript(_ sampleRate: Float64) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                let arguments = [
                    argumentSampleRate
                ]
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
}
