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

import Foundation
import NIO
import NIOConcurrencyHelpers

extension NIOJSONRPC {
    public final class TCPClient {
        public let group: MultiThreadedEventLoopGroup
        public let config: Config

        private var _state = State.idle
        private let lock = Lock()

        public init(group: MultiThreadedEventLoopGroup, config: Config = Config()) {
            self.group = group
            self.config = config
        }

        deinit {
            guard case .disconnected = self.state else {
                preconditionFailure("expected state to be disconnected")
            }
        }

        public func connect(host: String, port: Int) -> EventLoopFuture<TCPClient> {
            guard case .idle = self.state else {
                preconditionFailure("expected state to be idle")
            }

            let bootstrap = ClientBootstrap(group: self.group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelInitializer { channel in
                    return channel.pipeline.addTimeoutHandlers(self.config.timeout)
                        .flatMap { _ in
                            channel.pipeline.addFramingHandlers(framing: self.config.framing)
                        }.flatMap {
                            channel.pipeline.addHandlers([
                                Framing.CodableCodec<JSONResponse, JSONRequest>(),
                                Handler(),
                            ])
                        }
                }

            self.state = .connecting("\(host):\(port)")
            return bootstrap.connect(host: host, port: port).flatMap { channel in
                self.state = .connected(channel)
                return channel.eventLoop.makeSucceededFuture(self)
            }
        }

        public func disconnect() -> EventLoopFuture<Void> {
            guard case .connected(let channel) = self.state else {
                return self.group.next().makeFailedFuture(ClientError.notReady)
            }
            self.state = .disconnecting
            channel.closeFuture.whenComplete { _ in
                self.state = .disconnected
            }
            channel.close(promise: nil)
            return channel.closeFuture
        }

        public func call(method: String, params: RPCObject) -> EventLoopFuture<ClientResult> {
            guard case .connected(let channel) = self.state else {
                return self.group.next().makeFailedFuture(ClientError.notReady)
            }
            let promise: EventLoopPromise<JSONResponse> = channel.eventLoop.makePromise()
            let request = JSONRequest(id: NSUUID().uuidString, method: method, params: JSONObject(params))
            let requestWrapper = JSONRequestWrapper(request: request, promise: promise)
            let future = channel.writeAndFlush(requestWrapper)
            future.cascadeFailure(to: promise) // if write fails
            return future.flatMap {
                promise.futureResult.map { Result($0) }
            }
        }

        private var state: State {
            get {
                return self.lock.withLock { _state }
            }
            set {
                self.lock.withLock { _state = newValue }
            }
        }

        private enum State {
            case idle
            case connecting(String)
            case connected(Channel)
            case disconnecting
            case disconnected
        }

        public typealias ClientResult = Result<RPCObject, Error>

        public struct Error: Swift.Error, Equatable {
            public let kind: Kind
            public let description: String

            init(kind: Kind, description: String) {
                self.kind = kind
                self.description = description
            }

            internal init(_ error: JSONError) {
                self.init(kind: JSONErrorCode(rawValue: error.code).map { Kind($0) } ?? .otherServerError, description: error.message)
            }

            public enum Kind {
                case invalidMethod
                case invalidParams
                case invalidRequest
                case invalidServerResponse
                case otherServerError

                internal init(_ code: JSONErrorCode) {
                    switch code {
                    case .invalidRequest:
                        self = .invalidRequest
                    case .methodNotFound:
                        self = .invalidMethod
                    case .invalidParams:
                        self = .invalidParams
                    case .parseError:
                        self = .invalidServerResponse
                    case .internalError, .other:
                        self = .otherServerError
                    }
                }
            }
        }

        public struct Config {
            public let timeout: TimeAmount
            public let framing: Framing.Kind

            public init(timeout: TimeAmount = TimeAmount.seconds(5), framing: Framing.Kind = .newline) {
                self.timeout = timeout
                self.framing = framing
            }
        }
    }

    private class Handler: ChannelInboundHandler, ChannelOutboundHandler {
        public typealias InboundIn = JSONResponse
        public typealias OutboundIn = JSONRequestWrapper
        public typealias OutboundOut = JSONRequest

        private var queue = CircularBuffer<(String, EventLoopPromise<JSONResponse>)>()

        // outbound
        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let requestWrapper = self.unwrapOutboundIn(data)
            queue.append((requestWrapper.request.id, requestWrapper.promise))
            context.write(wrapOutboundOut(requestWrapper.request), promise: promise)
        }

        // inbound
        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if self.queue.isEmpty {
                return context.fireChannelRead(data) // already complete
            }
            let promise = queue.removeFirst().1
            let response = unwrapInboundIn(data)
            promise.succeed(response)
        }

        public func errorCaught(context: ChannelHandlerContext, error: Error) {
            if let remoteAddress = context.remoteAddress {
                print("server", remoteAddress, "error", error)
            }
            if self.queue.isEmpty {
                return context.fireErrorCaught(error) // already complete
            }
            let item = queue.removeFirst()
            let requestId = item.0
            let promise = item.1
            switch error {
            case NIOJSONRPC.Framing.CodecError.requestTooLarge, NIOJSONRPC.Framing.CodecError.badFraming, NIOJSONRPC.Framing.CodecError.badJSON:
                promise.succeed(JSONResponse(id: requestId, errorCode: .parseError, error: error))
            default:
                promise.fail(error)
                // close the connection
                context.close(promise: nil)
            }
        }

        public func channelActive(context: ChannelHandlerContext) {
            if let remoteAddress = context.remoteAddress {
                print("server", remoteAddress, "connected")
            }
        }

        public func channelInactive(context: ChannelHandlerContext) {
            if let remoteAddress = context.remoteAddress {
                print("server ", remoteAddress, "disconnected")
            }
            if !self.queue.isEmpty {
                self.errorCaught(context: context, error: ClientError.connectionResetByPeer)
            }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if (event as? IdleStateHandler.IdleStateEvent) == .read {
                self.errorCaught(context: context, error: ClientError.timeout)
            } else {
                context.fireUserInboundEventTriggered(event)
            }
        }
    }

    private struct JSONRequestWrapper {
        let request: JSONRequest
        let promise: EventLoopPromise<JSONResponse>
    }

    internal enum ClientError: Error {
        case notReady
        case cantBind
        case timeout
        case connectionResetByPeer
    }
}

internal extension Result where Success == NIOJSONRPC.RPCObject, Failure == NIOJSONRPC.TCPClient.Error {
    init(_ response: NIOJSONRPC.JSONResponse) {
        if let result = response.result {
            self = .success(NIOJSONRPC.RPCObject(result))
        } else if let error = response.error {
            self = .failure(NIOJSONRPC.TCPClient.Error(error))
        } else {
            self = .failure(NIOJSONRPC.TCPClient.Error(kind: .invalidServerResponse, description: "invalid server response"))
        }
    }
}
