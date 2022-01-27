// 
// Copyright 2021 The Matrix.org Foundation C.I.C
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

/// MXThreadingService error
public enum MXThreadingServiceError: Int, Error {
    case sessionNotFound
    case unknown
}

// MARK: - MXThreadingService errors
extension MXThreadingServiceError: CustomNSError {
    public static let errorDomain = "org.matrix.sdk.threadingservice"

    public var errorCode: Int {
        return rawValue
    }

    public var errorUserInfo: [String: Any] {
        return [:]
    }
}

@objc
public protocol MXThreadingServiceDelegate: AnyObject {
    func threadingServiceDidUpdateThreads(_ service: MXThreadingService)
}

@objcMembers
/// Threading service class.
public class MXThreadingService: NSObject {
    
    private weak var session: MXSession?
    
    private var threads: [String: MXThread] = [:]
    private let multicastDelegate: MXMulticastDelegate<MXThreadingServiceDelegate> = MXMulticastDelegate()
    
    /// Notification to be posted when a new thread is created.
    public static let newThreadCreated = Notification.Name("MXThreadingService.newThreadCreated")
    
    /// Initializer
    /// - Parameter session: session instance
    public init(withSession session: MXSession) {
        self.session = session
        super.init()
    }
    
    /// Adds event to the related thread instance
    /// - Parameter event: event to be handled
    /// - Returns: true if the event handled, false otherwise
    @discardableResult
    public func handleEvent(_ event: MXEvent, direction: MXTimelineDirection) -> Bool {
        guard let session = session else {
            //  session closed
            return false
        }
        if let threadId = event.threadId {
            //  event is in a thread
            let handled: Bool
            if let thread = thread(withId: threadId) {
                //  add event to the thread if found
                handled = thread.addEvent(event)
            } else {
                //  create the thread for the first time
                let thread: MXThread
                //  try to find the root event in the session store
                if let rootEvent = session.store?.event(withEventId: threadId, inRoom: event.roomId) {
                    thread = MXThread(withSession: session, rootEvent: rootEvent)
                } else {
                    thread = MXThread(withSession: session, identifier: threadId, roomId: event.roomId)
                }
                handled = thread.addEvent(event)
                saveThread(thread)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.newThreadCreated, object: thread, userInfo: nil)
                }
            }
            notifyDidUpdateThreads()
            return handled
        } else if let thread = thread(withId: event.eventId) {
            //  event is the root event of a thread
            let handled = thread.addEvent(event)
            notifyDidUpdateThreads()
            return handled
        } else if event.isEdit() && direction == .forwards {
            let editedEventId = event.relatesTo.eventId
            if let editedEvent = session.store?.event(withEventId: editedEventId, inRoom: event.roomId),
               let threadId = editedEvent.threadId,
               let thread = thread(withId: threadId),
               let newEvent = editedEvent.editedEvent(fromReplacementEvent: event) {
                let handled = thread.replaceEvent(withId: editedEventId, with: newEvent)
                notifyDidUpdateThreads()
                return handled
            }
        } else if event.eventType == .roomRedaction && direction == .forwards {
            if let redactedEventId = event.redacts,
               let thread = thread(withId: redactedEventId),
               let newEvent = session.store?.event(withEventId: redactedEventId,
                                                   inRoom: event.roomId) {
                let handled = thread.replaceEvent(withId: redactedEventId, with: newEvent)
                notifyDidUpdateThreads()
                return handled
            }
        }
        return false
    }
    
    /// Get notifications count of threads in a room
    /// - Parameter roomId: Room identifier
    /// - Returns: Notifications count
    public func notificationsCount(forRoom roomId: String) -> MXThreadNotificationsCount {
        let notified = unsortedParticipatedThreads(inRoom: roomId).filter { $0.notificationCount > 0 }.count
        let highlighted = unsortedThreads(inRoom: roomId).filter { $0.highlightCount > 0 }.count
        return MXThreadNotificationsCount(numberOfNotifiedThreads: UInt(notified),
                                          numberOfHighlightedThreads: UInt(highlighted))
    }
    
    /// Method to check an event is a thread root or not
    /// - Parameter event: event to be checked
    /// - Returns: true is given event is a thread root
    public func isEventThreadRoot(_ event: MXEvent) -> Bool {
        return thread(withId: event.eventId) != nil
    }
    
    /// Method to get a thread with specific identifier
    /// - Parameter identifier: identifier of a thread
    /// - Returns: thread instance if found, nil otherwise
    public func thread(withId identifier: String) -> MXThread? {
        objc_sync_enter(threads)
        let result = threads[identifier]
        objc_sync_exit(threads)
        return result
    }
    
    public func createTempThread(withId identifier: String, roomId: String) -> MXThread {
        guard let session = session else {
            fatalError("Session must be available")
        }
        return MXThread(withSession: session, identifier: identifier, roomId: roomId)
    }
    
    /// Get threads in a room
    /// - Parameter roomId: room identifier
    /// - Returns: thread list in given room
    public func threads(inRoom roomId: String) -> [MXThread] {
        //  sort threads so that the newer is the first
        return unsortedThreads(inRoom: roomId).sorted(by: <)
    }
    
    /// Get participated threads in a room
    /// - Parameter roomId: room identifier
    /// - Returns: participated thread list in given room
    public func participatedThreads(inRoom roomId: String) -> [MXThread] {
        //  filter only participated threads and then sort threads so that the newer is the first
        return unsortedParticipatedThreads(inRoom: roomId).sorted(by: <)
    }
    
    /// Mark a thread as read
    /// - Parameter threadId: Thread id
    public func markThreadAsRead(_ threadId: String) {
        guard let thread = thread(withId: threadId) else {
            return
        }
        thread.markAsRead()
        notifyDidUpdateThreads()
    }
    
    private func unsortedThreads(inRoom roomId: String) -> [MXThread] {
        return Array(threads.values).filter({ $0.roomId == roomId })
    }
    
    private func unsortedParticipatedThreads(inRoom roomId: String) -> [MXThread] {
        return Array(threads.values).filter({ $0.roomId == roomId && $0.isParticipated })
    }
    
    private func saveThread(_ thread: MXThread) {
        objc_sync_enter(threads)
        threads[thread.id] = thread
        objc_sync_exit(threads)
    }
    
    //  MARK: - Delegate
    
    /// Add delegate instance
    /// - Parameter delegate: delegate instance
    public func addDelegate(_ delegate: MXThreadingServiceDelegate) {
        multicastDelegate.addDelegate(delegate)
    }
    
    /// Remove delegate instance
    /// - Parameter delegate: delegate instance
    public func removeDelegate(_ delegate: MXThreadingServiceDelegate) {
        multicastDelegate.removeDelegate(delegate)
    }
    
    /// Remove all delegates
    public func removeAllDelegates() {
        multicastDelegate.removeAllDelegates()
    }
    
    private func notifyDidUpdateThreads() {
        multicastDelegate.invoke({ $0.threadingServiceDidUpdateThreads(self) })
    }
    
}
