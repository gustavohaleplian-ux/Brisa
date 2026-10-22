import Foundation

/// An error shown to the person in plain language, keeping LG's code for handling.
struct BrisaError: LocalizedError {
    let message: String
    /// LG ThinQ error code, when the failure came from the API.
    var code: String? = nil
    var errorDescription: String? { message }

    // Groups from the official SDK's ThinQAPIErrorCodes.
    /// The device or its profile does not provide the feature at all.
    static let unsupportedCodes: Set<String> = ["1219", "1220", "1221", "2101", "2201", "2202", "2203"]
    /// The feature exists, but not in the current mode or power state.
    static let stateCodes: Set<String> = ["1223", "2205", "2301", "2302", "2303", "2304", "2305"]
    /// Transient failures worth retrying later.
    static let temporaryCodes: Set<String> = ["1222", "2000", "2208", "2209", "2210", "2212", "2214"]

    var isUnsupported: Bool { code.map(Self.unsupportedCodes.contains) ?? false }
}

/// HTTPS client for the LG ThinQ Connect API, sending the same headers as LG's
/// official SDK. The token is only held in memory; it is stored by `TokenVault`.
struct ThinQClient {
    let token: String
    let clientID: String
    // Public application identifier distributed by LG's Apache-2.0 SDK.
    // This is NOT the user's Personal Access Token.
    private let applicationKey = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"

    /// Cleans a pasted Personal Access Token: drops a leading "Bearer" (the header
    /// adds its own), surrounding quotes, and any whitespace or invisible characters
    /// copied along with it, which LG rejects as a malformed request.
    static func normalizedToken(_ raw: String) -> String {
        var token = raw.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) &&
                      !CharacterSet.controlCharacters.contains($0) &&
                      $0.properties.generalCategory != .format }
            .map(String.init).joined()
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        while token.lowercased().hasPrefix("bearer") {
            token = String(token.dropFirst("bearer".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
        return token
    }

    /// x-message-id as in the official SDK: URL-safe base64 of 16 random bytes,
    /// without padding (22 characters).
    static func messageID() -> String {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func request(_ path: String, body: [String: Any]? = nil) async throws -> Any {
        // Brazil is mapped to AIC by the official LG SDK.
        let url = URL(string: "https://api-aic.lgthinq.com/" + path)!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        // Same header set as the official SDK; GET requests carry no Content-Type.
        let headers = ["Authorization": "Bearer \(token)", "x-country": "BR",
                       "x-client-id": clientID, "x-message-id": Self.messageID(),
                       "x-api-key": applicationKey, "x-service-phase": "OP"]
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-conditional-control")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrisaError(message: "Resposta de rede inválida.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if !(200..<300).contains(http.statusCode) || json?["error"] is [String: Any] {
            let error = json?["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "\(http.statusCode)"
            let original = error?["message"] as? String
            // Keep LG's own status, code and message visible for diagnosis.
            let detail = "HTTP \(http.statusCode) · código \(code)" + (original.map { " · \($0)" } ?? "")
            let message: String
            switch code {
            case "1000", "1101", "1102", "1104", "1216", "1311":
                message = "A LG recusou o formato da solicitação. Gere uma nova chave e cole somente o código, sem \"Bearer\"."
            case "1307": message = "A LG não oferece a API para a região desta conta."
            case "1103", "1218", "1302", "401": message = "Chave inválida ou expirada. Gere outra chave ThinQ."
            case "1308", "1305", "1309", "403": message = "A chave não tem permissão. Confira acesso aos aparelhos e controle."
            case "1222": message = "O ar está sem conexão. Confira o ThinQ e o Wi-Fi."
            case "1306", "429": message = "Limite de consultas atingido. Aguarde antes de atualizar."
            case _ where BrisaError.unsupportedCodes.contains(code):
                message = "Este aparelho não oferece esse recurso pela API da LG."
            case _ where BrisaError.stateCodes.contains(code):
                message = "O aparelho não aceita esse comando no modo ou estado atual."
            case _ where BrisaError.temporaryCodes.contains(code):
                message = "O aparelho não respondeu a tempo. Tente novamente em instantes."
            case "2207": message = "O aparelho recusou o comando."
            default: message = "A LG não concluiu a solicitação."
            }
            throw BrisaError(message: message + " (" + detail + ")", code: code)
        }
        if body != nil { return json?["response"] ?? [:] }
        guard let result = json?["response"] else {
            throw BrisaError(message: "Resposta ThinQ em formato não reconhecido.")
        }
        return result
    }
}
