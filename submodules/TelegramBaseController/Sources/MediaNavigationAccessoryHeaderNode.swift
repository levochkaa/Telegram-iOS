import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UniversalMediaPlayer
import AccountContext
import TelegramStringFormatting
import ManagedAnimationNode
import ContextUI
import TelegramNotices
import TooltipUI
import SliderContextItem

private let titleFont = Font.regular(12.0)
private let subtitleFont = Font.regular(10.0)

private func normalizeValue(_ value: CGFloat) -> CGFloat {
    return round(value * 10.0) / 10.0
}

private class MediaHeaderItemNode: ASDisplayNode {
    private let titleNode: TextNode
    private let subtitleNode: TextNode
    
    override init() {
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        self.subtitleNode = TextNode()
        self.subtitleNode.isUserInteractionEnabled = false
        self.subtitleNode.displaysAsynchronously = false
        
        super.init()
        
        self.isUserInteractionEnabled = false
        
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
    }
    
    func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, theme: PresentationTheme, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameDisplayOrder: PresentationPersonNameOrder, playbackItem: SharedMediaPlaylistItem?, transition: ContainedViewLayoutTransition) -> (NSAttributedString?, NSAttributedString?, Bool) {
        var rateButtonHidden = false
        var titleString: NSAttributedString?
        var subtitleString: NSAttributedString?
        if let playbackItem = playbackItem, let displayData = playbackItem.displayData {
            switch displayData {
                case let .music(title, performer, _, _, _):
                    rateButtonHidden = false
                    let titleText: String = title ?? strings.MediaPlayer_UnknownTrack
                    let subtitleText: String = performer ?? strings.MediaPlayer_UnknownArtist
                    
                    titleString = NSAttributedString(string: titleText, font: titleFont, textColor: theme.rootController.navigationBar.primaryTextColor)
                    subtitleString = NSAttributedString(string: subtitleText, font: subtitleFont, textColor: theme.rootController.navigationBar.secondaryTextColor)
                case let .voice(author, peer):
                    rateButtonHidden = false
                    let titleText: String = author?.displayTitle(strings: strings, displayOrder: nameDisplayOrder) ?? ""
                    let subtitleText: String
                    if let peer = peer {
                        if case let .channel(peer) = peer, case .broadcast = peer.info {
                            subtitleText = strings.MusicPlayer_VoiceNote
                        } else if case .legacyGroup = peer {
                            subtitleText = peer.displayTitle(strings: strings, displayOrder: nameDisplayOrder)
                        } else if case .channel = peer {
                            subtitleText = peer.displayTitle(strings: strings, displayOrder: nameDisplayOrder)
                        } else {
                            subtitleText = strings.MusicPlayer_VoiceNote
                        }
                    } else {
                        subtitleText = strings.MusicPlayer_VoiceNote
                    }
                    
                    titleString = NSAttributedString(string: titleText, font: titleFont, textColor: theme.rootController.navigationBar.primaryTextColor)
                    subtitleString = NSAttributedString(string: subtitleText, font: subtitleFont, textColor: theme.rootController.navigationBar.secondaryTextColor)
                case let .instantVideo(author, peer, timestamp):
                    rateButtonHidden = false
                    let titleText: String = author?.displayTitle(strings: strings, displayOrder: nameDisplayOrder) ?? ""
                    var subtitleText: String
                    
                    if let peer = peer {
                        switch peer {
                        case .legacyGroup, .channel:
                            subtitleText = peer.displayTitle(strings: strings, displayOrder: nameDisplayOrder)
                        default:
                            subtitleText = strings.Message_VideoMessage
                        }
                    } else {
                        subtitleText = strings.Message_VideoMessage
                    }
                    
                    if titleText == subtitleText {
                        subtitleText = humanReadableStringForTimestamp(strings: strings, dateTimeFormat: dateTimeFormat, timestamp: timestamp).string
                    }
                    
                    titleString = NSAttributedString(string: titleText, font: titleFont, textColor: theme.rootController.navigationBar.primaryTextColor)
                    subtitleString = NSAttributedString(string: subtitleText, font: subtitleFont, textColor: theme.rootController.navigationBar.secondaryTextColor)
            }
        }
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)
        
        var titleSideInset: CGFloat = 12.0
        if !rateButtonHidden {
            titleSideInset += 52.0
        }
        
        let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: titleString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: size.width - titleSideInset, height: 100.0), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: subtitleString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: size.width - titleSideInset, height: 100.0), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        
        let _ = titleApply()
        let _ = subtitleApply()
        
        let minimizedTitleOffset: CGFloat = subtitleString == nil ? 6.0 : 0.0
        
        let minimizedTitleFrame = CGRect(origin: CGPoint(x: floor((size.width - titleLayout.size.width) / 2.0), y: 4.0 + minimizedTitleOffset), size: titleLayout.size)
        let minimizedSubtitleFrame = CGRect(origin: CGPoint(x: floor((size.width - subtitleLayout.size.width) / 2.0), y: 20.0), size: subtitleLayout.size)
        
        transition.updateFrame(node: self.titleNode, frame: minimizedTitleFrame)
        transition.updateFrame(node: self.subtitleNode, frame: minimizedSubtitleFrame)
        
        return (titleString, subtitleString, rateButtonHidden)
    }
}

