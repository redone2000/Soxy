//
//  SOCKSServer.swift
//  S5
//
//  Created by Luo Sheng on 15/10/1.
//  Copyright © 2015年 Pop Tap. All rights reserved.
//

import Foundation
import CocoaAsyncSocket

class SOCKSServer: GCDAsyncSocketDelegate {
    
    private let socket: GCDAsyncSocket
    private var connections: [SOCKSConnection]
    
    init(port: UInt16) throws {
        connections = []
        socket = GCDAsyncSocket(delegate: nil, delegateQueue: dispatch_get_global_queue(0, 0))
        socket.delegate = self
        try socket.acceptOnPort(port)
    }
    
    deinit {
        self.disconnectAll()
    }
    
    func disconnectAll() {
        for connection in connections {
            connection.disconnect()
        }
    }
    
    // MARK: - GCDAsyncSocketDelegate
    
    @objc func socket(sock: GCDAsyncSocket!, didAcceptNewSocket newSocket: GCDAsyncSocket!) {
        let connection = SOCKSConnection(socket: newSocket)
        connections.append(connection)
    }
}

// MARK: -

class SOCKSConnection: GCDAsyncSocketDelegate {
    
    enum SocketTag: UInt8 {
        case
/* 
 +----+----------+----------+
 |VER | NMETHODS | METHODS  |
 +----+----------+----------+
 | 1  |    1     | 1 to 255 |
 +----+----------+----------+
*/
        HandshakeVersion = 5,
        HandshakeNumberOfAuthenticationMethods,
        HandshakeAuthenticationMethod,
        
/*
 +----+-----+-------+------+----------+----------+
 |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
 +----+-----+-------+------+----------+----------+
 | 1  |  1  | X'00' |  1   | Variable |    2     |
 +----+-----+-------+------+----------+----------+

 o  VER    protocol version: X'05'
 o  CMD
 o  CONNECT X'01'
 o  BIND X'02'
 o  UDP ASSOCIATE X'03'
 o  RSV    RESERVED
 o  ATYP   address type of following address
 o  IP V4 address: X'01'
 o  DOMAINNAME: X'03'
 o  IP V6 address: X'04'
 o  DST.ADDR       desired destination address
 o  DST.PORT desired destination port in network octet order
*/
        RequestHeaderFragment,
        RequestAddressType,
        RequestIPv4Address,
        RequestIPv6Address,
        RequestDomainNameLength,
        RequestDomainName,
        RequestPort
        
        func dataLength() -> Int {
            switch self {
                case .HandshakeVersion,
                .HandshakeNumberOfAuthenticationMethods:
                return 1
            default:
                return 0
            }
        }
    }
    
/*
o  X'00' NO AUTHENTICATION REQUIRED
o  X'01' GSSAPI
o  X'02' USERNAME/PASSWORD
o  X'03' to X'7F' IANA ASSIGNED
o  X'80' to X'FE' RESERVED FOR PRIVATE METHODS
o  X'FF' NO ACCEPTABLE METHODS
*/
    enum AuthenticationMethod: UInt8 {
        case
        None = 0x00,
        GSSAPI,
        UsernamePassword
    }
    
    enum SocketError: ErrorType {
        case InvalidSOCKSVersion
        case UnableToRetrieveNumberOfAuthenticationMethods
        case SupportedAuthenticationMethodNotFound
        case WrongNumberOfAuthenticationMethods
    }
    
    private let clientSocket: GCDAsyncSocket
    private var numberOfAuthenticationMethods = 0
    
    init(socket: GCDAsyncSocket) {
        clientSocket = socket
        let queue = dispatch_queue_create("net.luosheng.SOCKSConnection.DelegateQueue", DISPATCH_QUEUE_SERIAL)
        clientSocket.setDelegate(self, delegateQueue: queue)
        self.beginHandshake()
    }
    
    func disconnect() {
        clientSocket.disconnect()
    }
    
    // MARK: - Private methods
    
    private func beginHandshake() {
        clientSocket.readData(.HandshakeVersion)
    }
    
    private func readSOCKSVersion(data: NSData) throws {
        if (data.length == SocketTag.HandshakeVersion.dataLength()) {
            var version: UInt8 = 0
            data.getBytes(&version, length: data.length)
            if (version == SocketTag.HandshakeVersion.rawValue) {
                clientSocket.readData(.HandshakeNumberOfAuthenticationMethods)
                return
            }
        }
        throw SocketError.InvalidSOCKSVersion
    }
    
    private func readNumberOfAuthenticationMethods(data: NSData) throws {
        if (data.length == SocketTag.HandshakeNumberOfAuthenticationMethods.dataLength()) {
            data.getBytes(&numberOfAuthenticationMethods, length: data.length)
            clientSocket.readDataToLength(UInt(numberOfAuthenticationMethods), withTimeout: -1, tag: Int(SocketTag.HandshakeAuthenticationMethod.rawValue))
            return
        }
        throw SocketError.UnableToRetrieveNumberOfAuthenticationMethods
    }
    
    private func readAuthenticationMethods(data: NSData) throws {
        var authMethods: [UInt8] = Array<UInt8>(count: numberOfAuthenticationMethods, repeatedValue: 0)
        if (data.length == numberOfAuthenticationMethods) {
            data.getBytes(&authMethods, length: numberOfAuthenticationMethods)
            
            let methodSupported = authMethods.contains(AuthenticationMethod.None.rawValue)
            if (methodSupported) {
                /*
                +----+--------+
                |VER | METHOD |
                +----+--------+
                | 1  |   1    |
                +----+--------+
                */
                let methodSelectionBytes: [UInt8] = [SocketTag.HandshakeVersion.rawValue, AuthenticationMethod.None.rawValue];
                let methodSelectionData = NSData(bytes: methodSelectionBytes, length: methodSelectionBytes.count)
                clientSocket.writeData(methodSelectionData, withTimeout: -1, tag: 0)
            } else {
                throw SocketError.SupportedAuthenticationMethodNotFound
            }
        } else {
            throw SocketError.WrongNumberOfAuthenticationMethods
        }
    }
    
    // MARK: - GCDAsyncSocketDelegate

    @objc func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
        print("data: \(data)")
        guard let socketTag = SocketTag(rawValue: UInt8(tag)) else {
            return
        }
        switch socketTag {
        case .HandshakeVersion:
            try! self.readSOCKSVersion(data)
            break
        case .HandshakeNumberOfAuthenticationMethods:
            try! self.readNumberOfAuthenticationMethods(data)
            break
        case .HandshakeAuthenticationMethod:
            try! self.readAuthenticationMethods(data)
            break
        default:
            break
        }
    }
}

// MARK: -

extension GCDAsyncSocket {
    func readData(tag: SOCKSConnection.SocketTag) {
        return self.readDataToLength(UInt(tag.dataLength()), withTimeout: -1, tag: Int(tag.rawValue))
    }
}