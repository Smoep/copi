import AppKit

/// Blocks application startup until the local database encryption key is
/// available in memory. The passphrase is handed directly to the crypto layer
/// and is never logged or persisted by this UI.
enum DevelopmentPassphrasePrompt {
    static func unlockOrInitialize() -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if SecurePayloadCrypto.shared.hasPassphraseConfiguration {
            return unlockExistingStorage()
        }
        return initializeStorage()
    }

    private static func unlockExistingStorage() -> Bool {
        var errorMessage: String?

        while true {
            let field = makeSecureField(placeholder: "Database passphrase")
            let alert = makeAlert(
                title: "Unlock Copi",
                message: unlockMessage(errorMessage: errorMessage),
                primaryButton: "Unlock",
                fields: [field],
                tertiaryButton: "Start Fresh…"
            )

            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                guard confirmStartFresh() else { continue }
                return initializeStorage()
            }
            guard response == .alertFirstButtonReturn else { return false }

            let passphrase = field.stringValue
            guard !passphrase.isEmpty else {
                errorMessage = "Enter the database passphrase."
                continue
            }

            do {
                try SecurePayloadCrypto.shared.unlock(passphrase: passphrase)
                return true
            } catch {
                errorMessage = "That passphrase could not unlock Copi. Try again.\n\(error.localizedDescription)"
            }
        }
    }

    private static func initializeStorage() -> Bool {
        var errorMessage: String?

        while true {
            let passphraseField = makeSecureField(placeholder: "New database passphrase")
            let confirmationField = makeSecureField(placeholder: "Confirm passphrase")
            let alert = makeAlert(
                title: "Create Copi Passphrase",
                message: initializationMessage(errorMessage: errorMessage),
                primaryButton: "Create",
                fields: [passphraseField, confirmationField]
            )

            guard alert.runModal() == .alertFirstButtonReturn else { return false }

            let passphrase = passphraseField.stringValue
            let confirmation = confirmationField.stringValue
            guard passphrase.count >= SecurePayloadCrypto.minimumPassphraseLength else {
                errorMessage = "Use at least \(SecurePayloadCrypto.minimumPassphraseLength) characters."
                continue
            }
            guard passphrase == confirmation else {
                errorMessage = "The passphrases do not match."
                continue
            }

            do {
                try SecureStorageBootstrap.initializePassphraseStorage(passphrase: passphrase)
                return true
            } catch {
                errorMessage = "Copi could not create encrypted storage. Try again.\n\(error.localizedDescription)"
            }
        }
    }

    private static func makeSecureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(string: "")
        field.placeholderString = placeholder
        field.frame.size = NSSize(width: 360, height: 24)
        return field
    }

    private static func makeAlert(
        title: String,
        message: String,
        primaryButton: String,
        fields: [NSSecureTextField],
        tertiaryButton: String? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.keyEquivalent = "\u{1b}"
        if let tertiaryButton {
            alert.addButton(withTitle: tertiaryButton)
        }

        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(
            x: 0,
            y: 0,
            width: 360,
            height: CGFloat(fields.count * 24 + max(0, fields.count - 1) * 8)
        )
        fields.forEach { field in
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = fields.first
        return alert
    }

    private static func unlockMessage(errorMessage: String?) -> String {
        message(
            errorMessage: errorMessage,
            body: "Enter your passphrase to unlock Copi's encrypted database."
        )
    }

    private static func confirmStartFresh() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Start Copi with a fresh encrypted store?"
        alert.informativeText = "This permanently removes local clipboard history, favorites, and suggestion-learning data, then lets you create a new database passphrase. External encrypted backup files and the obsolete Keychain item are not changed. This cannot be undone."
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func initializationMessage(errorMessage: String?) -> String {
        let migrationMessage: String
        if SecureStorageBootstrap.hasExistingEncryptedArtifacts {
            migrationMessage = "Copi found local storage from an earlier build. Creating this passphrase starts local clipboard history, favorites, and suggestion counts fresh. External backup files are not changed."
        } else {
            migrationMessage = "Local clipboard history, favorites, and suggestion counts start fresh. External backup files are not changed."
        }

        return message(
            errorMessage: errorMessage,
            body: "Create a passphrase of at least \(SecurePayloadCrypto.minimumPassphraseLength) characters. Copi does not use macOS Keychain for its local encrypted database. The derived encryption key stays in memory only until Copi quits.\n\nIf you forget this passphrase, the encrypted local data cannot be recovered.\n\n\(migrationMessage)"
        )
    }

    private static func message(errorMessage: String?, body: String) -> String {
        guard let errorMessage else { return body }
        return "\(errorMessage)\n\n\(body)"
    }
}
