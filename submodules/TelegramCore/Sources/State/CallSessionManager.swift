import Foundation
import Postbox
import MtProtoKit
import SwiftSignalKit
import TelegramApi

private let minLayer: Int32 = 65

public enum CallSessionError: Equatable {
    case generic
    case privacyRestricted
    case notSupportedByPeer(isVideo: Bool)
    case serverProvided(text: String)
    case disconnected
}

public enum CallSessionEndedType: Equatable {
    case hungUp
    case busy
    case missed
    case switchedToConference(slug: String)
}

public enum CallSessionTerminationReason: Equatable {
    case ended(CallSessionEndedType)
    case error(CallSessionError)
    
    public static func ==(lhs: CallSessionTerminationReason, rhs: CallSessionTerminationReason) -> Bool {
        switch lhs {
        case let .ended(type):
            if case .ended(type) = rhs {
                return true
            } else {
                return false
            }
        case let .error(error):
            if case .error(error) = rhs {
                return true
            } else {
                return false
            }
        }
    }
}

public struct CallId: Equatable  {
    public let id: Int64
    public let accessHash: Int64
    
    public init(id: Int64, accessHash: Int64) {
        self.id = id
        self.accessHash = accessHash
    }
}

public struct GroupCallReference: Equatable {
    public var id: Int64
    public var accessHash: Int64
    
    public init(id: Int64, accessHash: Int64) {
        self.id = id
        self.accessHash = accessHash
    }
}

extension GroupCallReference {
    init?(_ apiGroupCall: Api.InputGroupCall) {
        switch apiGroupCall {
        case let .inputGroupCall(id, accessHash):
            self.init(id: id, accessHash: accessHash)
        case .inputGroupCallSlug, .inputGroupCallInviteMessage:
            return nil
        }
    }
    
    var apiInputGroupCall: Api.InputGroupCall {
        return .inputGroupCall(id: self.id, accessHash: self.accessHash)
    }
}

enum CallSessionInternalState {
    case ringing(id: Int64, accessHash: Int64, gAHash: Data, b: Data, versions: [String])
    case accepting(id: Int64, accessHash: Int64, gAHash: Data, b: Data, disposable: Disposable)
    case awaitingConfirmation(id: Int64, accessHash: Int64, gAHash: Data, b: Data, config: SecretChatEncryptionConfig)
    case requesting(a: Data, disposable: Disposable)
    case requested(id: Int64, accessHash: Int64, a: Data, gA: Data, config: SecretChatEncryptionConfig, remoteConfirmationTimestamp: Int32?)
    case confirming(id: Int64, accessHash: Int64, key: Data, keyId: Int64, keyVisualHash: Data, disposable: Disposable)
    case active(id: Int64, accessHash: Int64, beginTimestamp: Int32, key: Data, keyId: Int64, keyVisualHash: Data, connections: CallSessionConnectionSet, maxLayer: Int32, version: String, customParameters: String?, allowsP2P: Bool, supportsConferenceCalls: Bool)
    case switchedToConference(slug: String)
    case dropping(reason: CallSessionTerminationReason, disposable: Disposable)
    case terminated(id: Int64?, accessHash: Int64?, reason: CallSessionTerminationReason, reportRating: Bool, sendDebugLogs: Bool)

    var stableId: Int64? {
        switch self {
        case let .ringing(id, _, _, _, _):
            return id
        case let .accepting(id, _, _, _, _):
            return id
        case let .awaitingConfirmation(id, _, _, _, _):
            return id
        case .requesting:
            return nil
        case let .requested(id, _, _, _, _, _):
            return id
        case let .confirming(id, _, _, _, _, _):
            return id
        case let .active(id, _, _, _, _, _, _, _, _, _, _, _):
            return id
        case .switchedToConference:
            return nil
        case .dropping:
            return nil
        case let .terminated(id, _, _, _, _):
            return id
        }
    }
}

public typealias CallSessionInternalId = UUID
typealias CallSessionStableId = Int64

private final class StableIncomingUUIDs {
    private enum Key: Hashable {
        case global(callId: Int64)
        case group(peerId: Int64, messageId: Int32)
    }

    static let shared = Atomic<StableIncomingUUIDs>(value: StableIncomingUUIDs())

    private var dict: [Key: UUID] = [:]

    private init() {
    }

    func get(id: Int64) -> UUID {
        let key = Key.global(callId: id)
        if let value = self.dict[key] {
            return value
        } else {
            let value = UUID()
            self.dict[key] = value
            return value
        }
    }
    
    func get(peerId: Int64, messageId: Int32) -> UUID {
        let key = Key.group(peerId: peerId, messageId: messageId)
        if let value = self.dict[key] {
            return value
        } else {
            let value = UUID()
            self.dict[key] = value
            return value
        }
    }
}

public struct CallSessionRingingState: Equatable {
    public let id: CallSessionInternalId
    public let peerId: PeerId
    public let isVideo: Bool
    public let isVideoPossible: Bool
    public let conferenceSource: MessageId?
    public let otherParticipants: [EnginePeer]
}

public enum DropCallReason {
    case hangUp
    case busy
    case disconnect
    case missed
}

public struct CallTerminationOptions: OptionSet {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = 0
    }
    
    public static let reportRating = CallTerminationOptions(rawValue: 1 << 0)
    public static let sendDebugLogs = CallTerminationOptions(rawValue: 1 << 1)
}

public enum CallSessionState {
    case ringing
    case accepting
    case requesting(ringing: Bool)
    case active(id: CallId, key: Data, keyVisualHash: Data, connections: CallSessionConnectionSet, maxLayer: Int32, version: String, customParameters: String?, allowsP2P: Bool, supportsConferenceCalls: Bool)
    case switchedToConference(slug: String)
    case dropping(reason: CallSessionTerminationReason)
    case terminated(id: CallId?, reason: CallSessionTerminationReason, options: CallTerminationOptions)
    
    fileprivate init(_ context: CallSessionContext) {
        switch context.state {
            case .ringing:
                self = .ringing
            case .accepting, .awaitingConfirmation:
                self = .accepting
            case .requesting:
                self = .requesting(ringing: false)
            case .confirming:
                self = .requesting(ringing: true)
            case let .requested(_, _, _, _, _, remoteConfirmationTimestamp):
                self = .requesting(ringing: remoteConfirmationTimestamp != nil)
            case let .active(id, accessHash, _, key, _, keyVisualHash, connections, maxLayer, version, customParameters, allowsP2P, supportsConferenceCalls):
                self = .active(id: CallId(id: id, accessHash: accessHash), key: key, keyVisualHash: keyVisualHash, connections: connections, maxLayer: maxLayer, version: version, customParameters: customParameters, allowsP2P: allowsP2P, supportsConferenceCalls: supportsConferenceCalls)
            case let .dropping(reason, _):
                self = .dropping(reason: reason)
            case let .terminated(id, accessHash, reason, reportRating, sendDebugLogs):
                if case let .ended(endedReason) = reason, case let .switchedToConference(slug) = endedReason {
                    self = .switchedToConference(slug: slug)
                } else {
                    var options = CallTerminationOptions()
                    if reportRating {
                        options.insert(.reportRating)
                    }
                    if sendDebugLogs {
                        options.insert(.sendDebugLogs)
                    }
                    let callId: CallId?
                    if let id = id, let accessHash = accessHash {
                        callId = CallId(id: id, accessHash: accessHash)
                    } else {
                        callId = nil
                    }
                    self = .terminated(id: callId, reason: reason, options: options)
                }
            case let .switchedToConference(slug):
                self = .switchedToConference(slug: slug)
        }
    }
}

public struct CallSession {
    public enum CallType {
        case audio
        case video
    }
    
    public let id: CallSessionInternalId
    public let stableId: Int64?
    public let isOutgoing: Bool
    public let type: CallType
    public let state: CallSessionState
    public let isVideoPossible: Bool

