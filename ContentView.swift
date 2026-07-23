import SwiftUI
import CoreBluetooth

struct FarmDevice: Identifiable, Codable {
    let id: UUID // CBCentral identifier
    var name: String
    var isEnabled: Bool
    var isConnected: Bool
}

class GoPlusPeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var isAdvertising = false
    @Published var connectionStatus = "Disconnected"
    @Published var logMessages: [String] = []
    @Published var lastCommandReceived = "None"
    
    // Stats tracking
    @Published var pokemonCaught = 0
    @Published var pokestopsSpun = 0
    @Published var runTime: TimeInterval = 0
    
    // Farm & Device Management
    @Published var farmDevices: [FarmDevice] = []
    @Published var isPairingMode = false // "Add Phone" mode
    
    private var timer: Timer?
    private var advertisingStartTime: Date?
    
    enum EncounterType {
        case pokemon
        case pokestop
    }
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
        loadDevices()
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
        
        // Reset connection status for devices
        DispatchQueue.main.async {
            for i in 0..<self.farmDevices.count {
                self.farmDevices[i].isConnected = false
            }
        }
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
    
    // Toggle a device's enabled state. If disabled, we disconnect it.
    func toggleDevice(_ deviceId: UUID) {
        if let index = farmDevices.firstIndex(where: { $0.id == deviceId }) {
            farmDevices[index].isEnabled.toggle()
            saveDevices()
            
            let status = farmDevices[index].isEnabled ? "ENABLED" : "DISABLED"
            log("Phone '\(farmDevices[index].name)' \(status)")
            
            // If disabled and connected, force a clean service reset to kick it off
            if !farmDevices[index].isEnabled && farmDevices[index].isConnected {
                resetServicesToDisconnect()
            }
        }
    }
    
    // Rename a device in the farm
    func renameDevice(_ deviceId: UUID, newName: String) {
        if let index = farmDevices.firstIndex(where: { $0.id == deviceId }) {
            farmDevices[index].name = newName
            saveDevices()
            log("Renamed device to '\(newName)'")
        }
    }
    
    // Delete a device from the farm
    func deleteDevice(_ deviceId: UUID) {
        farmDevices.removeAll(where: { $0.id == deviceId })
        saveDevices()
        log("Device removed from farm.")
        resetServicesToDisconnect()
    }
    
    // Resetting services is the only clean way in iOS CoreBluetooth to drop active connections
    private func resetServicesToDisconnect() {
        log("Resetting services to enforce connection rules...")
        let wasAdvertising = isAdvertising
        peripheralManager.stopAdvertising()
        setupServices()
        if wasAdvertising {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                CBAdvertisementDataLocalNameKey: "Pokemon GO Plus"
            ]
            peripheralManager.startAdvertising(advertisementData)
        }
    }
    
    private func parseGameCommand(_ data: Data, from central: CBCentral) {
        // If device is disabled, ignore command
        if let device = farmDevices.firstMatch(for: central.identifier), !device.isEnabled {
            return
        }
        
        let hexString = data.map { String(format: "%02hhx", $0) }.joined()
        
        DispatchQueue.main.async {
            self.lastCommandReceived = "0x\(hexString)"
            
            if hexString.contains("020810") || hexString.contains("0000ff") || hexString.contains("030002") {
                self.lastEncounterType = .pokestop
                self.log("[\(self.deviceName(for: central))] Nearby Pokestop...")
            } else if hexString.contains("020808") || hexString.contains("00ff00") || hexString.contains("030001") {
                self.lastEncounterType = .pokemon
                self.log("[\(self.deviceName(for: central))] Nearby Pokemon...")
            } else if hexString.contains("040007") || hexString.contains("ffff") || hexString.contains("0500") {
                if let lastType = self.lastEncounterType {
                    if lastType == .pokemon {
                        self.pokemonCaught += 1
                        self.log("★ [\(self.deviceName(for: central))] Pokemon Caught!")
                    } else if lastType == .pokestop {
                        self.pokestopsSpun += 1
                        self.log("★ [\(self.deviceName(for: central))] Pokestop Spun!")
                    }
                    self.lastEncounterType = nil
                }
            } else if hexString.contains("040003") || hexString.contains("000000") {
                self.log("✗ [\(self.deviceName(for: central))] Encounter escaped.")
                self.lastEncounterType = nil
            }
        }
    }
    
    private func deviceName(for id: UUID) -> String {
        return farmDevices.first(where: { $0.id == id })?.name ?? "Unknown Phone"
    }
    
    private func deviceName(for central: CBCentral) -> String {
        return deviceName(for: central.identifier)
    }
    
    // Persistence
    private func saveDevices() {
        if let encoded = try? JSONEncoder().encode(farmDevices) {
            UserDefaults.standard.set(encoded, forKey: "GoPlusFarmDevices")
        }
    }
    
    private func loadDevices() {
        if let data = UserDefaults.standard.data(forKey: "GoPlusFarmDevices"),
           let decoded = try? JSONDecoder().decode([FarmDevice].self, from: data) {
            self.farmDevices = decoded
        }
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            log("Bluetooth Ready.")
        } else if peripheral.state == .poweredOff {
            log("Bluetooth Powered Off.")
            stopAdvertising()
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                self.log("Advertising failed: \(error.localizedDescription)")
                self.isAdvertising = false
            } else {
                self.log("Advertising Active.")
                self.isAdvertising = true
                self.connectionStatus = self.farmDevices.contains(where: { $0.isConnected }) ? "Connected" : "Advertising..."
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        DispatchQueue.main.async {
            let isAlreadyKnown = self.farmDevices.contains(where: { $0.id == central.identifier })
            let connectedDevicesCount = self.farmDevices.filter({ $0.isConnected && $0.isEnabled }).count
            
            // Rule: No new connections allowed if someone is already connected, UNLESS pairing mode is active
            if connectedDevicesCount > 0 && !self.isPairingMode && !isAlreadyKnown {
                self.log("Connection blocked: Another phone is connected. Turn on 'Add Phone' to pair.")
                self.resetServicesToDisconnect()
                return
            }
            
            // Add or activate device
            if let index = self.farmDevices.firstIndex(where: { $0.id == central.identifier }) {
                // If it is disabled, reject it immediately
                if !self.farmDevices[index].isEnabled {
                    self.log("Connection rejected: '\(self.farmDevices[index].name)' is disabled.")
                    self.resetServicesToDisconnect()
                    return
                }
                self.farmDevices[index].isConnected = true
            } else {
                // New device pairing
                if self.isPairingMode || self.farmDevices.isEmpty {
                    let newDevice = FarmDevice(
                        id: central.identifier,
                        name: "Phone \(self.farmDevices.count + 1)",
                        isEnabled: true,
                        isConnected: true
                    )
                    self.farmDevices.append(newDevice)
                    self.saveDevices()
                    self.isPairingMode = false // Auto-lock pairing mode
                    self.log("Linked new phone: \(newDevice.name)")
                } else {
                    self.log("Connection rejected: Unknown phone. Click 'Add Phone' to pair.")
                    self.resetServicesToDisconnect()
                    return
                }
            }
            
            self.connectionStatus = "Connected"
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        DispatchQueue.main.async {
            if let index = self.farmDevices.firstIndex(where: { $0.id == central.identifier }) {
                self.farmDevices[index].isConnected = false
                self.log("Phone '\(self.farmDevices[index].name)' disconnected.")
            }
            
            let anyConnected = self.farmDevices.contains(where: { $0.isConnected && $0.isEnabled })
            self.connectionStatus = anyConnected ? "Connected" : (self.isAdvertising ? "Advertising..." : "Disconnected")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            // Validate client authorization
            if let device = farmDevices.first(where: { $0.id == request.central.identifier }), !device.isEnabled {
                peripheralManager.respond(to: request, withResult: .writeNotPermitted)
                return
            }
            
            if request.characteristic.uuid == ledVibrateUUID || request.characteristic.uuid == certUUID {
                if let value = request.value {
                    parseGameCommand(value, from: request.central)
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else {
                peripheralManager.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Validate client authorization
        if let device = farmDevices.first(where: { $0.id == request.central.identifier }), !device.isEnabled {
            peripheralManager.respond(to: request, withResult: .readNotPermitted)
            return
        }
        
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

// Helper extension to find items
extension Array where Element == FarmDevice {
    func firstMatch(for id: UUID) -> FarmDevice? {
        return first(where: { $0.id == id })
    }
}

struct ContentView: View {
    @StateObject private var bleManager = GoPlusPeripheralManager()
    @State private var editingDeviceId: UUID? = nil
    @State private var editingDeviceName = ""
    
    var formattedTime: String {
        let hours = Int(bleManager.runTime) / 3600
        let minutes = (Int(bleManager.runTime) % 3600) / 60
        let seconds = Int(bleManager.runTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    var body: some View {
        ZStack {
            // Elegant Carbon Dark Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.04),
                    Color(red: 0.06, green: 0.06, blue: 0.09),
                    Color(red: 0.03, green: 0.03, blue: 0.05)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header Banner
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GO+ FARM MASTER")
                                .font(.system(size: 22, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .tracking(4)
                            
                            Text("MULTI-PHONE EMULATION HUBS")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        
                        Circle()
                            .fill(bleManager.isAdvertising ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: bleManager.isAdvertising ? .green : .red, radius: 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    
                    // Connection Status Dashboard
                    VStack(spacing: 6) {
                        Text("SYSTEM STATE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        Text(bleManager.connectionStatus)
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundColor(bleManager.connectionStatus == "Connected" ? .green : (bleManager.isAdvertising ? .cyan : .red))
                            .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : (bleManager.isAdvertising ? Color.cyan : Color.red)).opacity(0.3), radius: 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.02))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    
                    // Stats Widgets Row
                    HStack(spacing: 10) {
                        VStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.system(size: 14))
                                .foregroundColor(.cyan)
                            Text("UPTIME")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text(formattedTime)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        VStack(spacing: 6) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.purple)
                            Text("SPUN")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text("\(bleManager.pokestopsSpun)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.purple)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        VStack(spacing: 6) {
                            Image(systemName: "bolt.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.green)
                            Text("CAUGHT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text("\(bleManager.pokemonCaught)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.green)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 20)
                    
                    // Central Active Controller Ring
                    Button(action: {
                        if bleManager.connectionStatus == "Connected" {
                            bleManager.pressButton()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(gradient: Gradient(colors: [Color.cyan.opacity(0.15), Color.purple.opacity(0.15)]), startPoint: .top, endPoint: .bottom))
                                .frame(width: 170, height: 170)
                                .blur(radius: bleManager.connectionStatus == "Connected" ? 25 : 5)
                            
                            Circle()
                                .fill(LinearGradient(gradient: Gradient(colors: [Color.purple, Color.cyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 140, height: 140)
                                .shadow(color: .cyan.opacity(0.3), radius: 10)
                            
                            Circle()
                                .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                                .frame(width: 126, height: 126)
                            
                            Circle()
                                .fill(bleManager.connectionStatus == "Connected" ? Color.green : Color.red)
                                .frame(width: 44, height: 44)
                                .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : Color.red).opacity(0.8), radius: 10)
                            
                            Text("ACTION BUTTON")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .offset(y: -34)
                                .opacity(bleManager.connectionStatus == "Connected" ? 1.0 : 0.3)
                        }
                    }
                    .disabled(bleManager.connectionStatus != "Connected")
                    .buttonStyle(PlainButtonStyle())
                    
                    // Farm Device Manager Section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("PHONE FARM LIST")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            
                            Spacer()
                            
                            // "Add Phone" pairing mode button
                            Button(action: {
                                bleManager.isPairingMode.toggle()
                                bleManager.log("Pairing mode (Add Phone) set to: \(bleManager.isPairingMode)")
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: bleManager.isPairingMode ? "antenna.radiowaves.left.and.right" : "plus.circle.fill")
                                    Text(bleManager.isPairingMode ? "WAITING..." : "ADD PHONE")
                                }
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(bleManager.isPairingMode ? Color.yellow : Color.cyan)
                                .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal, 4)
                        
                        if bleManager.farmDevices.isEmpty {
                            Text("No phones linked yet. Boot the emulator and connect a phone, or toggle 'Add Phone' to pair.")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .background(Color.white.opacity(0.01))
                                .cornerRadius(12)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(bleManager.farmDevices) { device in
                                    HStack(spacing: 12) {
                                        // Edit Device Name / Normal Label
                                        if editingDeviceId == device.id {
                                            TextField("Name", text: $editingDeviceName, onCommit: {
                                                bleManager.renameDevice(device.id, newName: editingDeviceName)
                                                editingDeviceId = nil
                                            })
                                            .textFieldStyle(PlainTextFieldStyle())
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(6)
                                            .background(Color.white.opacity(0.08))
                                            .cornerRadius(6)
                                        } else {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(device.name)
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundColor(device.isEnabled ? .white : .gray)
                                                Text(device.isConnected ? "CONNECTED" : "LINK STANDBY")
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .foregroundColor(device.isConnected ? .green : .gray)
                                            }
                                            
                                            Button(action: {
                                                editingDeviceId = device.id
                                                editingDeviceName = device.name
                                            }) {
                                                Image(systemName: "pencil")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.gray)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        // Toggle active device emulation state
                                        Button(action: {
                                            bleManager.toggleDevice(device.id)
                                        }) {
                                            Text(device.isEnabled ? "ACTIVE" : "PAUSED")
                                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                                .foregroundColor(device.isEnabled ? .black : .white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .background(device.isEnabled ? Color.green : Color.white.opacity(0.1))
                                                .cornerRadius(8)
                                        }
                                        
                                        // Delete/Remove Device Button
                                        Button(action: {
                                            bleManager.deleteDevice(device.id)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 12))
                                                .foregroundColor(.red.opacity(0.8))
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.02))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(device.isConnected ? Color.green.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    // Boot up button
                    Button(action: {
                        if bleManager.isAdvertising {
                            bleManager.stopAdvertising()
                        } else {
                            bleManager.startAdvertising()
                        }
                    }) {
                        Text(bleManager.isAdvertising ? "POWER DOWN ENGINE" : "IGNITION EMULATOR")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 36)
                            .background(bleManager.isAdvertising ? Color.red : Color.cyan)
                            .cornerRadius(25)
                            .shadow(color: (bleManager.isAdvertising ? Color.red : Color.cyan).opacity(0.3), radius: 8)
                    }
                    
                    // Feed
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MASTER STREAM FEED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                        
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(bleManager.logMessages, id: \.self) { log in
                                    Text(log)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                        }
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(12)
                        .frame(height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    Spacer()
                }
                .padding(.vertical)
            }
        }
    }
}
