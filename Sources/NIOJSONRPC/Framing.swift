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
import Foundation

extension NIOJSONRPC {
    public enum Framing {
        /// A `CodecError` is sent through the pipeline if anything went wrong.
        public enum CodecError: Error, Equatable {
            /// The request was larger than the max set
            case requestTooLarge(Int)

            /// Unexpected framing problem
            case badFraming

            /// JSON encoding or decoding problem
            case badJSON(String)
        }

        /// The kind of JSON-RPC framing to use
        public enum Kind: CaseIterable {
            case contentLengthHeader
            case newline
            case bruteForce
        }

        /// `HalfCloseOnTimeout` is responsible for sending timeout events to help recognize partial frames.
        internal final class HalfCloseOnTimeout: ChannelInboundHandler {
            typealias InboundIn = Any

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if event is IdleStateHandler.IdleStateEvent {
                    // this will trigger ByteToMessageDecoder::decodeLast which is required to
                    // recognize partial frames
                    context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                }
                context.fireUserInboundEventTriggered(event)
            }
        }

        /// `CodableCodec` is responsible for translating bytes to `Codable` and back.
        /// The codec is useful in JSON-RPC processing pipelines.
        internal final class CodableCodec<In, Out>: ChannelInboundHandler, ChannelOutboundHandler where In: Decodable, Out: Encodable {
            public typealias InboundIn = ByteBuffer
            public typealias InboundOut = In
            public typealias OutboundIn = Out
            public typealias OutboundOut = ByteBuffer

            private let decoder = JSONDecoder()
            private let encoder = JSONEncoder()

            // inbound
            public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                let data = buffer.readData(length: buffer.readableBytes)!
                do {
                    let decodable = try self.decoder.decode(In.self, from: data)
                    // call next handler
                    context.fireChannelRead(wrapInboundOut(decodable))
                } catch let error as DecodingError {
                    context.fireErrorCaught(CodecError.badJSON("\(error)"))
                } catch {
                    context.fireErrorCaught(error)
                }
            }

            // outbound
            public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                do {
                    let encodable = self.unwrapOutboundIn(data)
                    let data = try encoder.encode(encodable)
                    var buffer = context.channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    context.write(wrapOutboundOut(buffer), promise: promise)
                } catch let error as EncodingError {
                    promise?.fail(CodecError.badJSON("\(error)"))
                } catch {
                    promise?.fail(error)
                }
            }
        }
    }
}

internal extension ChannelPipeline {
    func addTimeoutHandlers(_ timeout: TimeAmount) -> EventLoopFuture<Void> {
        return self.addHandlers([IdleStateHandler(readTimeout: timeout), NIOJSONRPC.Framing.HalfCloseOnTimeout()])
    }
}

internal extension ChannelPipeline {
    func addFramingHandlers(framing: NIOJSONRPC.Framing.Kind) -> EventLoopFuture<Void> {
        switch framing {
        case .contentLengthHeader:
            return self.addHandlers([ByteToMessageHandler(NIOJSONRPC.Framing.ContentLengthHeaderFrameDecoder()),
                                     NIOJSONRPC.Framing.ContentLengthHeaderFrameEncoder()])
        case .newline:
            let framingHandler = NIOJSONRPC.Framing.NewlineCodec()
            return self.addHandlers([ByteToMessageHandler(framingHandler),
                                     MessageToByteHandler(framingHandler)])
        case .bruteForce:
            let framingHandler = NIOJSONRPC.Framing.BruteForceCodec<NIOJSONRPC.JSONResponse>()
            return self.addHandlers([ByteToMessageHandler(framingHandler),
                                     MessageToByteHandler(framingHandler)])

        }
    }
}