private func generateMaskImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 12.0, height: 2.0), opaque: false, rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        
        let gradientColors = [color.cgColor, color.withAlphaComponent(0.0).cgColor] as CFArray
        
        var locations: [CGFloat] = [0.0, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
        
        context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 12.0, y: 0.0), options: CGGradientDrawingOptions())
    })
}

public final class MediaNavigationAccessoryHeaderNode: ASDisplayNode, ASScrollViewDelegate {
    public static let minimizedHeight: CGFloat = 37.0
    
    private let context: AccountContext
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    private var dateTimeFormat: PresentationDateTimeFormat
    private var nameDisplayOrder: PresentationPersonNameOrder
    
    private let scrollNode: ASScrollNode
    private var initialContentOffset: CGFloat?
    
    private let leftMaskNode: ASImageNode
    private let rightMaskNode: ASImageNode
    
    private let currentItemNode: MediaHeaderItemNode
    private let previousItemNode: MediaHeaderItemNode
    private let nextItemNode: MediaHeaderItemNode
    
    private let closeButton: HighlightableButtonNode
    private let actionButton: HighlightTrackingButtonNode
    private let playPauseIconNode: PlayPauseIconNode
    private let rateButton: AudioRateButton
    private let accessibilityAreaNode: AccessibilityAreaNode
    
    private let scrubbingNode: MediaPlayerScrubbingNode
    
    private var validLayout: (CGSize, CGFloat, CGFloat)?
    
    public var displayScrubber: Bool = true {
        didSet {
            self.scrubbingNode.isHidden = !self.displayScrubber
        }
    }
    
    private let separatorNode: ASDisplayNode
    
    private var tapRecognizer: UITapGestureRecognizer?
    
    public var tapAction: (() -> Void)?
    public var close: (() -> Void)?
    public var setRate: ((AudioPlaybackRate, MediaNavigationAccessoryPanel.ChangeType) -> Void)?
    public var togglePlayPause: (() -> Void)?
    public var playPrevious: (() -> Void)?
    public var playNext: (() -> Void)?
    
    public var getController: (() -> ViewController?)?
    public var presentInGlobalOverlay: ((ViewController) -> Void)?
    
    public var playbackBaseRate: AudioPlaybackRate? = nil {
        didSet {
            guard self.playbackBaseRate != oldValue, let playbackBaseRate = self.playbackBaseRate else {
                return
            }
            self.rateButton.accessibilityLabel = self.strings.VoiceOver_Media_PlaybackRate
            self.rateButton.accessibilityHint = self.strings.VoiceOver_Media_PlaybackRateChange
            self.rateButton.accessibilityValue = playbackBaseRate.stringValue
            
             self.rateButton.setContent(.image(optionsRateImage(rate: playbackBaseRate.stringValue.uppercased(), color: self.theme.rootController.navigationBar.controlColor)))
        }
    }
    
