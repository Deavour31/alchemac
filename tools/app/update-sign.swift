import Foundation
import CryptoKit
import Darwin

// Release signing tool for Alchemac updates (Ed25519).
//   update-sign keygen <keyfile>                    creates the key; prints only the base64 public key
//   update-sign pubkey <keyfile>                    prints the base64 public key
//   update-sign sign <keyfile> <file>               prints the base64 signature of the file's bytes
//   update-sign verify <pubkey-base64> <file> <sigfile>   exit 0 when valid, 1 otherwise
// The private key is never printed.

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(("update-sign: " + text + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { fail("key file not found or not a regular file") }
    guard info.st_mode & 0o077 == 0 else { fail("key file permissions allow group/other access; run chmod 600") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("key file is not a base64 32-byte Ed25519 key") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let path = args[1]
    if FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { fail("key file already exists") }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { fail("cannot create key folder") }
    let key = Curve25519.Signing.PrivateKey()
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("cannot create key file") }
    let text = Array((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    guard write(fd, text, text.count) == text.count else { close(fd); fail("cannot write key file") }
    close(fd)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("pubkey", 2):
    print(loadKey(args[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read file") }
    guard let signature = try? loadKey(args[1]).signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())
case ("verify", 4):
    guard let raw = Data(base64Encoded: args[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let data = FileManager.default.contents(atPath: args[2]),
          let text = try? String(contentsOfFile: args[3], encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          key.isValidSignature(signature, for: data) else { exit(1) }
    exit(0)
default:
    fail("usage: update-sign keygen|pubkey|sign|verify ...")
}