    public init(
        id: CallSessionInternalId,
        stableId: Int64?,
        isOutgoing: Bool,
        type: CallType,
        state: CallSessionState,
        isVideoPossible: Bool
    ) {
        self.id = id
        self.stableId = stableId
        self.isOutgoing = isOutgoing
        self.type = type
        self.state = state
        self.isVideoPossible = isVideoPossible
    }
}

public enum CallSessionConnection: Equatable {
    public struct Reflector: Equatable {
        public let id: Int64
        public let ip: String
        public let ipv6: String
        public let isTcp: Bool
        public let port: Int32
        public let peerTag: Data
        
        public init(
            id: Int64,
            ip: String,
            ipv6: String,
            isTcp: Bool,
            port: Int32,
            peerTag: Data
        ) {
            self.id = id
            self.ip = ip
            self.ipv6 = ipv6
            self.isTcp = isTcp
            self.port = port
            self.peerTag = peerTag
        }
    }
    
    public struct WebRtcReflector: Equatable {
        public let id: Int64
        public let hasStun: Bool
        public let hasTurn: Bool
        public let ip: String
        public let ipv6: String
        public let port: Int32
        public let username: String
        public let password: String
        
        public init(
            id: Int64,
            hasStun: Bool,
            hasTurn: Bool,
            ip: String,
            ipv6: String,
            port: Int32,
            username: String,
            password: String
        ) {
            self.id = id
            self.hasStun = hasStun
            self.hasTurn = hasTurn
            self.ip = ip
            self.ipv6 = ipv6
            self.port = port
            self.username = username
            self.password = password
        }
    }
    
    case reflector(Reflector)
    case webRtcReflector(WebRtcReflector)
}

private func parseConnection(_ apiConnection: Api.PhoneConnection) -> CallSessionConnection {
    switch apiConnection {
    case let .phoneConnection(flags, id, ip, ipv6, port, peerTag):
        let isTcp = (flags & (1 << 0)) != 0
        return .reflector(CallSessionConnection.Reflector(id: id, ip: ip, ipv6: ipv6, isTcp: isTcp, port: port, peerTag: peerTag.makeData()))
    case let .phoneConnectionWebrtc(flags, id, ip, ipv6, port, username, password):
        return .webRtcReflector(CallSessionConnection.WebRtcReflector(
            id: id,
            hasStun: (flags & (1 << 1)) != 0,
            hasTurn: (flags & (1 << 0)) != 0,
            ip: ip,
            ipv6: ipv6,
            port: port,
            username: username,
            password: password
        ))
    }
}

public struct CallSessionConnectionSet {
    public let primary: CallSessionConnection
    public let alternatives: [CallSessionConnection]

    public init(primary: CallSessionConnection, alternatives: [CallSessionConnection]) {
        self.primary = primary
        self.alternatives = alternatives
    }
}

private func parseConnectionSet(primary: Api.PhoneConnection, alternative: [Api.PhoneConnection]) -> CallSessionConnectionSet {
    return CallSessionConnectionSet(primary: parseConnection(primary), alternatives: alternative.map { parseConnection($0) })
}

private final class CallSessionContext {
    let peerId: PeerId
    let isOutgoing: Bool
    var type: CallSession.CallType
    var isVideoPossible: Bool
    var state: CallSessionInternalState
    let subscribers = Bag<(CallSession) -> Void>()
    var signalingReceiver: (([Data]) -> Void)?
    
    let signalingDisposables = DisposableSet()
    let acknowledgeIncomingCallDisposable = MetaDisposable()
    var createConferenceCallDisposable: Disposable?
    
    var isEmpty: Bool {
        if case .terminated = self.state {
            return self.subscribers.isEmpty
        } else {
            return false
        }
    }
    
    init(peerId: PeerId, isOutgoing: Bool, type: CallSession.CallType, isVideoPossible: Bool, state: CallSessionInternalState) {
        self.peerId = peerId
        self.isOutgoing = isOutgoing
        self.type = type
        self.isVideoPossible = isVideoPossible
        self.state = state
    }
    
    deinit {
        self.signalingDisposables.dispose()
        self.acknowledgeIncomingCallDisposable.dispose()
        self.createConferenceCallDisposable?.dispose()
    }
}

public struct IncomingConferenceTermporaryExternalInfo {
    public var callId: Int64
    public var isVideo: Bool
    
    public init(callId: Int64, isVideo: Bool) {
        self.callId = callId
        self.isVideo = isVideo
    }
}

private final class IncomingConferenceInvitationContext {
    enum State: Equatable {
        case pending
        case ringing(callId: Int64, isVideo: Bool, otherParticipants: [EnginePeer])
        case stopped
    }

    private let queue: Queue
    private var disposable: Disposable?

    let internalId: CallSessionInternalId

    private(set) var state: State = .pending

    init(queue: Queue, postbox: Postbox, internalId: CallSessionInternalId, messageId: MessageId, externalInfo: IncomingConferenceTermporaryExternalInfo?, updated: @escaping () -> Void) {
        self.queue = queue

        self.internalId = internalId

        let key = PostboxViewKey.messages(Set([messageId]))
        
        if let externalInfo {
            self.state = .ringing(
                callId: externalInfo.callId,
                isVideo: externalInfo.isVideo,
                otherParticipants: []
            )
        }

        let waitSignal: Signal<Void, NoError>
        if externalInfo != nil {
            waitSignal = postbox.combinedView(keys: [key])
            |> mapToSignal { view -> Signal<Void, NoError> in
                guard let view = view.views[key] as? MessagesView else {
                    return .never()
                }
                if view.messages[messageId] == nil {
                    return .never()
                }
                return .single(Void())
            }
            |> take(1)
            |> timeout(5.0, queue: self.queue, alternate: deferred {
                Logger.shared.log("CallSessionManagerContext", "IncomingConferenceInvitationContext timeout for message \(messageId)")
                return Signal<Void, NoError>.single(Void())
            })
        } else {
            waitSignal = .single(Void())
        }

        self.disposable = (waitSignal |> map { _ -> Message? in return nil }
        |> then(
            postbox.combinedView(keys: [key])
            |> map { view -> Message? in
                guard let view = view.views[key] as? MessagesView else {
                    return nil
                }
                return view.messages[messageId]
            }
        )
        |> deliverOn(self.queue)).startStrict(next: { [weak self] message in
            guard let self = self else {
                return
            }
            let state: State
            if let message = message {
                var foundAction: TelegramMediaAction? 
                for media in message.media {
                    if let action = media as? TelegramMediaAction {
                        foundAction = action
                        break
                    }
                }

                if let action = foundAction, case let .conferenceCall(conferenceCall) = action.action {
                    if conferenceCall.flags.contains(.isMissed) || conferenceCall.duration != nil {
                        state = .stopped
                    } else {
                        state = .ringing(callId: conferenceCall.callId, isVideo: conferenceCall.flags.contains(.isVideo), otherParticipants: conferenceCall.otherParticipants.compactMap { id -> EnginePeer? in
                            return message.peers[id].flatMap(EnginePeer.init)
                        })
                    }
                } else {
                    state = .stopped
                }
            } else {
                state = .stopped
            }
            if self.state != state {
                self.state = state
                updated()
            }
        })
    }

    deinit {
        self.disposable?.dispose()
    }
}

private func selectVersionOnAccept(localVersions: [CallSessionManagerImplementationVersion], remoteVersions: [String]) -> [String]? {
    let filteredVersions = localVersions.map({ $0.version }).filter(remoteVersions.contains)
    if filteredVersions.isEmpty {
        return nil
    } else {
        return [filteredVersions[0]]
    }
}

public struct CallSessionManagerImplementationVersion: Hashable {
    public var version: String
    public var supportsVideo: Bool
    
    public init(version: String, supportsVideo: Bool) {
        self.version = version
        self.supportsVideo = supportsVideo
    }
}

