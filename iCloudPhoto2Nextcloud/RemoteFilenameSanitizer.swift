//
//  RemoteFilenameSanitizer.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

/// Nettoie les noms de fichiers avant l'envoi vers Nextcloud afin qu'ils restent
/// valides sur les systèmes de fichiers qui refusent certains caractères
/// (NTFS / Windows / partages SMB : `\ / : * ? " < > |` et caractères de contrôle).
///
/// Le nom d'origine est conservé tel quel dans `SyncedResource.originalFilename`
/// (affichage / journaux) ; seule la copie distante (`remoteFilename`) est nettoyée.
/// La vérification d'intégrité et la suppression distante lisent `remoteFilename`,
/// elles restent donc cohérentes sans aucun changement.
public nonisolated enum RemoteFilenameSanitizer {
    
    /// Caractères interdits sur NTFS/Windows + caractères de contrôle.
    private static let invalidCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: #"\/:*?"<>|"#)
        set.formUnion(.controlCharacters)
        return set
    }()
    
    /// Noms de périphériques réservés par Windows (interdits avec ou sans extension).
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]
    
    /// Caractère de remplacement des caractères interdits.
    private static let replacement = "_"
    
    /// Renvoie une version du nom compatible NTFS/Windows.
    /// - Les caractères interdits sont remplacés par `_`.
    /// - Les points et espaces en fin de nom sont retirés (Windows les supprime,
    ///   ce qui créerait un décalage entre le nom attendu et le nom écrit).
    /// - Les noms réservés Windows sont préfixés par `_`.
    /// - Un nom vide ou entièrement invalide devient `fichier`.
    public static func sanitize(_ filename: String) -> String {
        var result = filename
            .components(separatedBy: invalidCharacters)
            .joined(separator: replacement)
        
        while result.hasSuffix(".") || result.hasSuffix(" ") {
            result.removeLast()
        }
        
        let stem = result.split(separator: ".").first.map(String.init) ?? result
        if !stem.isEmpty && reservedNames.contains(stem.uppercased()) {
            result = replacement + result
        }
        
        if result.isEmpty {
            result = "fichier"
        }
        return result
    }
    
    /// Vrai si le nom sera modifié par `sanitize` (contient un caractère problématique).
    public static func needsSanitizing(_ filename: String) -> Bool {
        sanitize(filename) != filename
    }
}
