import Foundation

enum Endianness { case big, little }

struct PacketReader {
    private let data: Data
    private(set) var offset = 0

    init(data: Data) { self.data = data }

    var available: Int { data.count - offset }

    mutating func skip(_ n: Int) { offset += n }

    mutating func readInt32(endianness: Endianness = .big) -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
        offset += 4
        return endianness == .big ? v.bigEndian : v.littleEndian
    }

    mutating func readInt16(endianness: Endianness = .big) -> Int16? {
        guard offset + 2 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int16.self) }
        offset += 2
        return endianness == .big ? v.bigEndian : v.littleEndian
    }

    mutating func readUInt32(endianness: Endianness = .big) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return endianness == .big ? v.bigEndian : v.littleEndian
    }

    mutating func bytes(_ length: Int) -> [UInt8] {
        guard length > 0, offset + length <= data.count else { return [] }
        let slice = data[offset..<offset + length]
        offset += length
        return [UInt8](slice)
    }
}

struct PacketWriter {
    private(set) var data = Data()

    mutating func write(_ v: Int32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func write(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func write(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func write(_ bytes: Data) { data.append(bytes) }
}
