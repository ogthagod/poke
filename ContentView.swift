import SwiftUI
import CoreBluetooth

class GoPlusPeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var isAdvertising = false
    @Published var connectionStatus = "Disconnected"
    @Published var logMessages: [String] = []
    @Published var lastCommandReceived = "None"
    
    // Stats tracking
    @Published var pokemonCaught = 0
    @Published var pokestopsSpun = 0
    @Published var runTime: TimeInterval = 0
    
    enum EncounterType {
        case pokemon
        case pokestop
    }
    
    private var timer: Timer?
    private var advertisingStartTime: Date?
    private var lastEncounterType: EncounterType? = nil
    
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
            if self.logMessages.count > 40 {
                self.logMessages.removeLast()
            }
        }
    }
    
    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            log("Error: Bluetooth is powered off.")
            return
        }
        
        setupServices()
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "Pokemon GO Plus"
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        log("Started advertising...")
        
        // Start runtime tracker
        advertisingStartTime = Date()
        runTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.advertisingStartTime else { return }
            DispatchQueue.main.async {
                self.runTime = Date().timeIntervalSince(start)
            }
        }
    }
    
    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        isAdvertising = false
        connectionStatus = "Disconnected"
        timer?.invalidate()
        timer = nil
        log("Stopped advertising.")
    }
    
    private func setupServices() {
        ledVibrateCharacteristic = CBMutableCharacteristic(
            type: ledVibrateUUID,
            properties: [.write, .notify, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        buttonCharacteristic = CBMutableCharacteristic(
            type: buttonUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        
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
    
    func pressButton() {
        guard let buttonChar = buttonCharacteristic else { return }
        log("Virtual button pressed!")
        
        let pressValue = Data([0x01, 0x00])
        peripheralManager.updateValue(pressValue, for: buttonChar, onSubscribedCentrals: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let releaseValue = Data([0x00, 0x00])
            self.peripheralManager.updateValue(releaseValue, for: buttonChar, onSubscribedCentrals: nil)
            self.log("Virtual button released.")
        }
    }
    
    // Heuristic parser for incoming game commands to track spins and catches
    private func parseGameCommand(_ data: Data) {
        let hexString = data.map { String(format: "%02hhx", $0) }.joined()
        log("Incoming CMD: 0x\(hexString)")
        
        DispatchQueue.main.async {
            self.lastCommandReceived = "0x\(hexString)"
            
            // Check for LED flashing patterns
            // Pokémon Go Plus protocol sends patterns with distinct byte signatures:
            // - Blue light flashing pattern typically indicates a Pokestop nearby
            // - Green/Yellow flashing pattern indicates a Pokemon nearby
            // - Rainbow/multi-vibration pattern indicates success (catch or spin completed)
            if hexString.contains("020810") || hexString.contains("0000ff") || hexString.contains("030002") {
                // Pokestop indicator (typically contains blue hex components)
                self.lastEncounterType = .pokestop
                self.log("Encountered Pokestop nearby...")
            } else if hexString.contains("020808") || hexString.contains("00ff00") || hexString.contains("030001") {
                // Pokemon indicator (typically contains green/yellow components)
                self.lastEncounterType = .pokemon
                self.log("Encountered wild Pokemon nearby...")
            } else if hexString.contains("040007") || hexString.contains("ffff") || hexString.contains("0500") {
                // Success vibration/LED pattern (Rainbow flash)
                if let lastType = self.lastEncounterType {
                    if lastType == .pokemon {
                        self.pokemonCaught += 1
                        self.log("★ Pokemon CAUGHT successfully!")
                    } else if lastType == .pokestop {
                        self.pokestopsSpun += 1
                        self.log("★ Pokestop SPUN successfully!")
                    }
                    self.lastEncounterType = nil // Reset until next indicator
                }
            } else if hexString.contains("040003") || hexString.contains("000000") {
                // Escape / Failure pattern (Red flash)
                self.log("✗ Encounter failed/escaped.")
                self.lastEncounterType = nil
            }
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
        default:
            break
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
            self.lastEncounterType = nil
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == ledVibrateUUID {
                if let value = request.value {
                    parseGameCommand(value)
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else if request.characteristic.uuid == certUUID {
                if let value = request.value {
                    parseGameCommand(value)
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else {
                peripheralManager.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == buttonUUID {
            let data = Data([0x00, 0x00])
            request.value = data
            peripheralManager.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == certUUID {
            let mockChallengeResponse = Data([0x00, 0x01, 0x02, 0x03])
            request.value = mockChallengeResponse
            peripheralManager.respond(to: request, withResult: .success)
        } else {
            peripheralManager.respond(to: request, withResult: .requestNotSupported)
        }
    }
}

struct ContentView: View {
    @StateObject private var bleManager = GoPlusPeripheralManager()
    
    // Timer formatting
    var formattedTime: String {
        let hours = Int(bleManager.runTime) / 3600
        let minutes = (Int(bleManager.runTime) % 3600) / 60
        let seconds = Int(bleManager.runTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    var body: some View {
        ZStack {
            // Dark elegant carbon-styled background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.05),
                    Color(red: 0.08, green: 0.08, blue: 0.12),
                    Color(red: 0.04, green: 0.04, blue: 0.06)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Premium Header Banner
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GO+ EMULATOR")
                            .font(.system(size: 24, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .tracking(4)
                        
                        Text("COLLABORATIVE REBEL HARDWARE EMULATOR")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.purple)
                    }
                    Spacer()
                    
                    // Small blinking activity dot
                    Circle()
                        .fill(bleManager.isAdvertising ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: bleManager.isAdvertising ? .green : .red, radius: 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                
                // Connection Status Box (Premium styling)
                VStack(spacing: 6) {
                    Text("ACCESSORY LINK STATUS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    Text(bleManager.connectionStatus)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(bleManager.connectionStatus == "Connected" ? .green : (bleManager.isAdvertising ? .cyan : .red))
                        .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : (bleManager.isAdvertising ? Color.cyan : Color.red)).opacity(0.3), radius: 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(LinearGradient(gradient: Gradient(colors: [.white.opacity(0.15), .clear]), startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
                
                // Runtime and Counters Panel (New Feature!)
                HStack(spacing: 12) {
                    // Timer Card
                    VStack(spacing: 8) {
                        Image(systemName: "timer")
                            .font(.system(size: 18))
                            .foregroundColor(.cyan)
                        Text("RUN TIME")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        Text(formattedTime)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.2), lineWidth: 1))
                    
                    // Pokestops Card
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.purple)
                        Text("SPINS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        Text("\(bleManager.pokestopsSpun)")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundColor(.purple)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.2), lineWidth: 1))
                    
                    // Pokemon Caught Card
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        Text("CATCHES")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        Text("\(bleManager.pokemonCaught)")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2), lineWidth: 1))
                }
                .padding(.horizontal, 20)
                
                // Giant Glowing Button (Central controller)
                Button(action: {
                    if bleManager.connectionStatus == "Connected" {
                        bleManager.pressButton()
                    }
                }) {
                    ZStack {
                        // Ambient radial glow
                        Circle()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.cyan.opacity(0.2), Color.purple.opacity(0.2)]), startPoint: .top, endPoint: .bottom))
                            .frame(width: 220, height: 220)
                            .blur(radius: bleManager.connectionStatus == "Connected" ? 30 : 5)
                        
                        // Metallic rim
                        Circle()
                            .fill(LinearGradient(gradient: Gradient(colors: [Color.purple, Color.cyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 170, height: 170)
                            .shadow(color: .cyan.opacity(0.4), radius: 15)
                        
                        // Inner core
                        Circle()
                            .fill(Color(red: 0.05, green: 0.05, blue: 0.08))
                            .frame(width: 154, height: 154)
                        
                        // Glowing LED button center
                        Circle()
                            .fill(bleManager.connectionStatus == "Connected" ? Color.green : Color.red)
                            .frame(width: 54, height: 54)
                            .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : Color.red).opacity(0.8), radius: 12)
                        
                        // Action text
                        Text("ACTION BUTTON")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .offset(y: -44)
                            .opacity(bleManager.connectionStatus == "Connected" ? 1.0 : 0.3)
                        
                        Text("PRESS TO SPIN/CATCH")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                            .offset(y: 44)
                            .opacity(bleManager.connectionStatus == "Connected" ? 1.0 : 0.2)
                    }
                }
                .disabled(bleManager.connectionStatus != "Connected")
                .buttonStyle(PlainButtonStyle())
                .padding(.vertical, 10)
                
                // Toggle Emulator Activation
                Button(action: {
                    if bleManager.isAdvertising {
                        bleManager.stopAdvertising()
                    } else {
                        bleManager.startAdvertising()
                    }
                }) {
                    Text(bleManager.isAdvertising ? "SHUT DOWN EMULATOR" : "BOOT UP EMULATOR")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 48)
                        .background(bleManager.isAdvertising ? Color.red : Color.cyan)
                        .cornerRadius(30)
                        .shadow(color: (bleManager.isAdvertising ? Color.red : Color.cyan).opacity(0.3), radius: 10)
                }
                .animation(.easeInOut, value: bleManager.isAdvertising)
                
                // Live Stream logs
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIVE EMULATOR FEED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 4)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(bleManager.logMessages, id: \.self) { log in
                                Text(log)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(12)
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 20)
                
                Spacer()
            }
            .padding(.vertical)
        }
    }
}
