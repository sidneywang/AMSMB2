//
//  MSRPC.swift
//  AMSMB2
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//

import Foundation

class MSRPC {
    static func parseNetShareEnumAllLevel1(data: Data, enumerateSpecial: Bool) throws -> [(name: String, comment: String)] {
        var shares = [(name: String, comment: String)]()
        
        /*
         Data Layout :
         
         struct _SHARE_INFO_1 {
         uint32 netname;  // pointer to NameContainer
         uint32 type;
         uint32 remark;   // pointer to NameContainer
         }
         
         struct NameContainer {
         uint32 maxCount;
         uint32 offset;
         uint32 actualCount;
         char* name; // null-terminated utf16le with (actualCount - 1) characters
         }
         
         struct _SHARE_INFO_1 {
         SHARE_INFO_1_CONTAINER[count] referantlist;
         NameContainer[count] nameslist;
         }
         */
        
        // First 48 bytes are header, _SHARE_INFO_1 is 12 bytes and "type" starts from 4th byte
        func typeOffset(_ i: Int) -> Int {
            return 48 + i * 12 + 4
        }
        
        // Count of shares to be enumerated, [44-47]
        guard let count_32: UInt32 = data.scanValue(start: 44) else {
            throw POSIXError(.EBADMSG)
        }
        let count = Int(count_32)
        
        // start of nameString structs header size + (_SHARE_INFO_1 * count)
        var offset = 48 + count * 12
        for i in 0..<count {
            // Type of current share, see https://msdn.microsoft.com/en-us/library/windows/desktop/cc462916(v=vs.85).aspx
            let type: UInt32 = data.scanValue(start: typeOffset(i)) ?? 0xffffffff
            
            // Parse name part
            guard let nameActualCount_32: UInt32 = data.scanValue(start: offset + 8) else {
                throw POSIXError(.EBADRPC)
            }
            let nameActualCount = Int(nameActualCount_32)
            
            offset += 12
            if offset + nameActualCount * 2 > data.count {
                throw POSIXError(.EBADRPC)
            }
            
            // Getting utf16le data, omitting nul char
            let nameStringData = data.dropFirst(offset).prefix((nameActualCount - 1) * 2)
            let nameString = nameActualCount > 1 ? (String(data: nameStringData, encoding: .utf16LittleEndian) ?? "") : ""
            
            offset += nameActualCount * 2
            if nameActualCount % 2 == 1 {
                // if name length is odd, there is an extra nul char pad for alignment.
                offset += 2
            }
            
            // Parse comment part
            guard let commentActualCount_32: UInt32 = data.scanValue(start: offset + 8) else {
                throw POSIXError(.EBADRPC)
            }
            let commentActualCount = Int(commentActualCount_32)
            
            offset += 12
            if offset + nameActualCount * 2 > data.count {
                throw POSIXError(.EBADRPC)
            }
            
            // Getting utf16le data, omitting nul char
            let commentStringData = data.dropFirst(offset).prefix((commentActualCount - 1) * 2)
            let commentString = commentActualCount > 1 ? (String(data: commentStringData, encoding: .utf16LittleEndian) ?? "") : ""
            
            offset += commentActualCount * 2
            
            if commentActualCount % 2 == 1 {
                // if name length is odd, there is an extra nul char pad for alignment.
                offset += 2
            }
            
            if type == 0 || (enumerateSpecial && type & 0x00ffffff == 0) {
                // type is STYPE_DISKTREE
                shares.append((name: nameString, comment: commentString))
            }
            
            if offset > data.count {
                break
            }
        }
        
        return shares
    }
    
    enum DCECommand: UInt8 {
        case request = 0x00
        case bind = 0x0b
    }
    
    private static func dceHeader(command: DCECommand, callId: UInt32) -> Data {
        var headerData = Data()
        // Version major, version minor, packet type = 'bind', packet flags
        headerData.append(contentsOf: [0x05, 0, command.rawValue, 0x03])
        // Representation = little endian/ASCII.
        headerData.append(uint32: 0x10)
        // data length
        headerData.append(uint16: 0)
        // Auth len
        headerData.append(uint16: 0)
        // Call ID
        headerData.append(uint32: callId)
        return headerData
    }
    
    private static func setDCELength(_ data: inout Data) {
        let count = data.count
        data[8] = UInt8(count & 0xff)
        data[9] = UInt8((count >> 8) & 0xff)
    }
    
    static func srvsvcBindData() -> Data {
        var reqData = dceHeader(command: .bind, callId: 1)
        // Max Xmit size
        reqData.append(uint16: UInt16.max)
        // Max Recv size
        reqData.append(uint16: UInt16.max)
        // Assoc group
        reqData.append(uint32: 0)
        // Num Ctx Item
        reqData.append(uint32: 1)
        // ContextID
        reqData.append(uint16: 0)
        // Num Trans Items
        reqData.append(uint16: 1)
        // SRVSVC UUID
        let srvsvcUuid = UUID(uuidString: "4b324fc8-1670-01d3-1278-5a47bf6ee188")!
        reqData.append(guid: srvsvcUuid)
        // SRVSVC Version = 3.0
        reqData.append(uint16: 3)
        reqData.append(uint16: 0)
        // NDR UUID
        let ndruuid = UUID(uuidString: "8a885d04-1ceb-11c9-9fe8-08002b104860")!
        reqData.append(guid: ndruuid)
        // NDR version = 2.0
        reqData.append(uint16: 2)
        reqData.append(uint16: 0)
        
        setDCELength(&reqData)
        return reqData
    }
    
    static func requestNetShareEnumAll(server serverName: String, level: UInt32 = 1) -> Data {
        let serverNameData = serverName.data(using: .utf16LittleEndian)!
        let serverNameLen = UInt32(serverName.count + 1)
        
        var reqData = dceHeader(command: .request, callId: 0)
        // Alloc hint
        reqData.append(uint32: 72)
        // Context ID
        reqData.append(uint16: 0)
        // OpNum = NetShareEnumAll
        reqData.append(uint16: 0x0f)
        
        // Pointer to server UNC
        // Referent ID
        reqData.append(uint32: 1)
        // Max count
        reqData.append(uint32: serverNameLen)
        // Offset
        reqData.append(uint32: 0)
        // Max count
        reqData.append(uint32: serverNameLen)
        
        // The server name
        reqData.append(serverNameData)
        reqData.append(uint16: 0) // null termination
        if serverNameLen % 2 == 1 {
            reqData.append(uint16: 0) // padding
        }
        
        // Level 1
        reqData.append(uint32: level)
        // Ctr
        reqData.append(uint32: 1)
        // Referent ID
        reqData.append(uint32: 1)
        // Count/Null Pointer to NetShareInfo1
        reqData.append(uint32: 0)
        // Null Pointer to NetShareInfo1
        reqData.append(uint32: 0)
        // Max Buffer
        reqData.append(uint32: 0xffffffff)
        // Resume Referent ID
        reqData.append(uint32: 1)
        // Resume
        reqData.append(uint32: 0)
        
        setDCELength(&reqData)
        return reqData
    }
}