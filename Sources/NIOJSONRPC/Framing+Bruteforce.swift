//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOFoundationCompat
import Foundation

extension NIOJSONRPC.Framing {
    /// `BruteForceCodec` is responsible for parsing JSON-RPC wire protocol,
    // when no delimeter is provided, brute force try to decode the json.
    public final class BruteForceCodec<T>: ByteToMessageDecoder, MessageToByteEncoder where T: Decodable {
        public typealias InboundIn = ByteBuffer
        public typealias InboundOut = ByteBuffer
        public typealias OutboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private let maxPayloadSize: Int64
        private let last = UInt8(ascii: "}")

        private var lastIndex = 0

        /// initialize the Codec with max paylaod size
        /// - parameters:
        ///   - maxPayloadSize: The max number of bytes to aggregate in memory.
        init(maxPayloadSize: Int64 = 1_000_000) {
            self.maxPayloadSize = maxPayloadSize
        }

        // `decode` will be invoked whenever there is inbound data available (or if we return `.continue`).
        public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            guard buffer.readableBytes < self.maxPayloadSize else {
                throw CodecError.requestTooLarge(buffer.readableBytes)
            }

            // try to find a payload by looking for a json payload, first rough cut is looking for a trailing }
            let readableBytesView = buffer.readableBytesView.dropFirst(self.lastIndex)
            guard let _ = readableBytesView.firstIndex(of: last) else {
                self.lastIndex = buffer.readableBytes
                return .needMoreData
            }

            // try to confirm its a json payload by brute force decoding
            let length = buffer.readableBytes
            let data = buffer.getData(at: buffer.readerIndex, length: length)!
            do {
                _ = try JSONDecoder().decode(T.self, from: data)
            } catch is DecodingError {
                self.lastIndex = buffer.readableBytes
                return .needMoreData
            }

            // slice the buffer
            let slice = buffer.readSlice(length: length)!
            self.lastIndex = 0
            // call next handler
            context.fireChannelRead(wrapInboundOut(slice))
            return .continue
        }

        /// Invoked when the `Channel` is being brough down.
        public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
            while try self.decode(context: context, buffer: &buffer) == .continue {}
            if buffer.readableBytes > buffer.readerIndex {
                throw CodecError.badFraming
            }
            return .needMoreData
        }

        // `encode` will be invoked whenever there is outbout data available.
        public func encode(data: OutboundIn, out: inout ByteBuffer) throws {
            var payload = data
            out.writeBuffer(&payload)
        }
    }

    
}
