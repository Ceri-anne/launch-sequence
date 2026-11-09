import Foundation

public enum PNG {
    /// Width and height from a PNG's IHDR chunk, without decoding the image.
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature, String(data: data.subdata(in: 12..<16), encoding: .ascii) == "IHDR" else { return nil }
        func be32(_ offset: Int) -> Int { data.subdata(in: offset..<(offset + 4)).reduce(0) { $0 << 8 | Int($1) } }
        return (be32(16), be32(20))
    }
}

public struct SimulatorDevice: Sendable, Equatable { public var udid: String; public var name: String; public var runtime: String }

public enum Simulators {
    /// Finds the simulator matching name + platform + OS from `simctl list devices --json`.
    public static func find(_ sim: Simulator, in json: Data) throws -> SimulatorDevice? {
        let doc = try JSONValue.parse(json)
        guard case .object(let runtimes) = doc["devices"] else { return nil }
        let wanted = "com.apple.CoreSimulator.SimRuntime.\(sim.platform)-\(sim.os.replacingOccurrences(of: ".", with: "-"))"
        for (runtime, devices) in runtimes where runtime == wanted {
            for d in devices.array where d["name"].string == sim.name && d["isAvailable"].bool != false {
                if let udid = d["udid"].string { return SimulatorDevice(udid: udid, name: sim.name, runtime: runtime) }
            }
        }
        return nil
    }
}

/// Captures raw screenshots from Debug builds, driven by `.launchseq.yml`.
public struct ScreenshotCapture: Sendable {
    let config: Config
    let shots: ScreenshotsSection
    let shell: Shell
    let console: Console
    let sleep: @Sendable (Double) -> Void

    public init(config: Config, shell: Shell, console: Console, sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard let shots = config.screenshots else { throw LaunchError.config("No `screenshots` section") }
        self.config = config; self.shots = shots; self.shell = shell; self.console = console; self.sleep = sleep
    }

    var derivedData: URL { shell.root.appendingPathComponent("build/launchseq/DerivedData") }
    var products: URL { derivedData.appendingPathComponent("Build/Products") }

    public func build() throws {
        for b in shots.builds {
            console.step("Building \(b.scheme) (Debug, \(b.simulator.name) \(b.simulator.os))")
            try shell.change([
                "xcodebuild", "build", "-project", config.app.project, "-scheme", b.scheme, "-configuration", "Debug",
                "-destination", b.simulator.destination, "-derivedDataPath", derivedData.path,
            ], mode: .log(shell.root.appendingPathComponent("build/launchseq/logs/build-\(b.scheme).log")))
        }
    }

    public func capture() throws {
        let listJSON = try shell.read(["xcrun", "simctl", "list", "devices", "--json"]).stdout
        let fm = FileManager.default
        let rawRoot = try SafePath.resolve(shots.rawDir, under: shell.root)
        for device in shots.devices {
            guard let sim = try Simulators.find(device.simulator, in: Data(listJSON.utf8)) else {
                throw LaunchError.precondition("No \(device.simulator.platform) \(device.simulator.os) simulator named \"\(device.simulator.name)\". Install the runtime or fix `screenshots.devices`.")
            }
            console.step("\(device.name): \(sim.name) (\(device.simulator.os))")
            if let before = device.before {
                if shell.dryRun { console.dry("ask you to: \(before)") } else { try console.pause(before) }
            }
            try shell.change(["xcrun", "simctl", "boot", sim.udid], allowFailure: true)
            try shell.change(["xcrun", "simctl", "bootstatus", sim.udid, "-b"])
            try shell.change(["xcrun", "simctl", "status_bar", sim.udid, "override"] + device.statusBar, allowFailure: true)
            let app = try SafePath.resolve(device.app, under: products)
            if !shell.dryRun && !fm.fileExists(atPath: app.path) {
                throw LaunchError.precondition("Built app not found at \(app.path). Check `screenshots.builds` and the device's `app`.")
            }
            try shell.change(["xcrun", "simctl", "install", sim.udid, app.path])
            if device.warmupSeconds > 0 {
                try shell.change(["xcrun", "simctl", "launch", sim.udid, device.bundleId])
                if !shell.dryRun { sleep(device.warmupSeconds) }
            }
            let codes = device.languages ?? config.languages.map(\.code)
            for code in codes {
                guard let lang = config.language(code: code) else { continue }
                let folder = rawRoot.appendingPathComponent(code).appendingPathComponent(device.name)
                if !shell.dryRun { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
                for scene in shots.scenes {
                    try shell.change(["xcrun", "simctl", "terminate", sim.udid, device.bundleId], allowFailure: true)
                    try shell.change(["xcrun", "simctl", "launch", sim.udid, device.bundleId, "-AppleLanguages", "(\(lang.code))", "-AppleLocale", lang.locale] + scene.args)
                    if !shell.dryRun { sleep(device.settleSeconds) }
                    var args = ["xcrun", "simctl", "io", sim.udid, "screenshot"]
                    if let display = device.display { args.append("--display=\(display)") }
                    args.append(folder.appendingPathComponent("\(scene.name).png").path)
                    try shell.change(args)
                }
                console.ok("\(code)/\(device.name): \(shots.scenes.count) \(shell.dryRun ? "to capture" : "captured")")
            }
            try shell.change(["xcrun", "simctl", "terminate", sim.udid, device.bundleId], allowFailure: true)
        }
    }

    public func render() throws {
        guard let hook = shots.render, !hook.isEmpty else { return }
        console.step("Rendering with \(Shell.display(hook))")
        try shell.change(hook, environment: [
            "LAUNCHSEQ_RAW_DIR": try SafePath.resolve(shots.rawDir, under: shell.root).path,
            "LAUNCHSEQ_OUTPUT_DIR": try SafePath.resolve(shots.outputDir, under: shell.root).path,
        ], mode: .log(shell.root.appendingPathComponent("build/launchseq/logs/render.log")))
    }
}

/// Checks that every rendered screenshot exists and matches its slot's accepted sizes.
public enum ScreenshotValidator {
    public struct Expected: Sendable { public var language: Language; public var device: Device }