private final class CallSessionManagerContext {
    private let queue: Queue
    private let postbox: Postbox
    private let network: Network
    private let accountPeerId: PeerId
    private let maxLayer: Int32
    private var versions: [CallSessionManagerImplementationVersion]
    private let addUpdates: (Api.Updates) -> Void
    
    private let ringingSubscribers = Bag<([CallSessionRingingState]) -> Void>()
    private var contexts: [CallSessionInternalId: CallSessionContext] = [:]
    private var futureContextSubscribers: [CallSessionInternalId: Bag<(CallSession) -> Void>] = [:]
    private var contextIdByStableId: [CallSessionStableId: CallSessionInternalId] = [:]

    private var incomingConferenceInvitationContexts: [MessageId: IncomingConferenceInvitationContext] = [:]

    private var enqueuedSignalingData: [Int64: [Data]] = [:]
    
    private let disposables = DisposableSet()
    private let rejectConferenceInvitationDisposables = DisposableSet()

    init(queue: Queue, postbox: Postbox, network: Network, accountPeerId: PeerId, maxLayer: Int32, versions: [CallSessionManagerImplementationVersion], addUpdates: @escaping (Api.Updates) -> Void) {
        self.queue = queue
        self.postbox = postbox
        self.network = network
        self.accountPeerId = accountPeerId
        self.maxLayer = maxLayer
        self.versions = versions.reversed()
        self.addUpdates = addUpdates
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.disposables.dispose()
        self.rejectConferenceInvitationDisposables.dispose()
    }
    
    func updateVersions(versions: [CallSessionManagerImplementationVersion]) {
        self.versions = versions.reversed()
    }
    
    func filteredVersions(enableVideo: Bool) -> [String] {
        return self.versions.compactMap { version -> String? in
            if enableVideo {
                return version.version
            } else if !version.supportsVideo {
                return version.version
            } else {
                return nil
            }
        }
    }
    
    func videoVersions() -> [String] {
        return self.versions.compactMap { version -> String? in
            if version.supportsVideo {
                return version.version
            } else {
                return nil
            }
        }
    }
    
