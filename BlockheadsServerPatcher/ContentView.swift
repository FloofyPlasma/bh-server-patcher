//
//  ContentView.swift
//  BlockheadsServerPatcher
//
//  Created by FloofyPlasma on 8/28/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct Tweak: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let version: String?
    let description: String?
    let author: String?
    var enabled: Bool
}

struct ContentView: View {
    @State private var tweaks: [Tweak] = []
    @State private var targetPath: String = "/Applications/BlockheadsServer.app/Contents/MacOS/BlockheadsServer"
    @State private var showFilePicker = false
    @State private var logText: String = ""
    @State private var serverOutput: String = ""
    
    var body: some View {
        VStack {
            HStack {
                Text("Tweak Launcher")
                    .font(.largeTitle)
                Spacer()
                Button("Refresh Tweaks") { loadTweaks() }
            }
            .padding(.bottom, 10)
            
            HStack {
                Text("Target:")
                Text(targetPath.isEmpty ? "None selected" : targetPath)
                    .foregroundColor(targetPath.isEmpty ? .red : .primary)
                Spacer()
                Button("Select Target") { showFilePicker = true }
            }
            .padding(.bottom, 10)
            
            List {
                ForEach($tweaks) { $tweak in
                    VStack(alignment: .leading) {
                        Toggle(tweak.name, isOn: $tweak.enabled)
                            .toggleStyle(SwitchToggleStyle(tint: tweak.enabled ? .green : .gray))
                        if let version = tweak.version {
                            Text("Version: \(version)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        if let description = tweak.description {
                            Text(description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let author = tweak.author {
                            Text("Author: \(author)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 200)
            
            Button("Launch Target") {
                launchTarget()
            }
            .padding()
            
            Text("Launcher Log:")
                .font(.headline)
            TextEditor(text: $logText)
                .frame(height: 100)
                .border(Color.gray)
            
            Text("Server Output:")
                .font(.headline)
                .padding(.top, 5)
            TextEditor(text: $serverOutput)
                .frame(height: 200)
                .border(Color.gray)
        }
        .frame(width: 600, height: 750)
        .padding()
        .onAppear(perform: loadTweaks)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let bundleURL = urls.first {
                    if let execPath = findTargetExecutable(appBundlePath: bundleURL.path) {
                        targetPath = execPath
                    } else {
                        appendLog("Executable not found inside bundle.")
                    }
                }
            case .failure(let error):
                appendLog("File selection failed: \(error)")
            }
        }
    }
    
    func appendLog(_ message: String) {
        logText += "\(message)\n"
    }
    
    func appendServerOutput(_ message: String) {
        DispatchQueue.main.async {
            serverOutput += "\(message)\n"
        }
    }
    
    func loadTweaks() {
        tweaks.removeAll()
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Patches") else { return }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
            let dylibs = files.filter { $0.pathExtension == "dylib" }
            
            tweaks = dylibs.map { dylib in
                let metaFile = dylib.deletingPathExtension().appendingPathExtension("json")
                var name = dylib.deletingPathExtension().lastPathComponent
                var version: String? = nil
                var description: String? = nil
                var author: String? = nil
                
                if let data = try? Data(contentsOf: metaFile),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    name = json["name"] ?? name
                    version = json["version"]
                    description = json["description"]
                    author = json["author"]
                }
                
                // Restore saved state
                let enabled = UserDefaults.standard.object(forKey: name) as? Bool ?? true
                
                return Tweak(name: name, path: dylib.path, version: version, description: description, author: author, enabled: enabled)
            }
            
            // Sort alphabetically
            tweaks.sort { $0.name < $1.name }
        } catch {
            appendLog("Failed to list patches: \(error)")
        }
    }
    
    func toggleChanged(_ tweak: Tweak) {
        UserDefaults.standard.set(tweak.enabled, forKey: tweak.name)
    }
    
    func launchTarget() {
        guard !targetPath.isEmpty else {
            appendLog("No target selected.")
            return
        }
        
        let enabledDylibs = tweaks.filter { $0.enabled }.map { $0.path }.joined(separator: ":")
        if enabledDylibs.isEmpty {
            appendLog("No enabled tweaks to inject.")
        } else {
            appendLog("Injecting dylibs: \(enabledDylibs)")
            setenv("DYLD_INSERT_LIBRARIES", enabledDylibs, 1)
        }
        
        let task = Process()
        task.launchPath = targetPath
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                appendServerOutput(str)
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                appendServerOutput(str)
            }
        }
        
        do {
            try task.run()
            appendLog("Launched target at \(targetPath)")
        } catch {
            appendLog("Failed to launch target: \(error)")
        }
    }
    
    func findTargetExecutable(appBundlePath: String) -> String? {
        let infoPlistPath = (appBundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let infoDict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] else {
            appendLog("Failed to read Info.plist at \(infoPlistPath)")
            return nil
        }

        guard let executableName = infoDict["CFBundleExecutable"] as? String else {
            appendLog("CFBundleExecutable not found in Info.plist")
            return nil
        }

        let macOSPath = (appBundlePath as NSString).appendingPathComponent("Contents/MacOS")
        let executablePath = (macOSPath as NSString).appendingPathComponent(executableName)

        return FileManager.default.fileExists(atPath: executablePath) ? executablePath : nil
    }
}