    public static func expected(_ config: Config) -> [Expected] {
        guard let shots = config.screenshots else { return [] }
        return shots.devices.flatMap { device in
            (device.languages ?? config.languages.map(\.code)).compactMap(config.language(code:)).map { Expected(language: $0, device: device) }
        }
    }

    public static func validate(config: Config, root: URL) throws -> [String] {
        guard let shots = config.screenshots else { return [] }
        let out = try SafePath.resolve(shots.outputDir, under: root)
        var problems: [String] = []
        for e in expected(config) {
            let folder = out.appendingPathComponent(e.language.code).appendingPathComponent(e.device.name)
            let sizes = e.device.acceptedSizes
            if e.device.displayType != nil && sizes.isEmpty {
                problems.append("\(e.device.name): no known sizes for \(e.device.displayType!); add `sizes` to the device")
            }
            for scene in shots.scenes {
                let file = folder.appendingPathComponent("\(scene.name).png")
                let rel = "\(shots.outputDir)/\(e.language.code)/\(e.device.name)/\(scene.name).png"
                guard let data = FileManager.default.contents(atPath: file.path) else { problems.append("\(rel) is missing"); continue }
                guard let size = PNG.size(of: data) else { problems.append("\(rel) isn't a PNG"); continue }
                if !sizes.isEmpty && !DisplayTypes.accepts(sizes, width: size.width, height: size.height) {
                    problems.append("\(rel) is \(size.width)×\(size.height); \(e.device.displayType ?? e.device.name) accepts \(sizes.map { "\($0[0])×\($0[1])" }.joined(separator: ", "))")
                }
            }
        }
        return problems
    }

    public struct Slot: Sendable { public var displayType: String; public var devices: [Device] }

    /// App Store screenshot slots for one language: devices grouped by display type, in config order.
    public static func slots(config: Config, language: String) -> [Slot] {
        var slots: [Slot] = []
        for device in config.screenshots?.devices ?? [] {
            guard let type = device.displayType, (device.languages ?? config.languages.map(\.code)).contains(language) else { continue }
            if let i = slots.firstIndex(where: { $0.displayType == type }) { slots[i].devices.append(device) }
            else { slots.append(Slot(displayType: type, devices: [device])) }
        }
        return slots
    }

    /// Rendered files to upload for one language and device, in file-name order.
    public static func files(config: Config, root: URL, language: String, device: Device) throws -> [URL] {
        guard let shots = config.screenshots else { return [] }
        let folder = try SafePath.resolve("\(shots.outputDir)/\(language)/\(device.name)", under: root)
        let wanted = Set(shots.scenes.map { "\($0.name).png" })
        return FileManager.default.files(in: folder, withExtension: "png").filter { wanted.contains($0.lastPathComponent) }
    }
}
