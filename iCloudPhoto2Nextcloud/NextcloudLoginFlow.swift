//
//  NextcloudLoginFlow.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

/// Erreurs du flux de connexion via navigateur (login flow Nextcloud).
public nonisolated enum LoginFlowError: LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case flowUnavailable
    case browserFailed
    case declined
    case timedOut
    case httpError(Int)
    case invalidResponse
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "URL du serveur Nextcloud invalide.")
        case .flowUnavailable:
            return String(localized: "Ce serveur ne semble pas prendre en charge le flux de connexion via navigateur.")
        case .browserFailed:
            return String(localized: "Impossible d'ouvrir le navigateur.")
        case .declined:
            return String(localized: "Autorisation refusée dans le navigateur.")
        case .timedOut:
            return String(localized: "Le délai d'autorisation est dépassé : annulez puis réessayez.")
        case .httpError(let code):
            return String(localized: "Erreur HTTP du flux de connexion (\(code)).")
        case .invalidResponse:
            return String(localized: "Réponse invalide du serveur lors du flux de connexion.")
        case .networkError(let detail):
            return String(localized: "Erreur réseau lors du flux de connexion : \(detail)")
        }
    }
}

/// Session de connexion lancée : à ouvrir dans le navigateur puis à interroger
/// (`poll`) jusqu'à ce que l'utilisateur autorise l'appareil.
public nonisolated struct LoginFlowSession: Sendable {
    public let pollToken: String
    public let pollEndpoint: URL
    public let loginURL: URL
    /// `true` : login flow v2 (poll en POST), `false` : v1 (poll en GET).
    public let isV2: Bool
    
    public init(pollToken: String, pollEndpoint: URL, loginURL: URL, isV2: Bool) {
        self.pollToken = pollToken
        self.pollEndpoint = pollEndpoint
        self.loginURL = loginURL
        self.isV2 = isV2
    }
}

/// Identifiants retournés par Nextcloud après autorisation dans le navigateur.
/// Le `appPassword` est un mot de passe d'application classique (révocable
/// depuis Réglages → Sécurité → Appareils).
public nonisolated struct LoginFlowCredentials: Sendable, Equatable {
    public let serverURL: String
    public let loginName: String
    public let appPassword: String
    
    public init(serverURL: String, loginName: String, appPassword: String) {
        self.serverURL = serverURL
        self.loginName = loginName
        self.appPassword = appPassword
    }
}

