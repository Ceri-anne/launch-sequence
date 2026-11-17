import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LaunchSequenceCore

/// A PNG filled with `background`, with a different-coloured status bar strip at the top
/// and `content` rectangles (in 0–1 unit coordinates, origin top-left) drawn in black.
func makePNG(width: Int = 402, height: Int = 874, background: CGColor = CGColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1),
             content: [CGRect] = []) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    func fill(_ r: CGRect, _ colour: CGColor) {
        context.setFillColor(colour)
        // CoreGraphics' origin is bottom-left.
        context.fill(CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h))
    }
    fill(CGRect(x: 0, y: 0, width: 1, height: 1), background)
    fill(CGRect(x: 0, y: 0, width: 1, height: 0.05), CGColor(red: 0, green: 0, blue: 0, alpha: 1))   // status bar
    content.forEach { fill($0, CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)) }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A screen with a title and a few short lines of text: about 3% of it isn't background.
let realScreen = makePNG(content: [CGRect(x: 0.1, y: 0.15, width: 0.6, height: 0.02)]
                         + (0..<6).map { CGRect(x: 0.1, y: 0.3 + Double($0) * 0.08, width: 0.4, height: 0.006) })
let blankScreen = makePNG()

/// Pretends to be `simctl`: lists one iPhone, and writes the next scripted image for each
/// `io screenshot`. The last image repeats.
final class FakeSimctl: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Data]
    private(set) var screenshots = 0
    private(set) var commands: [[String]] = []
    init(_ images: [Data]) { self.images = images }

    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        commands.append(arguments)
        if arguments.starts(with: ["xcrun", "simctl", "list"]) {
            let json = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 17 Pro", "udid": "U1", "isAvailable": true}]}}"#
            return CommandResult(status: 0, stdout: json, stderr: "")
        }
        if arguments.starts(with: ["xcrun", "simctl", "io"]), arguments.contains("screenshot"), let path = arguments.last {
            screenshots += 1
            let image = images.count > 1 ? images.removeFirst() : images[0]
            try image.write(to: URL(fileURLWithPath: path))
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite("Blank captures")
struct BlankCaptureTests {
    @Test func uniformImageIsBlank() {
        #expect(BlankCapture.isBlank(blankScreen))
    }

    @Test func realCaptureIsNotBlank() {
        #expect(!BlankCapture.isBlank(realScreen))
    }

    @Test func statusBarAloneDoesNotCountAsContent() {
        // The status bar strip differs from the background, but it's ignored.
        #expect(BlankCapture.isBlank(makePNG(width: 1320, height: 2868)))
    }

    @Test func unreadableDataIsNotBlank() {
        #expect(!BlankCapture.isBlank(Data("not a png".utf8)))
    }

    func capture(_ simctl: FakeSimctl, lines: Lines, sleeps: SleepLog) throws -> (ScreenshotCapture, URL) {
        // English only, so each test captures one scene on one device.
        let yml = try fixture("launchseq.yml").replacingOccurrences(of: "display_type: APP_IPHONE_61", with: "display_type: APP_IPHONE_61\n      languages: [en]")
        let config = try Config.parse(yml)
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build/launchseq/DerivedData/Build/Products/Debug-iphonesimulator/PrimeTime.app"), withIntermediateDirectories: true)
        let console = Console(answers: [], sink: lines.append)
        let shell = Shell(runner: simctl, console: console, dryRun: false, root: root)
        let file = root.appendingPathComponent("AppStoreAssets/Screenshots/Raw/en/iPhone/01-decide.png")
        return (try ScreenshotCapture(config: config, shell: shell, console: console, sleep: { sleeps.add($0) }), file)
    }

    @Test func blankCaptureIsRetried() throws {
        let simctl = FakeSimctl([blankScreen, realScreen])
        let lines = Lines(), sleeps = SleepLog()
        let (capture, file) = try capture(simctl, lines: lines, sleeps: sleeps)
        try capture.capture()
        #expect(simctl.screenshots == 2)
        #expect(FileManager.default.contents(atPath: file.path) == realScreen)
        #expect(lines.text.contains("en/iPhone/01-decide looks blank"))
        #expect(sleeps.all == [3, 3])   // settle, then settle again before the retry
    }

    @Test func captureFailsAfterTheLastRetry() throws {
        let simctl = FakeSimctl([blankScreen])
        let lines = Lines(), sleeps = SleepLog()
        let (capture, file) = try capture(simctl, lines: lines, sleeps: sleeps)
        let error = #expect(throws: LaunchError.self) { try capture.capture() }
        #expect(simctl.screenshots == 3)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let message = (error?.description) ?? ""
        #expect(message.contains("en/iPhone/01-decide"))
        #expect(message.contains("iPhone 17 Pro"))
        #expect(message.contains("settle_seconds"))
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [Double] = []
    func add(_ s: Double) { lock.lock(); seconds.append(s); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return seconds }
}
