//
//  LocalizationTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

/// Vérifie les tables compilées embarquées dans le bundle de l'app.
/// (La langue à l'exécution est pilotée par la langue système, pas par le paramètre `locale:`
/// de String(localized:) — on teste donc directement le contenu des .lproj générés.)
struct LocalizationTests {

    private func compiledTable(lproj: String, table: String) throws -> [String: String] {
        let path = try #require(Bundle.main.path(forResource: table, ofType: "strings", inDirectory: "\(lproj).lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String])
    }

    @Test("English Localizable.strings ships the expected translations")
    func testEnglishTranslations() throws {
        let table = try compiledTable(lproj: "en", table: "Localizable")
        #expect(table["Mettre en pause"] == "Pause")
        #expect(table["Quitter"] == "Quit")
        #expect(table["Envoi %lld / %lld"] == "Uploading %lld / %lld")
        #expect(table["Tous les éléments sont déjà à jour sur Nextcloud."] == "All items are already up to date on Nextcloud.")
    }

    @Test("French Localizable.strings ships the source strings")
    func testFrenchTranslations() throws {
        let table = try compiledTable(lproj: "fr", table: "Localizable")
        #expect(table["Mettre en pause"] == "Mettre en pause")
        #expect(table["Envoi %lld / %lld"] == "Envoi %lld / %lld")
    }

    @Test("InfoPlist.strings ships localized photo permission texts")
    func testInfoPlistTranslations() throws {
        let en = try compiledTable(lproj: "en", table: "InfoPlist")
        #expect(en["NSPhotoLibraryUsageDescription"]?.contains("photo library") == true)

        let fr = try compiledTable(lproj: "fr", table: "InfoPlist")
        #expect(fr["NSPhotoLibraryUsageDescription"]?.contains("photothèque") == true)
    }

    @Test("WebDAV error descriptions resolve consistently")
    func testWebDAVErrorLocalization() {
        let error = WebDAVError.httpError(statusCode: 401, message: "Unauthorized")
        #expect(error.errorDescription == String(localized: "Erreur HTTP WebDAV (\(401)): Unauthorized"))
    }
}