    func ringingStates() -> Signal<[CallSessionRingingState], NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            queue.async {
                if let strongSelf = self {
                    let index = strongSelf.ringingSubscribers.add { next in
                        subscriber.putNext(next)
                    }
                    subscriber.putNext(strongSelf.ringingStatesValue())
                    disposable.set(ActionDisposable {
                        queue.async {
                            if let strongSelf = self {
                                strongSelf.ringingSubscribers.remove(index)
                            }
                        }
                    })
                }
            }
            return disposable
        }
    }
    
    func callState(internalId: CallSessionInternalId) -> Signal<CallSession, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            queue.async {
                guard let strongSelf = self else {
                    return
                }
                if let context = strongSelf.contexts[internalId] {
                    let index = context.subscribers.add { next in
                        subscriber.putNext(next)
                    }
                    subscriber.putNext(CallSession(id: internalId, stableId: context.state.stableId, isOutgoing: context.isOutgoing, type: context.type, state: CallSessionState(context), isVideoPossible: context.isVideoPossible))
                    disposable.set(ActionDisposable {
                        queue.async {
                            if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                                context.subscribers.remove(index)
                                if context.isEmpty {
                                    strongSelf.contexts.removeValue(forKey: internalId)
                                }
                            }
                        }
                    })
                } else {
                    if strongSelf.futureContextSubscribers[internalId] == nil {
                        strongSelf.futureContextSubscribers[internalId] = Bag()
                    }
                    let index = strongSelf.futureContextSubscribers[internalId]?.add({ session in
                        subscriber.putNext(session)
                    })
                    if let index = index {
                        disposable.set(ActionDisposable {
                            queue.async {
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.futureContextSubscribers[internalId]?.remove(index)
                            }
                        })
                    }
                }
            }
            return disposable
        }
    }
    
    func beginReceivingCallSignalingData(internalId: CallSessionInternalId, _ receiver: @escaping ([Data]) -> Void) -> Disposable {
        let queue = self.queue

        let disposable = MetaDisposable()
        queue.async { [weak self] in
            if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                context.signalingReceiver = receiver

                for (listStableId, listInternalId) in strongSelf.contextIdByStableId {
                    if listInternalId == internalId {
                        strongSelf.deliverCallSignalingData(id: listStableId)
                        break
                    }
                }

                disposable.set(ActionDisposable {
                    queue.async {
                        if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                            context.signalingReceiver = nil
                        }
                    }
                })
            }
        }
        return disposable
    }
    
    private func ringingStatesValue() -> [CallSessionRingingState] {
        var ringingContexts: [CallSessionRingingState] = []
        for (id, context) in self.contexts {
            if case .ringing = context.state {
                ringingContexts.append(CallSessionRingingState(
                    id: id,
                    peerId: context.peerId,
                    isVideo: context.type == .video,
                    isVideoPossible: context.isVideoPossible,
                    conferenceSource: nil,
                    otherParticipants: []
                ))
            }
        }
        for (id, context) in self.incomingConferenceInvitationContexts {
            if case let .ringing(_, isVideo, otherParticipants) = context.state {
                ringingContexts.append(CallSessionRingingState(
                    id: context.internalId,
                    peerId: id.peerId,
                    isVideo: isVideo,
                    isVideoPossible: true,
                    conferenceSource: id,
                    otherParticipants: otherParticipants
                ))
            }
        }
        return ringingContexts
    }
    
    private func ringingStatesUpdated() {
        let states = self.ringingStatesValue()
        for subscriber in self.ringingSubscribers.copyItems() {
            subscriber(states)
        }
    }
    
    private func contextUpdated(internalId: CallSessionInternalId) {
        if let context = self.contexts[internalId] {
            let session = CallSession(id: internalId, stableId: context.state.stableId, isOutgoing: context.isOutgoing, type: context.type, state: CallSessionState(context), isVideoPossible: context.isVideoPossible)
            for subscriber in context.subscribers.copyItems() {
                subscriber(session)
            }
            if let futureSubscribers = self.futureContextSubscribers[internalId] {
                for subscriber in futureSubscribers.copyItems() {
                    subscriber(session)
                }
            }
        }
    }
    
    private func addIncoming(peerId: PeerId, stableId: CallSessionStableId, accessHash: Int64, timestamp: Int32, gAHash: Data, versions: [String], isVideo: Bool) -> CallSessionInternalId? {
        if self.contextIdByStableId[stableId] != nil {
            return nil
        }
        
        let bBytes = malloc(256)!
        let randomStatus = SecRandomCopyBytes(nil, 256, bBytes.assumingMemoryBound(to: UInt8.self))
        let b = Data(bytesNoCopy: bBytes, count: 256, deallocator: .free)
        
        if randomStatus == 0 {
            let isVideoPossible = true
            
            let internalId = CallSessionManager.getStableIncomingUUID(stableId: stableId)
            let context = CallSessionContext(peerId: peerId, isOutgoing: false, type: isVideo ? .video : .audio, isVideoPossible: isVideoPossible, state: .ringing(id: stableId, accessHash: accessHash, gAHash: gAHash, b: b, versions: versions))
            self.contexts[internalId] = context
            let queue = self.queue
            
            let requestSignal: Signal<Api.Bool, MTRpcError> = self.network.request(Api.functions.phone.receivedCall(peer: .inputPhoneCall(id: stableId, accessHash: accessHash)))
            
            context.acknowledgeIncomingCallDisposable.set(requestSignal.start(error: { [weak self] _ in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    context.state = .terminated(id: nil, accessHash: nil, reason: .ended(.missed), reportRating: false, sendDebugLogs: false)
                    strongSelf.contextUpdated(internalId: internalId)
                    strongSelf.ringingStatesUpdated()
                    if context.isEmpty {
                        strongSelf.contexts.removeValue(forKey: internalId)
                    }
                    
                    strongSelf.contextIdByStableId.removeValue(forKey: stableId)
                }
            }))
            self.contextIdByStableId[stableId] = internalId
            self.contextUpdated(internalId: internalId)
            self.deliverCallSignalingData(id: stableId)
            self.ringingStatesUpdated()
            return internalId
        } else {
            return nil
        }
    }
    
    func dropOutgoingConferenceRequest(messageId: MessageId) {
        let addUpdates = self.addUpdates
        let rejectSignal = self.network.request(Api.functions.phone.declineConferenceCallInvite(msgId: messageId.id))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.Updates?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { updates -> Signal<Never, NoError> in
            if let updates {
                addUpdates(updates)
            }
            return .complete()
        }

        self.rejectConferenceInvitationDisposables.add(rejectSignal.startStrict())
    }
    
    func drop(internalId: CallSessionInternalId, reason: DropCallReason, debugLog: Signal<String?, NoError>) {
        for (id, context) in self.incomingConferenceInvitationContexts {
            if context.internalId == internalId {
                self.incomingConferenceInvitationContexts.removeValue(forKey: id)
                self.ringingStatesUpdated()

                let addUpdates = self.addUpdates
                let rejectSignal = self.network.request(Api.functions.phone.declineConferenceCallInvite(msgId: id.id))
                |> map(Optional.init)
                |> `catch` { _ -> Signal<Api.Updates?, NoError> in
                    return .single(nil)
                }
                |> mapToSignal { updates -> Signal<Never, NoError> in
                    if let updates {
                        addUpdates(updates)
                    }
                    return .complete()
                }

                self.rejectConferenceInvitationDisposables.add(rejectSignal.startStrict())

                return
            }
        }

        if let context = self.contexts[internalId] {
            var dropData: (CallSessionStableId, Int64, DropCallSessionReason)?
            var wasRinging = false
            let isVideo = context.type == .video
            switch context.state {
                case let .ringing(id, accessHash, _, _, _):
                    wasRinging = true
                    let internalReason: DropCallSessionReason
                    switch reason {
                    case .busy:
                        internalReason = .busy
                    case .hangUp:
                        internalReason = .hangUp(0)
                    case .disconnect:
                        internalReason = .disconnect
                    case .missed:
                        internalReason = .missed
                    }
                    dropData = (id, accessHash, internalReason)
                case let .accepting(id, accessHash, _, _, disposable):
                    dropData = (id, accessHash, .abort)
                    disposable.dispose()
                case let .active(id, accessHash, beginTimestamp, _, _, _, _, _, _, _, _, _):
                    let duration = max(0, Int32(CFAbsoluteTimeGetCurrent()) - beginTimestamp)
                    let internalReason: DropCallSessionReason
                    switch reason {
                    case .busy, .hangUp:
                        internalReason = .hangUp(duration)
                    case .disconnect:
                        internalReason = .disconnect
                    case .missed:
                        internalReason = .missed
                    }
                    dropData = (id, accessHash, internalReason)
                case .switchedToConference:
                    break
                case .dropping, .terminated:
                    break
                case let .awaitingConfirmation(id, accessHash, _, _, _):
                    dropData = (id, accessHash, .abort)
                case let .confirming(id, accessHash, _, _, _, disposable):
                    disposable.dispose()
                    dropData = (id, accessHash, .abort)
                case let .requested(id, accessHash, _, _, _, _):
                    let internalReason: DropCallSessionReason
                    switch reason {
                    case .busy, .hangUp:
                        internalReason = .missed
                    case .disconnect:
                        internalReason = .disconnect
                    case .missed:
                        internalReason = .missed
                    }
                    dropData = (id, accessHash, internalReason)
                case let .requesting(_, disposable):
                    disposable.dispose()
                    context.state = .terminated(id: nil, accessHash: nil, reason: .ended(.hungUp), reportRating: false, sendDebugLogs: false)
                    self.contextUpdated(internalId: internalId)
                    if context.isEmpty {
                        self.contexts.removeValue(forKey: internalId)
                    }
            }
            
            if let (id, accessHash, reason) = dropData {
                self.contextIdByStableId.removeValue(forKey: id)
                let mappedReason: CallSessionTerminationReason
                switch reason {
                case .abort:
                    mappedReason = .ended(.hungUp)
                case .busy:
                    mappedReason = .ended(.busy)
                case .disconnect:
                    mappedReason = .error(.disconnected)
                case .hangUp:
                    mappedReason = .ended(.hungUp)
                case .missed:
                    mappedReason = .ended(.missed)
                case let .switchToConference(slug):
                    mappedReason = .ended(.switchedToConference(slug: slug))
                }
                context.state = .dropping(reason: mappedReason, disposable: (dropCallSession(network: self.network, addUpdates: self.addUpdates, stableId: id, accessHash: accessHash, isVideo: isVideo, reason: reason)
                |> deliverOn(self.queue)).start(next: { [weak self] reportRating, sendDebugLogs in
                    if let strongSelf = self {
                        if let context = strongSelf.contexts[internalId] {
                            context.state = .terminated(id: id, accessHash: accessHash,  reason: mappedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                            /*if sendDebugLogs {
                                let network = strongSelf.network
                                let _ = (debugLog
                                |> timeout(5.0, queue: strongSelf.queue, alternate: .single(nil))
                                |> deliverOnMainQueue).start(next: { debugLog in
                                    if let debugLog = debugLog {
                                        let _ = _internal_saveCallDebugLog(network: network, callId: CallId(id: id, accessHash: accessHash), log: debugLog).start()
                                    }
                                })
                            }*/
                            strongSelf.contextUpdated(internalId: internalId)
                            if context.isEmpty {
                                strongSelf.contexts.removeValue(forKey: internalId)
                            }
                        }
                    }
                }))
                self.contextUpdated(internalId: internalId)
                if wasRinging {
                    self.ringingStatesUpdated()
                }
            }
        } else {
            self.contextUpdated(internalId: internalId)
        }
    }
    
    func drop(stableId: CallSessionStableId, reason: DropCallReason) {
        if let internalId = self.contextIdByStableId[stableId] {
            self.contextIdByStableId.removeValue(forKey: stableId)
            self.drop(internalId: internalId, reason: reason, debugLog: .single(nil))
        }
    }
    
    func dropToConference(internalId: CallSessionInternalId, slug: String) {
        if let context = self.contexts[internalId] {
            var dropData: (CallSessionStableId, Int64)?
            let isVideo = context.type == .video
            switch context.state {
            case let .active(id, accessHash, _, _, _, _, _, _, _, _, _, _):
                dropData = (id, accessHash)
            default:
                break
            }
            
            if let (id, accessHash) = dropData {
                self.contextIdByStableId.removeValue(forKey: id)
                context.state = .dropping(reason: .ended(.switchedToConference(slug: slug)), disposable: (dropCallSession(network: self.network, addUpdates: self.addUpdates, stableId: id, accessHash: accessHash, isVideo: isVideo, reason: .switchToConference(slug: slug))
                |> deliverOn(self.queue)).start(next: { [weak self] reportRating, sendDebugLogs in
                    if let strongSelf = self {
                        if let context = strongSelf.contexts[internalId] {
                            context.state = .switchedToConference(slug: slug)
                            strongSelf.contextUpdated(internalId: internalId)
                            if context.isEmpty {
                                strongSelf.contexts.removeValue(forKey: internalId)
                            }
                        }
                    }
                }))
                self.contextUpdated(internalId: internalId)
            }
        } else {
            self.contextUpdated(internalId: internalId)
        }
    }
    
    func dropAll() {
        let contexts = self.contexts
        for (internalId, _) in contexts {
            self.drop(internalId: internalId, reason: .hangUp, debugLog: .single(nil))
        }
    }
    
    func accept(internalId: CallSessionInternalId) {
        if let context = self.contexts[internalId] {
            switch context.state {
                case let .ringing(id, accessHash, gAHash, b, _):
                    let acceptVersions = self.versions.map({ $0.version })
                    context.state = .accepting(id: id, accessHash: accessHash, gAHash: gAHash, b: b, disposable: (acceptCallSession(accountPeerId: self.accountPeerId, postbox: self.postbox, network: self.network, stableId: id, accessHash: accessHash, b: b, maxLayer: self.maxLayer, versions: acceptVersions) |> deliverOn(self.queue)).start(next: { [weak self] result in
                        if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                            if case .accepting = context.state {
                                switch result {
                                    case .failed:
                                        strongSelf.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                    case let .success(call):
                                        switch call {
                                            case let .waiting(config):
                                                context.state = .awaitingConfirmation(id: id, accessHash: accessHash, gAHash: gAHash, b: b, config: config)
                                                strongSelf.contextUpdated(internalId: internalId)
                                            case let .call(config, gA, timestamp, connections, maxLayer, version, customParameters, allowsP2P, supportsConferenceCalls):
                                                if let (key, keyId, keyVisualHash) = strongSelf.makeSessionEncryptionKey(config: config, gAHash: gAHash, b: b, gA: gA) {
                                                    context.state = .active(id: id, accessHash: accessHash, beginTimestamp: timestamp, key: key, keyId: keyId, keyVisualHash: keyVisualHash, connections: connections, maxLayer: maxLayer, version: version, customParameters: customParameters, allowsP2P: allowsP2P, supportsConferenceCalls: supportsConferenceCalls)
                                                    strongSelf.contextUpdated(internalId: internalId)
                                                } else {
                                                    strongSelf.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                                }
                                        }
                                }
                            }
                        }
                    }))
                    self.contextUpdated(internalId: internalId)
                    self.ringingStatesUpdated()
                default:
                    break
            }
        }
    }
    
    func sendSignalingData(internalId: CallSessionInternalId, data: Data) {
        if let context = self.contexts[internalId] {
            switch context.state {
            case let .active(id, accessHash, _, _, _, _, _, _, _, _, _, _):
                context.signalingDisposables.add(self.network.request(Api.functions.phone.sendSignalingData(peer: .inputPhoneCall(id: id, accessHash: accessHash), data: Buffer(data: data))).start())
            default:
                break
            }
        }
    }
    
    func createConferenceIfNecessary(internalId: CallSessionInternalId) {
        if let context = self.contexts[internalId] {
            if context.createConferenceCallDisposable != nil {
                return
            }
            
            var idAndAccessHash: (id: Int64, accessHash: Int64)?
            switch context.state {
            case let .active(id, accessHash, _, _, _, _, _, _, _, _, _, _):
                idAndAccessHash = (id, accessHash)
            default:
                break
            }
            
            if idAndAccessHash != nil {
                context.createConferenceCallDisposable = (_internal_createConferenceCall(
                    postbox: self.postbox,
                    network: self.network,
                    accountPeerId: self.accountPeerId
                )
                |> deliverOn(self.queue)).startStrict(next: { [weak self] result in
                     guard let self else {
                        return
                    }

                    self.dropToConference(internalId: internalId, slug: result.slug)
                }, error: { [weak self] error in
                    guard let self else {
                        return
                    }
                    self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                })
            }
        }
    }
    
    func updateCallType(internalId: CallSessionInternalId, type: CallSession.CallType) {
        if let context = self.contexts[internalId] {
            context.type = type
        }
    }
    
    func updateSession(_ call: Api.PhoneCall, completion: @escaping ((CallSessionRingingState, CallSession)?) -> Void) {
        var resultRingingState: (CallSessionRingingState, CallSession)?
        
        switch call {
        case .phoneCallEmpty:
            break
        case let .phoneCallAccepted(_, id, _, _, _, _, gB, remoteProtocol):
            let remoteVersions: [String]
            switch remoteProtocol {
            case let .phoneCallProtocol(_, _, _, versions):
                remoteVersions = versions
            }
            if let internalId = self.contextIdByStableId[id] {
                guard let selectedVersions = selectVersionOnAccept(localVersions: self.versions, remoteVersions: remoteVersions) else {
                    self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                    return
                }
                
                if let context = self.contexts[internalId] {
                    switch context.state {
                        case let .requested(_, accessHash, a, gA, config, _):
                            let p = config.p.makeData()
                            if !MTCheckIsSafeGAOrB(self.network.encryptionProvider, gA, p) {
                                self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                            }
                            var key = MTExp(self.network.encryptionProvider, gB.makeData(), a, p)!
                            
                            if key.count > 256 {
                                key.count = 256
                            } else  {
                                while key.count < 256 {
                                    key.insert(0, at: 0)
                                }
                            }
                            
                            let keyHash = MTSha1(key)
                            
                            var keyId: Int64 = 0
                            keyHash.withUnsafeBytes { rawBytes -> Void in
                                let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                memcpy(&keyId, bytes.advanced(by: keyHash.count - 8), 8)
                            }
                            
                            let keyVisualHash = MTSha256(key + gA)
                            
                            context.state = .confirming(id: id, accessHash: accessHash, key: key, keyId: keyId, keyVisualHash: keyVisualHash, disposable: (confirmCallSession(network: self.network, stableId: id, accessHash: accessHash, gA: gA, keyFingerprint: keyId, maxLayer: self.maxLayer, versions: selectedVersions) |> deliverOnMainQueue).start(next: { [weak self] updatedCall in
                                if let strongSelf = self, let context = strongSelf.contexts[internalId], case .confirming = context.state {
                                    if let updatedCall = updatedCall {
                                        strongSelf.updateSession(updatedCall, completion: { _ in })
                                    } else {
                                        strongSelf.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                    }
                                }
                            }))
                            self.contextUpdated(internalId: internalId)
                        default:
                            self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                    }
                } else {
                    assertionFailure()
                }
            }
        case let .phoneCallDiscarded(flags, id, reason, _):
            let reportRating = (flags & (1 << 2)) != 0
            let sendDebugLogs = (flags & (1 << 3)) != 0
            if let internalId = self.contextIdByStableId[id] {
                if let context = self.contexts[internalId] {
                    let parsedReason: CallSessionTerminationReason
                    if let reason = reason {
                        switch reason {
                        case .phoneCallDiscardReasonBusy:
                            parsedReason = .ended(.busy)
                        case .phoneCallDiscardReasonDisconnect:
                            parsedReason = .error(.disconnected)
                        case .phoneCallDiscardReasonHangup:
                            parsedReason = .ended(.hungUp)
                        case .phoneCallDiscardReasonMissed:
                            parsedReason = .ended(.missed)
                        case let .phoneCallDiscardReasonMigrateConferenceCall(slug):
                            parsedReason = .ended(.switchedToConference(slug: slug))
                        }
                    } else {
                        parsedReason = .ended(.hungUp)
                    }
                    
                    switch context.state {
                    case let .accepting(id, accessHash, _, _, disposable):
                        disposable.dispose()
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.contextUpdated(internalId: internalId)
                    case let .active(id, accessHash, _, _, _, _, _, _, _, _, _, _):
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.contextUpdated(internalId: internalId)
                    case let .awaitingConfirmation(id, accessHash, _, _, _):
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.contextUpdated(internalId: internalId)
                    case let .requested(id, accessHash, _, _, _, _):
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.contextUpdated(internalId: internalId)
                    case let .confirming(id, accessHash, _, _, _, disposable):
                        disposable.dispose()
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.contextUpdated(internalId: internalId)
                    case let .requesting(_, disposable):
                        disposable.dispose()
                        context.state = .terminated(id: nil, accessHash: nil, reason: parsedReason, reportRating: false, sendDebugLogs: false)
                        self.contextUpdated(internalId: internalId)
                    case let .ringing(id, accessHash, _, _, _):
                        context.state = .terminated(id: id, accessHash: accessHash, reason: parsedReason, reportRating: reportRating, sendDebugLogs: sendDebugLogs)
                        self.ringingStatesUpdated()
                        self.contextUpdated(internalId: internalId)
                    case .dropping, .terminated, .switchedToConference:
                        break
                    }
                } else {
                    //assertionFailure()
                }
            }
        case let .phoneCall(flags, id, _, _, _, _, gAOrB, keyFingerprint, callProtocol, connections, startDate, customParameters):
            let allowsP2P = (flags & (1 << 5)) != 0
            let supportsConferenceCalls = (flags & (1 << 8)) != 0
            if let internalId = self.contextIdByStableId[id] {
                if let context = self.contexts[internalId] {
                    switch context.state {
                        case .accepting, .dropping, .requesting, .ringing, .terminated, .requested, .switchedToConference:
                            break
                        case let .active(id, accessHash, beginTimestamp, key, keyId, keyVisualHash, connections, maxLayer, version, customParameters, allowsP2P, supportsConferenceCalls):
                            context.state = .active(id: id, accessHash: accessHash, beginTimestamp: beginTimestamp, key: key, keyId: keyId, keyVisualHash: keyVisualHash, connections: connections, maxLayer: maxLayer, version: version, customParameters: customParameters, allowsP2P: allowsP2P, supportsConferenceCalls: supportsConferenceCalls)
                            self.contextUpdated(internalId: internalId)
                        case let .awaitingConfirmation(_, accessHash, gAHash, b, config):
                            if let (key, calculatedKeyId, keyVisualHash) = self.makeSessionEncryptionKey(config: config, gAHash: gAHash, b: b, gA: gAOrB.makeData()) {
                                if keyFingerprint == calculatedKeyId {
                                    switch callProtocol {
                                        case let .phoneCallProtocol(_, _, maxLayer, versions):
                                            if !versions.isEmpty {
                                                var customParametersValue: String?
                                                switch customParameters {
                                                case .none:
                                                    break
                                                case let .dataJSON(data):
                                                    customParametersValue = data
                                                }
                                                
                                                let isVideoPossible = self.videoVersions().contains(where: { versions.contains($0) })
                                                context.isVideoPossible = isVideoPossible
                                                
                                                context.state = .active(id: id, accessHash: accessHash, beginTimestamp: startDate, key: key, keyId: calculatedKeyId, keyVisualHash: keyVisualHash, connections: parseConnectionSet(primary: connections.first!, alternative: Array(connections[1...])), maxLayer: maxLayer, version: versions[0], customParameters: customParametersValue, allowsP2P: allowsP2P, supportsConferenceCalls: supportsConferenceCalls)
                                                self.contextUpdated(internalId: internalId)
                                            } else {
                                                self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                            }
                                    }
                                } else {
                                    self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                }
                            } else {
                                self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                            }
                        case let .confirming(id, accessHash, key, keyId, keyVisualHash, _):
                            switch callProtocol {
                                case let .phoneCallProtocol(_, _, maxLayer, versions):
                                    if !versions.isEmpty {
                                        var customParametersValue: String?
                                        switch customParameters {
                                        case .none:
                                            break
                                        case let .dataJSON(data):
                                            customParametersValue = data
                                        }
                                        
                                        let isVideoPossible = self.videoVersions().contains(where: { versions.contains($0) })
                                        context.isVideoPossible = isVideoPossible
                                        
                                        context.state = .active(id: id, accessHash: accessHash, beginTimestamp: startDate, key: key, keyId: keyId, keyVisualHash: keyVisualHash, connections: parseConnectionSet(primary: connections.first!, alternative: Array(connections[1...])), maxLayer: maxLayer, version: versions[0], customParameters: customParametersValue, allowsP2P: allowsP2P, supportsConferenceCalls: supportsConferenceCalls)
                                        self.contextUpdated(internalId: internalId)
                                    } else {
                                        self.drop(internalId: internalId, reason: .disconnect, debugLog: .single(nil))
                                    }
                            }
                    }
                } else {
                    assertionFailure()
                }
            }
        case let .phoneCallRequested(flags, id, accessHash, date, adminId, _, gAHash, requestedProtocol):
            let isVideo = (flags & (1 << 6)) != 0
            let versions: [String]
            switch requestedProtocol {
            case let .phoneCallProtocol(_, _, _, libraryVersions):
                versions = libraryVersions
            }
            if self.contextIdByStableId[id] == nil {
                let internalId = self.addIncoming(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(adminId)), stableId: id, accessHash: accessHash, timestamp: date, gAHash: gAHash.makeData(), versions: versions, isVideo: isVideo)
                if let internalId = internalId {
                    var resultRingingStateValue: CallSessionRingingState?
                    for ringingState in self.ringingStatesValue() {
                        if ringingState.id == internalId {
                            resultRingingStateValue = ringingState
                            break
                        }
                    }
                    if let context = self.contexts[internalId] {
                        let callSession = CallSession(id: internalId, stableId: id, isOutgoing: context.isOutgoing, type: context.type, state: CallSessionState(context), isVideoPossible: context.isVideoPossible)
                        if let resultRingingStateValue = resultRingingStateValue {
                            resultRingingState = (resultRingingStateValue, callSession)
                        }
                    }
                }
            }
        case let .phoneCallWaiting(_, id, _, _, _, _, _, receiveDate):
            if let internalId = self.contextIdByStableId[id] {
                if let context = self.contexts[internalId] {
                    switch context.state {
                        case let .requested(id, accessHash, a, gA, config, remoteConfirmationTimestamp):
                            if let receiveDate = receiveDate, remoteConfirmationTimestamp == nil {
                                context.state = .requested(id: id, accessHash: accessHash, a: a, gA: gA, config: config, remoteConfirmationTimestamp: receiveDate)
                                self.contextUpdated(internalId: internalId)
                            }
                        default:
                            break
                    }
                } else {
                    assertionFailure()
                }
            }
        }
        
        completion(resultRingingState)
    }
    
    func addCallSignalingData(id: Int64, data: Data) {
        if self.enqueuedSignalingData[id] == nil {
            self.enqueuedSignalingData[id] = []
        }
        self.enqueuedSignalingData[id]?.append(data)

        self.deliverCallSignalingData(id: id)
    }

    private func deliverCallSignalingData(id: Int64) {
        guard let internalId = self.contextIdByStableId[id], let context = self.contexts[internalId] else {
            return
        }
        if let signalingReceiver = context.signalingReceiver {
            if let data = self.enqueuedSignalingData.removeValue(forKey: id) {
                signalingReceiver(data)
            }
        }
    }

    func addConferenceInvitationMessages(ids: [(id: MessageId, externalInfo: IncomingConferenceTermporaryExternalInfo?)]) {
        var updateRingingStates = false
        for (id, externalInfo) in ids {
            if self.incomingConferenceInvitationContexts[id] == nil {
                Logger.shared.log("CallSessionManagerContext", "Adding incoming conference invitation context for message \(id)")
                let context = IncomingConferenceInvitationContext(queue: self.queue, postbox: self.postbox, internalId: CallSessionManager.getStableIncomingUUID(peerId: id.peerId.id._internalGetInt64Value(), messageId: id.id), messageId: id, externalInfo: externalInfo, updated: { [weak self] in
                    guard let self else {
                        return
                    }
                    if let context = self.incomingConferenceInvitationContexts[id] {
                        switch context.state {
                        case .pending:
                            break
                        case .ringing:
                            self.ringingStatesUpdated()
                        case .stopped:
                            self.incomingConferenceInvitationContexts.removeValue(forKey: id)
                        }
                    }
                })
                self.incomingConferenceInvitationContexts[id] = context
                updateRingingStates = true
            } else {
                Logger.shared.log("CallSessionManagerContext", "Conference invitation context for message \(id) already exists")
            }
        }
        if updateRingingStates {
            self.ringingStatesUpdated()
        }
    }
    
    private func makeSessionEncryptionKey(config: SecretChatEncryptionConfig, gAHash: Data, b: Data, gA: Data) -> (key: Data, keyId: Int64, keyVisualHash: Data)? {
        var key = MTExp(self.network.encryptionProvider, gA, b, config.p.makeData())!
        
        if key.count > 256 {
            key.count = 256
        } else  {
            while key.count < 256 {
                key.insert(0, at: 0)
            }
        }
        
        let keyHash = MTSha1(key)
        
        var keyId: Int64 = 0
        keyHash.withUnsafeBytes { rawBytes -> Void in
            let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            memcpy(&keyId, bytes.advanced(by: keyHash.count - 8), 8)
        }
        
        if MTSha256(gA) != gAHash {
            return nil
        }
        
        let keyVisualHash = MTSha256(key + gA)
        
        return (key, keyId, keyVisualHash)
    }
    
    func request(peerId: PeerId, internalId: CallSessionInternalId, isVideo: Bool, enableVideo: Bool) -> CallSessionInternalId? {
        let aBytes = malloc(256)!
        let randomStatus = SecRandomCopyBytes(nil, 256, aBytes.assumingMemoryBound(to: UInt8.self))
        let a = Data(bytesNoCopy: aBytes, count: 256, deallocator: .free)
        if randomStatus == 0 {
            self.contexts[internalId] = CallSessionContext(peerId: peerId, isOutgoing: true, type: isVideo ? .video : .audio, isVideoPossible: enableVideo || isVideo, state: .requesting(a: a, disposable: (requestCallSession(postbox: self.postbox, network: self.network, peerId: peerId, a: a, maxLayer: self.maxLayer, versions: self.filteredVersions(enableVideo: true), isVideo: isVideo) |> deliverOn(queue)).start(next: { [weak self] result in
                if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                    if case .requesting = context.state {
                        switch result {
                            case let .success(id, accessHash, config, gA, remoteConfirmationTimestamp):
                                context.state = .requested(id: id, accessHash: accessHash, a: a, gA: gA, config: config, remoteConfirmationTimestamp: remoteConfirmationTimestamp)
                                strongSelf.contextIdByStableId[id] = internalId
                                strongSelf.contextUpdated(internalId: internalId)
                                strongSelf.deliverCallSignalingData(id: id)
                            case let .failed(error):
                                context.state = .terminated(id: nil, accessHash: nil, reason: .error(error), reportRating: false, sendDebugLogs: false)
                                strongSelf.contextUpdated(internalId: internalId)
                                if context.isEmpty {
                                    strongSelf.contexts.removeValue(forKey: internalId)
                                }
                        }
                    }
                }
            })))
            self.contextUpdated(internalId: internalId)
            return internalId
        } else {
            return nil
        }
    }
}

