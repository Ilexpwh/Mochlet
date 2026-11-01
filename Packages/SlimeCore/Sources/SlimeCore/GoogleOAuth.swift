import Foundation
import AppKit
@preconcurrency import AppAuth

// AppAuth owns PKCE, state validation, code exchange and refresh. This small
// external user agent opens the system browser for Google's loopback flow.
@MainActor private final class GoogleBrowser: NSObject, @preconcurrency OIDExternalUserAgent {
    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        NSWorkspace.shared.open(request.externalUserAgentRequestURL())
    }
    func dismiss(animated: Bool, completion: @escaping () -> Void) { completion() }
}

@MainActor public final class GoogleOAuth {
    private let credentials = CredentialStore()
    private let store: Store
    private var states: [String: OIDAuthState] = [:]
    private var busy = false
    private var listener: OIDRedirectHTTPHandler?
    public init(store: Store) { self.store = store }
    public func cancel() { listener?.cancelHTTPListener() }
    public static func request(clientID: String, secret: String?, scopes: Set<String>, redirect: URL) throws -> OIDAuthorizationRequest {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains(where: { $0.isWhitespace }),
              redirect.scheme == "http", redirect.host == "127.0.0.1" || redirect.host == "::1", redirect.port != nil else {
            throw MochletError.message("Use a Google Desktop app OAuth client and a loopback callback.")
        }
        let configuration = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
        return OIDAuthorizationRequest(configuration: configuration, clientId: clientID, clientSecret: secret,
            scopes: Array(scopes.union(GoogleScope.identity)).sorted(), redirectURL: redirect, responseType: OIDResponseTypeCode,
            additionalParameters: ["access_type": "offline", "prompt": "consent select_account"])
    }
    public func connect(clientID: String, secret: String?, scopes: Set<String>) async throws -> ConnectedAccount {
        guard !busy else { throw MochletError.message("A Google account operation is already in progress.") }; busy = true; defer { busy = false }
        guard listener == nil else { throw MochletError.message("Finish or cancel the current Google sign-in first.") }
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirect = handler.startHTTPListener(&listenerError)
        if listenerError != nil { throw MochletError.message("Could not open the local Google sign-in callback.") }
        listener = handler
        defer { handler.cancelHTTPListener(); listener = nil }
        let request = try Self.request(clientID: clientID, secret: secret, scopes: scopes, redirect: redirect)
        let timeout = Task { try? await Task.sleep(for: .seconds(300)); if !Task.isCancelled { handler.cancelHTTPListener() } }
        defer { timeout.cancel() }
        let state: OIDAuthState = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: GoogleBrowser()) { state, _ in
                    if let state { continuation.resume(returning: state) }
                    else { continuation.resume(throwing: MochletError.message("Google sign-in was cancelled or failed. Check the Desktop OAuth client and consent configuration.")) }
                }
            }
        } onCancel: { Task { @MainActor in handler.cancelHTTPListener() } }
        try Task.checkCancellation()
        guard let token = state.lastTokenResponse?.accessToken else { throw MochletError.message("Google returned no access token.") }
        var identityRequest = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        identityRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let identity = try JSONDecoder().decode(JSONValue.self, from: await ConnectorHTTP().send(identityRequest))
        guard let sub = identity["sub"].string, !sub.isEmpty, let email = identity["email"].string,
              identity["email_verified"] == .bool(true) else { throw MochletError.message("Google did not verify this account identity.") }
        let granted = Set((state.scope ?? "").split(separator: " ").map(String.init))
        var account = ConnectedAccount(provider: "google", remoteID: sub, label: email, scopes: granted)
        if let old = try await store.connections().first(where: { $0.provider == "google" && $0.remoteID == sub }) { account.id = old.id; account.projectIDs = old.projectIDs }
        try Task.checkCancellation()
        let credentialID = "google.oauth." + account.id
        let previous = try await credentials.read(credentialID)
        try await persist(state, account: account)
        do { try await store.saveConnection(account) }
        catch {
            if let previous { try await credentials.save(previous, account: credentialID) }
            else { try await credentials.remove(credentialID) }
            throw error
        }
        states[account.id] = state
        return account
    }
    private func persist(_ state: OIDAuthState, account: ConnectedAccount) async throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        try await credentials.save(data, account: "google.oauth." + account.id)
    }
    public func token(for account: ConnectedAccount, scope: String) async throws -> String {
        guard !busy else { throw MochletError.message("A Google account operation is already in progress.") }; busy = true; defer { busy = false }
        guard account.provider == "google", account.scopes.contains(scope), try await store.connections().contains(account) else { throw MochletError.message("This Google connection or permission is unavailable. Refresh connections or sign in again.") }
        let state: OIDAuthState
        if let cached = states[account.id] { state = cached }
        else {
            guard let data = try await credentials.read("google.oauth." + account.id),
                  let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else { throw MochletError.message("Sign in to this Google account again.") }
            state = restored; states[account.id] = restored
        }
        let token: String = try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, _ in
                if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: MochletError.message("Google access expired or was revoked. Sign in again.")) }
            }
        }
        guard try await store.connections().contains(account) else { throw MochletError.message("Google was disconnected during refresh.") }
        try await persist(state, account: account)
        let granted = Set((state.scope ?? "").split(separator: " ").map(String.init))
        if granted != account.scopes {
            var updated = account; updated.scopes = granted; updated.generation = UUID().uuidString
            try await store.saveConnection(updated)
            throw MochletError.message("Google permissions changed. Refresh connections before continuing.")
        }
        return token
    }
    public func disconnect(_ account: ConnectedAccount) async throws {
        guard !busy else { throw MochletError.message("A Google account operation is already in progress.") }; busy = true; defer { busy = false }
        try await store.disconnect(account.id); states.removeValue(forKey: account.id)
        try await credentials.remove("google.oauth." + account.id)
    }
}
