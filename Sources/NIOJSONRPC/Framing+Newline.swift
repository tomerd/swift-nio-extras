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

extension NIOJSONRPC.Framing {
    /// `BruteForceCodec` is responsible for parsing JSON-RPC wire protocol with a \r\n delimieter.
    /// The codec will aggregate bytes till the delimiter is found, and add delimiter at end.
    public final class NewlineCodec: ByteToMessageDecoder, MessageToByteEncoder {
        public typealias InboundIn = ByteBuffer
        public typealias InboundOut = ByteBuffer
        public typealias OutboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private let maxPayloadSize: Int64
        private let delimiter1 = UInt8(ascii: "\r")
        private let delimiter2 = UInt8(ascii: "\n")

        private var lastIndex = 0

        /// initialize the Codec with max paylaod size
        /// - parameters:
        ///   - maxPayloadSize: The max number of bytes to aggregate in memory.
        init(maxPayloadSize: Int64 = 1_000_000) {
            self.maxPayloadSize = maxPayloadSize
        }

        // `decode` will be invoked whenever there is  inbound data available (or if we return `.continue`).
        public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            guard buffer.readableBytes < self.maxPayloadSize else {
                throw CodecError.requestTooLarge(buffer.readableBytes)
            }
            guard buffer.readableBytes >= 3 else {
                return .needMoreData
            }

            // try to find a payload by looking for a \r\n delimiter
            let readableBytesView = buffer.readableBytesView.dropFirst(self.lastIndex)
            guard let index = readableBytesView.firstIndex(of: delimiter2) else {
                self.lastIndex = buffer.readableBytes
                return .needMoreData
            }
            guard readableBytesView[index - 1] == delimiter1 else {
                return .needMoreData
            }

            // slice the buffer
            let length = index - buffer.readerIndex - 1
            let slice = buffer.readSlice(length: length)!
            buffer.moveReaderIndex(forwardBy: 2)
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
            // original data
            out.writeBuffer(&payload)
            // add delimiter
            out.writeBytes([delimiter1, delimiter2])
        }
    }

}
