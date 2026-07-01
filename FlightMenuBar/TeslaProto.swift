import Foundation

// MARK: - Minimal protobuf wire encoder

struct ProtoWriter {
    private(set) var data = Data()

    // Wire type 2: length-delimited (bytes, strings, embedded messages)
    mutating func bytes(_ fieldNumber: Int, value: Data) {
        writeTag(fieldNumber, wireType: 2)
        writeVarint(value.count)
        data.append(value)
    }

    // Wire type 0: varint
    mutating func varint(_ fieldNumber: Int, value: Int) {
        writeTag(fieldNumber, wireType: 0)
        writeVarint(value)
    }

    // Wire type 1: 64-bit fixed (double)
    mutating func double(_ fieldNumber: Int, value: Double) {
        writeTag(fieldNumber, wireType: 1)
        var v = value.bitPattern
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // Embedded message (wire type 2)
    mutating func embedded(_ fieldNumber: Int, build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(fieldNumber, value: inner.data)
    }

    private mutating func writeTag(_ fieldNumber: Int, wireType: Int) {
        writeVarint((fieldNumber << 3) | wireType)
    }

    private mutating func writeVarint(_ value: Int) {
        var v = value
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            data.append(v > 0 ? byte | 0x80 : byte)
        } while v > 0
    }
}

// MARK: - Minimal protobuf wire decoder

struct ProtoReader {
    private let data: Data
    private var pos: Int = 0

    init(_ data: Data) { self.data = data }

    // Read all fields into a dict: fieldNumber → [Data] (may repeat)
    mutating func readAll() -> [Int: [Data]] {
        var result: [Int: [Data]] = [:]
        while pos < data.count {
            guard let (fieldNumber, wireType) = readTag() else { break }
            let value: Data
            switch wireType {
            case 0:  // varint
                value = readVarintBytes()
            case 1:  // 64-bit
                value = readFixed(8)
            case 2:  // length-delimited
                let len = readVarint()
                value = readFixed(len)
            case 5:  // 32-bit
                value = readFixed(4)
            default:
                return result  // unknown wire type, stop
            }
            result[fieldNumber, default: []].append(value)
        }
        return result
    }

    private mutating func readTag() -> (Int, Int)? {
        let v = readVarint()
        if v == 0 { return nil }
        return (v >> 3, v & 0x07)
    }

    private mutating func readVarint() -> Int {
        var result = 0
        var shift = 0
        while pos < data.count {
            let byte = Int(data[pos]); pos += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    private mutating func readVarintBytes() -> Data {
        var result = 0
        var shift = 0
        var raw = Data()
        while pos < data.count {
            let byte = data[pos]; pos += 1
            raw.append(byte)
            result |= (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return raw
    }

    private mutating func readFixed(_ count: Int) -> Data {
        let end = min(pos + count, data.count)
        let slice = data[pos..<end]
        pos = end
        return Data(slice)
    }
}

// MARK: - Tesla domain constants

enum TeslaDomain: Int {
    case broadcast    = 0
    case vehicleSecurity = 2
    case infotainment    = 3
}

// MARK: - Parsed session info

struct TeslaSessionInfo {
    var counter: UInt32
    var vehiclePublicKeyX963: Data  // 65-byte uncompressed point
    var epoch: Data
    var clockTime: UInt32
}

extension TeslaSessionInfo {
    /// Parse from the raw bytes of the `session_info` field (field 3) in RoutableMessage
    static func parse(from data: Data) -> TeslaSessionInfo? {
        var reader = ProtoReader(data)
        let fields = reader.readAll()

        let counterData = fields[1]?.first ?? Data([0, 0, 0, 0])
        let pubKeyData  = fields[2]?.first ?? Data()
        let epochData   = fields[3]?.first ?? Data()
        let clockData   = fields[4]?.first ?? Data([0, 0, 0, 0])

        // Decode varint counter
        let counter = decodeVarint(counterData)
        let clock   = decodeVarint(clockData)

        return TeslaSessionInfo(
            counter: UInt32(counter),
            vehiclePublicKeyX963: pubKeyData,
            epoch: epochData,
            clockTime: UInt32(clock)
        )
    }

    private static func decodeVarint(_ data: Data) -> Int {
        var result = 0
        var shift = 0
        for byte in data {
            result |= (Int(byte) & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }
}

// MARK: - Navigation command proto builder

/// Builds a car_server.Action proto for GPS navigation.
///
/// Based on Tesla's vehicle-command open-source library:
/// https://github.com/teslamotors/vehicle-command
///
/// ⚠️ NOTE: The field number for NavGPSRequest inside VehicleAction (currently set to 15)
/// should be verified against the actual car_server.proto in Tesla's vehicle-command repo.
/// If commands fail, check: pkg/protocol/protobuf/car_server.proto → VehicleAction oneof
func buildNavGPSAction(latitude: Double, longitude: Double) -> Data {
    var action = ProtoWriter()
    // Action.vehicle_action = field 1
    action.embedded(1) { vehicleAction in
        // VehicleAction.nav_gps_request = field 15
        // ⚠️ Verify this field number in car_server.proto
        vehicleAction.embedded(15) { req in
            req.double(1, value: latitude)   // NavGPSRequest.latitude
            req.double(2, value: longitude)  // NavGPSRequest.longitude
        }
    }
    return action.data
}
