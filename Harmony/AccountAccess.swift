import AuthenticationServices
import CryptoKit
import SwiftUI
import Supabase

enum HarmonyAccountState: Equatable {
    case loading
    case guest
    case apple
    case signedOut
    case revoked
    case failed(String)
}

@MainActor
final class HarmonyAccountController: NSObject, ObservableObject {
    @Published private(set) var state: HarmonyAccountState = .loading
    @Published private(set) var isWorking = false

    private let client: SupabaseClient
    private var rawNonce: String?
    private var authObservation: Task<Void, Never>?

    init(client: SupabaseClient? = nil) {
        self.client = client ?? HarmonySupabaseClient.shared
        super.init()
        let observedClient = self.client
        authObservation = Task { [weak self, observedClient] in
            for await (_, session) in observedClient.auth.authStateChanges {
                guard !Task.isCancelled else { return }
                self?.apply(session: session)
            }
        }
    }

    deinit { authObservation?.cancel() }

    func bootstrap() async {
        do {
            let session = try await client.auth.session
            apply(session: session)
            await verifyAppleCredentialIfNeeded(session: session)
        } catch {
            state = .signedOut
        }
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.makeNonce()
        rawNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        isWorking = true
        defer { isWorking = false; rawNonce = nil }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = rawNonce else {
                throw AccountAccessError.invalidAppleCredential
            }
            let credentials = OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                nonce: nonce
            )
            let existing = client.auth.currentSession
            let session: Session
            if existing?.user.isAnonymous == true {
                session = try await client.auth.linkIdentityWithIdToken(credentials: credentials)
                HarmonyLog.authentication.info("Anonymous account upgraded with Apple identity")
            } else {
                session = try await client.auth.signInWithIdToken(credentials: credentials)
                HarmonyLog.authentication.info("Apple authentication completed")
            }
            apply(session: session)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            HarmonyLog.authentication.info("Apple authentication cancelled")
        } catch {
            let code = HarmonyLog.safeFailure(error)
            state = .failed(code)
            HarmonyLog.authentication.error("Apple authentication failed: \(code, privacy: .public)")
        }
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
            state = .signedOut
        } catch {
            state = .failed(HarmonyLog.safeFailure(error))
        }
    }

    func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let response: DeleteAccountResult = try await client.functions.invoke("delete-account")
            guard response.deleted else { throw AccountAccessError.deletionRejected }
            try await client.auth.signOut(scope: .local)
            state = .signedOut
            HarmonyLog.authentication.info("Account deletion completed")
        } catch {
            let code = HarmonyLog.safeFailure(error)
            state = .failed(code)
            HarmonyLog.authentication.error("Account deletion failed: \(code, privacy: .public)")
        }
    }

    private func apply(session: Session?) {
        guard let session else { state = .signedOut; return }
        state = session.user.isAnonymous ? .guest : .apple
    }

    private func verifyAppleCredentialIfNeeded(session: Session) async {
        guard !session.user.isAnonymous,
              let identity = session.user.identities?.first(where: { $0.provider == "apple" }) else { return }
        do {
            let result = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: identity.id)
            if result == .revoked || result == .notFound { state = .revoked }
        } catch {
            HarmonyLog.authentication.error("Apple credential verification failed: \(HarmonyLog.safeFailure(error), privacy: .public)")
        }
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func makeNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var generator = SystemRandomNumberGenerator()
        while result.count < length { result.append(characters.randomElement(using: &generator)!) }
        return result
    }
}

private struct DeleteAccountResult: Decodable { let deleted: Bool }
private enum AccountAccessError: Error { case invalidAppleCredential, deletionRejected }

struct HarmonyAccountSheet: View {
    @ObservedObject var account: HarmonyAccountController
    @ObservedObject var notifications: HarmonyNotificationController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Text(statusText)
                    if account.state != .apple {
                        SignInWithAppleButton(.continue) { account.configure($0) } onCompletion: {
                            result in Task { await account.complete(result) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 48)
                        .disabled(account.isWorking)
                    } else {
                        Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                        Button("Delete account", role: .destructive) { confirmsDeletion = true }
                    }
                }
                Section("Notifications") {
                    Toggle("Follows and requests", isOn: $notifications.preferences.follows)
                    Toggle("Comments and reactions", isOn: $notifications.preferences.socialActivity)
                    Toggle("Session invitations", isOn: $notifications.preferences.sessions)
                    Toggle("Live listening", isOn: $notifications.preferences.liveListening)
                    Button("Enable notifications") { Task { await notifications.requestAuthorizationAndRegister() } }
                }
            }
            .navigationTitle("Account & alerts")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog(
                "Permanently delete your Harmony account?",
                isPresented: $confirmsDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { await account.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your profile, sessions, social activity, provider connections, and authored content will be removed. This cannot be undone.")
            }
        }
    }

    private var statusText: String {
        switch account.state {
        case .loading: return "Checking your account…"
        case .guest: return "Guest account — continue with Apple to preserve your profile."
        case .apple: return "Signed in with Apple"
        case .signedOut: return "Signed out"
        case .revoked: return "Apple access was revoked. Sign in again to recover access."
        case .failed(let code): return "Sign-in failed (\(code)). Please try again."
        }
    }
}
