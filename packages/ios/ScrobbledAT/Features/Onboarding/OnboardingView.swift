import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var appleSignInService: AppleSignInService
    @State private var showHandleSelection = false
    @State private var handleSelectionData: [String: Any]?
    @State private var showErrorAlert = false
    
    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("Selector")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Share your music taste with friends")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                Text("Connect with Apple ID and share tracks from your music library")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button(action: {
                    appleSignInService.signInWithApple()
                }) {
                    HStack {
                        Image(systemName: "applelogo")
                        Text("Sign in with Apple")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.black)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                
                if appleSignInService.isLoading {
                    ProgressView("Signing in...")
                        .padding()
                }
            }
            
            Spacer()
        }
        .padding()
        .alert("Sign In Failed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                appleSignInService.error = nil
            }
        } message: {
            Text(appleSignInService.error ?? "")
        }
        .onChange(of: appleSignInService.error) { _, error in
            showErrorAlert = error != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHandleSelection)) { notification in
            if let data = notification.object as? [String: Any] {
                handleSelectionData = data
                showHandleSelection = true
            }
        }
        .sheet(isPresented: $showHandleSelection) {
            if let data = handleSelectionData {
                HandleSelectionView(
                    appleUserId: data["appleUserId"] as? String ?? ""
                )
                .environmentObject(appleSignInService)
            }
        }
    }
}
