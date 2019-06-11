//
//  TagHandler.swift
//  NFCTest
//
//  Created by Andy Qua on 09/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import CoreNFC

enum TagError: Error {
    case noConnectedTag
    case InvalidResponse
    case D087Malformed
    case InvalidResponseChecksum
    case MissingMandatoryFields
    case CannotDecodeASN1Length
    case InvalidASN1Value
    case UnableToProtectAPDU
    case UnableToUnprotectAPDU
    case UnsupportedDataGroup
}

enum DataGroup {
    case COM
    case DG1
    case DG2
}

private let DGMap : [DataGroup: [UInt8]] = [
    .COM : [0x01,0x1E],
    .DG1 : [0x01,0x01],
    .DG2 : [0x01,0x02]
]

struct ResponseAPDU {
    var data : [UInt8]
    var sw1 : UInt8
    var sw2 : UInt8
}

class TagReader {
    var tag : NFCISO7816Tag
    var secureMessaging : SecureMessaging?

    init( tag: NFCISO7816Tag) {
        self.tag = tag
    }

    func readDataGroup( dataGroup: DataGroup, completed: @escaping ([UInt8]?, Error?)->() )  throws {
        guard let tag = DGMap[dataGroup] else { throw TagError.UnsupportedDataGroup }
        
        selectFileAndRead(tag: tag, completed:completed )
    }
    
    func getChallenge( completed: @escaping (ResponseAPDU?, Error?)->() ) {
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x84, p1Parameter: 0, p2Parameter: 0, data: Data(), expectedResponseLength: 8)
        
        send( cmd: cmd, completed: completed )
    }

    func doMutualAuthentication( cmdData : Data, completed: @escaping (ResponseAPDU?, Error?)->() ) {
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x82, p1Parameter: 0, p2Parameter: 0, data: cmdData, expectedResponseLength: 40)

        send( cmd: cmd, completed: completed )
    }
    

    func readCOM( completed: @escaping ([UInt8]?, Error?)->() ) {
        selectFileAndRead(tag: [0x01,0x1E], completed:completed )
    }
    
    func readDG1( completed: @escaping ([UInt8]?, Error?)->() ) {
        selectFileAndRead(tag: [0x01,0x02], completed:completed )
    }
    
    
    var header = [UInt8]()
    func selectFileAndRead( tag: [UInt8], completed: @escaping ([UInt8]?, Error?)->() ) {
        selectFile(tag: tag ) { [unowned self] (resp,err) in
            
            // Read first 4 bytes of header to see how big the data structure is
            let data : [UInt8] = [0x00, 0xB0, 0x00, 0x00, 0x00, 0x00,0x04]
            let cmd = NFCISO7816APDU(data:Data(data))!
            self.send( cmd: cmd ) { [unowned self] (resp,err) in
                guard let response = resp else {
                    completed( nil, err)
                    return
                }
                // Header looks like:  <tag><length of data><nextTag> e.g.60145F01 -
                // the total length is the 2nd value plus the two header 2 bytes
                // We've read 4 bytes so we now need to read the remaining bytes from offset 4
                self.header = response.data
                var leftToRead = 0
                
                let (len, o) = try! asn1Length(data: [UInt8](self.header[1..<4]))
                leftToRead = Int(len)
                let offset = o + 1
                
                log.info( "Amount of data to read - \(leftToRead)" )
                self.readBinaryData(leftToRead: leftToRead, amountRead: offset, completed: completed)

            }
        }
    }
    
    func selectFile( tag: [UInt8], completed: @escaping (ResponseAPDU?, Error?)->() ) {
        
        let data : [UInt8] = [0x00, 0xA4, 0x02, 0x0C, 0x02] + tag
        let cmd = NFCISO7816APDU(data:Data(data))!
        
        send( cmd: cmd, completed: completed )
    }

    func readBinaryData( leftToRead: Int, amountRead : Int, completed: @escaping ([UInt8]?, Error?)->() ) {
        let maxSize : UInt8 = 0xDF
        var readAmount : UInt8 = maxSize
        if leftToRead < maxSize {
            readAmount = UInt8(leftToRead)
        }
        
        let offset = intToBin(amountRead, pad:4)

        let data : [UInt8] = [0x00, 0xB0, offset[0], offset[1], 0x00, 0x00, readAmount]
        let cmd = NFCISO7816APDU(data:Data(data))!
        self.send( cmd: cmd ) { (resp,err) in
            guard let response = resp else {
                completed( nil, err)
                return
            }
            log.debug( "got resp - \(response)" )
            self.header += response.data
            
            let remaining = leftToRead - response.data.count
            log.info( "Amount of data left read - \(remaining)" )
            if remaining > 0 {
                self.readBinaryData(leftToRead: remaining, amountRead: amountRead + response.data.count, completed: completed )
            } else {
                completed( self.header, err )
            }
            
        }
    }

    
    func send( cmd: NFCISO7816APDU, completed: @escaping (ResponseAPDU?, Error?)->() ) {
        
        var toSend = cmd
        if let sm = secureMessaging {
            do {
                toSend = try sm.protect(apdu:cmd)
            } catch {
                completed( nil, TagError.UnableToProtectAPDU )
            }
            log.debug("[SM] \(toSend)" )
        }

        tag.sendCommand(apdu: toSend) { [unowned self] (data, sw1, sw2, error) in
            if error == nil {
                var rep = ResponseAPDU(data: [UInt8](data), sw1: sw1, sw2: sw2)
                
                if let sm = self.secureMessaging {
                    do {
                        rep = try sm.unprotect(rapdu:rep)
                        log.debug(String(format:"[SM] \(rep.data), sw1:0x%02x sw2:0x%02x", rep.sw1, rep.sw2) )
                    } catch {
                        completed( nil, TagError.UnableToUnprotectAPDU )
                        return
                    }
                }
                
                if rep.sw1 == 0x90 && rep.sw2 == 0x00 {
                    completed( rep, nil )
                } else {
                    log.error( "Error reading tag: sw1 - \(binToHexRep(sw1)), sw2 - \(binToHexRep(sw2))" )
                    completed( nil, TagError.InvalidResponse )
                }
            }
        }
    }
}
