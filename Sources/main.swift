/*
   Copyright 2024 Sean McNamara <smcnam@gmail.com>

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

import Cocoa
import Foundation
import Network
import SwiftUI

func query(address: String) -> String {
  let url = URL(string: address)
  let semaphore = DispatchSemaphore(value: 0)

  var result: String = ""

  let task = URLSession.shared.dataTask(with: url!) { (data, response, error) in
    result = String(data: data!, encoding: String.Encoding.utf8)!
    semaphore.signal()
  }

  task.resume()
  semaphore.wait()
  return result
}

struct Configuration {
  static var cliHost: String = "127.0.0.1"
  static var cliPort: UInt16 = 4712
  static var httpHost: String = "127.0.0.1"
  static var httpPort: String = "4714"
}

@main
struct TrayApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  static func main() {
    let args = CommandLine.arguments

    if args.contains("-h") || args.contains("--help") {
      printUsage()
      return
    }

    if args.count == 1 {
      print(
        "Going with all default arguments: localhost for the server, 4712 for the CLI TCP port, and 4714 for the HTTP port."
      )
    } else if args.count == 5, let cliPort = UInt16(args[2]) {
      Configuration.cliHost = args[1]
      Configuration.cliPort = cliPort
      Configuration.httpHost = args[3]
      Configuration.httpPort = args[4]
      print(
        "Configuration is: \(Configuration.cliHost):\(Configuration.cliPort) for the CLI, and \(Configuration.httpHost):\(Configuration.httpPort) for the HTTP server."
      )
    } else {
      print("Error: Invalid arguments.")
      printUsage()
      return
    }

    let ad = AppDelegate()

    NSApplication.shared.setActivationPolicy(.regular)
    NSApp.delegate = ad
    NSApp.run()
  }

  static func printUsage() {
    print(
      """
      Usage: \(CommandLine.arguments[0]) <CLI IP> <CLI Port> <HTTP IP> <HTTP Port>
      Options:
        -h, --help       Show help information and usage.
      """)
  }

  var body: some Scene {
    Settings {
      Text("Settings")
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusBarItem: NSStatusItem?
  var popover = NSPopover()
  var pulseAudioClient: PulseAudioClient?

  func applicationDidFinishLaunching(_ notification: Notification) {
    self.pulseAudioClient = PulseAudioClient(
      cliHost: Configuration.cliHost, cliPort: Configuration.cliPort,
      httpHost: Configuration.httpHost, httpPort: Configuration.httpPort)
    setupStatusItem()
  }

  func setupStatusItem() {
    statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusBarItem?.button {
      button.image = NSImage(
        systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Volume")
      button.action = #selector(togglePopover(_:))
      button.target = self
    }

    popover.contentSize = NSSize(width: 400, height: 200)
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
      rootView: VolumeControlView(pulseAudioClient: pulseAudioClient!))
  }

  @objc func togglePopover(_ sender: AnyObject?) {
    if let button = statusBarItem?.button {
      if popover.isShown {
        popover.performClose(sender)
      } else {
        print("Showing popover")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      }
    }
  }
}

struct VolumeControlView: View {
  @State private var sinkVolume: Double = 0
  @State private var sourceVolume: Double = 0
  var pulseAudioClient: PulseAudioClient

  var body: some View {
    VStack(spacing: 20) {
      Text("Output Volume").font(.headline)
      Slider(value: $sinkVolume, in: 0...100, step: 1.0)
        .onChange(of: sinkVolume) { newValue in
          pulseAudioClient.setVolume(to: Int(newValue), isSink: true)
        }
      Text("Volume: \(Int(sinkVolume))%")

      Text("Input Volume").font(.headline)
      Slider(value: $sourceVolume, in: 0...100, step: 1.0)
        .onChange(of: sourceVolume) { newValue in
          pulseAudioClient.setVolume(to: Int(newValue), isSink: false)
        }
      Text("Volume: \(Int(sourceVolume))%")
    }
    .padding()
    .onAppear {
      pulseAudioClient.connect()
      pulseAudioClient.getVolumes { sinkVol, sourceVol in
        sinkVolume = sinkVol
        sourceVolume = sourceVol
      }
    }
  }
}

class PulseAudioClient {
  private var connection: NWConnection?
  private let cliHost: NWEndpoint.Host
  private let cliPort: NWEndpoint.Port
  private let httpHost: String
  private let httpPort: String

  init(cliHost: String, cliPort: UInt16, httpHost: String, httpPort: String) {
    self.cliHost = NWEndpoint.Host(cliHost)
    self.cliPort = NWEndpoint.Port(rawValue: cliPort)!
    self.httpHost = httpHost
    self.httpPort = httpPort
  }

  func connect() {
    connection = NWConnection(host: cliHost, port: cliPort, using: .tcp)
    print("Connecting to PulseAudio server with host: \(cliHost) and port: \(cliPort)")
    connection?.stateUpdateHandler = { state in
      switch state {
      case .ready:
        print("Connected to PulseAudio server")
      case .failed(let error):
        print("Failed to connect: \(error)")
      default:
        print("Unhandled state: \(state)")
        break
      }
    }
    connection?.start(queue: .main)
  }

  func setVolume(to volumeLevel: Int, isSink: Bool) {
    let volume = Int(Double(volumeLevel) / 100.0 * 65536.0)
    let command =
      isSink
      ? "set-sink-volume @DEFAULT_SINK@ \(volume)\n"
      : "set-source-volume @DEFAULT_SOURCE@ \(volume)\n"
    send(command: command)
  }

  func getVolumes(completion: @escaping (Double, Double) -> Void) {
    let httpResp = query(address: "http://\(httpHost):\(httpPort)/status")
    print("Got HTTP response from PulseAudio server:\n\(httpResp)")
    let (sinkVolume, sourceVolume) = self.parseVolumes(response: httpResp)
    print("Parsed volumes: sink=\(sinkVolume), source=\(sourceVolume)")
    completion(sinkVolume, sourceVolume)
  }

  private func send(command: String) {
    guard let data = command.data(using: .utf8) else { return }
    connection?.send(
      content: data,
      completion: .contentProcessed { error in
        if let error = error {
          print("Error sending command: \(error)")
          return
        }
        print("Command sent successfully")
      })
  }

  func parseVolumes(response: String) -> (Double, Double) {
    let lines = response.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var currentMode: ParseMode = .none
    var defaultSinkVolume: Double = 0.0
    var defaultSourceVolume: Double = 0.0
    var grabNext: Bool = false

    enum ParseMode {
      case none, sinks, sources
    }

    for line in lines {
      switch line {
      case let line where line.contains("sink(s) available."):
        print("Parsing sinks")
        currentMode = .sinks
      case let line where line.contains("source(s) available."):
        print("Parsing sources")
        currentMode = .sources
      default:
        if line.starts(with: "* index:") {
          print("Found default sink or source: \(line)")
          grabNext = true
        }
        if line.starts(with: "volume:") && grabNext {
          let volume = extractVolume(from: line)
          if currentMode == .sinks {
            defaultSinkVolume = volume
          } else if currentMode == .sources {
            defaultSourceVolume = volume
          }
          grabNext = false
        }
      }
    }

    return (defaultSinkVolume, defaultSourceVolume)
  }

  private func extractVolume(from line: String) -> Double {
    let pattern = "\\bvolume:.*?(\\d+)%"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let matchRange = Range(match.range(at: 1), in: line)
    else {
      return 0
    }
    return Double(line[matchRange]) ?? 0
  }

}

extension Array {
  subscript(safe index: Int) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}