/// Flux de connexion via navigateur de Nextcloud (« se connecter pour ajouter un
/// appareil », sans mot de passe d'application saisi à la main) :
/// 1. `POST /index.php/login/flow/v2` (repli v1 pour les instances < 20) avec
///    un nom de client → l'appareil apparaît dans Réglages → Sécurité.
/// 2. Le navigateur s'ouvre sur l'URL `login` : l'utilisateur s'authentifie
///    avec ses identifiants habituels puis autorise l'appareil.
/// 3. On interroge l'endpoint `poll` (v2 : POST toutes les 3 s, 404 = en attente ;
///    v1 : GET, 202 = en attente) → réponse `{ server, loginName, appPassword }`.
public nonisolated enum NextcloudLoginFlow {
    private static let clientName = "iCloudPhoto2Nextcloud-macOS"
    private static let userAgent = "iCloudPhoto2Nextcloud-macOS/1.0"
    /// Durée maximale d'attente de l'autorisation (les jetons Nextcloud expirent ~10 min).
    private static let pollTimeout: TimeInterval = 9 * 60
    private static let pollInterval: TimeInterval = 3
    
    // MARK: - Décodage (testable sans réseau)
    
    private struct StartResponse: Decodable, Sendable {
        struct Poll: Decodable, Sendable {
            let token: String
            let endpoint: String
        }
        let poll: Poll
        let login: String
    }
    
    private struct PollResult: Decodable, Sendable {
        let server: String
        let loginName: String
        let appPassword: String
    }
    
    /// Normalise une URL de serveur (ajoute https:// si nécessaire, retire les slashes finaux).
    public static func normalizedBaseURL(from serverURL: String) -> URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base), url.host != nil else { return nil }
        return url
    }
    
    public static func decodeStartResponse(_ data: Data) throws -> LoginFlowSession {
        let start: StartResponse
        do {
            start = try JSONDecoder().decode(StartResponse.self, from: data)
        } catch {
            throw LoginFlowError.invalidResponse
        }
        guard let endpoint = URL(string: start.poll.endpoint),
              let login = URL(string: start.login) else {
            throw LoginFlowError.invalidResponse
        }
        return LoginFlowSession(pollToken: start.poll.token, pollEndpoint: endpoint, loginURL: login, isV2: true)
    }
    
    public static func decodePollResult(_ data: Data) throws -> LoginFlowCredentials {
        let result: PollResult
        do {
            result = try JSONDecoder().decode(PollResult.self, from: data)
        } catch {
            throw LoginFlowError.invalidResponse
        }
        return LoginFlowCredentials(serverURL: result.server, loginName: result.loginName, appPassword: result.appPassword)
    }
    
    // MARK: - Flux
    
    /// Démarre le flux de connexion : tente le login flow v2, sinon le v1
    /// (instances Nextcloud < 20). Renvoie la session à afficher dans le navigateur.
    public static func start(serverURL: String) async throws -> LoginFlowSession {
        guard let base = normalizedBaseURL(from: serverURL) else {
            throw LoginFlowError.invalidServerURL
        }
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }
        
        do {
            return try await beginFlow(base: base, v2: true, session: session)
        } catch LoginFlowError.httpError(let code) where code == 401 || code == 404 || code == 405 || code == 400 {
            // Instances < 20 ou config proxy/auth : le point d'entrée v2 n'existe pas ou
            // renvoie 401 (ex. mod_security, brute-force protection).
            do {
                return try await beginFlow(base: base, v2: false, session: session)
            } catch LoginFlowError.httpError(let code) where code == 401 || code == 404 || code == 405 || code == 400 {
                throw LoginFlowError.flowUnavailable
            }
        }
    }
    
    private static func beginFlow(base: URL, v2: Bool, session: URLSession) async throws -> LoginFlowSession {
        let path = v2 ? "index.php/login/v2" : "index.php/login/flow"
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw LoginFlowError.flowUnavailable
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let encodedName = clientName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientName
        request.httpBody = Data("client_name=\(encodedName)".utf8)
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LoginFlowError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LoginFlowError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LoginFlowError.httpError(http.statusCode)
        }
        
        let start = try JSONDecoder().decode(StartResponse.self, from: data)
        guard let endpoint = URL(string: start.poll.endpoint),
              let login = URL(string: start.login) else {
            throw LoginFlowError.invalidResponse
        }
        return LoginFlowSession(pollToken: start.poll.token, pollEndpoint: endpoint, loginURL: login, isV2: v2)
    }
    
    /// Interroge l'endpoint `poll` jusqu'à l'autorisation (ou l'annulation de la
    /// tâche appelante). Annulable via `Task.checkCancellation()`.
    public static func poll(session: LoginFlowSession) async throws -> LoginFlowCredentials {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        let urlSession = URLSession(configuration: sessionConfig)
        defer { urlSession.finishTasksAndInvalidate() }
        
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let (data, response) = try await pollRequest(session: session, urlSession: urlSession)
                guard let http = response as? HTTPURLResponse else {
                    throw LoginFlowError.invalidResponse
                }
                switch http.statusCode {
                case 200:
                    return try decodePollResult(data)
                case 202, 401, 404:
                    break // en attente de l'autorisation (certains serveurs renvoient 401)
                case 403:
                    throw LoginFlowError.declined
                default:
                    throw LoginFlowError.httpError(http.statusCode)
                }
            } catch let error as LoginFlowError {
                throw error
            } catch {
                // Erreur réseau transitoire : on retente après une pause plus longue.
                try await Task.sleep(for: .seconds(5))
                continue
            }
            try await Task.sleep(for: .seconds(session.isV2 ? pollInterval : 2))
        }
        throw LoginFlowError.timedOut
    }
    
    private static func pollRequest(session: LoginFlowSession, urlSession: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: session.pollEndpoint)
        if session.isV2 {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(session.pollToken)".utf8)
        } else {
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await urlSession.data(for: request)
    }
}