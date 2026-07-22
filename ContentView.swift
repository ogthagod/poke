import SwiftUI
import CoreBluetooth

class GoPlusPeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var isAdvertising = false
    @Published var connectionStatus = "Disconnected"
    @Published var logMessages: [String] = []
    @Published var lastCommandReceived = "None"
    
    private var peripheralManager: CBPeripheralManager!
    private var goPlusService: CBMutableService?
    private var ledVibrateCharacteristic: CBMutableCharacteristic?
    private var buttonCharacteristic: CBMutableCharacteristic?
    private var certCharacteristic: CBMutableCharacteristic?
    
    // Service and Characteristic UUIDs for Pokemon Go Plus
    let serviceUUID = CBUUID(string: "0EE0C041-87C4-0485-8C20-00E41E91EAA7")
    let ledVibrateUUID = CBUUID(string: "0EE0C042-87C4-0485-8C20-00E41E91EAA7")
    let buttonUUID = CBUUID(string: "0EE0C043-87C4-0485-8C20-00E41E91EAA7")
    let certUUID = CBUUID(string: "0EE0C044-87C4-0485-8C20-00E41E91EAA7")
    
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logMessages.insert("[\(timestamp)] \(message)", at: 0)
            if self.logMessages.count > 50 {
                self.logMessages.removeLast()
            }
        }
    }
    
    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            log("Error: Bluetooth is powered off or unavailable.")
            return
        }
        
        setupServices()
        
        // Advertise as "Pokemon GO Plus" with the service UUID
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "Pokemon GO Plus"
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        log("Started advertising as 'Pokemon GO Plus'...")
    }
    
    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        isAdvertising = false
        connectionStatus = "Disconnected"
        log("Stopped advertising.")
    }
    
    private func setupServices() {
        // Characteristic for LED and Vibration commands (Write/Notify)
        ledVibrateCharacteristic = CBMutableCharacteristic(
            type: ledVibrateUUID,
            properties: [.write, .notify, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        // Characteristic for button press updates (Read/Notify)
        buttonCharacteristic = CBMutableCharacteristic(
            type: buttonUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        
        // Characteristic for handshake authentication (Read/Write)
        certCharacteristic = CBMutableCharacteristic(
            type: certUUID,
            properties: [.read, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        goPlusService = CBMutableService(type: serviceUUID, primary: true)
        goPlusService?.characteristics = [ledVibrateCharacteristic!, buttonCharacteristic!, certCharacteristic!]
        
        peripheralManager.removeAllServices()
        peripheralManager.add(goPlusService!)
    }
    
    // Send virtual button press event
    func pressButton() {
        guard let buttonChar = buttonCharacteristic else { return }
        log("Virtual button pressed!")
        
        // When pressed, send a value notification.
        // The standard Go Plus protocol uses specific payloads (e.g. 0x0100 for pressed, 0x0000 for released)
        let pressValue = Data([0x01, 0x00])
        peripheralManager.updateValue(pressValue, for: buttonChar, onSubscribedCentrals: nil)
        
        // Auto release after a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let releaseValue = Data([0x00, 0x00])
            self.peripheralManager.updateValue(releaseValue, for: buttonChar, onSubscribedCentrals: nil)
            self.log("Virtual button released.")
        }
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("Bluetooth powered on and ready.")
        case .poweredOff:
            log("Bluetooth powered off.")
            stopAdvertising()
        case .unauthorized:
            log("Bluetooth permission unauthorized.")
        default:
            log("Bluetooth state changed: \(peripheral.state.rawValue)")
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                self.log("Advertising failed: \(error.localizedDescription)")
                self.isAdvertising = false
            } else {
                self.log("Successfully advertising.")
                self.isAdvertising = true
                self.connectionStatus = "Advertising..."
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        log("Central connected: \(central.identifier.uuidString)")
        DispatchQueue.main.async {
            self.connectionStatus = "Connected"
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("Central disconnected: \(central.identifier.uuidString)")
        DispatchQueue.main.async {
            self.connectionStatus = "Disconnected"
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == ledVibrateUUID {
                if let value = request.value {
                    let hexString = value.map { String(format: "%02hhx", $0) }.joined()
                    log("Vibrate/LED Command: 0x\(hexString)")
                    DispatchQueue.main.async {
                        self.lastCommandReceived = "0x\(hexString)"
                    }
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else if request.characteristic.uuid == certUUID {
                if let value = request.value {
                    let hexString = value.map { String(format: "%02hhx", $0) }.joined()
                    log("Auth handshake payload: 0x\(hexString)")
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else {
                peripheralManager.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == buttonUUID {
            let data = Data([0x00, 0x00]) // Default idle state
            request.value = data
            peripheralManager.respond(to: request, withResult: .success)
            log("Read request on Button characteristic.")
        } else if request.characteristic.uuid == certUUID {
            // Echo back or provide mock handshake responses
            let mockChallengeResponse = Data([0x00, 0x01, 0x02, 0x03])
            request.value = mockChallengeResponse
            peripheralManager.respond(to: request, withResult: .success)
            log("Read request on Handshake/Cert characteristic.")
        } else {
            peripheralManager.respond(to: request, withResult: .requestNotSupported)
        }
    }
}

struct ContentView: View {
    @StateObject private var bleManager = GoPlusPeripheralManager()
    
    var body: some View {
        ZStack {
            // Dark futuristic background
            LinearGradient(gradient: Gradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.1, green: 0.1, blue: 0.15)]),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 4) {
                    Text("GO PLUS EMULATOR")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(3)
                    
                    Text("LO & ENI Collaborative Hack")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.purple)
                }
                .padding(.top, 20)
                
                // Status panel
                VStack(spacing: 8) {
                    Text("Status")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    Text(bleManager.connectionStatus)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(bleManager.connectionStatus == "Connected" ? .green : (bleManager.isAdvertising ? .blue : .red))
                        .animation(.easeInOut, value: bleManager.connectionStatus)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal)
                
                // Giant interactive LED button
                Button(action: {
                    if bleManager.connectionStatus == "Connected" {
                        bleManager.pressButton()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.purple, Color.cyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 180, height: 180)
                            .shadow(color: .purple.opacity(0.5), radius: bleManager.connectionStatus == "Connected" ? 25 : 5)
                            
                        Circle()
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
                            .frame(width: 160, height: 160)
                        
                        // Internal glowing indicator
                        Circle()
                            .fill(bleManager.connectionStatus == "Connected" ? Color.green : Color.red)
                            .frame(width: 60, height: 60)
                            .shadow(color: bleManager.connectionStatus == "Connected" ? .green.opacity(0.8) : .red.opacity(0.8), radius: 15)
                        
                        Text("TAP")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .opacity(bleManager.connectionStatus == "Connected" ? 1.0 : 0.3)
                    }
                }
                .disabled(bleManager.connectionStatus != "Connected")
                .buttonStyle(PlainButtonStyle())
                .padding(.vertical, 10)
                
                // Toggle advertising
                Button(action: {
                    if bleManager.isAdvertising {
                        bleManager.stopAdvertising()
                    } else {
                        bleManager.startAdvertising()
                    }
                }) {
                    Text(bleManager.isAdvertising ? "STOP EMULATOR" : "START EMULATOR")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 40)
                        .background(bleManager.isAdvertising ? Color.red : Color.cyan)
                        .cornerRadius(30)
                        .shadow(color: (bleManager.isAdvertising ? Color.red : Color.cyan).opacity(0.4), radius: 10)
                }
                .animation(.easeInOut, value: bleManager.isAdvertising)
                
                // Command readout
                HStack {
                    Text("Last Game CMD:")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    Text(bleManager.lastCommandReceived)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
                
                // Log view
                VStack(alignment: .leading, spacing: 6) {
                    Text("LOGS")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(bleManager.logMessages, id: \.self) { log in
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(8)
                    .frame(height: 120)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
        }
    }
}
