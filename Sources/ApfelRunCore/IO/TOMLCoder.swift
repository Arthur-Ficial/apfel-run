import Foundation
import TOMLKit

public enum TOMLCoder {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let enc = TOMLEncoder()
        return try enc.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let dec = TOMLDecoder()
        return try dec.decode(type, from: text)
    }
}
