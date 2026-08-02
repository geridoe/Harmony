import Foundation

/// Real MusicKit requests belong here after MusicKit is enabled for the App ID.
/// Tokens must be provisioned securely and are never embedded in the app.
enum AppleMusicIntegrationStatus { case mockConnected, requiresAuthorization }
