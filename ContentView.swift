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
            if self.logMessages.count > 30 {
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
        
        // The game requires the advertised BLE name to be "Pokemon GO Plus" (or "PGP") to detect it.
        // We keep the Bluetooth broadcast name correct so the hack works, but rebrand the app UI to COMP WARE.
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "Pokemon GO Plus"
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        log("Started COMP WARE transmitter...")
        
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
        
        DispatchQueue.main.async {
            for i in 0..<self.farmDevices.count {
                self.farmDevices[i].isConnected = false
            }
        }
        log("COMP WARE transmitter stopped.")
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
        log("COMP WARE: Virtual click!")
        
        let pressValue = Data([0x01, 0x00])
        peripheralManager.updateValue(pressValue, for: buttonChar, onSubscribedCentrals: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let releaseValue = Data([0x00, 0x00])
            self.peripheralManager.updateValue(releaseValue, for: buttonChar, onSubscribedCentrals: nil)
            self.log("COMP WARE: Click released.")
        }
    }
    
    func toggleDevice(_ deviceId: UUID) {
        if let index = farmDevices.firstIndex(where: { $0.id == deviceId }) {
            farmDevices[index].isEnabled.toggle()
            saveDevices()
            
            let status = farmDevices[index].isEnabled ? "ENABLED" : "DISABLED"
            log("Phone '\(farmDevices[index].name)' \(status)")
            
            if !farmDevices[index].isEnabled && farmDevices[index].isConnected {
                resetServicesToDisconnect()
            }
        }
    }
    
    func renameDevice(_ deviceId: UUID, newName: String) {
        if let index = farmDevices.firstIndex(where: { $0.id == deviceId }) {
            farmDevices[index].name = newName
            saveDevices()
            log("Renamed device to '\(newName)'")
        }
    }
    
    func deleteDevice(_ deviceId: UUID) {
        farmDevices.removeAll(where: { $0.id == deviceId })
        saveDevices()
        log("Device removed from farm.")
        resetServicesToDisconnect()
    }
    
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
            log("COMP WARE Ready.")
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
                self.log("COMP WARE Active.")
                self.isAdvertising = true
                self.connectionStatus = self.farmDevices.contains(where: { $0.isConnected }) ? "Connected" : "Advertising..."
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        DispatchQueue.main.async {
            let isAlreadyKnown = self.farmDevices.contains(where: { $0.id == central.identifier })
            let connectedDevicesCount = self.farmDevices.filter({ $0.isConnected && $0.isEnabled }).count
            
            if connectedDevicesCount > 0 && !self.isPairingMode && !isAlreadyKnown {
                self.log("Access blocked: Pairing locked. Use 'ADD PHONE'.")
                self.resetServicesToDisconnect()
                return
            }
            
            if let index = self.farmDevices.firstIndex(where: { $0.id == central.identifier }) {
                if !self.farmDevices[index].isEnabled {
                    self.log("Rejected connection: '\(self.farmDevices[index].name)' paused.")
                    self.resetServicesToDisconnect()
                    return
                }
                self.farmDevices[index].isConnected = true
            } else {
                if self.isPairingMode || self.farmDevices.isEmpty {
                    let newDevice = FarmDevice(
                        id: central.identifier,
                        name: "Phone \(self.farmDevices.count + 1)",
                        isEnabled: true,
                        isConnected: true
                    )
                    self.farmDevices.append(newDevice)
                    self.saveDevices()
                    self.isPairingMode = false
                    self.log("Linked new phone: \(newDevice.name)")
                } else {
                    self.log("Rejected connection: Click 'ADD PHONE' to link.")
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
                self.log("Phone '\(self.farmDevices[index].name)' offline.")
            }
            
            let anyConnected = self.farmDevices.contains(where: { $0.isConnected && $0.isEnabled })
            self.connectionStatus = anyConnected ? "Connected" : (self.isAdvertising ? "Advertising..." : "Disconnected")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
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
                    Color(red: 0.05, green: 0.05, blue: 0.08),
                    Color(red: 0.02, green: 0.02, blue: 0.04)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Scaled ScrollView to prevent overflow on all devices (iPhone SE to Pro Max)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    
                    // Compact Header Banner
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("COMP WARE")
                                .font(.system(size: 26, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .tracking(4)
                            
                            Text("MULTI-PHONE FARM EMULATOR")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        
                        Circle()
                            .fill(bleManager.isAdvertising ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: bleManager.isAdvertising ? .green : .red, radius: 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    
                    // Connected Status Dashboard
                    VStack(spacing: 4) {
                        Text("SYSTEM STATE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        Text(bleManager.connectionStatus)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundColor(bleManager.connectionStatus == "Connected" ? .green : (bleManager.isAdvertising ? .cyan : .red))
                            .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : (bleManager.isAdvertising ? Color.cyan : Color.red)).opacity(0.3), radius: 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.02))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    
                    // Stats Widgets Row
                    HStack(spacing: 8) {
                        VStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 12))
                                .foregroundColor(.cyan)
                            Text("UPTIME")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text(formattedTime)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        VStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.purple)
                            Text("SPUN")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text("\(bleManager.pokestopsSpun)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.purple)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        VStack(spacing: 4) {
                            Image(systemName: "bolt.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                            Text("CAUGHT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Text("\(bleManager.pokemonCaught)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.green)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 16)
                    
                    // Compact Active Controller Ring
                    Button(action: {
                        if bleManager.connectionStatus == "Connected" {
                            bleManager.pressButton()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(gradient: Gradient(colors: [Color.cyan.opacity(0.12), Color.purple.opacity(0.12)]), startPoint: .top, endPoint: .bottom))
                                .frame(width: 140, height: 140)
                                .blur(radius: bleManager.connectionStatus == "Connected" ? 15 : 2)
                            
                            Circle()
                                .fill(LinearGradient(gradient: Gradient(colors: [Color.purple, Color.cyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 110, height: 110)
                                .shadow(color: .cyan.opacity(0.3), radius: 8)
                            
                            Circle()
                                .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                                .frame(width: 98, height: 98)
                            
                            Circle()
                                .fill(bleManager.connectionStatus == "Connected" ? Color.green : Color.red)
                                .frame(width: 32, height: 32)
                                .shadow(color: (bleManager.connectionStatus == "Connected" ? Color.green : Color.red).opacity(0.8), radius: 8)
                            
                            Text("CLICK")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .offset(y: -26)
                                .opacity(bleManager.connectionStatus == "Connected" ? 1.0 : 0.3)
                        }
                    }
                    .disabled(bleManager.connectionStatus != "Connected")
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 4)
                    
                    // Farm Device Manager Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("FARM DEVICE POOL")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            
                            Spacer()
                            
                            Button(action: {
                                bleManager.isPairingMode.toggle()
                                bleManager.log("Pairing mode (Add Phone) set to: \(bleManager.isPairingMode)")
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: bleManager.isPairingMode ? "antenna.radiowaves.left.and.right" : "plus.circle.fill")
                                    Text(bleManager.isPairingMode ? "LOCKING..." : "ADD PHONE")
                                }
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(bleManager.isPairingMode ? Color.yellow : Color.cyan)
                                .cornerRadius(10)
                            }
                        }
                        
                        if bleManager.farmDevices.isEmpty {
                            Text("No phones linked. Enable transmitter and connect a device, or click 'ADD PHONE' to pair.")
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .background(Color.white.opacity(0.01))
                                .cornerRadius(10)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(bleManager.farmDevices) { device in
                                    HStack(spacing: 8) {
                                        if editingDeviceId == device.id {
                                            TextField("Name", text: $editingDeviceName, onCommit: {
                                                bleManager.renameDevice(device.id, newName: editingDeviceName)
                                                editingDeviceId = nil
                                            })
                                            .textFieldStyle(PlainTextFieldStyle())
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(4)
                                            .background(Color.white.opacity(0.08))
                                            .cornerRadius(4)
                                        } else {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(device.name)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(device.isEnabled ? .white : .gray)
                                                Text(device.isConnected ? "CONNECTED" : "LINK STANDBY")
                                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                                    .foregroundColor(device.isConnected ? .green : .gray)
                                            }
                                            
                                            Button(action: {
                                                editingDeviceId = device.id
                                                editingDeviceName = device.name
                                            }) {
                                                Image(systemName: "pencil")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.gray)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            bleManager.toggleDevice(device.id)
                                        }) {
                                            Text(device.isEnabled ? "ACTIVE" : "PAUSED")
                                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                                .foregroundColor(device.isEnabled ? .black : .white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(device.isEnabled ? Color.green : Color.white.opacity(0.1))
                                                .cornerRadius(6)
                                        }
                                        
                                        Button(action: {
                                            bleManager.deleteDevice(device.id)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 10))
                                                .foregroundColor(.red.opacity(0.8))
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.02))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(device.isConnected ? Color.green.opacity(0.3) : Color.white.opacity(0.04), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Boot up button
                    Button(action: {
                        if bleManager.isAdvertising {
                            bleManager.stopAdvertising()
                        } else {
                            bleManager.startAdvertising()
                        }
                    }) {
                        Text(bleManager.isAdvertising ? "TERMINATE COMP WARE" : "IGNITE COMP WARE")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 32)
                            .background(bleManager.isAdvertising ? Color.red : Color.cyan)
                            .cornerRadius(20)
                            .shadow(color: (bleManager.isAdvertising ? Color.red : Color.cyan).opacity(0.3), radius: 6)
                    }
                    .padding(.vertical, 4)
                    
                    // Log Feed
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COMP WARE SYSTEM FEED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                        
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(bleManager.logMessages, id: \.self) { log in
                                    Text(log)
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(10)
                        .frame(height: 75)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 16)
                    
                }
                .padding(.vertical, 8)
            }
        }
    }
}