public enum CallRequestError {
    case generic
}

public final class CallSessionManager {
    public static func getStableIncomingUUID(stableId: Int64) -> UUID {
        return StableIncomingUUIDs.shared.with { impl in
            return impl.get(id: stableId)
        }
    }
    
    public static func getStableIncomingUUID(peerId: Int64, messageId: Int32) -> UUID {
        return StableIncomingUUIDs.shared.with { impl in
            return impl.get(peerId: peerId, messageId: messageId)
        }
    }

    private let queue = Queue()
    private var contextRef: Unmanaged<CallSessionManagerContext>?
    
    init(postbox: Postbox, network: Network, accountPeerId: PeerId, maxLayer: Int32, versions: [CallSessionManagerImplementationVersion], addUpdates: @escaping (Api.Updates) -> Void) {
        self.queue.async {
            let context = CallSessionManagerContext(queue: self.queue, postbox: postbox, network: network, accountPeerId: accountPeerId, maxLayer: maxLayer, versions: versions, addUpdates: addUpdates)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
    
    private func withContext(_ f: @escaping (CallSessionManagerContext) -> Void) {
        self.queue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                f(context)
            }
        }
    }
    
    func updateSession(_ call: Api.PhoneCall, completion: @escaping ((CallSessionRingingState, CallSession)?) -> Void) {
        self.withContext { context in
            context.updateSession(call, completion: completion)
        }
    }
    
