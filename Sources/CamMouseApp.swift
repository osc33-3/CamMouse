// CamMouse — usa el iPhone como ratón: la cámara trasera mira a la mesa,
// calcula cuánto se mueve el móvil y lo envía al ordenador por WiFi (UDP, puerto 5005).

import SwiftUI
import AVFoundation
import Vision
import Network

@main
struct CamMouseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}

// MARK: - Envío por WiFi

final class UDPSender {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "udp")

    func connect(host: String, port: UInt16) {
        connection?.cancel()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        c.start(queue: queue)
        connection = c
    }

    func send(_ text: String) {
        connection?.send(content: text.data(using: .utf8), completion: .idempotent)
    }
}

// MARK: - Seguimiento del movimiento con la cámara

final class MotionTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let sender = UDPSender()
    @Published var status = "Escribe la IP del ordenador y pulsa Conectar"

    // Ajustes (los cambia la interfaz)
    var sensitivity = 2.0
    var invertX = false
    var invertY = false
    var swapAxes = false

    private var device: AVCaptureDevice?
    private var torchLevel: Float = 0
    private var previous: CIImage?
    private let handler = VNSequenceRequestHandler()
    private let queue = DispatchQueue(label: "camara")
    private var configured = false

    func connect(to ip: String) {
        let host = ip.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { status = "Escribe primero la IP"; return }
        sender.connect(host: host, port: 5005)
        status = "Enviando a \(host) — mueve el móvil"
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.status = "Sin permiso de cámara (actívalo en Ajustes)" }
                return
            }
            self.queue.async { self.configure() }
        }
    }

    /// 0 = apagada, 1 = máximo
    func setTorch(_ level: Float) {
        queue.async {
            self.torchLevel = level
            self.applyTorch()
        }
    }

    private func applyTorch() {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        if torchLevel <= 0.01 {
            d.torchMode = .off
        } else {
            try? d.setTorchModeOn(level: min(torchLevel, AVCaptureDevice.maxAvailableTorchLevel))
        }
        d.unlockForConfiguration()
    }

    private func configure() {
        guard !configured else { return }
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: d) else {
            DispatchQueue.main.async { self.status = "No se encontró la cámara" }
            return
        }
        device = d

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()

        // Enfoque bloqueado a la distancia más corta posible
        if (try? d.lockForConfiguration()) != nil {
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: 0, completionHandler: nil)
            }
            d.unlockForConfiguration()
        }
        applyTorch()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Imagen reducida (160x120): más rápido y suficiente para medir el desplazamiento
        let current = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        defer { previous = current }
        guard let prev = previous else { return }

        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: current)
        do {
            try handler.perform([request], on: prev)
            guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return }
            var dx = Double(obs.alignmentTransform.tx)
            var dy = Double(obs.alignmentTransform.ty)
            if abs(dx) < 0.2 { dx = 0 }   // zona muerta: ignora el ruido con el móvil quieto
            if abs(dy) < 0.2 { dy = 0 }
            guard dx != 0 || dy != 0 else { return }

            var cx = dy * sensitivity      // la imagen de la cámara llega girada respecto al móvil
            var cy = dx * sensitivity
            if swapAxes { swap(&cx, &cy) }
            if invertX { cx = -cx }
            if invertY { cy = -cy }
            sender.send(String(format: "M %.2f %.2f", cx, cy))
        } catch {
            // Fotograma borroso o sin textura: se ignora
        }
    }
}

// MARK: - Interfaz

struct ContentView: View {
    @StateObject private var tracker = MotionTracker()
    @AppStorage("ip") private var ip = ""
    @AppStorage("sens") private var sens = 2.0
    @AppStorage("torch") private var torch = 0.0
    @AppStorage("invx") private var invx = false
    @AppStorage("invy") private var invy = false
    @AppStorage("swap") private var swapAxes = false
    @FocusState private var ipFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("IP del ordenador (ej. 192.168.1.50)", text: $ip)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($ipFocused)
                Button("Conectar") {
                    ipFocused = false
                    tracker.connect(to: ip)
                }
                .buttonStyle(.borderedProminent)
            }
            Text(tracker.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Sensibilidad").frame(width: 100, alignment: .leading)
                Slider(value: $sens, in: 0.5...8)
            }
            HStack {
                Text("Linterna").frame(width: 100, alignment: .leading)
                Slider(value: $torch, in: 0...1)
                Text(torch <= 0.01 ? "Off" : "\(Int(torch * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }

            Toggle("Invertir horizontal", isOn: $invx)
            Toggle("Invertir vertical", isOn: $invy)
            Toggle("Intercambiar ejes", isOn: $swapAxes)

            HStack(spacing: 10) {
                ClickButton(title: "Izquierdo", code: "L", sender: tracker.sender)
                ScrollWheel(sender: tracker.sender).frame(width: 64)
                ClickButton(title: "Derecho", code: "R", sender: tracker.sender)
            }
            .frame(minHeight: 220)
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // que no se apague la pantalla
            sync()
        }
        .onChange(of: sens) { sync() }
        .onChange(of: torch) { sync() }
        .onChange(of: invx) { sync() }
        .onChange(of: invy) { sync() }
        .onChange(of: swapAxes) { sync() }
    }

    private func sync() {
        tracker.sensitivity = sens
        tracker.invertX = invx
        tracker.invertY = invy
        tracker.swapAxes = swapAxes
        tracker.setTorch(Float(torch))
    }
}

// Botón de clic: pulsar al tocar, soltar al levantar el dedo (mantener = arrastrar)
struct ClickButton: View {
    let title: String
    let code: String
    let sender: UDPSender
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(pressed ? Color.blue : Color(white: 0.17))
            .overlay(Text(title).font(.title3.bold()))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            sender.send(code + "D")
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        sender.send(code + "U")
                        sender.send(code + "U")   // por si se pierde un paquete
                    }
            )
    }
}

// Rueda: deslizar = scroll, toque corto = clic central
struct ScrollWheel: View {
    let sender: UDPSender
    @State private var last: CGFloat = 0
    @State private var acc: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var active = false
    private let step: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule().fill(Color(white: 0.11))
                VStack(spacing: 10) {
                    ForEach(0..<60, id: \.self) { _ in
                        Rectangle().fill(Color(white: 0.22)).frame(height: 2)
                    }
                }
                .padding(.horizontal, 14)
                .offset(y: offset.truncatingRemainder(dividingBy: 12))
                .frame(height: geo.size.height)
                .clipped()
                VStack {
                    Image(systemName: "chevron.up")
                    Spacer()
                    Text("rueda").font(.caption2)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .padding(.vertical, 14)
                .foregroundStyle(.secondary)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(active ? Color.blue : Color(white: 0.25), lineWidth: 2))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !active { active = true; last = 0; acc = 0 }
                        let d = v.translation.height - last
                        last = v.translation.height
                        acc += d
                        offset += d
                        while abs(acc) >= step {
                            let dir: CGFloat = acc > 0 ? 1 : -1
                            acc -= dir * step
                            sender.send("S \(Int(-dir))")   // dedo hacia arriba = subir
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { v in
                        active = false
                        if abs(v.translation.height) < 8 && abs(v.translation.width) < 8 {
                            sender.send("MD")
                            sender.send("MU")
                        }
                    }
            )
        }
    }
}