    public var playbackStatus: Signal<MediaPlayerStatus, NoError>? {
        didSet {
            self.scrubbingNode.status = self.playbackStatus
        }
    }
    
    public var playbackItems: (SharedMediaPlaylistItem?, SharedMediaPlaylistItem?, SharedMediaPlaylistItem?)? {
        didSet {
            if !arePlaylistItemsEqual(self.playbackItems?.0, oldValue?.0) || !arePlaylistItemsEqual(self.playbackItems?.1, oldValue?.1) || !arePlaylistItemsEqual(self.playbackItems?.2, oldValue?.2), let layout = validLayout {
                self.updateLayout(size: layout.0, leftInset: layout.1, rightInset: layout.2, transition: .immediate)
            }
        }
    }
    
    private weak var tooltipController: TooltipScreen?
    private let dismissedPromise = ValuePromise<Bool>(false)
    
    public init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        
        self.theme = presentationData.theme
        self.strings = presentationData.strings
        self.dateTimeFormat = presentationData.dateTimeFormat
        self.nameDisplayOrder = presentationData.nameDisplayOrder
        
        self.scrollNode = ASScrollNode()
        
        self.currentItemNode = MediaHeaderItemNode()
        self.previousItemNode = MediaHeaderItemNode()
        self.nextItemNode = MediaHeaderItemNode()
        
        self.leftMaskNode = ASImageNode()
        self.leftMaskNode.contentMode = .scaleToFill
        self.rightMaskNode = ASImageNode()
        self.rightMaskNode.contentMode = .scaleToFill
        
        let maskImage = generateMaskImage(color: self.theme.rootController.navigationBar.opaqueBackgroundColor)
        self.leftMaskNode.image = maskImage
        self.rightMaskNode.image = maskImage
        
