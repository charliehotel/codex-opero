import Foundation

enum KeychainReader {
    struct Password: Sendable {
        let data: Data
        let identity: Data
    }
}

/// Accesses keychain items through `/usr/bin/security`, the same client Claude Code and agy use.
/// Going through the Apple-signed tool keeps this ad-hoc signed app, whose identity changes with
/// every build, out of item ACLs and partition lists, so updating the app no longer re-prompts.
enum SecurityCLIKeychain {
    private static let executable = URL(fileURLWithPath: "/usr/bin/security")
    private static let itemNotFound: Int32 = 44
    // Claude Code sends updates over `security -i` stdin below this size and falls back to argv above it.
    private static let interactiveLineLimit = 4000

    static func genericPasswordItem(service: String) throws -> KeychainReader.Password {
        let account = try account(service: service)
        return KeychainReader.Password(data: try password(service: service, account: account),
                                       identity: identity(service: service, account: account))
    }

    static func updateGenericPassword(_ expected: KeychainReader.Password, service: String, data: Data) throws -> Bool {
        let account: String
        let current: Data
        do {
            account = try self.account(service: service)
            current = try password(service: service, account: account)
        } catch ProviderError.credentialsMissing {
            return false
        }
        guard identity(service: service, account: account) == expected.identity, current == expected.data else { return false }
        try setGenericPassword(service: service, account: account, data: data)
        return true
    }

    static func genericPassword(service: String, account: String) throws -> Data {
        try password(service: service, account: account)
    }

    /// Creates or updates the item; an existing item keeps its ACL and `Always Allow` grants.
    static func setGenericPassword(service: String, account: String, data: Data) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        let status: Int32
        if line.utf8.count <= interactiveLineLimit, !(account + service).contains(where: { "\"\\\n".contains($0) }) {
            status = try run(["-i"], input: Data(line.utf8)).status
        } else {
            status = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]).status
        }
        // `security -i` reports success even when the command inside fails, so confirm by reading back.
        guard status == 0, try password(service: service, account: account) == data else {
            throw ProviderError.other("keychain update failed")
        }
    }

    private static func identity(service: String, account: String) -> Data {
        Data("\(service)\n\(account)".utf8)
    }

    /// Reads the account from the item's attributes, which does not require access to its secret.
    private static func account(service: String) throws -> String {
        let output = String(decoding: try checkedRun(["find-generic-password", "-s", service]), as: UTF8.self)
        for line in output.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"acct\"<blob>=") else { continue }
            let value = line.dropFirst("\"acct\"<blob>=".count)
            if value.hasPrefix("0x"), let hex = value.dropFirst(2).split(separator: " ").first,
               let data = Data(hex: String(hex)) {
                return String(decoding: data, as: UTF8.self)
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                return String(value.dropFirst().dropLast())
            }
        }
        throw ProviderError.other("keychain item has no account")
    }

    private static func password(service: String, account: String) throws -> Data {
        var data = try checkedRun(["find-generic-password", "-a", account, "-s", service, "-w"])
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        // `security -w` prints non-printable secrets as hex.
        if data.first != UInt8(ascii: "{"), let decoded = Data(hex: String(decoding: data, as: UTF8.self)) {
            return decoded
        }
        return data
    }

    private static func checkedRun(_ arguments: [String]) throws -> Data {
        let result = try run(arguments)
        guard result.status != itemNotFound else { throw ProviderError.credentialsMissing }
        guard result.status == 0 else { throw ProviderError.other("keychain error \(result.status)") }
        return result.output
    }

    private static func run(_ arguments: [String], input: Data? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProviderError.other("failed to run security: \(error.localizedDescription)")
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