    func addCallSignalingData(id: Int64, data: Data) {
        self.withContext { context in
            context.addCallSignalingData(id: id, data: data)
        }
    }

    public func addConferenceInvitationMessages(ids: [(id: MessageId, externalInfo: IncomingConferenceTermporaryExternalInfo?)]) {
        self.withContext { context in
            context.addConferenceInvitationMessages(ids: ids)
        }
    }
    
    public func drop(internalId: CallSessionInternalId, reason: DropCallReason, debugLog: Signal<String?, NoError>) {
        self.withContext { context in
            context.drop(internalId: internalId, reason: reason, debugLog: debugLog)
        }
    }
    
    public func dropOutgoingConferenceRequest(messageId: MessageId) {
        self.withContext { context in
            context.dropOutgoingConferenceRequest(messageId: messageId)
        }
    }
    
    func drop(stableId: CallSessionStableId, reason: DropCallReason) {
        self.withContext { context in
            context.drop(stableId: stableId, reason: reason)
        }
    }
    
    func dropAll() {
        self.withContext { context in
            context.dropAll()
        }
    }
    
    public func accept(internalId: CallSessionInternalId) {
        self.withContext { context in
            context.accept(internalId: internalId)
        }
    }
    
    public func request(peerId: PeerId, isVideo: Bool, enableVideo: Bool, internalId: CallSessionInternalId = CallSessionInternalId()) -> Signal<CallSessionInternalId, NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            
            self?.withContext { context in
                if let internalId = context.request(peerId: peerId, internalId: internalId, isVideo: isVideo, enableVideo: enableVideo) {
                    subscriber.putNext(internalId)
                    subscriber.putCompletion()
                }
            }
            
