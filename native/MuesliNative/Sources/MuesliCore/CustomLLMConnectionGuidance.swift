import Foundation

/// Explains transport failures without including endpoint URLs or credentials.
public enum CustomLLMConnectionGuidance {
    public static let endpointHelp = "Use HTTPS for LAN/remote servers; HTTP is for localhost."

    public static func message(for error: Error) -> String? {
        guard let error = error as? URLError else { return nil }
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocked this connection because it requires HTTPS. Enable TLS on your Custom LLM server or use an HTTPS reverse proxy such as Caddy, then update the endpoint in Settings. The certificate must be trusted by your Mac."
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The Custom LLM server's HTTPS certificate could not be verified. Use a valid certificate trusted by your Mac that matches the endpoint hostname, then try again."
        case .secureConnectionFailed:
            return "A secure connection to the Custom LLM server could not be established. Check the server's TLS configuration and use an HTTPS endpoint with a valid certificate trusted by your Mac."
        default:
            return nil
        }
    }
}
