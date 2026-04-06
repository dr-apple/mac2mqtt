import CocoaMQTT
import Foundation
import Yams

struct AppConfig: Decodable {
    struct MQTT: Decodable {
        let host: String
        let port: Int
        let username: String?
        let password: String?
        let useTLS: Bool
        let keepAliveSeconds: UInt16
    }

    struct Topics: Decodable {
        let base: String
    }

    struct Intervals: Decodable {
        let volumeSeconds: TimeInterval
        let batterySeconds: TimeInterval
    }

    let computerName: String
    let mqtt: MQTT
    let topics: Topics
    let intervals: Intervals
}

enum ShellError: Error {
    case failed(String)
}

@discardableResult
func runProcess(_ launchPath: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
        throw ShellError.failed("Command failed: \(launchPath) \(args.joined(separator: " ")); \(err)")
    }
    return output
}

func currentVolume() throws -> Int {
    let output = try runProcess("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
    return Int(output) ?? 0
}

func isMuted() throws -> Bool {
    let output = try runProcess("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"])
    return output.lowercased() == "true"
}

func setVolume(_ value: Int) throws {
    let clamped = max(0, min(100, value))
    _ = try runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(clamped)"])
}

func setMuted(_ value: Bool) throws {
    let script = value ? "set volume with output muted" : "set volume without output muted"
    _ = try runProcess("/usr/bin/osascript", ["-e", script])
}

func batteryPercent() throws -> Int {
    let output = try runProcess("/usr/bin/pmset", ["-g", "batt"])
    let regex = try NSRegularExpression(pattern: "(\\d+)%")
    let nsString = output as NSString
    let range = NSRange(location: 0, length: nsString.length)
    if let match = regex.firstMatch(in: output, range: range),
       match.numberOfRanges > 1 {
        return Int(nsString.substring(with: match.range(at: 1))) ?? 0
    }
    return 0
}

func sleepMac() throws {
    _ = try runProcess("/usr/bin/pmset", ["sleepnow"])
}

func shutdownMac() throws {
    _ = try runProcess("/sbin/shutdown", ["-h", "now"])
}

func displaySleep() throws {
    _ = try runProcess("/usr/bin/pmset", ["displaysleepnow"])
}

final class Daemon: NSObject, CocoaMQTTDelegate {
    private let config: AppConfig
    private let mqtt: CocoaMQTT
    private var volumeTimer: DispatchSourceTimer?
    private var batteryTimer: DispatchSourceTimer?

    private var baseTopic: String {
        "\(config.topics.base)/\(config.computerName)"
    }

    init(config: AppConfig) {
        self.config = config
        self.mqtt = CocoaMQTT(clientID: "mac2mqttd-\(config.computerName)-\(UUID().uuidString.prefix(8))",
                              host: config.mqtt.host,
                              port: UInt16(config.mqtt.port))
        super.init()

        mqtt.username = config.mqtt.username
        mqtt.password = config.mqtt.password
        mqtt.keepAlive = config.mqtt.keepAliveSeconds
        mqtt.enableSSL = config.mqtt.useTLS
        mqtt.autoReconnect = true
        mqtt.delegate = self
        mqtt.willMessage = CocoaMQTTMessage(topic: "\(baseTopic)/status/alive",
                                            string: "false",
                                            qos: .qos1,
                                            retained: true)
    }

    func start() {
        print("Starting mac2mqttd ...")
        _ = mqtt.connect()
    }

    private func publishStatus() {
        do {
            mqtt.publish("\(baseTopic)/status/volume", withString: String(try currentVolume()), qos: .qos1, retained: true)
            mqtt.publish("\(baseTopic)/status/mute", withString: String(try isMuted()), qos: .qos1, retained: true)
            mqtt.publish("\(baseTopic)/status/battery", withString: String(try batteryPercent()), qos: .qos1, retained: true)
        } catch {
            print("Status update error: \(error)")
        }
    }

    private func schedulePolling() {
        let volumeTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        volumeTimer.schedule(deadline: .now(), repeating: config.intervals.volumeSeconds)
        volumeTimer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                self.mqtt.publish("\(self.baseTopic)/status/volume", withString: String(try currentVolume()), qos: .qos1, retained: true)
                self.mqtt.publish("\(self.baseTopic)/status/mute", withString: String(try isMuted()), qos: .qos1, retained: true)
            } catch {
                print("Volume poll error: \(error)")
            }
        }
        volumeTimer.resume()
        self.volumeTimer = volumeTimer

        let batteryTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        batteryTimer.schedule(deadline: .now(), repeating: config.intervals.batterySeconds)
        batteryTimer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                self.mqtt.publish("\(self.baseTopic)/status/battery", withString: String(try batteryPercent()), qos: .qos1, retained: true)
            } catch {
                print("Battery poll error: \(error)")
            }
        }
        batteryTimer.resume()
        self.batteryTimer = batteryTimer
    }

    private func subscribeCommands() {
        mqtt.subscribe("\(baseTopic)/command/#", qos: .qos1)
    }

    private func handleCommand(topic: String, payload: String) {
        switch topic {
        case "\(baseTopic)/command/volume":
            if let value = Int(payload) {
                try? setVolume(value)
            }
        case "\(baseTopic)/command/mute":
            try? setMuted(payload.lowercased() == "true")
        case "\(baseTopic)/command/sleep":
            if payload == "sleep" { try? sleepMac() }
        case "\(baseTopic)/command/shutdown":
            if payload == "shutdown" { try? shutdownMac() }
        case "\(baseTopic)/command/displaysleep":
            if payload == "displaysleep" { try? displaySleep() }
        default:
            break
        }

        publishStatus()
    }

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            print("MQTT connect failed: \(ack)")
            return
        }
        print("Connected to MQTT")
        mqtt.publish("\(baseTopic)/status/alive", withString: "true", qos: .qos1, retained: true)
        subscribeCommands()
        publishStatus()
        schedulePolling()
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        print("Disconnected: \(err?.localizedDescription ?? "none")")
    }
    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = message.string ?? ""
        handleCommand(topic: message.topic, payload: payload)
    }
}

func loadConfig() throws -> AppConfig {
    let args = CommandLine.arguments
    let configPath: String
    if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) {
        configPath = args[index + 1]
    } else {
        configPath = "\(NSHomeDirectory())/mac2mqtt/mac2mqtt.yaml"
    }

    let content = try String(contentsOfFile: configPath, encoding: .utf8)
    return try YAMLDecoder().decode(AppConfig.self, from: content)
}

do {
    let config = try loadConfig()
    let daemon = Daemon(config: config)
    daemon.start()
    dispatchMain()
} catch {
    fputs("Startup error: \(error)\n", stderr)
    exit(1)
}
