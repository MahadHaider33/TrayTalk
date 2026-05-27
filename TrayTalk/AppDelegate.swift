//
//  AppDelegate.swift
//  TrayTalk
//
//  Created by Sem Visscher on 25/12/2024.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var speedSlider: NSSlider?
    private var speedValueLabel: NSTextField?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // register hotkey
        _ = HotkeyManager.shared

        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem?.button {
            button.target = self
            button.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "Smooth Talker")
        }
        
        let menu = NSMenu()
        menu.delegate = self
        
        let settingsMenuItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        
        menu.addItem(settingsMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(createSpeedMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)
        
        statusBarItem?.menu = menu
        
        SpeechManager.shared.appDelegate = self
    }

    
    @objc func openSettings(_ sender: NSStatusBarButton) {
        window = NSApplication.shared.windows.first
        
        if let window = window {
            if !window.canBecomeKey {
                return createSettingsWindow()
            }
            // If the settings window is already open, bring it to the front
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(self)
        } else {
            print("window is not available")
            // Create the settings window if it doesn't exist
            createSettingsWindow()
        }
    }
    
    func createSettingsWindow() {
        let contentView = ContentView()
        
        let windowWidth: CGFloat = 920
        let windowHeight: CGFloat = 760
        
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        settingsWindow.title = "Smooth Talker"
        settingsWindow.minSize = NSSize(width: 760, height: 650)
        settingsWindow.contentView = NSHostingView(rootView: contentView)
        
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        
        self.window = settingsWindow
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    
    func setTrayLoading(_ loading: Bool) {
        if loading {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "Loading")
        } else {
            statusBarItem?.button?.image = NSImage(systemSymbolName: "speaker.wave.2.bubble.left", accessibilityDescription: "Smooth Talker")
        }
    }
    
    @objc func quitApp(_ sender: NSStatusBarButton) {
        NSApplication.shared.terminate(self)
    }

    private func createSpeedMenuItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))

        let titleLabel = NSTextField(labelWithString: "Speed")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .left

        let slider = NSSlider(value: Preferences.shared.speakingSpeed, minValue: 0.25, maxValue: 4.0, target: self, action: #selector(speedSliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small

        let valueLabel = NSTextField(labelWithString: formatSpeed(slider.doubleValue))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let stackView = NSStackView(views: [titleLabel, slider, valueLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 42),
            slider.widthAnchor.constraint(equalToConstant: 130)
        ])

        speedSlider = slider
        speedValueLabel = valueLabel

        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        Preferences.shared.speakingSpeed = sender.doubleValue
        speedValueLabel?.stringValue = formatSpeed(sender.doubleValue)
    }

    private func formatSpeed(_ speed: Double) -> String {
        String(format: "%.2fx", speed)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let savedSpeed = Preferences.shared.speakingSpeed
        speedSlider?.doubleValue = savedSpeed
        speedValueLabel?.stringValue = formatSpeed(savedSpeed)
    }
}
