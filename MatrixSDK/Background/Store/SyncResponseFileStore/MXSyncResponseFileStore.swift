// 
// Copyright 2020 The Matrix.org Foundation C.I.C
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

@objcMembers
/// Sync response storage in a file implementation.
public class MXSyncResponseFileStore: NSObject {
    
    private enum Constants {
        static let folderName = "SyncResponse"
        static let fileName = "syncResponse"
        static let fileEncoding: String.Encoding = .utf8
        static let fileOperationQueue: DispatchQueue = DispatchQueue(label: "MXSyncResponseFileStoreQueue")
    }
    private var filePath: URL!
    private var credentials: MXCredentials!
    
    private func setupFilePath() {
        guard let userId = credentials.userId else {
            fatalError("Credentials must provide a user identifier")
        }
        var cachePath: URL!
        
        if let appGroupIdentifier = MXSDKOptions.sharedInstance().applicationGroupIdentifier {
            cachePath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        } else {
            cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
        
        filePath = cachePath
            .appendingPathComponent(Constants.folderName)
            .appendingPathComponent(userId)
            .appendingPathComponent(Constants.fileName)
        
        Constants.fileOperationQueue.async {
            try? FileManager.default.createDirectory(at: self.filePath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        }
    }
    
    private func readSyncResponse() -> MXSyncResponse? {
        guard let filePath = filePath else {
            return nil
        }
        var fileContents: String?
        
        Constants.fileOperationQueue.sync {
            fileContents = try? String(contentsOf: filePath,
                                       encoding: Constants.fileEncoding)
        }
        guard let jsonString = fileContents else {
            return nil
        }
        guard let json = MXTools.deserialiseJSONString(jsonString) as? [AnyHashable: Any] else {
            return nil
        }
        return MXSyncResponse(fromJSON: json)
    }
    
    private func saveSyncResponse(_ syncResponse: MXSyncResponse?) {
        guard let filePath = filePath else {
            return
        }
        
        guard let syncResponse = syncResponse else {
            try? FileManager.default.removeItem(at: filePath)
            return
        }
        Constants.fileOperationQueue.async {
            try? syncResponse.jsonString()?.write(to: self.filePath,
                                                  atomically: true,
                                                  encoding: Constants.fileEncoding)
        }
    }
    
}

//  MARK: - MXSyncResponseStore

extension MXSyncResponseFileStore: MXSyncResponseStore {
    
    public func open(withCredentials credentials: MXCredentials) {
        self.credentials = credentials
        self.setupFilePath()
    }
    
    public var syncResponse: MXSyncResponse? {
        return readSyncResponse()
    }
    
    public func event(withEventId eventId: String, inRoom roomId: String) -> MXEvent? {
        guard let response = syncResponse else {
            return nil
        }
        
        var allEvents: [MXEvent] = []
        if let joinedRoomSync = response.rooms.join[roomId] {
            allEvents.appendIfNotNil(contentsOf: joinedRoomSync.state?.events)
            allEvents.appendIfNotNil(contentsOf: joinedRoomSync.timeline?.events)
            allEvents.appendIfNotNil(contentsOf: joinedRoomSync.accountData?.events)
        }
        if let invitedRoomSync = response.rooms.invite[roomId] {
            allEvents.appendIfNotNil(contentsOf: invitedRoomSync.inviteState?.events)
        }
        if let leftRoomSync = response.rooms.leave[roomId] {
            allEvents.appendIfNotNil(contentsOf: leftRoomSync.state?.events)
            allEvents.appendIfNotNil(contentsOf: leftRoomSync.timeline?.events)
            allEvents.appendIfNotNil(contentsOf: leftRoomSync.accountData?.events)
        }
        
        let result = allEvents.first(where: { eventId == $0.eventId })
        result?.roomId = roomId
        return result
    }
    
    public func roomSummary(forRoomId roomId: String) -> MXRoomSummary? {
        guard let response = syncResponse else {
            return nil
        }
        if let invitedRoomSync = response.rooms.invite[roomId],
            let stateEvents = invitedRoomSync.inviteState?.events {
            guard let summary = MXRoomSummary(roomId: roomId, andMatrixSession: nil) else {
                return nil
            }
            for event in stateEvents {
                switch event.eventType {
                case .roomName:
                    summary.displayname = event.content["name"] as? String
                case .roomCanonicalAlias:
                    if summary.displayname == nil {
                        summary.displayname = event.content["alias"] as? String
                        if summary.displayname == nil {
                            summary.displayname = (event.content["alt_aliases"] as? [String])?.first
                        }
                    }
                case .roomAliases:
                    if summary.displayname == nil {
                        summary.displayname = (event.content["aliases"] as? [String])?.first
                    }
                default: break
                }
            }
            return summary
        }
        return nil
    }
    
    public func update(with response: MXSyncResponse?) {
        guard filePath != nil else {
            return
        }
        
        guard let response = response else {
            //  Return if no new response
            return
        }
        if let syncResponse = syncResponse {
            //  current sync response exists, merge it with the new response
            var dictionary = NSDictionary(dictionary: syncResponse.jsonDictionary())
            dictionary = dictionary + NSDictionary(dictionary: response.jsonDictionary())
            saveSyncResponse(MXSyncResponse(fromJSON: dictionary as? [AnyHashable : Any]))
        } else {
            //  no current sync response, directly save the new one
            saveSyncResponse(response)
        }
    }
    
    public func deleteData() {
        saveSyncResponse(nil)
    }
    
}

//  MARK: - Private

private extension Array {
    
    mutating func appendIfNotNil(contentsOf array: Array?) {
        if let array = array {
            append(contentsOf: array)
        }
    }
    
}
