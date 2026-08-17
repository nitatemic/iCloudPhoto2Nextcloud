//
//  PhotoThumbnailView.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI
import Photos

/// Miniature d'une photo de la photothèque, chargée via PHImageManager.
public struct PhotoThumbnailView: View {
    let localIdentifier: String
    let size: CGSize

    @State private var image: NSImage?
    @State private var isMissing = false

    public init(localIdentifier: String, size: CGSize) {
        self.localIdentifier = localIdentifier
        self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isMissing {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityLabel("Photo synchronisée")
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let results = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = results.firstObject else {
            isMissing = true
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        // targetSize est en pixels : on double la taille en points pour le Retina
        let pixelSize = CGSize(width: size.width * 2, height: size.height * 2)
        PHImageManager.default().requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { image, _ in
            guard let image else { return }
            Task { @MainActor in
                self.image = image
            }
        }
    }
}
