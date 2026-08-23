import Foundation

/// Lenient decoding policy for guest-produced payloads.
///
/// The guest agent is the producer and serializes Go structs whose empty
/// fields disappear (`omitempty`) and whose nil slices and maps encode as
/// JSON null. The host is the consumer, so absent and null values must decode
/// as defaults instead of failing the whole payload. Identity fields (ids,
/// names, references, status strings) stay required: a payload missing them
/// is a protocol error worth surfacing loudly.
///
/// Swift property-wrapper synthesis cannot express this: a wrapper carrying
/// `init(from:)` receives a decoder that has already failed on the absent
/// key. Instead, guest payload structs declare `CodingKeys` plus a small
/// `init(from:)` built from the `decodeLenient*` helpers below.
protocol GuestLenientDefault {
    static var guestDefault: Self { get }
}

extension Bool: GuestLenientDefault { static var guestDefault: Bool { false } }
extension Int: GuestLenientDefault { static var guestDefault: Int { 0 } }
extension Int32: GuestLenientDefault { static var guestDefault: Int32 { 0 } }
extension Int64: GuestLenientDefault { static var guestDefault: Int64 { 0 } }
extension UInt: GuestLenientDefault { static var guestDefault: UInt { 0 } }
extension UInt32: GuestLenientDefault { static var guestDefault: UInt32 { 0 } }
extension UInt64: GuestLenientDefault { static var guestDefault: UInt64 { 0 } }

extension KeyedDecodingContainerProtocol {
    /// Decodes a scalar with its zero value when the key is absent or JSON
    /// null. A wrong JSON type still fails loudly.
    func decodeLenient<Value>(forKey key: Self.Key) throws -> Value
    where Value: Decodable & GuestLenientDefault {
        try decodeIfPresent(Value.self, forKey: key) ?? Value.guestDefault
    }

    /// Decodes an array as empty when the key is absent or JSON null; the
    /// guest's nil Go slices arrive as null, not missing.
    func decodeLenientArray<Element>(forKey key: Self.Key) throws -> [Element]
    where Element: Decodable {
        try decodeIfPresent([Element].self, forKey: key) ?? []
    }

    /// Decodes a dictionary as empty when the key is absent or JSON null; the
    /// guest's nil Go maps arrive as null, not missing.
    func decodeLenientMap<Key2, Value>(forKey key: Self.Key) throws -> [Key2: Value]
    where Key2: Hashable & Decodable, Value: Decodable {
        try decodeIfPresent([Key2: Value].self, forKey: key) ?? [:]
    }
}
