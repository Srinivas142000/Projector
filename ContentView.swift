import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = StreamingViewModel()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Status indicator
                HStack {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text(viewModel.statusText)
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(10)
                
                Spacer()
                
                // Server URL input
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server URL")
                        .foregroundColor(.white)
                        .font(.caption)
                    
                    TextField("http://192.168.1.x:3000", text: $viewModel.serverURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(.horizontal, 40)
                
                // Room ID input
                VStack(alignment: .leading, spacing: 10) {
                    Text("Room ID")
                        .foregroundColor(.white)
                        .font(.caption)
                    
                    TextField("default-room", text: $viewModel.roomId)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(.horizontal, 40)
                
                // Start/Stop button
                Button(action: {
                    viewModel.toggleStreaming()
                }) {
                    Text(viewModel.isStreaming ? "Stop Streaming" : "Start Streaming")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.isStreaming ? Color.red : Color.blue)
                        .cornerRadius(10)
                }
                .padding(.horizontal, 40)
                
                Spacer()
                
                // Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructions:")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("1. Make sure your laptop server is running")
                    Text("2. Enter your laptop's IP address above")
                    Text("3. Keep the same room ID as on laptop")
                    Text("4. Press Start Streaming")
                }
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal, 40)
                
                Spacer()
            }
            .padding()
        }
    }
}

class StreamingViewModel: NSObject, ObservableObject {
    @Published var serverURL: String = "http://192.168.1.1:3000"
    @Published var roomId: String = "default-room"
    @Published var isStreaming: Bool = false
    @Published var isConnected: Bool = false
    @Published var statusText: String = "Disconnected"
    
    private var webRTCClient: WebRTCClient?
    
    func toggleStreaming() {
        if isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }
    
    private func startStreaming() {
        statusText = "Connecting..."
        
        webRTCClient = WebRTCClient(serverURL: serverURL, roomId: roomId)
        webRTCClient?.delegate = self
        webRTCClient?.connect()
        webRTCClient?.startCapture()
        
        isStreaming = true
    }
    
    private func stopStreaming() {
        webRTCClient?.disconnect()
        webRTCClient = nil
        isStreaming = false
        isConnected = false
        statusText = "Disconnected"
    }
}

extension StreamingViewModel: WebRTCClientDelegate {
    func didConnect() {
        DispatchQueue.main.async {
            self.isConnected = true
            self.statusText = "Connected & Streaming"
        }
    }
    
    func didDisconnect() {
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusText = "Disconnected"
        }
    }
}

#Preview {
    ContentView()
}