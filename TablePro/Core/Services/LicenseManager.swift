//
//  LicenseManager.swift
//  TablePro
//
//  Orchestrates license activation, offline verification, and periodic re-validation
//

import Combine
import Foundation
import os

/// Manages the app's license state with offline-first verification
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LicenseManager")

    /// Current cached license (nil = unlicensed)
    @Published private(set) var license: License?

    /// Current license status
    @Published private(set) var status: LicenseStatus = .unlicensed

    /// Whether a network operation is in progress
    @Published private(set) var isValidating: Bool = false

    /// Last error from an operation (cleared on success)
    @Published private(set) var lastError: LicenseError?

    private let storage = LicenseStorage.shared
    private let apiClient = LicenseAPIClient.shared
    private let verifier = LicenseSignatureVerifier.shared

    /// Re-validation interval: 7 days
    private let revalidationInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Grace period: 30 days without server contact before forcing re-validation
    private let gracePeriodDays = 30

    private var revalidationTimer: Timer?

    private init() {
        loadCachedLicense()
    }

    // MARK: - Startup

    /// Load cached license from storage and re-verify its signature offline
    private func loadCachedLicense() {
        guard let cached = storage.loadLicense() else {
            status = .unlicensed
            return
        }

        // Verify license belongs to this machine (prevents backup/restore cross-machine use)
        guard cached.machineId == storage.machineId else {
            Self.logger.warning("Cached license machineId mismatch, clearing")
            storage.clearAll()
            status = .unlicensed
            return
        }

        // Re-verify signature offline with embedded public key
        do {
            _ = try verifier.verify(payload: cached.signedPayload)

            license = cached
            evaluateStatus()

            Self.logger.debug("Loaded cached license for \(cached.email)")
        } catch {
            // Signature invalid — clear everything
            Self.logger.error("Cached license signature invalid, clearing")
            storage.clearAll()
            license = nil
            status = .unlicensed
        }
    }

    /// Start periodic re-validation timer. Call from AppDelegate.applicationDidFinishLaunching.
    func startPeriodicValidation() {
        // Check if revalidation is needed right now
        if let license, license.daysSinceLastValidation >= Int(revalidationInterval / 86_400) {
            Task {
                await revalidate()
            }
        }

        // Schedule periodic timer
        revalidationTimer?.invalidate()
        revalidationTimer = Timer.scheduledTimer(
            withTimeInterval: revalidationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.revalidate()
            }
        }
    }

    // MARK: - Activation

    /// Activate a license key on this machine
    func activate(licenseKey: String) async throws {
        let trimmedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty else {
            throw LicenseError.invalidKey
        }

        isValidating = true
        lastError = nil
        defer { isValidating = false }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let request = LicenseActivationRequest(
            licenseKey: trimmedKey,
            machineId: storage.machineId,
            machineName: storage.machineName,
            appVersion: appVersion,
            osVersion: osVersion
        )

        do {
            // Call server
            let signedPayload = try await apiClient.activate(request: request)

            // Verify signature
            let payloadData = try verifier.verify(payload: signedPayload)

            // Build and store license
            let newLicense = License.from(
                payload: payloadData,
                signedPayload: signedPayload,
                machineId: storage.machineId
            )

            storage.saveLicenseKey(trimmedKey)
            storage.saveLicense(newLicense)

            license = newLicense
            evaluateStatus()

            NotificationCenter.default.post(name: .licenseStatusDidChange, object: nil)
            Self.logger.info("License activated for \(payloadData.email)")
        } catch let error as LicenseError {
            lastError = error
            throw error
        } catch {
            let licenseError = LicenseError.networkError(error)
            lastError = licenseError
            throw licenseError
        }
    }

    // MARK: - Deactivation

    /// Deactivate the license on this machine
    func deactivate() async throws {
        guard let license else { return }

        isValidating = true
        lastError = nil
        defer { isValidating = false }

        let request = LicenseDeactivationRequest(
            licenseKey: license.key,
            machineId: storage.machineId
        )

        do {
            try await apiClient.deactivate(request: request)
        } catch {
            // Log but don't block — clear local state regardless.
            // By design, deactivation always clears local data even if the API call fails.
            // The user will need their license key to reactivate.
            Self.logger.warning("Deactivation API call failed: \(error.localizedDescription)")
        }

        // Clear local state (Keychain key + UserDefaults payload)
        storage.clearAll()
        self.license = nil
        status = .deactivated

        revalidationTimer?.invalidate()
        revalidationTimer = nil

        NotificationCenter.default.post(name: .licenseStatusDidChange, object: nil)
        Self.logger.info("License deactivated")
    }

    // MARK: - Re-validation

    /// Periodic re-validation: refresh license from server, fall back to offline grace period
    private func revalidate() async {
        guard let license else { return }

        isValidating = true
        defer { isValidating = false }

        let request = LicenseValidationRequest(
            licenseKey: license.key,
            machineId: storage.machineId
        )

        do {
            let signedPayload = try await apiClient.validate(request: request)
            let payloadData = try verifier.verify(payload: signedPayload)

            // Update cached license with fresh data
            let updatedLicense = License.from(
                payload: payloadData,
                signedPayload: signedPayload,
                machineId: storage.machineId
            )

            storage.saveLicense(updatedLicense)
            self.license = updatedLicense
            evaluateStatus()

            Self.logger.debug("License re-validated successfully")
        } catch {
            // Network failure — use grace period
            Self.logger.warning("Re-validation failed: \(error.localizedDescription)")

            if license.daysSinceLastValidation > gracePeriodDays {
                // Grace period exceeded — mark as validation failed
                self.status = .validationFailed
                Self.logger.error("Grace period exceeded (\(license.daysSinceLastValidation) days)")
            }
            // Otherwise keep using cached license (still within grace period)
        }

        NotificationCenter.default.post(name: .licenseStatusDidChange, object: nil)
    }

    // MARK: - Status Evaluation

    /// Evaluate current license status based on expiration, grace period, and signature validity
    private func evaluateStatus() {
        guard let license else {
            status = .unlicensed
            return
        }

        // Check server-reported status
        switch license.status {
        case .suspended:
            status = .suspended
            return
        case .expired:
            status = .expired
            return
        case .deactivated:
            status = .deactivated
            return
        default:
            break
        }

        // Check local expiration
        if license.isExpired {
            status = .expired
            return
        }

        // Check grace period
        if license.daysSinceLastValidation > gracePeriodDays {
            status = .validationFailed
            return
        }

        status = .active
    }
}