        self.closeButton = HighlightableButtonNode()
        self.closeButton.accessibilityLabel = presentationData.strings.VoiceOver_Media_PlaybackStop
        self.closeButton.setImage(PresentationResourcesRootController.navigationPlayerCloseButton(self.theme), for: [])
        self.closeButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -8.0, bottom: -8.0, right: -8.0)
        self.closeButton.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 2.0)
        self.closeButton.displaysAsynchronously = false
        
        self.rateButton = AudioRateButton()
        self.rateButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -4.0, bottom: -8.0, right: -4.0)
        self.rateButton.displaysAsynchronously = false
        
        self.accessibilityAreaNode = AccessibilityAreaNode()
        
        self.actionButton = HighlightTrackingButtonNode()
        self.actionButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -8.0, bottom: -8.0, right: -8.0)
        self.actionButton.displaysAsynchronously = false
        
        self.playPauseIconNode = PlayPauseIconNode()
        self.playPauseIconNode.customColor = self.theme.rootController.navigationBar.accentTextColor
        
        self.scrubbingNode = MediaPlayerScrubbingNode(content: .standard(lineHeight: 2.0, lineCap: .square, scrubberHandle: .none, backgroundColor: .clear, foregroundColor: self.theme.rootController.navigationBar.accentTextColor, bufferingColor: self.theme.rootController.navigationBar.accentTextColor.withAlphaComponent(0.5), chapters: []))
        
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.separatorNode.backgroundColor = theme.rootController.navigationBar.separatorColor
        
        super.init()
        
        self.clipsToBounds = true
        
        self.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.currentItemNode)
        self.scrollNode.addSubnode(self.previousItemNode)
        self.scrollNode.addSubnode(self.nextItemNode)
        
        self.addSubnode(self.closeButton)
        self.addSubnode(self.rateButton)
        self.addSubnode(self.accessibilityAreaNode)
        
        self.actionButton.addSubnode(self.playPauseIconNode)
        self.addSubnode(self.actionButton)
        
        self.closeButton.addTarget(self, action: #selector(self.closeButtonPressed), forControlEvents: .touchUpInside)
        self.actionButton.addTarget(self, action: #selector(self.actionButtonPressed), forControlEvents: .touchUpInside)
        
        self.rateButton.addTarget(self, action: #selector(self.rateButtonPressed), forControlEvents: .touchUpInside)
        self.rateButton.contextAction = { [weak self] sourceNode, gesture in
            self?.openRateMenu(sourceNode: sourceNode, gesture: gesture)
        }
        
        self.addSubnode(self.scrubbingNode)
        
        self.addSubnode(self.separatorNode)
        
        self.actionButton.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.actionButton.layer.removeAnimation(forKey: "opacity")
                    strongSelf.actionButton.alpha = 0.4
                } else {
                    strongSelf.actionButton.alpha = 1.0
                    strongSelf.actionButton.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.scrubbingNode.playerStatusUpdated = { [weak self] status in
            guard let strongSelf = self else {
                return
            }
            if let status = status {
                strongSelf.playbackBaseRate = AudioPlaybackRate(status.baseRate)
            } else {
                strongSelf.playbackBaseRate = .x1
            }
        }
        
        self.scrubbingNode.playbackStatusUpdated = { [weak self] status in
            if let strongSelf = self {
                let paused: Bool
                if let status = status {
                    switch status {
                        case .paused:
                            paused = true
                        case let .buffering(_, whilePlaying, _, _):
                            paused = !whilePlaying
                        case .playing:
                            paused = false
                    }
                } else {
                    paused = true
                }
                strongSelf.playPauseIconNode.enqueueState(paused ? .play : .pause, animated: true)
                strongSelf.actionButton.accessibilityLabel = paused ? strongSelf.strings.VoiceOver_Media_PlaybackPlay : strongSelf.strings.VoiceOver_Media_PlaybackPause
            }
        }
    }
    
    override public func didLoad() {
        super.didLoad()
        
        self.view.disablesInteractiveTransitionGestureRecognizer = true
        self.scrollNode.view.alwaysBounceHorizontal = true
        self.scrollNode.view.delegate = self.wrappedScrollViewDelegate
        self.scrollNode.view.isPagingEnabled = true
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.showsVerticalScrollIndicator = false
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.tapRecognizer = tapRecognizer
        self.view.addGestureRecognizer(tapRecognizer)
    }
    
    public func updatePresentationData(_ presentationData: PresentationData) {
        self.theme = presentationData.theme
        self.strings = presentationData.strings
        self.nameDisplayOrder = presentationData.nameDisplayOrder
        self.dateTimeFormat = presentationData.dateTimeFormat
        
        let maskImage = generateMaskImage(color: self.theme.rootController.navigationBar.opaqueBackgroundColor)
        self.leftMaskNode.image = maskImage
        self.rightMaskNode.image = maskImage
        
        self.closeButton.setImage(PresentationResourcesRootController.navigationPlayerCloseButton(self.theme), for: [])
        self.playPauseIconNode.customColor = self.theme.rootController.navigationBar.accentTextColor
        self.separatorNode.backgroundColor = self.theme.rootController.navigationBar.separatorColor
        self.scrubbingNode.updateContent(.standard(lineHeight: 2.0, lineCap: .square, scrubberHandle: .none, backgroundColor: .clear, foregroundColor: self.theme.rootController.navigationBar.accentTextColor, bufferingColor: self.theme.rootController.navigationBar.accentTextColor.withAlphaComponent(0.5), chapters: []))
        
        if let playbackBaseRate = self.playbackBaseRate {
            self.rateButton.setContent(.image(optionsRateImage(rate: playbackBaseRate.stringValue.uppercased(), color: self.theme.rootController.navigationBar.controlColor)))
        }
        if let (size, leftInset, rightInset) = self.validLayout {
            self.updateLayout(size: size, leftInset: leftInset, rightInset: rightInset, transition: .immediate)
        }
    }
    
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView.isDecelerating {
            self.changeTrack()
        }
        
        self.rateButton.alpha = 0.0
        self.rateButton.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2)
    }
    
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.changeTrack()
        
        self.rateButton.alpha = 1.0
        self.rateButton.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }
    
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else {
            return
        }
        self.changeTrack()
        
        self.rateButton.alpha = 1.0
        self.rateButton.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }
    
    private func changeTrack() {
        guard let initialContentOffset = self.initialContentOffset, abs(initialContentOffset - self.scrollNode.view.contentOffset.x) > self.bounds.width / 2.0 else {
            return
        }
        if self.scrollNode.view.contentOffset.x < initialContentOffset {
            self.playPrevious?()
        } else if self.scrollNode.view.contentOffset.x > initialContentOffset {
            self.playNext?()
        }
    }

    func animateIn(transition: ContainedViewLayoutTransition) {
        guard let (size, _, _) = self.validLayout else {
            return
        }

        transition.animatePositionAdditive(node: self.separatorNode, offset: CGPoint(x: 0.0, y: size.height))
    }

    func animateOut(transition: ContainedViewLayoutTransition) {
        guard let (size, _, _) = self.validLayout else {
            return
        }
        
        self.tooltipController?.dismiss()
        self.dismissedPromise.set(true)

        transition.updatePosition(node: self.separatorNode, position: self.separatorNode.position.offsetBy(dx: 0.0, dy: size.height))
    }
    
    public func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (size, leftInset, rightInset)
        
        let minHeight = MediaNavigationAccessoryHeaderNode.minimizedHeight
        
        let inset: CGFloat = 45.0 + leftInset
        let constrainedSize = CGSize(width: size.width - inset * 2.0, height: size.height)
        let (titleString, subtitleString, rateButtonHidden) = self.currentItemNode.updateLayout(size: constrainedSize, leftInset: leftInset, rightInset: rightInset, theme: self.theme, strings: self.strings, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, playbackItem: self.playbackItems?.0, transition: transition)
        self.accessibilityAreaNode.accessibilityLabel = "\(titleString?.string ?? ""). \(subtitleString?.string ?? "")"
        self.rateButton.isHidden = rateButtonHidden
        
        let _ = self.previousItemNode.updateLayout(size: constrainedSize, leftInset: 0.0, rightInset: 0.0, theme: self.theme, strings: self.strings, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, playbackItem: self.playbackItems?.1, transition: transition)
        let _ = self.nextItemNode.updateLayout(size: constrainedSize, leftInset: 0.0, rightInset: 0.0, theme: self.theme, strings: self.strings, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, playbackItem: self.playbackItems?.2, transition: transition)
        
        let constrainedBounds = CGRect(origin: CGPoint(), size: constrainedSize)
        transition.updateFrame(node: self.scrollNode, frame: constrainedBounds.offsetBy(dx: inset, dy: 0.0))
        
        var contentSize = constrainedSize
        var contentOffset: CGFloat = 0.0
        if self.playbackItems?.1 != nil {
            contentSize.width += constrainedSize.width
            contentOffset = constrainedSize.width
        }
        if self.playbackItems?.2 != nil {
            contentSize.width += constrainedSize.width
        }
        
        self.previousItemNode.frame = constrainedBounds.offsetBy(dx: contentOffset - constrainedSize.width, dy: 0.0)
        self.currentItemNode.frame = constrainedBounds.offsetBy(dx: contentOffset, dy: 0.0)
        self.nextItemNode.frame = constrainedBounds.offsetBy(dx: contentOffset + constrainedSize.width, dy: 0.0)
        
        self.leftMaskNode.frame = CGRect(x: inset, y: 0.0, width: 12.0, height: minHeight)
        self.rightMaskNode.transform = CATransform3DMakeScale(-1.0, 1.0, 1.0)
        self.rightMaskNode.frame = CGRect(x: size.width - inset - 12.0, y: 0.0, width: 12.0, height: minHeight)
        
        if !self.scrollNode.view.isTracking && !self.scrollNode.view.isTracking {
            self.scrollNode.view.contentSize = contentSize
            self.scrollNode.view.contentOffset = CGPoint(x: contentOffset, y: 0.0)
            self.initialContentOffset = contentOffset
        }
        
        let bounds = CGRect(origin: CGPoint(), size: size)
        let closeButtonSize = self.closeButton.measure(CGSize(width: 100.0, height: 100.0))
        transition.updateFrame(node: self.closeButton, frame: CGRect(origin: CGPoint(x: bounds.size.width - 44.0 - rightInset, y: 0.0), size: CGSize(width: 44.0, height: minHeight)))
        let rateButtonSize = CGSize(width: 30.0, height: minHeight)
        transition.updateFrame(node: self.rateButton, frame: CGRect(origin: CGPoint(x: bounds.size.width - 27.0 - closeButtonSize.width - rateButtonSize.width - rightInset, y: -4.0), size: rateButtonSize))
        
        transition.updateFrame(node: self.playPauseIconNode, frame: CGRect(origin: CGPoint(x: 6.0, y: 4.0 + UIScreenPixel), size: CGSize(width: 28.0, height: 28.0)))
        transition.updateFrame(node: self.actionButton, frame: CGRect(origin: CGPoint(x: leftInset, y: 0.0), size: CGSize(width: 40.0, height: 37.0)))
        transition.updateFrame(node: self.scrubbingNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 37.0 - 2.0), size: CGSize(width: size.width, height: 2.0)))
        
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: UIScreenPixel)))
        
        self.accessibilityAreaNode.frame = CGRect(origin: CGPoint(x: self.actionButton.frame.maxX, y: 0.0), size: CGSize(width: self.rateButton.frame.minX - self.actionButton.frame.maxX, height: minHeight))
    }
    
    @objc public func closeButtonPressed() {
        self.close?()
    }
    
    @objc public func rateButtonPressed() {
        var changeType: MediaNavigationAccessoryPanel.ChangeType = .preset
        let nextRate: AudioPlaybackRate
        if let rate = self.playbackBaseRate {
            switch rate {
            case .x0_5, .x2:
                nextRate = .x1
            case .x1:
                nextRate = .x1_5
            case .x1_5:
                nextRate = .x2
            default:
                if rate.doubleValue < 0.5 {
                    nextRate = .x0_5
                } else if rate.doubleValue < 1.0 {
                    nextRate = .x1
                } else if rate.doubleValue < 1.5 {
                    nextRate = .x1_5
                } else if rate.doubleValue < 2.0 {
                    nextRate = .x2
                } else {
                    nextRate = .x1
                }
                changeType = .sliderCommit(rate.doubleValue, nextRate.doubleValue)
            }
        } else {
            nextRate = .x1_5
        }
        self.setRate?(nextRate, changeType)
        
        let frame = self.rateButton.view.convert(self.rateButton.bounds, to: nil)
        
        let _ = (ApplicationSpecificNotice.incrementAudioRateOptionsTip(accountManager: self.context.sharedContext.accountManager)
        |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self, let controller = strongSelf.getController?(), value == 2 {
                let tooltipController = TooltipScreen(account: strongSelf.context.account, sharedContext: strongSelf.context.sharedContext, text: .plain(text: strongSelf.strings.Conversation_AudioRateOptionsTooltip), style: .default, icon: nil, location: .point(frame.offsetBy(dx: 0.0, dy: 4.0), .bottom), displayDuration: .custom(3.0), inset: 3.0, shouldDismissOnTouch: { _, _ in
                    return .dismiss(consume: false)
                })
                controller.present(tooltipController, in: .window(.root))
                strongSelf.tooltipController = tooltipController
            }
        })
    }
    
    private func speedList(strings: PresentationStrings) -> [(String, String, AudioPlaybackRate)] {
        let speedList: [(String, String, AudioPlaybackRate)] = [
            ("0.5x", "0.5x", .x0_5),
            (strings.PlaybackSpeed_Normal, "1x", .x1),
            ("1.5x", "1.5x", .x1_5),
            ("2x", "2x", .x2)
        ]
        return speedList
    }
    
    private func contextMenuSpeedItems(scheduleTooltip: @escaping (MediaNavigationAccessoryPanel.ChangeType?) -> Void) -> Signal<ContextController.Items, NoError> {
        var presetItems: [ContextMenuItem] = []

        let previousRate = self.playbackBaseRate
        let previousValue = self.playbackBaseRate?.doubleValue ?? 1.0
        let sliderValuePromise = ValuePromise<Double?>(nil)
        let sliderItem: ContextMenuItem = .custom(SliderContextItem(minValue: 0.2, maxValue: 2.5, value: previousValue, valueChanged: { [weak self] newValue, finished in
            let newValue = normalizeValue(newValue)
            self?.setRate?(AudioPlaybackRate(newValue), .sliderChange)
            sliderValuePromise.set(newValue)
            if finished {
                scheduleTooltip(.sliderCommit(previousValue, newValue))
            }
        }), true)
        
        let theme = self.context.sharedContext.currentPresentationData.with { $0 }.theme
        for (text, _, rate) in self.speedList(strings: self.strings) {
            let isSelected = self.playbackBaseRate == rate
            presetItems.append(.action(ContextMenuActionItem(text: text, icon: { _ in return nil }, iconSource: ContextMenuActionItemIconSource(size: CGSize(width: 24.0, height: 24.0), signal: sliderValuePromise.get()
            |> map { value in
                if isSelected && value == nil {
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
                } else {
                    return nil
                }
            }), action: { [weak self] _, f in
                scheduleTooltip(nil)
                f(.default)
                
                if let previousRate, previousRate.isPreset {
                    self?.setRate?(rate, .preset)
                } else {
                    self?.setRate?(rate, .sliderCommit(previousValue, rate.doubleValue))
                }
            })))
        }

        return .single(ContextController.Items(content: .twoLists(presetItems, [sliderItem])))
    }
    
    private func openRateMenu(sourceNode: ASDisplayNode, gesture: ContextGesture?) {
        guard let controller = self.getController?() else {
            return
        }
        var scheduledTooltip: MediaNavigationAccessoryPanel.ChangeType?
        let items = self.contextMenuSpeedItems(scheduleTooltip: { change in
            scheduledTooltip = change
        })
        let contextController = ContextController(presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, source: .reference(HeaderContextReferenceContentSource(controller: controller, sourceNode: self.rateButton.referenceNode, shouldBeDismissed: self.dismissedPromise.get())), items: items, gesture: gesture)
        contextController.dismissed = { [weak self] in
            if let scheduledTooltip, let self, let rate = self.playbackBaseRate {
                self.setRate?(rate, scheduledTooltip)
            }
        }
        self.presentInGlobalOverlay?(contextController)
    }
    
    @objc public func actionButtonPressed() {
        self.togglePlayPause?()
    }
    
    @objc public func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.tapAction?()
        }
    }
}

