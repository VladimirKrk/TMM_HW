import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine
import CoreGraphics

class VideoProcessor: NSObject, ObservableObject {
    @Published var currentFrame: CGImage?
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    
    // 1. СТАБИЛИЗАЦИЯ МАСКИ (Рука)
    private var previousIntersection: CGRect?
    private var framesWithoutDetection = 0
    private let maxFramesToKeepAlive = 10
    
    // 2. СТАБИЛИЗАЦИЯ ЛИЦА (Защита от дергания)
    private var smoothedFaceRect: CGRect?
    
    // 3. ПАМЯТЬ ЛИЦА (TEMPORAL BUFFER)
    private var lastCleanFaceImage: CIImage?
    private var lastCleanFaceRect: CGRect?
    private var clearFramesCount = 0
    
    override init() {
        super.init()
        setupCamera()
    }
    
    private func setupCamera() {
        captureSession.sessionPreset = .high
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: frontCamera) else { return }
        
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) { connection.videoRotationAngle = 90 }
            else { connection.videoOrientation = .portrait }
            connection.isVideoMirrored = true
        }
    }
    
    func start() { DispatchQueue.global(qos: .background).async { self.captureSession.startRunning() } }
    func stop() { captureSession.stopRunning() }
}

extension VideoProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 1
        
        let requestHandler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        
        do {
            try requestHandler.perform([faceRequest, handRequest])
            
            var finalImage = ciImage
            let imageSize = ciImage.extent.size
            var currentTargetRect: CGRect? = nil
            var isHandDetected = false
            
            // Если найдено лицо
            if let face = faceRequest.results?.first {
                let rawFaceRect = VNImageRectForNormalizedRect(face.boundingBox, Int(imageSize.width), Int(imageSize.height))
                
                // --- НОВОЕ: СГЛАЖИВАЕМ РАМКУ ЛИЦА ---
                let currentFaceRect: CGRect
                if let prevFace = smoothedFaceRect {
                    let alpha: CGFloat = 0.15 // Чем меньше цифра, тем плавнее движения (0.15 = очень плавно)
                    currentFaceRect = CGRect(
                        x: prevFace.origin.x * (1 - alpha) + rawFaceRect.origin.x * alpha,
                        y: prevFace.origin.y * (1 - alpha) + rawFaceRect.origin.y * alpha,
                        width: prevFace.width * (1 - alpha) + rawFaceRect.width * alpha,
                        height: prevFace.height * (1 - alpha) + rawFaceRect.height * alpha
                    )
                } else {
                    currentFaceRect = rawFaceRect
                }
                smoothedFaceRect = currentFaceRect // Обновляем стабилизатор
                
                // Ищем руку
                if let hand = handRequest.results?.first {
                    var handPoints: [CGPoint] = []
                    if let points = try? hand.recognizedPoints(.all) {
                        for point in points.values {
                            handPoints.append(CGPoint(x: point.location.x * imageSize.width,
                                                      y: point.location.y * imageSize.height))
                        }
                    }
                    
                    if !handPoints.isEmpty {
                        let handRect = createBoundingBox(from: handPoints, padding: 80)
                        // Используем сглаженное лицо для проверки пересечений
                        if currentFaceRect.intersects(handRect) {
                            isHandDetected = true
                            currentTargetRect = currentFaceRect.intersection(handRect).insetBy(dx: -40, dy: -40)
                        }
                    }
                }
                
                // ЛОГИКА "УМНОЙ ПАМЯТИ" И СТАБИЛИЗАЦИИ МАСКИ
                if isHandDetected {
                    framesWithoutDetection = 0
                    clearFramesCount = 0
                    
                    let smoothedRect: CGRect
                    if let prev = previousIntersection {
                        let alpha: CGFloat = 0.25
                        smoothedRect = CGRect(
                            x: prev.origin.x * (1 - alpha) + currentTargetRect!.origin.x * alpha,
                            y: prev.origin.y * (1 - alpha) + currentTargetRect!.origin.y * alpha,
                            width: prev.width * (1 - alpha) + currentTargetRect!.width * alpha,
                            height: prev.height * (1 - alpha) + currentTargetRect!.height * alpha
                        )
                    } else {
                        smoothedRect = currentTargetRect!
                    }
                    previousIntersection = smoothedRect
                    
                } else {
                    framesWithoutDetection += 1
                    if framesWithoutDetection < maxFramesToKeepAlive, let prev = previousIntersection {
                        currentTargetRect = prev
                    } else {
                        previousIntersection = nil
                        
                        clearFramesCount += 1
                        if clearFramesCount == 6 {
                            if let copiedFace = context.createCGImage(ciImage, from: ciImage.extent) {
                                lastCleanFaceImage = CIImage(cgImage: copiedFace)
                                // Запоминаем именно сглаженные координаты!
                                lastCleanFaceRect = currentFaceRect
                            }
                        }
                    }
                }
                
                if let rectToRepair = previousIntersection {
                    // Передаем сглаженное лицо в отрисовку
                    finalImage = applySmartInpainting(to: ciImage, in: rectToRepair, currentFaceRect: currentFaceRect)
                }
            } else {
                // Если лицо потеряно (вышел из кадра), сбрасываем сглаживание
                smoothedFaceRect = nil
            }
            
            if let cgImage = context.createCGImage(finalImage, from: ciImage.extent) {
                DispatchQueue.main.async { self.currentFrame = cgImage }
            }
            
        } catch {
            print("Ошибка: \(error)")
        }
    }
    
    private func createBoundingBox(from points: [CGPoint], padding: CGFloat) -> CGRect {
        guard !points.isEmpty else { return .zero }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        return CGRect(x: (xs.min()!) - padding, y: (ys.min()!) - padding,
                      width: (xs.max()! - xs.min()!) + (padding * 2),
                      height: (ys.max()! - ys.min()!) + (padding * 2))
    }
    
    private func applySmartInpainting(to currentImage: CIImage, in rect: CGRect, currentFaceRect: CGRect) -> CIImage {
        let safeRect = rect.intersection(currentImage.extent)
        guard !safeRect.isEmpty && !safeRect.isInfinite else { return currentImage }
        
        let softMask = CIImage(color: .white)
            .cropped(to: safeRect)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30.0])
        
        var patchImage: CIImage
        
        if let savedImage = lastCleanFaceImage, let savedFaceRect = lastCleanFaceRect, savedFaceRect.width > 0 {
            
            let scaleX = currentFaceRect.width / savedFaceRect.width
            let scaleY = currentFaceRect.height / savedFaceRect.height
            
            if scaleX.isFinite && scaleY.isFinite && scaleX > 0 {
                let tx = currentFaceRect.origin.x - savedFaceRect.origin.x * scaleX
                let ty = currentFaceRect.origin.y - savedFaceRect.origin.y * scaleY
                
                let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: tx, ty: ty)
                patchImage = savedImage.transformed(by: transform)
            } else {
                patchImage = currentImage.cropped(to: currentFaceRect).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 100.0])
            }
            
        } else {
            patchImage = currentImage.cropped(to: currentFaceRect).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 100.0])
        }
        
        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = patchImage
        blendFilter.backgroundImage = currentImage
        blendFilter.maskImage = softMask
        
        return blendFilter.outputImage ?? currentImage
    }
}
