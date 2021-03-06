public struct InputByteStream {
    private(set) var offset: Int
    let bytes: ArraySlice<UInt8>
    var isEOF: Bool {
        offset >= bytes.endIndex
    }

    public init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    public init(bytes: [UInt8]) {
        self.init(bytes: bytes[...])
    }

    @discardableResult
    mutating func read(_ length: Int) -> ArraySlice<UInt8> {
        let result = bytes[offset ..< offset + length]
        offset += length
        return result
    }

    mutating func readUInt8() -> UInt8 {
        let byte = read(1)
        return byte[byte.startIndex]
    }

    mutating func readVarUInt32() -> UInt32 {
        let (value, advanced) = decodeULEB128(bytes[offset...], UInt32.self)
        offset += advanced
        return value
    }

    mutating func consumeULEB128<T>(_: T.Type) where T: UnsignedInteger, T: FixedWidthInteger {
        let (_, advanced) = decodeULEB128(bytes[offset...], T.self)
        offset += advanced
    }

    enum Error: Swift.Error {
        case invalidValueType(UInt8)
        case expectConstOpcode(UInt8)
        case expectI32Const(ConstOpcode)
        case unexpectedOpcode(UInt8)
        case expectEnd
    }

    /// https://webassembly.github.io/spec/core/binary/types.html#result-types
    mutating func readResultTypes() throws -> (types: [ValueType], hasI64: Bool) {
        let count = readVarUInt32()
        var resultTypes: [ValueType] = []
        var hasI64: Bool = false
        for _ in 0 ..< count {
            let rawType = readUInt8()
            guard let type = ValueType(rawValue: rawType) else {
                throw Error.invalidValueType(rawType)
            }
            hasI64 = hasI64 || (type == ValueType.i64)
            resultTypes.append(type)
        }
        return (resultTypes, hasI64)
    }

    typealias Consumer = (ArraySlice<UInt8>) throws -> Void

    mutating func consumeString(consumer: Consumer? = nil) rethrows {
        let start = offset
        let length = Int(readVarUInt32())
        offset += length
        try consumer?(bytes[start ..< offset])
    }

    /// https://webassembly.github.io/spec/core/binary/types.html#table-types
    mutating func consumeTable(consumer: Consumer? = nil) rethrows {
        let start = offset
        _ = readUInt8() // element type
        let hasMax = readUInt8() != 0
        _ = readVarUInt32() // initial
        if hasMax {
            _ = readVarUInt32() // max
        }
        try consumer?(bytes[start ..< offset])
    }

    /// https://webassembly.github.io/spec/core/binary/types.html#memory-types
    mutating func consumeMemory(consumer: Consumer? = nil) rethrows {
        let start = offset
        let flags = readUInt8()
        let hasMax = (flags & LIMITS_HAS_MAX_FLAG) != 0
        _ = readVarUInt32() // initial
        if hasMax {
            _ = readVarUInt32() // max
        }
        try consumer?(bytes[start ..< offset])
    }

    /// https://webassembly.github.io/spec/core/binary/types.html#global-types
    mutating func consumeGlobalHeader(consumer: Consumer? = nil) rethrows {
        let start = offset
        _ = readUInt8() // value type
        _ = readUInt8() // mutable
        try consumer?(bytes[start ..< offset])
    }

    mutating func consumeI32InitExpr(consumer: Consumer? = nil) throws {
        let start = offset
        let code = readUInt8()
        guard let constOp = ConstOpcode(rawValue: code) else {
            throw Error.expectConstOpcode(code)
        }
        switch constOp {
        case .i32Const:
            _ = readVarUInt32()
        case .f32Const, .f64Const, .i64Const:
            throw Error.expectI32Const(constOp)
        }
        let opcode = try readOpcode()
        guard opcode == .end else {
            throw Error.expectEnd
        }
        try consumer?(bytes[start ..< offset])
    }

    /// https://webassembly.github.io/spec/core/binary/modules.html#binary-local
    mutating func consumeLocals(consumer: Consumer? = nil) throws {
        let start = offset
        let count = readVarUInt32()
        for _ in 0..<count {
            _ = readVarUInt32() // n
            _ = readUInt8() // value type
        }
        try consumer?(bytes[start ..< offset])
    }

    mutating func consumeBlockType() {
        let head = bytes[offset]
        let length: Int
        switch head {
        case 0x40:
            length = 1
        case _ where ValueType(rawValue: head) != nil:
            length = 1
        default:
            (_, length) = decodeSLEB128(bytes, Int64.self)
        }
        offset += length
    }

    mutating func consumeBrTable() {
        let count = readVarUInt32()
        for _ in 0 ..< count {
            _ = readVarUInt32()
        }
        _ = readVarUInt32()
    }

    mutating func consumeMemoryArg() {
        _ = readVarUInt32()
        _ = readVarUInt32()
    }

    mutating func readOpcode() throws -> Opcode {
        let start = offset
        let rawCode = readUInt8()
        var code: Opcode?
        switch rawCode {
        // https://webassembly.github.io/spec/core/binary/instructions.html#control-instructions
        case 0x00, 0x01: break
        case 0x02, 0x03, 0x04: consumeBlockType()
        case 0x05: break
        case 0x0B: code = .end
        case 0x0C, 0x0D: _ = readVarUInt32() // label index
        case 0x0E: consumeBrTable()
        case 0x0F: break
        case 0x10:
            let funcIndex = readVarUInt32()
            code = .call(funcIndex)
        case 0x11:
            _ = readVarUInt32() // type index
            _ = readUInt8() // 0x00

        // https://webassembly.github.io/spec/core/binary/instructions.html#parametric-instructions
        case 0x1A, 0x1B: break

        // https://webassembly.github.io/spec/core/binary/instructions.html#variable-instructions
        case 0x20: code = .localGet(readVarUInt32())
        case 0x21 ... 0x24: _ = readVarUInt32() // local index

        // https://webassembly.github.io/spec/core/binary/instructions.html#memory-instructions
        case 0x28 ... 0x3E: consumeMemoryArg()
        case 0x3F, 0x40: _ = readUInt8() // 0x00

        // https://webassembly.github.io/spec/core/binary/instructions.html#numeric-instructions
        case 0x41: consumeULEB128(UInt32.self)
        case 0x42: consumeULEB128(UInt64.self)
        case 0x43: _ = read(4)
        case 0x44: _ = read(8)
        case 0x45 ... 0xA6: break
        case 0xA7: code = .i32WrapI64
        case 0xA8 ... 0xC4: break
        case 0xFC: _ = readVarUInt32()
        default:
            throw Error.unexpectedOpcode(rawCode)
        }
        if let code = code {
            return code
        } else {
            return .unknown(Array(bytes[start ..< offset]))
        }
    }
}
