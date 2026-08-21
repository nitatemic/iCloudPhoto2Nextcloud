//
//  RemoteFilenameSanitizerTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct RemoteFilenameSanitizerTests {
    
    @Test("Les caractères interdits sur NTFS sont remplacés")
    func testInvalidCharactersReplaced() {
        #expect(RemoteFilenameSanitizer.sanitize("photo:2024.jpg") == "photo_2024.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("a/b\\c.jpg") == "a_b_c.jpg")
        #expect(RemoteFilenameSanitizer.sanitize(#"star*?.jpg"#) == "star__.jpg")
        #expect(RemoteFilenameSanitizer.sanitize(#"quote"file.jpg"#) == "quote_file.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("a<b>c|d.jpg") == "a_b_c_d.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("IMG:1234.HEIC") == "IMG_1234.HEIC")
    }
    
    @Test("Un nom valide reste inchangé")
    func testValidNameUnchanged() {
        #expect(RemoteFilenameSanitizer.sanitize("IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(RemoteFilenameSanitizer.sanitize("photo de vacances.jpg") == "photo de vacances.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("vidéo-2024.MOV") == "vidéo-2024.MOV")
        #expect(RemoteFilenameSanitizer.sanitize("archive.tar.gz") == "archive.tar.gz")
    }
    
    @Test("Points et espaces en fin de nom sont retirés")
    func testTrailingDotsAndSpacesRemoved() {
        #expect(RemoteFilenameSanitizer.sanitize("photo.jpg.") == "photo.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("photo.jpg ") == "photo.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("photo...") == "photo")
        #expect(RemoteFilenameSanitizer.sanitize("photo. . ") == "photo")
    }
    
    @Test("Les noms réservés Windows sont préfixés")
    func testReservedNamesPrefixed() {
        #expect(RemoteFilenameSanitizer.sanitize("CON.jpg") == "_CON.jpg")
        #expect(RemoteFilenameSanitizer.sanitize("con") == "_con")
        #expect(RemoteFilenameSanitizer.sanitize("nul.txt") == "_nul.txt")
        #expect(RemoteFilenameSanitizer.sanitize("COM1") == "_COM1")
        // Pas réservé : préfixe inutile.
        #expect(RemoteFilenameSanitizer.sanitize("CONSOLE.jpg") == "CONSOLE.jpg")
    }
    
    @Test("Un nom vide ou entièrement invalide produit un repli")
    func testEmptyFallback() {
        #expect(RemoteFilenameSanitizer.sanitize("") == "fichier")
        #expect(RemoteFilenameSanitizer.sanitize("...") == "fichier")
        // ":::" → "___" (trois underscores), nom valide
        #expect(RemoteFilenameSanitizer.sanitize(":::") == "___")
    }
    
    @Test("needsSanitizing détecte uniquement les noms problématiques")
    func testNeedsSanitizing() {
        #expect(RemoteFilenameSanitizer.needsSanitizing("photo:2024.jpg") == true)
        #expect(RemoteFilenameSanitizer.needsSanitizing("photo.jpg.") == true)
        #expect(RemoteFilenameSanitizer.needsSanitizing("CON.jpg") == true)
        #expect(RemoteFilenameSanitizer.needsSanitizing("IMG_0001.HEIC") == false)
    }
    
    @Test("L'extension est préservée après nettoyage")
    func testExtensionPreserved() {
        #expect(RemoteFilenameSanitizer.sanitize("mon:fichier.HEIC").hasSuffix(".HEIC"))
        #expect(RemoteFilenameSanitizer.sanitize("clip:final.MOV").hasSuffix(".MOV"))
    }
}
