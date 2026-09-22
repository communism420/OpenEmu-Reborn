// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
import OpenEmuBase

import Cocoa

/// Preferences pane for ScreenScraper cover art credentials.
final class PrefScreenScraperController: NSViewController {

    // MARK: - UI Elements

    private let headerLabel     = NSTextField(labelWithString: "")
    private let descLabel       = NSTextField(wrappingLabelWithString: "")
    private let usernameLabel   = NSTextField(labelWithString: NSLocalizedString("Username", comment: ""))
    private let usernameField   = NSTextField()
    private let passwordLabel   = NSTextField(labelWithString: NSLocalizedString("Password", comment: ""))
    private let passwordField   = NSSecureTextField()
    private let saveButton      = NSButton()
    private let clearButton     = NSButton()
    private let statusLabel     = NSTextField(labelWithString: "")
    private let registerLabel   = NSTextField(labelWithString: "")

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 360))
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSavedCredentials()
        updateStatus()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateStatus()
    }

    // MARK: - Build UI

    private func buildUI() {
        // Header
        headerLabel.stringValue = NSLocalizedString("Cover Art", comment: "")
        headerLabel.font = .boldSystemFont(ofSize: 15)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerLabel)

        // Description
        descLabel.stringValue = NSLocalizedString("OpenEmu looks up cover art in three places: first the built-in OpenVGDB database, then ScreenScraper (if you're signed in below), and finally libretro-thumbnails as a last resort. Signing in to ScreenScraper gives the best coverage — registration is free.", comment: "")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descLabel)

        // Username label + field
        usernameLabel.font = .systemFont(ofSize: 13)
        usernameLabel.alignment = .right
        usernameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(usernameLabel)

        usernameField.placeholderString = NSLocalizedString("screenscraper.fr username", comment: "")
        usernameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(usernameField)

        // Password label + field
        passwordLabel.font = .systemFont(ofSize: 13)
        passwordLabel.alignment = .right
        passwordLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(passwordLabel)

        passwordField.placeholderString = NSLocalizedString("screenscraper.fr password", comment: "")
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(passwordField)

        // Save button
        saveButton.title = NSLocalizedString("Save", comment: "")
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveCredentials)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(saveButton)

        // Clear button
        clearButton.title = NSLocalizedString("Clear", comment: "")
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .regular
        clearButton.target = self
        clearButton.action = #selector(clearCredentials)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clearButton)

        // Status
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Register link
        registerLabel.stringValue = NSLocalizedString("Register at screenscraper.fr — it's free.", comment: "")
        registerLabel.font = .systemFont(ofSize: 11)
        registerLabel.textColor = .tertiaryLabelColor
        registerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(registerLabel)

        // Layout
        NSLayoutConstraint.activate([
            // Header
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            // Description
            descLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            // Username row
            usernameLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 28),
            usernameLabel.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: 156),
            usernameLabel.widthAnchor.constraint(equalToConstant: 80),

            usernameField.centerYAnchor.constraint(equalTo: usernameLabel.centerYAnchor),
            usernameField.leadingAnchor.constraint(equalTo: usernameLabel.trailingAnchor, constant: 8),
            usernameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            // Password row
            passwordLabel.topAnchor.constraint(equalTo: usernameField.bottomAnchor, constant: 12),
            passwordLabel.trailingAnchor.constraint(equalTo: usernameLabel.trailingAnchor),
            passwordLabel.widthAnchor.constraint(equalToConstant: 80),

            passwordField.centerYAnchor.constraint(equalTo: passwordLabel.centerYAnchor),
            passwordField.leadingAnchor.constraint(equalTo: passwordLabel.trailingAnchor, constant: 8),
            passwordField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            // Buttons
            saveButton.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 20),
            saveButton.trailingAnchor.constraint(equalTo: passwordField.trailingAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 80),

            clearButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            clearButton.widthAnchor.constraint(equalToConstant: 80),

            // Status
            statusLabel.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            // Register link
            registerLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            registerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            registerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
        ])
    }

    // MARK: - Credential Management

    private func loadSavedCredentials() {
        usernameField.stringValue = OEPreferences.shared.string(forKey: "ScreenScraperUsername") ?? ""
        // Password is stored encrypted — show placeholder only, don't pre-fill for security
        if OECredentialStore.shared.has(.screenScraperPassword) {
            passwordField.placeholderString = NSLocalizedString("••••••••  (saved)", comment: "")
        }
    }

    private func updateStatus() {
        let username = OEPreferences.shared.string(forKey: "ScreenScraperUsername") ?? ""
        let isSignedIn = !username.isEmpty && OECredentialStore.shared.has(.screenScraperPassword)

        if isSignedIn {
            Task { @MainActor in
                if let fetchError = ScreenScraperClient.shared.lastFetchError,
                   let description = fetchError.errorDescription {
                    // A previous game lookup failed — surface the error so the user knows.
                    self.statusLabel.stringValue = description
                    self.statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
                } else if ScreenScraperClient.shared.hasVerifiedCredentials {
                    self.statusLabel.stringValue = String(format: NSLocalizedString("✓  Signed in as %@", comment: ""), username)
                    self.statusLabel.textColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
                } else {
                    // Credentials are stored but haven't been verified this session yet.
                    // Silently verify in the background so the pane shows the correct state
                    // without the user needing to hit Save.
                    self.statusLabel.stringValue = NSLocalizedString("Verifying…", comment: "")
                    self.statusLabel.textColor = .secondaryLabelColor
                    self.silentlyVerify(username: username)
                }
            }
        } else {
            statusLabel.stringValue = NSLocalizedString("Not signed in — ScreenScraper will be skipped. OpenVGDB and libretro-thumbnails are still active.", comment: "")
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Actions

    /// Called on pane load when credentials exist but haven't been confirmed this session.
    /// Fires a lightweight API call in the background and updates the status label with the result.
    private func silentlyVerify(username: String) {
        guard let password = OECredentialStore.shared.get(.screenScraperPassword) else { return }
        Task { @MainActor in
            do {
                let ok = try await ScreenScraperClient.shared.verifyCredentials(username: username, password: password)
                if ok {
                    ScreenScraperClient.shared.clearLastFetchError()
                    self.statusLabel.stringValue = String(format: NSLocalizedString("✓  Signed in as %@", comment: ""), username)
                    self.statusLabel.textColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
                } else {
                    self.statusLabel.stringValue = NSLocalizedString("ScreenScraper rejected these credentials. Re-enter your password and save.", comment: "")
                    self.statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
                }
            } catch {
                // Network unavailable — don't show an error for a background check, just go neutral.
                self.statusLabel.stringValue = NSLocalizedString("Could not reach ScreenScraper — check your connection.", comment: "")
                self.statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    @objc private func saveCredentials() {
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !username.isEmpty else {
            statusLabel.stringValue = NSLocalizedString("Username cannot be empty.", comment: "")
            statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
            return
        }
        guard !password.isEmpty else {
            statusLabel.stringValue = NSLocalizedString("Password cannot be empty.", comment: "")
            statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
            return
        }

        OEPreferences.shared.set(username, forKey: "ScreenScraperUsername")
        OECredentialStore.shared.set(password, forKey: .screenScraperPassword)
        passwordField.stringValue = ""
        passwordField.placeholderString = NSLocalizedString("••••••••  (saved)", comment: "")

        saveButton.isEnabled = false
        clearButton.isEnabled = false
        statusLabel.stringValue = NSLocalizedString("Verifying credentials…", comment: "")
        statusLabel.textColor = .secondaryLabelColor

        Task { @MainActor in
            do {
                let ok = try await ScreenScraperClient.shared.verifyCredentials(username: username, password: password)
                if ok {
                    // Clear any prior fetch error so the pane reflects the fresh verification.
                    ScreenScraperClient.shared.clearLastFetchError()
                    statusLabel.stringValue = String(format: NSLocalizedString("✓  Signed in as %@", comment: ""), username)
                    statusLabel.textColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
                } else {
                    statusLabel.stringValue = NSLocalizedString("ScreenScraper rejected these credentials. Check your username and password.", comment: "")
                    statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
                }
            } catch {
                statusLabel.stringValue = NSLocalizedString("Could not reach ScreenScraper — check your connection.", comment: "")
                statusLabel.textColor = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
            }
            saveButton.isEnabled = true
            clearButton.isEnabled = true
        }
    }

    @objc private func clearCredentials() {
        OEPreferences.shared.removeObject(forKey: "ScreenScraperUsername")
        OECredentialStore.shared.remove(.screenScraperPassword)
        usernameField.stringValue = ""
        passwordField.stringValue = ""
        passwordField.placeholderString = NSLocalizedString("screenscraper.fr password", comment: "")
        updateStatus()
    }
}

// MARK: - PreferencePane

extension PrefScreenScraperController: PreferencePane {

    var icon: NSImage? {
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: NSLocalizedString("Cover Art", comment: ""))
        }
        return NSImage(named: NSImage.slideshowTemplateName)
    }

    var panelTitle: String { "Cover Art" }

    var viewSize: NSSize { NSSize(width: 468, height: 360) }
}
