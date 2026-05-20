import SwiftUI

struct ContentView: View {
    @StateObject private var videoProcessor = VideoProcessor()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let frame = videoProcessor.currentFrame {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                // Если мы видим это, значит камера не присылает кадры
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2)
                    Text("Запуск камеры...")
                        .foregroundColor(.white)
                        .padding(.top, 20)
                }
            }
        }
        .onAppear {
            videoProcessor.start()
        }
        .onDisappear {
            videoProcessor.stop()
        }
    }
}
