import SwiftUI

struct HandleSelectionView: View {
    let appleUserId: String
    
    @State private var handle = ""
    @State private var isLoading = false
    @State private var error: String?
    
    @EnvironmentObject var appleSignInService: AppleSignInService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("Choose Your Handle")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("This is how others will find and follow you")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Handle")
                    .font(.headline)
                
                HStack {
                    Text("@")
                        .foregroundColor(.secondary)
                    TextField("yourhandle", text: $handle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            
            if let error = error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button(action: completeRegistration) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Complete Setup")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(handle.isEmpty || isLoading)
            
            Spacer()
        }
        .padding()
        .navigationBarHidden(true)
    }
    
    private func completeRegistration() {
        isLoading = true
        
        Task {
            do {
                let apiUrl = "\(Config.apiBaseUrl)/me/handle"
                guard let url = URL(string: apiUrl),
                      let idToken = KeychainService.shared.get(key: "idToken") else { return }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                
                let body = ["handle": handle]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (_, _) = try await URLSession.shared.data(for: request)
                
                await MainActor.run {
                    appleSignInService.currentUser = AppleSignInService.User(
                        handle: handle,
                        name: nil
                    )
                    dismiss()
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Registration failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}
