import Foundation
import UIKit
import UniformTypeIdentifiers

/// Handles all user-generated content uploads:
/// 1. Resizes and converts images to 1024x1024 WebP
/// 2. Requests a pre-signed PUT URL from the backend
/// 3. PUTs the file directly to S3
/// 4. Returns the CDN URL (valid immediately after upload completes)
@MainActor
class UploadService {
    static let shared = UploadService()

    private let apiBaseUrl = Config.apiBaseUrl
    private let targetSize = CGSize(width: 1024, height: 1024)

    // MARK: - Public API

    /// Upload an image (avatar or post image). Resizes and converts to WebP before upload.
    /// - Returns: CDN URL string, valid immediately after this call returns
    func uploadImage(
        _ image: UIImage,
        type: UploadType,
        postId: String? = nil
    ) async throws -> String {
        let webpData = try resizeAndConvert(image)
        let (uploadUrl, cdnUrl) = try await requestUploadUrl(type: type, postId: postId)
        try await putToS3(data: webpData, url: uploadUrl, contentType: "image/webp")
        return cdnUrl
    }

    /// Upload a voice memo m4a file.
    /// - Returns: CDN URL string, valid immediately after this call returns
    func uploadVoice(
        fileURL: URL,
        postId: String
    ) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        let (uploadUrl, cdnUrl) = try await requestUploadUrl(type: .voice, postId: postId)
        try await putToS3(data: data, url: uploadUrl, contentType: "audio/m4a")
        return cdnUrl
    }

    // MARK: - Upload types

    enum UploadType: String {
        case avatar = "avatar"
        case postImage = "post-image"
        case voice = "voice"
    }

    // MARK: - Image processing

    /// Center-crops to square, resizes to 1024x1024, encodes as WebP.
    private func resizeAndConvert(_ image: UIImage) throws -> Data {
        // 1. Center-crop to square
        let cropped = centerCrop(image)

        // 2. Resize to 1024x1024
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // 3. Encode as WebP (supported iOS 14+)
        guard let cgImage = resized.cgImage else {
            throw UploadError.imageConversionFailed
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.webP.identifier as CFString,
            1,
            nil
        ) else {
            throw UploadError.imageConversionFailed
        }
        // Lossless WebP
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw UploadError.imageConversionFailed
        }
        return mutableData as Data
    }

    private func centerCrop(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(
            x: (image.size.width - side) / 2,
            y: (image.size.height - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Backend request

    private func requestUploadUrl(type: UploadType, postId: String?) async throws -> (uploadUrl: String, cdnUrl: String) {
        guard let idToken = KeychainService.shared.get(key: "idToken") else {
            throw UploadError.notAuthenticated
        }
        guard let url = URL(string: "\(apiBaseUrl)/upload/request") else {
            throw UploadError.invalidURL
        }

        var body: [String: Any] = ["type": type.rawValue]
        if let postId { body["postId"] = postId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadError.serverError(status)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadUrl = json["uploadUrl"] as? String,
              let cdnUrl = json["cdnUrl"] as? String else {
            throw UploadError.unexpectedResponse
        }
        return (uploadUrl, cdnUrl)
    }

    // MARK: - S3 PUT

    private func putToS3(data: Data, url: String, contentType: String) async throws {
        guard let s3Url = URL(string: url) else { throw UploadError.invalidURL }

        var request = URLRequest(url: s3Url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadError.s3Error(status)
        }
    }
}

// MARK: - Errors

enum UploadError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case imageConversionFailed
    case serverError(Int)
    case s3Error(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "Not signed in"
        case .invalidURL:             return "Invalid URL"
        case .imageConversionFailed:  return "Failed to process image"
        case .serverError(let code):  return "Server error (\(code))"
        case .s3Error(let code):      return "Upload failed (\(code))"
        case .unexpectedResponse:     return "Unexpected server response"
        }
    }
}
