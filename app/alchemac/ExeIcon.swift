import AppKit

/// Extracts a program's own icon from its PE file (PE32 and PE32+): the first RT_GROUP_ICON and its RT_ICON
/// images become an in-memory .ico. Every read is bounds-checked; any problem yields nil.
enum ExeIcon {
    static let maxResourceBytes = 64 << 20, maxFileBytes = 2 << 30, maxImageBytes = 16 << 20

    static func icoData(at url: URL) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= maxFileBytes,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return icoData(from: data)
    }

    static func icoData(from input: Data) -> Data? {
        let d = input.startIndex == 0 ? input : Data(input)
        func u16(_ o: Int) -> Int? { o >= 0 && o <= d.count - 2 ? Int(d[o]) | Int(d[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o <= d.count - 4 ? Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 : nil }
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A, let pe = u32(0x3C), pe > 0, u32(pe) == 0x0000_4550,
              let sectionCount = u16(pe + 6), let optSize = u16(pe + 20), sectionCount > 0, sectionCount <= 96,
              let magic = u16(pe + 24), magic == 0x10B || magic == 0x20B else { return nil }
        let opt = pe + 24, dirs = opt + (magic == 0x20B ? 112 : 96)
        guard let dirCount = u32(dirs - 4), dirCount > 2, let rsrcRVA = u32(dirs + 16), let rsrcSize = u32(dirs + 20),
              rsrcRVA > 0, rsrcSize > 0, rsrcSize <= maxResourceBytes else { return nil }
        let table = opt + optSize
        func offset(_ rva: Int) -> Int? {
            for i in 0..<sectionCount {
                let s = table + i * 40
                guard let virtualSize = u32(s + 8), let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { return nil }
                if rva >= va, rva - va < max(virtualSize, rawSize), rva - va < rawSize, raw + (rva - va) < d.count { return raw + (rva - va) }
            }
            return nil
        }
        guard let base = offset(rsrcRVA) else { return nil }
        /// Entries of the resource directory at `dir`: (name or id, target offset, isDirectory).
        func entries(_ dir: Int) -> [(id: Int, target: Int, isDir: Bool)] {
            guard dir >= base, let named = u16(dir + 12), let ids = u16(dir + 14), named + ids <= 4096 else { return [] }
            var result: [(Int, Int, Bool)] = []
            for i in 0..<(named + ids) {
                guard let name = u32(dir + 16 + i * 8), let target = u32(dir + 20 + i * 8) else { break }
                result.append((name & 0x8000_0000 == 0 ? name : -1, target & 0x7FFF_FFFF, target & 0x8000_0000 != 0))
            }
            return result
        }
        /// The first data entry below `entry`, descending through any names and languages.
        func firstData(_ entry: (id: Int, target: Int, isDir: Bool)) -> Data? {
            var e = entry
            for _ in 0..<4 {
                if !e.isDir {
                    let at = base + e.target
                    guard let rva = u32(at), let size = u32(at + 4), size > 0, size <= maxImageBytes, let start = offset(rva),
                          start + size <= d.count else { return nil }
                    return d.subdata(in: start..<(start + size))
                }
                guard let next = entries(base + e.target).first else { return nil }
                e = next
            }
            return nil
        }
        func type(_ id: Int) -> (id: Int, target: Int, isDir: Bool)? { entries(base).first { $0.id == id && $0.isDir } }
        guard let groupType = type(14), let icons = type(3), let group = entries(base + groupType.target).first,
              let dir = firstData(group), dir.count >= 6, dir[2] == 1, dir[3] == 0 else { return nil }
        let count = Int(dir[4]) | Int(dir[5]) << 8
        guard count > 0, count <= 64, dir.count >= 6 + count * 14 else { return nil }
        let byID = Dictionary(entries(base + icons.target).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [(Data, Data)] = [] // ICONDIRENTRY without offset, image
        for i in 0..<count {
            let e = 6 + i * 14
            let id = Int(dir[e + 12]) | Int(dir[e + 13]) << 8
            if let entry = byID[id], let image = firstData(entry) { found.append((dir.subdata(in: e..<(e + 12)), image)) }
        }
        guard !found.isEmpty else { return nil }
        var out = Data([0, 0, 1, 0, UInt8(found.count & 0xFF), UInt8(found.count >> 8)])
        var next = 6 + found.count * 16
        for (header, image) in found {
            out += header
            out += withUnsafeBytes(of: UInt32(next).littleEndian) { Data($0) }
            next += image.count
        }
        for (_, image) in found { out += image }
        return out
    }

    /// The largest representation of an .ico as PNG data.
    static func png(fromICO ico: Data) -> Data? {
        guard let image = NSImage(data: ico),
              let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), rep.pixelsWide > 0 else { return nil }
        return (rep as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
    }

    /// icon.png in `dir`, refreshed when the program's modification date or size changes. A failed
    /// extraction is remembered the same way (key without PNG) so it is not retried on every start.
    static func cachedPNG(exe: URL, dir: URL) -> Data? {
        let fm = FileManager.default, png = dir.appendingPathComponent("icon.png"), keyFile = dir.appendingPathComponent("icon.key")
        guard let attributes = try? fm.attributesOfItem(atPath: exe.path), let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let key = "\(Int(modified.timeIntervalSince1970))-\(size)"
        if (try? String(contentsOf: keyFile, encoding: .utf8)) == key { return try? Data(contentsOf: png) }
        let data = icoData(at: exe).flatMap(png(fromICO:))
        if fm.fileExists(atPath: dir.path) {
            if let data { try? data.write(to: png, options: .atomic) } else { try? fm.removeItem(at: png) }
            try? key.write(to: keyFile, atomically: true, encoding: .utf8)
        }
        return data
    }
}