private enum PlayPauseIconNodeState: Equatable {
    case play
    case pause
}

private final class PlayPauseIconNode: ManagedAnimationNode {
    private let duration: Double = 0.35
    private var iconState: PlayPauseIconNodeState = .pause
    
    init() {
        super.init(size: CGSize(width: 28.0, height: 28.0))
        
        self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
    }
    
    func enqueueState(_ state: PlayPauseIconNodeState, animated: Bool) {
        guard self.iconState != state else {
            return
        }
        
        let previousState = self.iconState
        self.iconState = state
        
        switch previousState {
            case .pause:
                switch state {
                    case .play:
                        if animated {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 83), duration: self.duration))
                        } else {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 0), duration: 0.01))
                        }
                    case .pause:
                        break
                }
            case .play:
                switch state {
                    case .pause:
                        if animated {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 41), duration: self.duration))
                        } else {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
                        }
                    case .play:
                        break
                }
        }
    }
}

private func optionsRateImage(rate: String, color: UIColor = .white) -> UIImage? {
    let isLarge = "".isEmpty
    return generateImage(isLarge ? CGSize(width: 30.0, height: 30.0) : CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
        UIGraphicsPushContext(context)

        context.clear(CGRect(origin: CGPoint(), size: size))

        if let image = generateTintedImage(image: UIImage(bundleImageName: isLarge ? "Chat/Context Menu/Playspeed30" : "Chat/Context Menu/Playspeed24"), color: color) {
            image.draw(at: CGPoint(x: 0.0, y: 0.0))
        }

        let string = NSMutableAttributedString(string: rate, font: Font.with(size: isLarge ? 11.0 : 10.0, design: .round, weight: .semibold), textColor: color)

        var offset = CGPoint(x: 1.0, y: 0.0)
        if rate.count >= 3 {
            if rate == "0.5x" {
                string.addAttribute(.kern, value: -0.8 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.5
            } else {
                string.addAttribute(.kern, value: -0.5 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.3
            }
        } else {
            offset.x += -0.3
        }

        if !isLarge {
            offset.x *= 0.5
            offset.y *= 0.5
        }

        let boundingRect = string.boundingRect(with: size, options: [], context: nil)
        string.draw(at: CGPoint(x: offset.x + floor((size.width - boundingRect.width) / 2.0), y: offset.y + floor((size.height - boundingRect.height) / 2.0)))

        UIGraphicsPopContext()
    })
}

public final class AudioRateButton: HighlightableButtonNode {
    public enum Content {
        case image(UIImage?)
    }

    public let referenceNode: ContextReferenceContentNode
    let containerNode: ContextControllerSourceNode
    private let iconNode: ASImageNode

    public var contextAction: ((ASDisplayNode, ContextGesture?) -> Void)?

    private let wide: Bool

    public init(wide: Bool = false) {
        self.wide = wide

        self.referenceNode = ContextReferenceContentNode()
        self.containerNode = ContextControllerSourceNode()
        self.containerNode.animateScale = false
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.contentMode = .scaleToFill

        super.init()

        self.containerNode.addSubnode(self.referenceNode)
        self.referenceNode.addSubnode(self.iconNode)
        self.addSubnode(self.containerNode)

        self.containerNode.shouldBegin = { [weak self] location in
            guard let strongSelf = self, let _ = strongSelf.contextAction else {
                return false
            }
            return true
        }
        self.containerNode.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                return
            }
            strongSelf.contextAction?(strongSelf.containerNode, gesture)
        }

        self.containerNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: 26.0, height: 44.0))
        self.referenceNode.frame = self.containerNode.bounds

        if let image = self.iconNode.image {
            self.iconNode.frame = CGRect(origin: CGPoint(x: floor((self.containerNode.bounds.width - image.size.width) / 2.0), y: floor((self.containerNode.bounds.height - image.size.height) / 2.0)), size: image.size)
        }

        self.hitTestSlop = UIEdgeInsets(top: 0.0, left: -4.0, bottom: 0.0, right: -4.0)
    }

    private var content: Content?
    public func setContent(_ content: Content, animated: Bool = false) {
        if animated {
            if let snapshotView = self.referenceNode.view.snapshotContentTree() {
                snapshotView.frame = self.referenceNode.frame
                self.view.addSubview(snapshotView)

                snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                    snapshotView?.removeFromSuperview()
                })
                snapshotView.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)

                self.iconNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                self.iconNode.layer.animateScale(from: 0.1, to: 1.0, duration: 0.3)
            }

            switch content {
                case let .image(image):
                    if let image = image {
                        self.iconNode.frame = CGRect(origin: CGPoint(x: floor((self.containerNode.bounds.width - image.size.width) / 2.0), y: floor((self.containerNode.bounds.height - image.size.height) / 2.0)), size: image.size)
                    }

                    self.iconNode.image = image
                    self.iconNode.isHidden = false
            }
        } else {
            self.content = content
            switch content {
                case let .image(image):
                    if let image = image {
                        self.iconNode.frame = CGRect(origin: CGPoint(x: floor((self.containerNode.bounds.width - image.size.width) / 2.0), y: floor((self.containerNode.bounds.height - image.size.height) / 2.0)), size: image.size)
                    }

                    self.iconNode.image = image
                    self.iconNode.isHidden = false
            }
        }
    }

    public override func didLoad() {
        super.didLoad()
        self.view.isOpaque = false
    }

    public override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: wide ? 32.0 : 22.0, height: 44.0)
    }

    func onLayout() {
    }
}

private final class HeaderContextReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceNode: ContextReferenceContentNode

    var shouldBeDismissed: Signal<Bool, NoError>
    
    init(controller: ViewController, sourceNode: ContextReferenceContentNode, shouldBeDismissed: Signal<Bool, NoError>) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.shouldBeDismissed = shouldBeDismissed
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