            return disposable
        }
    }
    
    public func sendSignalingData(internalId: CallSessionInternalId, data: Data) {
        self.withContext { context in
            context.sendSignalingData(internalId: internalId, data: data)
        }
    }
    
    public func createConferenceIfNecessary(internalId: CallSessionInternalId) {
        self.withContext { context in
            context.createConferenceIfNecessary(internalId: internalId)
        }
    }
    
    public func updateCallType(internalId: CallSessionInternalId, type: CallSession.CallType) {
        self.withContext { context in
            context.updateCallType(internalId: internalId, type: type)
        }
    }
    
    public func updateVersions(versions: [CallSessionManagerImplementationVersion]) {
        self.withContext { context in
            context.updateVersions(versions: versions)
        }
    }
    
    public func ringingStates() -> Signal<[CallSessionRingingState], NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            self?.withContext { context in
                disposable.set(context.ringingStates().start(next: { next in
                    subscriber.putNext(next)
                }))
            }
            return disposable
        }
    }
    
    public func callState(internalId: CallSessionInternalId) -> Signal<CallSession, NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            self?.withContext { context in
                disposable.set(context.callState(internalId: internalId).start(next: { next in
                    subscriber.putNext(next)
                }))
            }
            return disposable
        }
    }
    
    public func beginReceivingCallSignalingData(internalId: CallSessionInternalId, _ receiver: @escaping ([Data]) -> Void) -> Disposable {
        let disposable = MetaDisposable()

        self.withContext { context in
            disposable.set(context.beginReceivingCallSignalingData(internalId: internalId, receiver))
        }

        return disposable
    }
}

private enum AcceptedCall {
    case waiting(config: SecretChatEncryptionConfig)
    case call(config: SecretChatEncryptionConfig, gA: Data, timestamp: Int32, connections: CallSessionConnectionSet, maxLayer: Int32, version: String, customParameters: String?, allowsP2P: Bool, supportsConferenceCalls: Bool)
}

private enum AcceptCallResult {
    case failed
    case success(AcceptedCall)
}

private func acceptCallSession(accountPeerId: PeerId, postbox: Postbox, network: Network, stableId: CallSessionStableId, accessHash: Int64, b: Data, maxLayer: Int32, versions: [String]) -> Signal<AcceptCallResult, NoError> {
    return validatedEncryptionConfig(postbox: postbox, network: network)
    |> mapToSignal { config -> Signal<AcceptCallResult, NoError> in
        var gValue: Int32 = config.g.byteSwapped
        let g = Data(bytes: &gValue, count: 4)
        let p = config.p.makeData()
        
        let bData = b
        
        let gb = MTExp(network.encryptionProvider, g, bData, p)!
        
        if !MTCheckIsSafeGAOrB(network.encryptionProvider, gb, p) {
            return .single(.failed)
        }
                
        return network.request(Api.functions.phone.acceptCall(peer: .inputPhoneCall(id: stableId, accessHash: accessHash), gB: Buffer(data: gb), protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: minLayer, maxLayer: maxLayer, libraryVersions: versions)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.phone.PhoneCall?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { call -> Signal<AcceptCallResult, NoError> in
            if let call = call {
                return postbox.transaction { transaction -> AcceptCallResult in
                    switch call {
                    case let .phoneCall(phoneCall, users):
                        updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: AccumulatedPeers(users: users))
                        
                        switch phoneCall {
                        case .phoneCallEmpty, .phoneCallRequested, .phoneCallAccepted, .phoneCallDiscarded:
                            return .failed
                        case .phoneCallWaiting:
                            return .success(.waiting(config: config))
                        case let .phoneCall(flags, id, _, _, _, _, gAOrB, _, callProtocol, connections, startDate, customParameters):
                            if id == stableId {
                                switch callProtocol{
                                    case let .phoneCallProtocol(_, _, maxLayer, versions):
                                        if !versions.isEmpty {
                                            var customParametersValue: String?
                                            switch customParameters {
                                            case .none:
                                                break
                                            case let .dataJSON(data):
                                                customParametersValue = data
                                            }
                                            
                                            return .success(.call(config: config, gA: gAOrB.makeData(), timestamp: startDate, connections: parseConnectionSet(primary: connections.first!, alternative: Array(connections[1...])), maxLayer: maxLayer, version: versions[0], customParameters: customParametersValue, allowsP2P: (flags & (1 << 5)) != 0, supportsConferenceCalls: (flags & (1 << 8)) != 0))
                                        } else {
                                            return .failed
                                        }
                                }
                            } else {
                                return .failed
                            }
                        }
                    }
                }
            } else {
                return .single(.failed)
            }
        }
    }
}

private enum RequestCallSessionResult {
    case success(id: CallSessionStableId, accessHash: Int64, config: SecretChatEncryptionConfig, gA: Data, remoteConfirmationTimestamp: Int32?)
    case failed(CallSessionError)
}

private func requestCallSession(postbox: Postbox, network: Network, peerId: PeerId, a: Data, maxLayer: Int32, versions: [String], isVideo: Bool) -> Signal<RequestCallSessionResult, NoError> {
    return validatedEncryptionConfig(postbox: postbox, network: network)
    |> mapToSignal { config -> Signal<RequestCallSessionResult, NoError> in
        return postbox.transaction { transaction -> Signal<RequestCallSessionResult, NoError> in
            if let peer = transaction.getPeer(peerId), let inputUser = apiInputUser(peer) {
                var gValue: Int32 = config.g.byteSwapped
                let g = Data(bytes: &gValue, count: 4)
                let p = config.p.makeData()
                
                let ga = MTExp(network.encryptionProvider, g, a, p)!
                if !MTCheckIsSafeGAOrB(network.encryptionProvider, ga, p) {
                    return .single(.failed(.generic))
                }
                
                let gAHash = MTSha256(ga)
                
                var callFlags: Int32 = 0
                if isVideo {
                    callFlags |= 1 << 0
                }
                
                return network.request(Api.functions.phone.requestCall(flags: callFlags, userId: inputUser, randomId: Int32(bitPattern: arc4random()), gAHash: Buffer(data: gAHash), protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: minLayer, maxLayer: maxLayer, libraryVersions: versions)))
                |> map { result -> RequestCallSessionResult in
                    switch result {
                        case let .phoneCall(phoneCall, _):
                            switch phoneCall {
                                case let .phoneCallRequested(_, id, accessHash, _, _, _, _, _):
                                    return .success(id: id, accessHash: accessHash, config: config, gA: ga, remoteConfirmationTimestamp: nil)
                                case let .phoneCallWaiting(_, id, accessHash, _, _, _, _, receiveDate):
                                    return .success(id: id, accessHash: accessHash, config: config, gA: ga, remoteConfirmationTimestamp: receiveDate)
                                default:
                                    return .failed(.generic)
                            }
                    }
                }
                |> `catch` { error -> Signal<RequestCallSessionResult, NoError> in
                    switch error.errorDescription {
                        case "PARTICIPANT_VERSION_OUTDATED":
                            return .single(.failed(.notSupportedByPeer(isVideo: isVideo)))
                        case "USER_PRIVACY_RESTRICTED":
                            return .single(.failed(.privacyRestricted))
                        default:
                            if error.errorCode == 406 {
                                return .single(.failed(.serverProvided(text: error.errorDescription)))
                            } else {
                                return .single(.failed(.generic))
                            }
                    }
                }
            } else {
                return .single(.failed(.generic))
            }
        }
        |> switchToLatest
    }
}

private func confirmCallSession(network: Network, stableId: CallSessionStableId, accessHash: Int64, gA: Data, keyFingerprint: Int64, maxLayer: Int32, versions: [String]) -> Signal<Api.PhoneCall?, NoError> {
    return network.request(Api.functions.phone.confirmCall(peer: Api.InputPhoneCall.inputPhoneCall(id: stableId, accessHash: accessHash), gA: Buffer(data: gA), keyFingerprint: keyFingerprint, protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: minLayer, maxLayer: maxLayer, libraryVersions: versions)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.phone.PhoneCall?, NoError> in
            return .single(nil)
        }
        |> map { result -> Api.PhoneCall? in
            if let result = result {
                switch result {
                    case let .phoneCall(phoneCall, _):
                        return phoneCall
                }
            } else {
                return nil
            }
    }
}

private enum DropCallSessionReason {
    case abort
    case hangUp(Int32)
    case busy
    case disconnect
    case missed
    case switchToConference(slug: String)
}

private func dropCallSession(network: Network, addUpdates: @escaping (Api.Updates) -> Void, stableId: CallSessionStableId, accessHash: Int64, isVideo: Bool, reason: DropCallSessionReason) -> Signal<(Bool, Bool), NoError> {
    var mappedReason: Api.PhoneCallDiscardReason
    var duration: Int32 = 0
    switch reason {
    case .abort:
        mappedReason = .phoneCallDiscardReasonHangup
    case let .hangUp(value):
        duration = value
        mappedReason = .phoneCallDiscardReasonHangup
    case .busy:
        mappedReason = .phoneCallDiscardReasonBusy
    case .disconnect:
        mappedReason = .phoneCallDiscardReasonDisconnect
    case .missed:
        mappedReason = .phoneCallDiscardReasonMissed
    case let .switchToConference(slug):
        mappedReason = .phoneCallDiscardReasonMigrateConferenceCall(slug: slug)
    }
    
    var callFlags: Int32 = 0
    if isVideo {
        callFlags |= 1 << 0
    }
    
    return network.request(Api.functions.phone.discardCall(flags: callFlags, peer: Api.InputPhoneCall.inputPhoneCall(id: stableId, accessHash: accessHash), duration: duration, reason: mappedReason, connectionId: 0))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.Updates?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { updates -> Signal<(Bool, Bool), NoError> in
        var reportRating: Bool = false
        var sendDebugLogs: Bool = false
        if let updates = updates {
            switch updates {
                case .updates(let updates, _, _, _, _):
                    for update in updates {
                        switch update {
                            case .updatePhoneCall(let phoneCall):
                                switch phoneCall {
                                    case let .phoneCallDiscarded(flags, _, _, _):
                                        reportRating = (flags & (1 << 2)) != 0
                                        sendDebugLogs = (flags & (1 << 3)) != 0
                                    default:
                                        break
                                }
                                break
                            default:
                                break
                        }
                    }
                default:
                    break
            }
            
            addUpdates(updates)
            
        }
        return .single((reportRating, sendDebugLogs))
    }
}

